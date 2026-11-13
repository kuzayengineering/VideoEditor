package com.kuzayengineering.video_editor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.media3.common.MimeTypes
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.File
import java.util.concurrent.Executors

/** Everything the export needs, sent from the Flutter side. */
data class ExportRequest(
    val segments: List<Segment>,
    val audioTracks: List<List<Segment>>,
    val texts: List<TextLayer>,
    val dips: List<Dip>,
    val blends: BlendInput?,
    val pips: List<PipLayer>,
    /** If blending the transitions fails: the same video with every
     * transition as a dip through black (what older versions did). */
    val fallbackSegments: List<Segment>?,
    val fallbackDips: List<Dip>?,
    val width: Int,
    val height: Int,
    val frameRate: Double,
    val bitrate: Int,
    val codec: String, // "hevc" or "h264"
    val range: String, // "hlg", "hdr10" or "sdr"
    val folder: String?, // tree URI, or null for Movies/Video Editor
    val fileName: String,
    val expectedFrames: Long,
    val expectedDurationUs: Long,
    /** The recording date to give the video (ms since 1970), if chosen. */
    val createdAtMs: Long?,
    /** False on the automatic second try after a stall: no frame dropping
     * at all (see CompositionFactory). */
    val frameCap: Boolean = true,
) {
    companion object {
        fun from(m: Map<String, Any?>) = ExportRequest(
            segments = @Suppress("UNCHECKED_CAST") Segment.listFrom(m["segments"] as List<Map<String, Any?>>),
            audioTracks = @Suppress("UNCHECKED_CAST") (m["audioTracks"] as List<List<Map<String, Any?>>>?)
                ?.map { Segment.listFrom(it) } ?: emptyList(),
            texts = @Suppress("UNCHECKED_CAST") (m["texts"] as List<Map<String, Any?>>?)
                ?.map { TextLayer.from(it) } ?: emptyList(),
            dips = (m["dips"] as List<*>?)?.map { Dip.from(it as Map<*, *>) } ?: emptyList(),
            blends = BlendInput.from(m),
            pips = PipLayer.listFrom(m),
            fallbackSegments = @Suppress("UNCHECKED_CAST") (m["fallbackSegments"] as List<Map<String, Any?>>?)
                ?.let { Segment.listFrom(it) },
            fallbackDips = (m["fallbackDips"] as List<*>?)?.map { Dip.from(it as Map<*, *>) },
            width = (m["width"] as Number).toInt(),
            height = (m["height"] as Number).toInt(),
            frameRate = (m["frameRate"] as Number).toDouble(),
            bitrate = (m["bitrate"] as Number).toInt(),
            codec = m["codec"] as String,
            range = m["range"] as String,
            folder = m["folder"] as String?,
            fileName = m["fileName"] as String,
            expectedFrames = (m["expectedFrames"] as Number).toLong(),
            expectedDurationUs = (m["expectedDurationUs"] as Number).toLong(),
            createdAtMs = (m["createdAtMs"] as Number?)?.toLong(),
        )
    }
}

/**
 * Runs exports. Lives for the whole app process, so an export keeps going and
 * can be checked on even if the editor screen is closed.
 *
 * Media3's Transformer processes frames one by one from their timestamps and
 * waits for the encoder, never for a clock, so a slow or busy phone makes the
 * export take longer but cannot drop or freeze frames.
 */
object ExportManager {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    @Volatile private var state = "idle"
    @Volatile private var fraction = 0.0
    @Volatile private var message: String? = null
    @Volatile private var location: String? = null
    @Volatile private var verification: Map<String, Any?>? = null

    private var transformer: Transformer? = null
    private var request: ExportRequest? = null
    private var tempFile: File? = null
    private var service: ExportService? = null
    internal var pending: ExportRequest? = null

    fun status(): Map<String, Any?> = mapOf(
        "state" to state,
        "fraction" to fraction,
        "message" to message,
        "location" to location,
        "verification" to verification,
    )

    val isBusy: Boolean get() = state == "preparing" || state == "running" || state == "finishing"

    fun start(context: Context, req: ExportRequest) {
        if (isBusy) throw IllegalStateException("An export is already running.")
        state = "preparing"
        fraction = 0.0
        message = null
        location = null
        verification = null
        fallbackNote = ""
        pending = req
        val intent = Intent(context, ExportService::class.java)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
    }

    /** Called by the service once it is in the foreground. */
    internal fun run(svc: ExportService, req: ExportRequest) {
        service = svc
        request = req
        val ctx = svc.applicationContext
        val temp = File(ctx.cacheDir, "export-in-progress.mp4").apply { delete() }
        tempFile = temp

        try {
            val maxSourceFps = req.segments.maxOf { it.frameRate }
            // HDR inputs stay HDR (Media3 keeps the clips' own HDR format), or
            // are tone-mapped on the graphics chip when SDR is chosen.
            val hdrMode = if (req.range == "sdr") {
                Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
            } else {
                Composition.HDR_MODE_KEEP_HDR
            }
            val composition = CompositionFactory.build(
                req.segments, req.width, req.height,
                if (req.frameCap) Math.round(req.frameRate).toInt() else null, hdrMode,
                audioTracks = req.audioTracks,
                withGain = true,
                texts = req.texts,
                dips = req.dips,
                blends = req.blends,
                pips = req.pips,
            )

            val encoders = DefaultEncoderFactory.Builder(ctx)
                .setRequestedVideoEncoderSettings(
                    VideoEncoderSettings.Builder()
                        .setBitrate(req.bitrate)
                        .setBitrateMode(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
                        .build()
                )
                .setEnableFallback(true)
                .build()

            // Media3 is driven from a thread of its own (not the app's main
            // thread): its progress question waits for an answer, so if the
            // export ever got stuck the whole app would freeze with it.
            val thread = android.os.HandlerThread("export").apply { start() }
            exportThread?.quitSafely()
            exportThread = thread
            val work = Handler(thread.looper)
            this.work = work
            val t = Transformer.Builder(ctx)
                .setLooper(thread.looper)
                .setVideoMimeType(if (req.codec == "h264") MimeTypes.VIDEO_H264 else MimeTypes.VIDEO_H265)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .setEncoderFactory(encoders)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        main.post { if (transformer != null && transformer === tRef) onEncoded() }
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException,
                    ) {
                        main.post { if (transformer != null && transformer === tRef) failedWith(exportException) }
                    }

                    fun failedWith(exportException: ExportException) {
                        val fallback = req.fallbackSegments
                        if ((req.blends != null || req.pips.isNotEmpty()) && fallback != null) {
                            // Mixing the clips didn't work on this phone: try
                            // again with simple dips through black.
                            transformer = null
                            fallbackNote = "\n\nTransitions are shown as fades " +
                                "through black and picture in picture is left out, " +
                                "because layering the clips failed:\n" +
                                TransitionRenderer.describe(exportException)
                            main.post {
                                run(svc, req.copy(
                                    segments = fallback,
                                    dips = req.fallbackDips ?: emptyList(),
                                    blends = null,
                                    pips = emptyList(),
                                    fallbackSegments = null,
                                ))
                            }
                            return
                        }
                        fail(
                            "Export failed:\n" + TransitionRenderer.describe(exportException) +
                                if (fallbackNote.isNotEmpty()) {
                                    "\n\n(This was the second try.)$fallbackNote"
                                } else {
                                    ""
                                }
                        )
                    }
                })
                .build()
            tRef = t
            transformer = t
            state = "running"
            message = if (maxSourceFps + 0.5 < req.frameRate) {
                "Encoding (your clips are ${"%.0f".format(maxSourceFps)} fps, so that rate is kept)"
            } else "Encoding"
            lastProgress = -1
            lastProgressAt = android.os.SystemClock.elapsedRealtime()
            work.post {
                try {
                    t.start(composition, temp.absolutePath)
                } catch (e: Exception) {
                    main.post { fail("Export could not start: ${e.message ?: e}") }
                    return@post
                }
                pollProgress(t)
            }
            main.postDelayed(::watchdog, 2000)
        } catch (e: Exception) {
            fail("Export could not start: ${e.message ?: e}")
        }
    }

    private val holder = ProgressHolder()
    private var exportThread: android.os.HandlerThread? = null
    @Volatile private var work: Handler? = null
    /** The current export's Transformer, for its callbacks to check against. */
    @Volatile private var tRef: Transformer? = null

    /** Added to the result when the transitions had to be simplified. */
    private var fallbackNote = ""

    // Stall watchdog: when the progress hasn't moved for a while, the export
    // is stopped with a description of what it was making, rather than
    // sitting at the same percentage for ever.
    @Volatile private var lastProgress = -1
    @Volatile private var lastProgressAt = 0L
    private val stallMs = 90_000L

    /** On the export's own thread: asks Media3 how far it is. */
    private fun pollProgress(t: Transformer) {
        if (tRef !== t || state != "running") return
        if (t.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
            val p = holder.progress
            fraction = (p / 100.0).coerceIn(0.0, 0.97)
            if (p != lastProgress) {
                lastProgress = p
                lastProgressAt = android.os.SystemClock.elapsedRealtime()
                main.post { service?.updateNotification((fraction * 100).toInt(), "Exporting video") }
            }
        }
        work?.postDelayed({ pollProgress(t) }, 500)
    }

    /**
     * On the main thread: when the progress hasn't moved for a while (or
     * Media3 stopped answering), the export is stopped with a description
     * of what it was making, instead of sitting there for ever.
     */
    private fun watchdog() {
        val t = transformer ?: return
        if (state != "running") return
        if (android.os.SystemClock.elapsedRealtime() - lastProgressAt > stallMs) {
            val details = describe()
            val at = lastProgress
            // Stop it on its own thread (it may never answer); forget it here.
            work?.post { try { t.cancel() } catch (_: Exception) {} }
            exportThread?.quitSafely()
            exportThread = null
            val req = request
            val svc = service
            if (req != null && svc != null && req.frameCap) {
                // Second try, with no frame dropping at all.
                transformer = null
                tRef = null
                fallbackNote += "\n\n(The first try stalled at $at%; this was the second try.)"
                message = "Trying again (the first try got stuck at $at%)…"
                run(svc, req.copy(frameCap = false))
                return
            }
            fail(
                "The export stopped making progress at $at% and was stopped. " +
                    "Please copy these details and send them:\n$details"
            )
            return
        }
        main.postDelayed(::watchdog, 2000)
    }

    /** What the export was made of (for reports of stuck exports). */
    private fun describe(): String {
        val r = request ?: return "(no details)"
        fun ms(us: Long) = "${us / 1000}ms"
        fun seg(x: Segment) = buildString {
            append(x.source.substringAfterLast('/').take(24))
            append(" ").append(ms(x.inUs)).append("–").append(ms(x.outUs))
            if (Math.abs(x.speed - 1.0) > 0.001) append(" ×").append(x.speed)
            if (x.hasEffects) append(" fx")
            if (x.fx != null) append(" sound-fx")
            if (x.fadeInUs > 0 || x.fadeOutUs > 0) append(" fade")
            if (x.startUs > 0) append(" @").append(ms(x.startUs))
            if (!x.hasAudio) append(" no-sound")
        }
        return buildString {
            append("size ${r.width}x${r.height} ${r.frameRate}fps ${r.codec} ${r.range}; ")
            append("expected ${ms(r.expectedDurationUs)}, ${r.expectedFrames} frames\n")
            append("video: ").append(r.segments.joinToString("; ") { seg(it) }).append("\n")
            r.audioTracks.forEachIndexed { i, t ->
                append("sound ${i + 1}: ").append(t.joinToString("; ") { seg(it) }).append("\n")
            }
            if (!r.frameCap) append("(second try, no frame dropping)\n")
            append("texts ${r.texts.size}, dips ${r.dips.size}, pip ${r.pips.size}, ")
            append("blends ${if (r.blends != null) "yes" else "no"}")
        }
    }

    private fun onEncoded() {
        transformer = null
        state = "finishing"
        fraction = 0.98
        message = "Checking and saving the video…"
        service?.updateNotification(98, "Saving video")
        val req = request ?: return
        val temp = tempFile ?: return
        val ctx = service?.applicationContext ?: return
        io.execute {
            try {
                req.createdAtMs?.let { Mp4Dates.set(temp, it) }
                verification = verify(temp, req)
                location = saveToDestination(ctx, temp, req)
                temp.delete()
                main.post { finish("done", "Saved to $location$fallbackNote") }
            } catch (e: Exception) {
                main.post { fail("Could not save the video: ${e.message ?: e}") }
            }
        }
    }

    private fun verify(file: File, req: ExportRequest): Map<String, Any?> {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(file.absolutePath)
            var track = -1
            var durationUs = 0L
            var isHdr: Boolean? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                    track = i
                    if (f.containsKey(MediaFormat.KEY_DURATION)) durationUs = f.getLong(MediaFormat.KEY_DURATION)
                    if (f.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                        val tr = f.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
                        isHdr = tr == 6 || tr == 7
                    }
                }
            }
            var frames = 0L
            if (track >= 0) {
                ex.selectTrack(track)
                while (ex.sampleTime >= 0) {
                    frames++
                    ex.advance()
                }
            }
            return mapOf(
                "expectedFrames" to req.expectedFrames,
                "actualFrames" to frames,
                "expectedDurationUs" to req.expectedDurationUs,
                "actualDurationUs" to durationUs,
                "isHdr" to isHdr,
            )
        } finally {
            ex.release()
        }
    }

    private fun saveToDestination(ctx: Context, file: File, req: ExportRequest): String {
        val resolver = ctx.contentResolver
        val folder = req.folder
        if (folder != null) {
            val tree = Uri.parse(folder)
            val parent = DocumentsContract.buildDocumentUriUsingTree(
                tree, DocumentsContract.getTreeDocumentId(tree))
            val target = DocumentsContract.createDocument(resolver, parent, "video/mp4", req.fileName)
                ?: throw IllegalStateException("The chosen folder can't be written to.")
            resolver.openOutputStream(target)!!.use { out -> file.inputStream().use { it.copyTo(out, 1 shl 20) } }
            val name = Uri.decode(DocumentsContract.getTreeDocumentId(tree)).substringAfter(':')
            return "$name/${req.fileName}"
        }
        val relative = "${Environment.DIRECTORY_MOVIES}/Video Editor"
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, req.fileName)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, relative)
            put(MediaStore.Video.Media.IS_PENDING, 1)
            req.createdAtMs?.let { put(MediaStore.Video.Media.DATE_TAKEN, it) }
        }
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Couldn't create the file in Movies.")
        try {
            resolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out, 1 shl 20) } }
            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return "$relative/${req.fileName}"
    }

    fun cancel() {
        main.post {
            if (!isBusy) return@post
            val t = transformer
            work?.post { try { t?.cancel() } catch (_: Exception) {} }
            transformer = null
            tempFile?.delete()
            finish("cancelled", "Export cancelled.")
        }
    }

    internal fun fail(text: String) {
        transformer = null
        tRef = null
        tempFile?.delete()
        finish("failed", text)
    }

    private fun finish(newState: String, text: String) {
        state = newState
        message = text
        if (newState == "done") fraction = 1.0
        service?.finish(newState == "done", text)
        service = null
    }
}

/**
 * A foreground service: Android's official way to say "important work in
 * progress". It shows a progress notification and keeps the export running
 * when the app is in the background or the screen is off.
 */
class ExportService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val req = ExportManager.pending
        ExportManager.pending = null
        startInForeground()
        if (req == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "VideoEditor:export")
            .apply { acquire(6 * 60 * 60 * 1000L) }
        ExportManager.run(this, req)
        return START_NOT_STICKY
    }

    private fun channel(): String {
        val id = "export"
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(id) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(id, "Video export", NotificationManager.IMPORTANCE_LOW))
            }
        }
        return id
    }

    private fun builder(): Notification.Builder {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel())
        else @Suppress("DEPRECATION") Notification.Builder(this))
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentIntent(open)
            .setOnlyAlertOnce(true)
    }

    private fun startInForeground() {
        val n = builder().setContentTitle("Exporting video").setProgress(100, 0, true).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 35) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING)
        } else if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    fun updateNotification(percent: Int, title: String) {
        val n = builder().setContentTitle(title).setContentText("$percent%")
            .setProgress(100, percent, false).setOngoing(true).build()
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, n)
    }

    fun finish(success: Boolean, text: String) {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_DETACH)
        val n = builder()
            .setSmallIcon(if (success) android.R.drawable.stat_sys_upload_done else android.R.drawable.stat_notify_error)
            .setContentTitle(if (success) "Export complete" else "Export stopped")
            .setContentText(text)
            .setAutoCancel(true)
            .build()
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, n)
        stopSelf()
    }

    /** Android 15+: called if the daily time limit for this kind of work runs out. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        ExportManager.fail("Android stopped the export because it ran too long.")
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }

    companion object {
        private const val NOTIFICATION_ID = 7
    }
}

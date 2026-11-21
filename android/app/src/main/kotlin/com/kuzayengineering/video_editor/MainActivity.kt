package com.kuzayengineering.video_editor

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Bridge between the Flutter screens and Android's media features.
 *
 * All slow work (reading files, making thumbnails) happens on background
 * threads; answers are always delivered back on the main thread.
 */
class MainActivity : FlutterActivity() {
    private val io = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    private val preview by lazy { PreviewManager(applicationContext) }
    private val audioPlayers by lazy { ClipAudioPlayers(applicationContext) }

    /** Picture-in-picture players for the preview, by texture id. */
    private val overlays = HashMap<Long, OverlayPreview>()
    private var textures: io.flutter.view.TextureRegistry? = null

    private var pendingPick: MethodChannel.Result? = null
    /** Waiting for the answer to the video-access question. */
    private val afterVideoAccess = mutableListOf<() -> Unit>()
    private var askedVideoAccess = false
    private var pendingFolder: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        CompositionFactory.context = applicationContext
        textures = flutterEngine.renderer
        flutterEngine.platformViewsController.registry
            .registerViewFactory(PreviewViewFactory.VIEW_TYPE, PreviewViewFactory(preview))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ve/engine")
            .setMethodCallHandler(::onCall)
    }

    override fun onDestroy() {
        // An export keeps running in its own service; only the preview goes.
        preview.release()
        audioPlayers.releaseAll()
        overlays.values.forEach { it.release() }
        overlays.clear()
        super.onDestroy()
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                // Anything at all (out of memory included) is reported to the
                // app as an error message instead of closing it.
                main.post { result.error("engine", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickVideos" -> pickVideos(result)
            "realFileName" -> {
                val source = call.argument<String>("source")!!
                withVideoAccess { result.success(realFileName(Uri.parse(source))) }
            }
            "pickAudio" -> pickAudio(result)
            "reverse" -> {
                val source = call.argument<String>("source")!!
                val inUs = call.argument<Number>("inUs")!!.toLong()
                val outUs = call.argument<Number>("outUs")!!.toLong()
                val output = call.argument<String>("output")!!
                background(result) {
                    Reverser.reverse(applicationContext, source, inUs, outUs, output)
                    output
                }
            }
            "reverseProgress" -> result.success(Reverser.progress)
            "speechAudio" -> {
                val source = call.argument<String>("source")!!
                val inUs = (call.argument<Number>("inUs")!!).toLong()
                val outUs = (call.argument<Number>("outUs")!!).toLong()
                val output = call.argument<String>("output")!!
                background(result) {
                    SpeechAudio.write(applicationContext, source, inUs, outUs, output)
                    null
                }
            }
            "waveform" -> {
                val source = call.argument<String>("source")!!
                background(result) { Waveform.peaks(applicationContext, source) }
            }
            "audioOpen" -> {
                audioPlayers.open(call.argument<Int>("id")!!, call.argument<String>("source")!!)
                result.success(null)
            }
            "audioSeek" -> {
                audioPlayers.seek(call.argument<Int>("id")!!, call.argument<Number>("sourceUs")!!.toLong())
                result.success(null)
            }
            "audioPlay" -> { audioPlayers.play(call.argument<Int>("id")!!); result.success(null) }
            "audioPause" -> { audioPlayers.pause(call.argument<Int>("id")!!); result.success(null) }
            "audioVolume" -> {
                audioPlayers.volume(call.argument<Int>("id")!!, call.argument<Number>("volume")!!.toDouble())
                result.success(null)
            }
            "audioRate" -> {
                audioPlayers.rate(call.argument<Int>("id")!!, call.argument<Number>("rate")!!.toDouble())
                result.success(null)
            }
            "audioEffects" -> {
                audioPlayers.effects(
                    call.argument<Int>("id")!!,
                    FxSpec.from(call.argument<Map<String, Any?>>("fx")) ?: FxSpec.NONE,
                )
                result.success(null)
            }
            "audioRelease" -> { audioPlayers.release(call.argument<Int>("id")!!); result.success(null) }
            "previewVolume" -> {
                preview.setVolume(call.argument<Number>("volume")!!.toDouble())
                result.success(null)
            }
            "pickFolder" -> pickFolder(result)
            "deleteThumbnails" -> {
                val sources = call.argument<List<String>>("sources") ?: emptyList()
                background(result) {
                    val dir = java.io.File(cacheDir, "thumbnails")
                    val keys = sources.map { Integer.toHexString(it.hashCode()) + "_" }
                    dir.listFiles()?.forEach { f -> if (keys.any { f.name.startsWith(it) }) f.delete() }
                    null
                }
            }
            "missingSources" -> {
                val sources = call.argument<List<String>>("sources") ?: emptyList()
                background(result) { MediaFiles.missing(applicationContext, sources) }
            }
            "mediaFilesIn" -> {
                val folder = call.argument<String>("folder")!!
                background(result) { MediaFiles.list(applicationContext, folder) }
            }
            "probe" -> {
                val source = call.argument<String>("source")!!
                background(result) { MediaProbe.probe(applicationContext, source) }
            }
            "thumbnails" -> {
                val source = call.argument<String>("source")!!
                val times = call.argument<List<Number>>("timesUs")!!.map { it.toLong() }
                val height = call.argument<Int>("height") ?: 120
                background(result) {
                    MediaProbe.thumbnails(applicationContext, source, times, height)
                }
            }
            "previewSetTimeline" -> {
                preview.setTimeline(
                    Segment.listFrom(call.argument<List<Map<String, Any?>>>("segments")!!),
                    call.argument<Int>("canvasWidth") ?: 1920,
                    call.argument<Int>("canvasHeight") ?: 1080,
                    (call.arguments as? Map<*, *>)?.let { BlendInput.from(it) },
                )
                result.success(null)
            }
            "previewPlay" -> { preview.play(); result.success(null) }
            "overlayCreate" -> {
                val o = OverlayPreview(applicationContext, textures!!.createSurfaceProducer())
                overlays[o.textureId] = o
                result.success(o.textureId)
            }
            "overlayOpen" -> {
                val o = overlays[(call.argument<Number>("id")!!).toLong()]
                result.success(
                    o?.open(
                        call.argument<String>("source")!!,
                        (call.argument<Number>("inUs")!!).toLong(),
                        (call.argument<Number>("outUs")!!).toLong(),
                        (call.argument<Number>("speed") ?: 1.0).toDouble(),
                        call.argument<Boolean>("cutout") ?: false,
                    ) ?: 0
                )
            }
            "overlaySeek" -> {
                overlays[(call.argument<Number>("id")!!).toLong()]?.seek(
                    (call.argument<Number>("offsetUs")!!).toLong(),
                    call.argument<Boolean>("exact") ?: true,
                )
                result.success(null)
            }
            "overlayPlay" -> {
                overlays[(call.argument<Number>("id")!!).toLong()]?.play()
                result.success(null)
            }
            "overlayPause" -> {
                overlays[(call.argument<Number>("id")!!).toLong()]?.pause()
                result.success(null)
            }
            "overlayVolume" -> {
                overlays[(call.argument<Number>("id")!!).toLong()]
                    ?.setVolume((call.argument<Number>("volume")!!).toDouble())
                result.success(null)
            }
            "overlayRelease" -> {
                overlays.remove((call.argument<Number>("id")!!).toLong())?.release()
                result.success(null)
            }
            "previewGrades" -> {
                val raw = call.argument<Map<String, List<Number>>>("grades") ?: emptyMap()
                preview.setGrades(
                    raw.entries.associate { (k, v) ->
                        k.toInt() to FloatArray(v.size) { v[it].toFloat() }
                    }
                )
                result.success(null)
            }
            "previewScrubbing" -> {
                preview.setScrubbing(call.argument<Boolean>("on") ?: false)
                result.success(null)
            }
            "previewPause" -> { preview.pause(); result.success(null) }
            // While exporting: free the preview's video decoders (the editor
            // sends its timeline again afterwards).
            "previewSuspend" -> { preview.release(); result.success(null) }
            "previewSeek" -> {
                preview.seek(
                    (call.argument<Number>("timeUs")!!).toLong(),
                    call.argument<Boolean>("exact") ?: true,
                    (call.argument<Number>("toleranceUs"))?.toLong() ?: 0L,
                )
                result.success(null)
            }
            "previewPosition" -> result.success(preview.positionUs())
            "renderTransition" -> {
                TransitionRenderer.render(this, call.arguments as Map<*, *>) { error ->
                    result.success(mapOf("ok" to (error == null), "error" to error))
                }
            }
            "startExport" -> {
                @Suppress("UNCHECKED_CAST")
                val request = ExportRequest.from(call.arguments as Map<String, Any?>)
                askForNotifications()
                try {
                    ExportManager.start(this, request)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("export", e.message ?: e.toString(), null)
                }
            }
            "exportStatus" -> result.success(ExportManager.status())
            "cancelExport" -> { ExportManager.cancel(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------------------
    // Choosing videos and folders
    // -------------------------------------------------------------------------

    private fun pickVideos(result: MethodChannel.Result) {
        pendingPick?.success(emptyList<Any>())
        pendingPick = result
        val intent = if (Build.VERSION.SDK_INT >= 33) {
            // The modern photo/video picker (looks like the gallery).
            Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                type = "video/*"
                putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, MediaStore.getPickImagesMaxLimit())
            }
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "video/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_PICK_VIDEOS)
    }

    /** Music, sound effects, or the sound of other videos. */
    private fun pickAudio(result: MethodChannel.Result) {
        pendingPick?.success(emptyList<Any>())
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("audio/*", "video/*"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_PICK_VIDEOS)
    }

    private fun pickFolder(result: MethodChannel.Result) {
        pendingFolder?.success(null)
        pendingFolder = result
        @Suppress("DEPRECATION")
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQUEST_PICK_FOLDER)
    }

    @Deprecated("Uses the classic activity result API, which FlutterActivity supports.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_PICK_VIDEOS -> {
                val result = pendingPick ?: return
                pendingPick = null
                if (resultCode != Activity.RESULT_OK || data == null) {
                    result.success(emptyList<Any>())
                    return
                }
                val uris = mutableListOf<Uri>()
                data.clipData?.let { clip ->
                    for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
                }
                if (uris.isEmpty()) data.data?.let { uris.add(it) }
                result.success(uris.map { uri ->
                    // Keep access after the app restarts, so drafts still work.
                    try {
                        contentResolver.takePersistableUriPermission(
                            uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    } catch (_: SecurityException) {
                    }
                    mapOf("source" to uri.toString(), "name" to displayName(uri))
                })
            }
            REQUEST_PICK_FOLDER -> {
                val result = pendingFolder ?: return
                pendingFolder = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    result.success(null)
                    return
                }
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                } catch (_: SecurityException) {
                }
                result.success(uri.toString())
            }
        }
    }

    private fun videoPermission() =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_VIDEO
        else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun hasVideoAccess() =
        checkSelfPermission(videoPermission()) == PackageManager.PERMISSION_GRANTED

    /**
     * Runs [then] once the user has answered the video-access question
     * (asked at most once per app run; used only to look up the real names
     * of videos picked with the photo picker, which hides them).
     */
    private fun withVideoAccess(then: () -> Unit) {
        if (hasVideoAccess() || askedVideoAccess) {
            then()
            return
        }
        afterVideoAccess += then
        if (afterVideoAccess.size == 1) {
            askedVideoAccess = true
            requestPermissions(arrayOf(videoPermission()), REQUEST_VIDEO_ACCESS)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_VIDEO_ACCESS) {
            val waiting = afterVideoAccess.toList()
            afterVideoAccess.clear()
            waiting.forEach { it() }
        }
    }

    /**
     * The video's real file name (e.g. PXL_20261120_153012345.mp4). The
     * photo picker only gives a number for privacy; with video access the
     * real name is looked up in the phone's media library by that number.
     */
    private fun realFileName(uri: Uri): String? {
        val id = uri.lastPathSegment?.toLongOrNull()
        if (id != null && uri.authority == MediaStore.AUTHORITY && hasVideoAccess()) {
            try {
                val item = android.content.ContentUris.withAppendedId(
                    MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
                    id,
                )
                contentResolver.query(
                    item, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null,
                )?.use { c ->
                    if (c.moveToFirst()) c.getString(0)?.let { return it }
                }
            } catch (_: Exception) {
            }
        }
        val name = displayName(uri)
        // A bare number is the picker's stand-in, not a real name.
        return if (name.substringBeforeLast('.').all { it.isDigit() }) null else name
    }

    private fun displayName(uri: Uri): String {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) return c.getString(0) ?: "Video" }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment ?: "Video"
    }

    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFY)
        }
    }

    companion object {
        private const val REQUEST_PICK_VIDEOS = 41
        private const val REQUEST_PICK_FOLDER = 42
        private const val REQUEST_NOTIFY = 43
        private const val REQUEST_VIDEO_ACCESS = 44
    }
}

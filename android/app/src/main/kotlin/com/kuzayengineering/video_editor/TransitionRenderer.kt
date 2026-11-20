package com.kuzayengineering.video_editor

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MimeTypes
import androidx.media3.transformer.Composition
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import java.io.File

/**
 * Makes the short video of one transition that the preview plays in place
 * of the cut (Media3's two-layer player can't jump around reliably, so the
 * preview never blends live). Uses exactly the export's blending, at the
 * preview's size, keeping HDR.
 */
object TransitionRenderer {
    private val main = Handler(Looper.getMainLooper())

    /** Calls [done] with null when the file at `path` is ready, or the
     * reason it failed. */
    fun render(context: Context, args: Map<*, *>, done: (String?) -> Unit) {
        @Suppress("UNCHECKED_CAST")
        val segments = Segment.listFrom(args["segments"] as List<Map<String, Any?>>)
        val dips = (args["dips"] as List<*>?)?.map { Dip.from(it as Map<*, *>) } ?: emptyList()
        val path = args["path"] as String
        val out = File(path).apply { delete() }
        var finished = false
        fun finish(error: String?) {
            if (finished) return
            finished = true
            if (error != null) out.delete()
            done(error)
        }
        try {
            val composition = CompositionFactory.build(
                segments,
                (args["width"] as Number).toInt(),
                (args["height"] as Number).toInt(),
                (args["frameRate"] as Number?)?.toInt(),
                Composition.HDR_MODE_KEEP_HDR,
                withGain = true,
                dips = dips,
                blends = BlendInput.from(args),
            )
            val transformer = Transformer.Builder(context)
                .setVideoMimeType(MimeTypes.VIDEO_H265)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        finish(null)
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException,
                    ) {
                        finish(describe(exportException))
                    }
                })
                .build()
            transformer.start(composition, out.absolutePath)
            // A stuck render must not hold up the others: stopped after a
            // minute without progress (long clips may take several minutes).
            val holder = ProgressHolder()
            var lastProgress = -1
            var lastChangeMs = android.os.SystemClock.elapsedRealtime()
            val watchdog = object : Runnable {
                override fun run() {
                    if (finished) return
                    val now = android.os.SystemClock.elapsedRealtime()
                    if (transformer.getProgress(holder) ==
                        Transformer.PROGRESS_STATE_AVAILABLE &&
                        holder.progress != lastProgress
                    ) {
                        lastProgress = holder.progress
                        lastChangeMs = now
                    }
                    if (now - lastChangeMs > 60_000) {
                        transformer.cancel()
                        finish("it stopped making progress for a minute")
                    } else {
                        main.postDelayed(this, 5_000)
                    }
                }
            }
            main.postDelayed(watchdog, 5_000)
        } catch (e: Exception) {
            finish(describe(e))
        }
    }

    /** The error and its causes, for the screen (so problems can be told
     * apart from a distance). */
    fun describe(e: Throwable): String {
        val parts = mutableListOf<String>()
        var t: Throwable? = e
        var root: Throwable = e
        while (t != null && parts.size < 8) {
            val code = (t as? ExportException)?.errorCodeName
            parts += listOfNotNull(
                code?.takeIf { !it.startsWith("invalid") },
                t.javaClass.simpleName,
                t.message,
            ).joinToString(": ")
            root = t
            t = t.cause
        }
        // Where the deepest problem happened (the first lines of the app's
        // or Media3's code), so it can be found in the source.
        val where = root.stackTrace.take(6).joinToString("\n") {
            "  at ${it.className.substringAfterLast('.')}.${it.methodName}(${it.fileName}:${it.lineNumber})"
        }
        return parts.joinToString("\n← ") + "\n" + where
    }
}

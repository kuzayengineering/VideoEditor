package com.kuzayengineering.video_editor

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MimeTypes
import androidx.media3.transformer.Composition
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
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

    /** Calls [done] with true when the file at `path` is ready. */
    fun render(context: Context, args: Map<*, *>, done: (Boolean) -> Unit) {
        @Suppress("UNCHECKED_CAST")
        val segments = Segment.listFrom(args["segments"] as List<Map<String, Any?>>)
        val dips = (args["dips"] as List<*>?)?.map { Dip.from(it as Map<*, *>) } ?: emptyList()
        val path = args["path"] as String
        val out = File(path).apply { delete() }
        var finished = false
        fun finish(ok: Boolean) {
            if (finished) return
            finished = true
            if (!ok) out.delete()
            done(ok)
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
                        finish(true)
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException,
                    ) {
                        finish(false)
                    }
                })
                .build()
            transformer.start(composition, out.absolutePath)
            // A stuck render must not hold up the others.
            main.postDelayed({
                if (!finished) {
                    transformer.cancel()
                    finish(false)
                }
            }, 60_000)
        } catch (e: Exception) {
            finish(false)
        }
    }
}

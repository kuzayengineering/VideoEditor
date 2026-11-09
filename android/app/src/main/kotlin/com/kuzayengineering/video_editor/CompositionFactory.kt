package com.kuzayengineering.video_editor

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.effect.Crop
import androidx.media3.effect.Presentation
import androidx.media3.effect.RgbAdjustment
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects

/**
 * Turns the timeline into a Media3 Composition. Used for both the preview and
 * the export, so what you see while editing is what you get.
 */
object CompositionFactory {

    fun build(
        segments: List<Segment>,
        width: Int,
        height: Int,
        maxFrameRate: Int?,
        hdrMode: Int,
    ): Composition {
        val items = segments.map { item(it, width, height, maxFrameRate) }
        return Composition.Builder(EditedMediaItemSequence.withAudioAndVideoFrom(items))
            .setHdrMode(hdrMode)
            // Clips without sound get silence, so sound stays in sync.
            .experimentalSetForceAudioTrack(true)
            .build()
    }

    private fun item(s: Segment, width: Int, height: Int, maxFrameRate: Int?): EditedMediaItem {
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.parse(s.source))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(s.inUs / 1000)
                    .setEndPositionMs(s.outUs / 1000)
                    .build()
            )
            .build()

        val video = mutableListOf<Effect>()
        // Turn first, then mirror and crop the picture as the user sees it.
        if (s.rotation % 4 != 0) {
            // Media3 turns counter-clockwise for positive angles.
            video += ScaleAndRotateTransformation.Builder()
                .setRotationDegrees(-90f * (s.rotation % 4))
                .build()
        }
        if (s.flipH || s.flipV) {
            video += ScaleAndRotateTransformation.Builder()
                .setScale(if (s.flipH) -1f else 1f, if (s.flipV) -1f else 1f)
                .build()
        }
        val (l, t, r, b) = s.crop
        if (l > 0.0005 || t > 0.0005 || r < 0.9995 || b < 0.9995) {
            // Media3 measures from the centre: -1 (left/bottom) to 1 (right/top).
            video += Crop(
                (-1 + 2 * l).toFloat(),
                (-1 + 2 * r).toFloat(),
                (1 - 2 * b).toFloat(),
                (1 - 2 * t).toFloat(),
            )
        }
        if (s.opacity < 0.999) {
            // Over the black background, opacity is the same as dimming.
            val o = s.opacity.toFloat()
            video += RgbAdjustment.Builder().setRedScale(o).setGreenScale(o).setBlueScale(o).build()
        }
        // Fit into the canvas; black bars where the shapes differ.
        video += Presentation.createForWidthAndHeight(width, height, Presentation.LAYOUT_SCALE_TO_FIT)

        val builder = EditedMediaItem.Builder(mediaItem)
            .setEffects(Effects(listOf<AudioProcessor>(), video))
        if (s.sourceDurationUs > 0) builder.setDurationUs(s.sourceDurationUs)
        if (Math.abs(s.speed - 1.0) > 0.0001) {
            val speed = s.speed.toFloat()
            builder.setSpeed(object : SpeedProvider {
                override fun getSpeed(timeUs: Long): Float = speed
                override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
            })
        }
        // Never more frames per second than asked for (speeding up a 60 fps
        // clip would otherwise produce 120 fps).
        if (maxFrameRate != null) builder.setFrameRate(maxFrameRate)
        return builder.build()
    }
}

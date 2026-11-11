package com.kuzayengineering.video_editor

import android.net.Uri
import com.google.common.collect.ImmutableList
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.effect.Crop
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.RgbAdjustment
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects

/** What mixing transitions need (see BlendSettings): a second picture layer
 * lined up with the main one, the transition windows, and the incoming
 * clips' sound. */
data class BlendInput(
    val layerB: List<Segment>,
    val windows: List<Blend>,
    val audio: List<Segment>,
) {
    companion object {
        /** From the method-channel arguments, or null when there are none. */
        @Suppress("UNCHECKED_CAST")
        fun from(m: Map<*, *>): BlendInput? {
            val layerB = m["layerB"] as List<Map<String, Any?>>? ?: return null
            val windows = (m["blends"] as List<*>?)?.map { Blend.from(it as Map<*, *>) }
                ?: return null
            val audio = (m["blendAudio"] as List<Map<String, Any?>>?) ?: emptyList()
            if (windows.isEmpty()) return null
            return BlendInput(Segment.listFrom(layerB), windows, Segment.listFrom(audio))
        }
    }
}

/**
 * Turns the timeline into a Media3 Composition. Used for both the preview and
 * the export, so what you see while editing is what you get.
 */
object CompositionFactory {

    /**
     * [audioTracks]: each list is one audio track (clips in time order, with
     * their [Segment.startUs]). [withGain]: apply volume and fades in the
     * sound itself (export); the preview sets player volume instead.
     */
    fun build(
        segments: List<Segment>,
        width: Int,
        height: Int,
        maxFrameRate: Int?,
        hdrMode: Int,
        audioTracks: List<List<Segment>> = emptyList(),
        withGain: Boolean = false,
        texts: List<TextLayer> = emptyList(),
        dips: List<Dip> = emptyList(),
        blends: BlendInput? = null,
    ): Composition {
        val items = segments.map { item(it, width, height, maxFrameRate, withGain) }
        val videoLengthUs = segments.sumOf { it.timelineUs }
        val sequences = mutableListOf(EditedMediaItemSequence.withAudioAndVideoFrom(items))
        val mixing = blends != null && blends.windows.isNotEmpty() && blends.layerB.isNotEmpty()
        if (mixing) {
            // Second picture layer (silent): the incoming clips' starts.
            val layerB = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO))
            for (s in blends!!.layerB) {
                layerB.addItem(item(s, width, height, maxFrameRate, withGain = false, silent = true))
            }
            sequences += layerB.build()
        }
        for (track in audioTracks) {
            audioSequence(track, videoLengthUs)?.let { sequences += it }
        }
        if (mixing) {
            // The incoming clips' sound, fading in under the outgoing sound.
            audioSequence(blends!!.audio, videoLengthUs)?.let { sequences += it }
        }
        val builder = Composition.Builder(sequences)
        if (mixing) builder.setVideoCompositorSettings(BlendSettings(blends!!.windows))
        if (texts.isNotEmpty() || dips.isNotEmpty()) {
            // Text goes on top of the finished picture, in timeline time.
            builder.setEffects(
                Effects(
                    listOf<AudioProcessor>(),
                    listOf<Effect>(OverlayEffect(ImmutableList.copyOf(TextOverlays.create(texts, dips)))),
                )
            )
        }
        builder.setHdrMode(hdrMode)
        // Clips without sound get silence, so sound stays in sync. With two
        // picture layers this is left off: it would give the silent second
        // layer a sound track too, which Media3 can't set up (it crashes);
        // the main layer already has sound and picture tracks of its own.
        if (!mixing) builder.experimentalSetForceAudioTrack(true)
        return builder.build()
    }

    /** One audio track: its clips with silent gaps in between. */
    private fun audioSequence(track: List<Segment>, videoLengthUs: Long): EditedMediaItemSequence? {
        val builder = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
        var cursor = 0L
        var any = false
        for (s in track.sortedBy { it.startUs }) {
            if (s.startUs >= videoLengthUs || s.volume <= 0) continue
            if (s.startUs > cursor) builder.addGap(s.startUs - cursor)
            // Never run past the end of the video.
            var clip = s
            val room = videoLengthUs - s.startUs
            if (s.timelineUs > room) {
                clip = s.copy(outUs = s.inUs + Math.round(room * s.speed))
            }
            val mediaItem = MediaItem.Builder()
                .setUri(Uri.parse(clip.source))
                .setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionMs(clip.inUs / 1000)
                        .setEndPositionMs(clip.outUs / 1000)
                        .build()
                )
                .build()
            val b = EditedMediaItem.Builder(mediaItem)
                .setRemoveVideo(true)
                .setEffects(Effects(pitchKeeper(clip.speed) + gainProcessors(clip), listOf()))
            if (clip.sourceDurationUs > 0) b.setDurationUs(clip.sourceDurationUs)
            applySpeed(b, clip.speed)
            builder.addItem(b.build())
            cursor = clip.startUs + clip.timelineUs
            any = true
        }
        return if (any) builder.build() else null
    }

    private fun gainProcessors(s: Segment): List<AudioProcessor> {
        val fadeOut = maxOf(s.fadeOutUs, s.blendOutUs)
        if (Math.abs(s.volume - 1.0) < 0.0001 && s.fadeInUs <= 0 && fadeOut <= 0) {
            return listOf()
        }
        return listOf(
            GainEnvelopeProcessor(s.volume.toFloat(), s.fadeInUs, fadeOut, s.timelineUs)
        )
    }

    /**
     * Media3's speed change works like a tape machine: faster also means
     * higher pitch. This shifts the pitch back by the same factor (without
     * changing the length), so voices sound normal at any speed.
     */
    private fun pitchKeeper(speed: Double): List<AudioProcessor> {
        if (Math.abs(speed - 1.0) < 0.0001) return listOf()
        return listOf(SonicAudioProcessor().apply { setPitch((1.0 / speed).toFloat()) })
    }

    private fun applySpeed(builder: EditedMediaItem.Builder, speed: Double) {
        if (Math.abs(speed - 1.0) > 0.0001) {
            val f = speed.toFloat()
            builder.setSpeed(object : SpeedProvider {
                override fun getSpeed(timeUs: Long): Float = f
                override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
            })
        }
    }

    private fun item(
        s: Segment,
        width: Int,
        height: Int,
        maxFrameRate: Int?,
        withGain: Boolean,
        silent: Boolean = false,
    ): EditedMediaItem {
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

        val audio = when {
            silent -> listOf()
            withGain -> pitchKeeper(s.speed) + gainProcessors(s)
            // Preview: only the fade under a mixing transition (the player's
            // volume does the rest).
            s.blendOutUs > 0 -> pitchKeeper(s.speed) +
                GainEnvelopeProcessor(1f, 0, s.blendOutUs, s.timelineUs)
            else -> pitchKeeper(s.speed)
        }
        val builder = EditedMediaItem.Builder(mediaItem)
            .setEffects(Effects(audio, video))
        if (silent) builder.setRemoveAudio(true)
        if (s.sourceDurationUs > 0) builder.setDurationUs(s.sourceDurationUs)
        applySpeed(builder, s.speed)
        // Never more frames per second than asked for (speeding up a 60 fps
        // clip would otherwise produce 120 fps).
        if (maxFrameRate != null) builder.setFrameRate(maxFrameRate)
        return builder.build()
    }
}

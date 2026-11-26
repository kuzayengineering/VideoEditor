package com.kuzayengineering.video_editor

import android.net.Uri
import com.google.common.collect.ImmutableList
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.SpeedParameters
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.effect.Crop
import androidx.media3.effect.MotionInterpolation
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

/** Where and when a picture-in-picture clip shows (fractions of the canvas). */
data class PipWindow(
    val startUs: Long,
    val endUs: Long,
    val x: Float,
    val y: Float,
    val w: Float,
    val h: Float,
    val angle: Float,
    val opacity: Float,
    /** 0 normal, 1 screen, 2 add, 3 multiply, 4 lighten, 5 darken
     * (PipBlend in the Flutter side, by position). */
    val blend: Int = 0,
)

/** One picture-in-picture layer: its pieces (as long as the video) and its clips' places. */
data class PipLayer(val segments: List<Segment>, val windows: List<PipWindow>) {
    companion object {
        @Suppress("UNCHECKED_CAST")
        fun listFrom(m: Map<*, *>): List<PipLayer> =
            (m["pips"] as List<*>?)?.map { l ->
                val layer = l as Map<*, *>
                PipLayer(
                    Segment.listFrom(layer["segments"] as List<Map<String, Any?>>),
                    (layer["windows"] as List<*>).map { w ->
                        val win = w as Map<*, *>
                        fun f(k: String) = (win[k] as Number).toFloat()
                        PipWindow(
                            (win["startUs"] as Number).toLong(),
                            (win["endUs"] as Number).toLong(),
                            f("x"), f("y"), f("w"), f("h"), f("angle"), f("opacity"),
                            (win["blend"] as Number?)?.toInt() ?: 0,
                        )
                    },
                )
            } ?: emptyList()
    }
}

/**
 * Turns the timeline into a Media3 Composition. Used for both the preview and
 * the export, so what you see while editing is what you get.
 */
object CompositionFactory {
    /** The app (for effects that load files, like the person cutout). */
    var context: android.content.Context? = null

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
        pips: List<PipLayer> = emptyList(),
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
        // Picture-in-picture layers (silent; their sound is an audio track).
        for (layer in pips) {
            val seq = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO))
            for (s in layer.segments) {
                seq.addItem(item(s, width, height, maxFrameRate, withGain = false, silent = true))
            }
            sequences += seq.build()
        }
        val layered = mixing || pips.isNotEmpty()
        for (track in audioTracks) {
            audioSequence(track, videoLengthUs)?.let { sequences += it }
        }
        if (mixing) {
            // The incoming clips' sound, fading in under the outgoing sound.
            audioSequence(blends!!.audio, videoLengthUs)?.let { sequences += it }
        }
        val builder = Composition.Builder(sequences)
        if (layered) {
            // Video layers come first, so their numbers are their positions.
            val first = if (mixing) 2 else 1
            builder.setVideoCompositorSettings(
                BlendSettings(
                    if (mixing) blends!!.windows else emptyList(),
                    pips.mapIndexed { i, layer -> PipDraw(first + i, layer.windows) },
                    inputCount = first + pips.size,
                )
            )
        }
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
        if (!layered) builder.experimentalSetForceAudioTrack(true)
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
                .setEffects(Effects(soundEffects(clip) + gainProcessors(clip), listOf()))
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

    /** The clip's sound effects (its pitch setting included; speed changes
     * keep the pitch by themselves, see [applySpeed]). */
    private fun soundEffects(s: Segment): List<AudioProcessor> {
        val fx = s.fx
        val list = mutableListOf<AudioProcessor>()
        fx?.noise?.let { list += NoiseReducer(it) }
        list += pitchProcessor(1.0, fx?.pitch ?: 1.0)
        if (fx != null && fx.hasFilters) list += FxAudioProcessor(fx)
        return list
    }

    /**
     * Plays the clip faster or slower, keeping the sound's pitch (Media3's
     * own pitch-keeping time stretch). This used to be a tape-style speed
     * change followed by a second pitch shift of our own; with that, exports
     * of sped-up clips got stuck for good at the end of the clip.
     */
    @androidx.annotation.OptIn(markerClass = [ExperimentalApi::class])
    private fun applySpeed(builder: EditedMediaItem.Builder, speed: Double) {
        if (Math.abs(speed - 1.0) > 0.0001) {
            val f = speed.toFloat()
            val provider = object : SpeedProvider {
                override fun getSpeed(timeUs: Long): Float = f
                override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
            }
            builder.setSpeed(SpeedParameters(provider, /* shouldMaintainPitch= */ true))
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
        val grade = s.grade
        if (grade != null && grade.size >= 6) {
            video += GradeEffect(
                FloatArray(11) { grade.getOrElse(it) { 0.0 }.toFloat() },
                s.transfer,
                // The preview follows the sliders live; exports don't.
                liveClipId = if (withGain) null else s.clipId,
            )
        }
        if (s.opacity < 0.999) {
            // Over the black background, opacity is the same as dimming.
            val o = s.opacity.toFloat()
            video += RgbAdjustment.Builder().setRedScale(o).setGreenScale(o).setBlueScale(o).build()
        }
        // Fit into the canvas; black bars where the shapes differ.
        // Picture-in-picture pieces get their own box size.
        video += Presentation.createForWidthAndHeight(
            if (s.boxW > 0) s.boxW else width,
            if (s.boxH > 0) s.boxH else height,
            Presentation.LAYOUT_SCALE_TO_FIT,
        )
        // Smooth slow motion (exports only): enough in-between frames to
        // reach the export's frame rate (×0.5 of 60 fps: one between each
        // pair), made at the export's size.
        if (withGain && s.smooth && s.speed < 0.99) {
            val target = (maxFrameRate ?: 60).toDouble()
            val factor = Math.ceil(target / (s.frameRate * s.speed) - 0.01).toInt().coerceIn(1, 4)
            if (factor > 1) video += MotionInterpolation(factor)
        }
        val ctx2 = context
        // The people-finding models take longer than a frame lasts: the
        // preview finds people about 10 times a second (each answer used
        // for the frames until the next), exports about 30 times.
        val everyUs = if (withGain) 33_000L else 100_000L
        // Hair / skin / clothes colours (before the cutout, which goes last).
        val parts = s.recolor
        if (parts != null && s.partsModel != null && java.io.File(s.partsModel).isFile) {
            video += PartsRecolor(s.partsModel, parts.toIntArray(), s.recolorStrength, everyUs)
        }
        // Eye colour and tight-fitting outfits (they need the app, to load
        // the face and body models).
        if (ctx2 != null && (s.eyeColor != 0 || s.eyeBright > 0f) && s.faceModel != null &&
            java.io.File(s.faceModel).isFile
        ) {
            video += EyeColorEffect(ctx2, s.faceModel, s.eyeColor, s.eyeStrength, s.eyeBright, everyUs)
        }
        val outfit = s.outfit
        if (ctx2 != null && outfit != null && s.poseModel != null && s.partsModel != null &&
            java.io.File(s.poseModel).isFile && java.io.File(s.partsModel).isFile
        ) {
            video += OutfitEffect(
                ctx2, s.poseModel, s.partsModel, outfit.toIntArray(),
                s.outfitSleeves, s.outfitTop, s.outfitSheer, s.outfitPattern, everyUs,
            )
        }
        // Person cutout last, so nothing after it makes the picture solid again.
        val ctx = context
        if (s.cutout && ctx != null) video += PersonCutout.effect(ctx, s.cutoutFill)

        val audio = when {
            silent -> listOf()
            // Export: pitch, equalizer, delay and reverb too. (The preview
            // plays clips with sound effects through its own small players.)
            withGain -> soundEffects(s) + gainProcessors(s)
            // Preview: only the fade under a mixing transition (the player's
            // volume does the rest).
            s.blendOutUs > 0 ->
                listOf(GainEnvelopeProcessor(1f, 0, s.blendOutUs, s.timelineUs))
            else -> listOf()
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

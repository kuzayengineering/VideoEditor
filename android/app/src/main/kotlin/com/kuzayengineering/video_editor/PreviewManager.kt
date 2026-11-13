package com.kuzayengineering.video_editor

import android.content.Context
import android.net.Uri
import android.view.SurfaceView
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.effect.DefaultVideoFrameProcessor
import androidx.media3.effect.MultipleInputVideoGraph
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.transformer.Composition
import androidx.media3.transformer.CompositionPlayer
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * The editor's preview player. The picture is drawn into a SurfaceView, which
 * Android shows in true HDR on HDR screens such as the Pixel's.
 *
 * Two modes:
 * - plain clips: ExoPlayer plays the pieces back to back (lightest, true HDR)
 * - clips with effects (turn, mirror, crop, speed, opacity): Media3's
 *   CompositionPlayer renders exactly what the export will produce
 */
class PreviewManager(private val context: Context) {
    private var player: Player? = null
    private var usingComposition = false

    private var segments: List<Segment> = emptyList()
    private var blends: BlendInput? = null
    /** The player was built for two picture layers (mixing transitions). */
    private var usingLayers = false
    private var layersFailed = false
    /** Paused: tuned for many quick jumps (Media3's scrubbing mode). */
    private var scrubbing = false
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private var canvas = Pair(1920, 1080)
    /** Start of each segment on the timeline (plain mode), in microseconds. */
    private var starts: LongArray = LongArray(0)
    private var surface: SurfaceView? = null

    fun attach(view: SurfaceView) {
        surface = view
        player?.setVideoSurfaceView(view)
    }

    fun detach(view: SurfaceView) {
        if (surface === view) {
            player?.clearVideoSurfaceView(view)
            surface = null
        }
    }

    /**
     * Pieces that carry straight on from the previous one in the same file
     * (a clip split in two, both kept) play as one: at a cut between two
     * items the player has to restart decoding from the last key frame,
     * which shows as a judder or a pause.
     */
    private fun joined(list: List<Segment>): List<Segment> {
        val out = mutableListOf<Segment>()
        for (s in list) {
            val last = out.lastOrNull()
            fun plain(x: Segment) = x.copy(inUs = 0, outUs = 0, fadeInUs = 0, fadeOutUs = 0, clipId = null)
            if (last != null && last.source == s.source &&
                Math.abs(s.inUs - last.outUs) <= 1000 &&
                last.fadeOutUs == 0L && s.fadeInUs == 0L && last.blendOutUs == 0L &&
                plain(last) == plain(s)
            ) {
                out[out.size - 1] = last.copy(outUs = s.outUs, fadeOutUs = s.fadeOutUs)
            } else {
                out.add(s)
            }
        }
        return out
    }

    fun setTimeline(
        given: List<Segment>,
        canvasWidth: Int,
        canvasHeight: Int,
        newBlends: BlendInput? = null,
    ) {
        // (Mixing transitions refer to pieces by position: keep them as is.)
        val newSegments = if (newBlends == null) joined(given) else given
        val newCanvas = Pair(canvasWidth, canvasHeight)
        if (newSegments == segments && newCanvas == canvas && newBlends == blends &&
            player != null
        ) return
        val keep = positionUs()
        // A rebuild carries the newest filter values itself.
        LiveGrades.set(emptyMap())
        segments = newSegments
        blends = newBlends
        canvas = newCanvas
        starts = LongArray(newSegments.size)
        var t = 0L
        newSegments.forEachIndexed { i, s ->
            starts[i] = t
            t += Math.round(s.lengthUs / s.speed)
        }
        // If mixing failed once on this phone, preview without it (cuts).
        val wantLayers = newBlends != null && !layersFailed
        val wantComposition = wantLayers || newSegments.any { it.hasEffects }
        if (player == null || wantComposition != usingComposition || wantLayers != usingLayers) {
            player?.release()
            player = if (wantLayers) {
                // Two picture layers mixed by our TransitionBlender.
                CompositionPlayer.Builder(context)
                    .setVideoGraphFactory(
                        MultipleInputVideoGraph.Factory(
                            DefaultVideoFrameProcessor.Factory.Builder().build()
                        )
                    )
                    .build()
            } else if (wantComposition) {
                CompositionPlayer.Builder(context).build()
            } else {
                // A second decoder gets the next piece ready during playback
                // ("pre-warming"), so cuts play without a hitch.
                ExoPlayer.Builder(
                    context,
                    DefaultRenderersFactory(context)
                        .experimentalSetEnableMediaCodecVideoRendererPrewarming(true),
                ).build()
            }
            usingComposition = wantComposition
            usingLayers = wantLayers
            if (wantLayers) {
                player!!.addListener(object : Player.Listener {
                    override fun onPlayerError(error: PlaybackException) {
                        layersFailed = true
                        val s = segments
                        segments = emptyList()
                        main.post { setTimeline(s, canvas.first, canvas.second, blends) }
                    }
                })
            }
            player!!.repeatMode = Player.REPEAT_MODE_OFF
            applyScrubbing()
            surface?.let { player!!.setVideoSurfaceView(it) }
        }
        val p = player!!
        if (newSegments.isEmpty()) {
            p.clearMediaItems()
            return
        }
        if (p is CompositionPlayer) {
            // Preview at up to 1920 pixels on the long side: smooth on the
            // phone, sharp enough on its screen.
            val scale = minOf(1.0, 1920.0 / maxOf(canvasWidth, canvasHeight))
            val w = evenAtLeast2(canvasWidth * scale)
            val h = evenAtLeast2(canvasHeight * scale)
            p.setComposition(
                CompositionFactory.build(
                    newSegments, w, h, null, Composition.HDR_MODE_KEEP_HDR,
                    blends = if (wantLayers) newBlends else null,
                )
            )
            p.seekTo(keep.coerceIn(0, t) / 1000)
            p.prepare()
        } else if (p is ExoPlayer) {
            val items = newSegments.map { s ->
                MediaItem.Builder()
                    .setUri(Uri.parse(s.source))
                    .setClippingConfiguration(
                        MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionMs(s.inUs / 1000)
                            .setEndPositionMs(s.outUs / 1000)
                            .build()
                    )
                    .build()
            }
            val (index, offsetMs) = locate(keep.coerceIn(0, t))
            p.setMediaItems(items, index, offsetMs)
            p.prepare()
        }
    }

    private fun evenAtLeast2(v: Double) = maxOf(2, (Math.round(v / 2) * 2).toInt())

    private fun locate(timeUs: Long): Pair<Int, Long> {
        if (segments.isEmpty()) return 0 to 0L
        var i = starts.indexOfLast { it <= timeUs }
        if (i < 0) i = 0
        val offset = (timeUs - starts[i]).coerceIn(0, segments[i].lengthUs)
        return i to offset / 1000
    }

    fun play() {
        player?.play()
    }

    /** New filter values while a slider moves: redraw the frame with them. */
    fun setGrades(grades: Map<Int, FloatArray>) {
        LiveGrades.set(grades)
        val p = player ?: return
        if (!p.isPlaying) p.seekTo(p.currentPosition)
    }

    /**
     * Scrubbing mode keeps the decoder running between jumps (no restart from
     * the last key frame for every small move), so dragging the timeline and
     * stepping frames show real frames quickly, even in 4K.
     */
    fun setScrubbing(on: Boolean) {
        scrubbing = on
        applyScrubbing()
    }

    private fun applyScrubbing() {
        when (val p = player) {
            is ExoPlayer -> p.setScrubbingModeEnabled(scrubbing)
            is CompositionPlayer -> p.setScrubbingModeEnabled(scrubbing)
        }
    }

    /** Loudness of the video's own sound (0–1; louder isn't possible here). */
    fun setVolume(v: Double) {
        player?.volume = v.toFloat().coerceIn(0f, 1f)
    }

    fun pause() {
        player?.pause()
    }

    fun seek(timeUs: Long, exact: Boolean, toleranceUs: Long = 0) {
        val p = player ?: return
        if (segments.isEmpty()) return
        if (p is ExoPlayer) {
            // Exact frames when asked (or when moving slowly). While the
            // timeline is dragged quickly, a key frame up to [toleranceUs]
            // away is shown instead: no decoding of the frames in between,
            // so the picture keeps up with the finger (a 4K phone video has
            // about one key frame per second).
            p.setSeekParameters(
                if (exact || toleranceUs <= 0) SeekParameters.EXACT
                else SeekParameters(toleranceUs, toleranceUs)
            )
            val (index, offsetMs) = locate(timeUs)
            p.seekTo(index, offsetMs)
        } else {
            p.seekTo(timeUs / 1000)
        }
    }

    fun positionUs(): Long {
        val p = player ?: return 0
        if (segments.isEmpty()) return 0
        if (usingComposition) return p.currentPosition * 1000
        val i = p.currentMediaItemIndex.coerceIn(0, segments.size - 1)
        return starts[i] + p.currentPosition * 1000
    }

    fun release() {
        player?.release()
        player = null
        segments = emptyList()
        blends = null
        starts = LongArray(0)
    }
}

/** Lets Flutter place the preview SurfaceView inside its screen. */
class PreviewViewFactory(private val manager: PreviewManager) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val view = SurfaceView(context)
        manager.attach(view)
        return object : PlatformView {
            override fun getView(): View = view
            override fun dispose() = manager.detach(view)
        }
    }

    companion object {
        const val VIEW_TYPE = "ve/preview"
    }
}

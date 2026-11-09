package com.kuzayengineering.video_editor

import android.content.Context
import android.net.Uri
import android.view.SurfaceView
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
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

    fun setTimeline(newSegments: List<Segment>, canvasWidth: Int, canvasHeight: Int) {
        val newCanvas = Pair(canvasWidth, canvasHeight)
        if (newSegments == segments && newCanvas == canvas && player != null) return
        val keep = positionUs()
        segments = newSegments
        canvas = newCanvas
        starts = LongArray(newSegments.size)
        var t = 0L
        newSegments.forEachIndexed { i, s ->
            starts[i] = t
            t += Math.round(s.lengthUs / s.speed)
        }
        val wantComposition = newSegments.any { it.hasEffects }
        if (player == null || wantComposition != usingComposition) {
            player?.release()
            player = if (wantComposition) {
                CompositionPlayer.Builder(context).build()
            } else {
                ExoPlayer.Builder(context).build()
            }
            usingComposition = wantComposition
            player!!.repeatMode = Player.REPEAT_MODE_OFF
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
                CompositionFactory.build(newSegments, w, h, null, Composition.HDR_MODE_KEEP_HDR)
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

    /** Loudness of the video's own sound (0–1; louder isn't possible here). */
    fun setVolume(v: Double) {
        player?.volume = v.toFloat().coerceIn(0f, 1f)
    }

    fun pause() {
        player?.pause()
    }

    fun seek(timeUs: Long, exact: Boolean) {
        val p = player ?: return
        if (segments.isEmpty()) return
        if (p is ExoPlayer) {
            p.setSeekParameters(if (exact) SeekParameters.EXACT else SeekParameters.CLOSEST_SYNC)
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

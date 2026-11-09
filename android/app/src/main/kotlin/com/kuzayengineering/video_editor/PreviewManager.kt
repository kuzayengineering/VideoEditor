package com.kuzayengineering.video_editor

import android.content.Context
import android.net.Uri
import android.view.SurfaceView
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * The editor's preview player. The picture is drawn into a SurfaceView, which
 * Android shows in true HDR on HDR screens such as the Pixel's.
 */
class PreviewManager(private val context: Context) {
    private var playerOrNull: ExoPlayer? = null
    private val player: ExoPlayer
        get() = playerOrNull ?: ExoPlayer.Builder(context).build().also {
            it.repeatMode = ExoPlayer.REPEAT_MODE_OFF
            playerOrNull = it
        }

    private var segments: List<Segment> = emptyList()
    /** Start of each segment on the timeline, in microseconds. */
    private var starts: LongArray = LongArray(0)
    private var surface: SurfaceView? = null

    fun attach(view: SurfaceView) {
        surface = view
        player.setVideoSurfaceView(view)
    }

    fun detach(view: SurfaceView) {
        if (surface === view) {
            playerOrNull?.clearVideoSurfaceView(view)
            surface = null
        }
    }

    fun setTimeline(newSegments: List<Segment>) {
        if (newSegments == segments) return
        val keep = positionUs()
        segments = newSegments
        starts = LongArray(newSegments.size)
        var t = 0L
        newSegments.forEachIndexed { i, s -> starts[i] = t; t += s.lengthUs }
        val p = player
        if (newSegments.isEmpty()) {
            p.clearMediaItems()
            return
        }
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

    private fun locate(timeUs: Long): Pair<Int, Long> {
        if (segments.isEmpty()) return 0 to 0L
        var i = starts.indexOfLast { it <= timeUs }
        if (i < 0) i = 0
        val offset = (timeUs - starts[i]).coerceIn(0, segments[i].lengthUs)
        return i to offset / 1000
    }

    fun play() {
        playerOrNull?.play()
    }

    fun pause() {
        playerOrNull?.pause()
    }

    fun seek(timeUs: Long, exact: Boolean) {
        val p = playerOrNull ?: return
        if (segments.isEmpty()) return
        p.setSeekParameters(if (exact) SeekParameters.EXACT else SeekParameters.CLOSEST_SYNC)
        val (index, offsetMs) = locate(timeUs)
        p.seekTo(index, offsetMs)
    }

    fun positionUs(): Long {
        val p = playerOrNull ?: return 0
        if (segments.isEmpty()) return 0
        val i = p.currentMediaItemIndex.coerceIn(0, segments.size - 1)
        return starts[i] + p.currentPosition * 1000
    }

    fun release() {
        playerOrNull?.release()
        playerOrNull = null
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

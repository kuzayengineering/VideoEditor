package com.kuzayengineering.video_editor

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import io.flutter.view.TextureRegistry

/**
 * Plays one picture-in-picture clip for the preview, into a Flutter texture
 * (so the screen can move, size, turn and fade it freely). Positions are in
 * timeline time from the start of the clip.
 */
class OverlayPreview(
    private val context: Context,
    private val producer: TextureRegistry.SurfaceProducer,
) {
    private val player = ExoPlayer.Builder(context).build()
    private var speed = 1.0
    private var lengthUs = 0L
    private var source: String? = null
    private var inUs = 0L
    private var outUs = 0L
    private var cutout = false

    /** Quarter turns the screen must add (when the texture doesn't). */
    var rotationCorrection = 0
        private set

    val textureId: Long get() = producer.id()

    init {
        player.repeatMode = Player.REPEAT_MODE_OFF
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                player.setVideoSurface(producer.surface)
            }

            override fun onSurfaceCleanup() {
                player.setVideoSurface(null)
            }
        })
        player.setVideoSurface(producer.surface)
        player.addListener(object : Player.Listener {
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    producer.setSize(videoSize.width, videoSize.height)
                }
            }
        })
    }

    /** Returns the quarter turns the screen must add to show it upright. */
    fun open(source: String, inUs: Long, outUs: Long, speed: Double, cutout: Boolean = false): Int {
        if (source == this.source && inUs == this.inUs && outUs == this.outUs &&
            speed == this.speed && cutout == this.cutout
        ) return rotationCorrection
        if (cutout != this.cutout) {
            // Person cutout: the background becomes see-through, and the
            // screen shows the clips below through it.
            player.setVideoEffects(if (cutout) listOf(PersonCutout.effect(context)) else listOf())
            this.cutout = cutout
        }
        if (source != this.source) {
            // Phone videos are often stored sideways with a "turn" note;
            // some texture kinds don't apply that note themselves.
            rotationCorrection = if (producer.handlesCropAndRotation()) 0 else {
                val r = android.media.MediaMetadataRetriever()
                try {
                    r.setDataSource(context, Uri.parse(source))
                    val degrees = r.extractMetadata(
                        android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION
                    )?.toIntOrNull() ?: 0
                    (degrees / 90) % 4
                } catch (_: Exception) {
                    0
                } finally {
                    r.release()
                }
            }
        }
        this.source = source
        this.inUs = inUs
        this.outUs = outUs
        this.speed = speed
        lengthUs = outUs - inUs
        player.setMediaItem(
            MediaItem.Builder()
                .setUri(Uri.parse(source))
                .setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionMs(inUs / 1000)
                        .setEndPositionMs(outUs / 1000)
                        .build()
                )
                .build()
        )
        // Sped-up or slowed-down, keeping the pitch.
        player.playbackParameters = PlaybackParameters(speed.toFloat())
        player.prepare()
        return rotationCorrection
    }

    /** [offsetUs]: timeline time since the clip started. */
    fun seek(offsetUs: Long, exact: Boolean) {
        player.setSeekParameters(if (exact) SeekParameters.EXACT else SeekParameters.CLOSEST_SYNC)
        val mediaUs = Math.round(offsetUs * speed).coerceIn(0, lengthUs)
        player.seekTo(mediaUs / 1000)
    }

    fun play() {
        player.setScrubbingModeEnabled(false)
        player.play()
    }

    fun pause() {
        player.pause()
        player.setScrubbingModeEnabled(true)
    }

    fun setVolume(v: Double) {
        player.volume = v.toFloat().coerceIn(0f, 1f)
    }

    fun release() {
        player.release()
        producer.release()
    }
}

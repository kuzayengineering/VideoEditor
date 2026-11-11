package com.kuzayengineering.video_editor

import android.content.Context
import android.media.AudioFormat as PlatformAudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.exoplayer.ExoPlayer
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Volume plus fade-in/fade-out, applied to the sound of one clip during
 * export. [durationUs] is the clip's length on the timeline.
 */
class GainEnvelopeProcessor(
    private val volume: Float,
    private val fadeInUs: Long,
    private val fadeOutUs: Long,
    private val durationUs: Long,
) : BaseAudioProcessor() {
    private var framesDone = 0L

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT &&
            inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT
        ) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        return inputAudioFormat
    }

    private fun gainAt(timeUs: Long): Float {
        var g = volume
        if (fadeInUs > 0 && timeUs < fadeInUs) g *= timeUs.toFloat() / fadeInUs
        val fromEnd = durationUs - timeUs
        if (fadeOutUs > 0 && fromEnd < fadeOutUs) g *= max(0L, fromEnd).toFloat() / fadeOutUs
        return g
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val format = inputAudioFormat
        val channels = format.channelCount
        val rate = format.sampleRate
        val isFloat = format.encoding == C.ENCODING_PCM_FLOAT
        val bytesPerFrame = channels * (if (isFloat) 4 else 2)
        val out = replaceOutputBuffer(inputBuffer.remaining())
        inputBuffer.order(ByteOrder.nativeOrder())
        while (inputBuffer.remaining() >= bytesPerFrame) {
            val g = gainAt(framesDone * 1_000_000L / rate)
            for (c in 0 until channels) {
                if (isFloat) {
                    out.putFloat(inputBuffer.float * g)
                } else {
                    val v = (inputBuffer.short * g).toInt()
                    out.putShort(min(32767, max(-32768, v)).toShort())
                }
            }
            framesDone++
        }
        inputBuffer.position(inputBuffer.limit())
        out.flip()
    }

    override fun onFlush() {
        framesDone = 0
    }

    override fun onReset() {
        framesDone = 0
    }
}

/** Reads a file's sound and summarises its loudness, 100 values per second. */
object Waveform {
    fun peaks(context: Context, source: String): ByteArray {
        val extractor = MediaExtractor()
        extractor.setDataSource(context, Uri.parse(source), null)
        var track = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                track = i
                format = f
                break
            }
        }
        if (track < 0 || format == null) {
            extractor.release()
            return ByteArray(0)
        }
        extractor.selectTrack(track)
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()

        var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var isFloat = false
        val result = ByteArrayOutputStream()
        var bucketFrames = max(1, sampleRate / 100)
        var inBucket = 0
        var peak = 0f
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        try {
            while (true) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buf = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    isFloat = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        f.getInteger(MediaFormat.KEY_PCM_ENCODING) == PlatformAudioFormat.ENCODING_PCM_FLOAT
                    bucketFrames = max(1, sampleRate / 100)
                } else if (outIndex >= 0) {
                    val buf = codec.getOutputBuffer(outIndex)!!.order(ByteOrder.nativeOrder())
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val bytesPerSample = if (isFloat) 4 else 2
                    while (buf.remaining() >= bytesPerSample * channels) {
                        for (c in 0 until channels) {
                            val v = if (isFloat) abs(buf.float) else abs(buf.short.toFloat() / 32768f)
                            if (v > peak) peak = v
                        }
                        if (++inBucket >= bucketFrames) {
                            result.write((min(1f, peak) * 255).toInt())
                            inBucket = 0
                            peak = 0f
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } finally {
            codec.stop()
            codec.release()
            extractor.release()
        }
        return result.toByteArray()
    }
}

/** Plays audio-track clips during preview, one small player per clip. */
class ClipAudioPlayers(private val context: Context) {
    private val players = HashMap<Int, ExoPlayer>()

    /** Each player's sound effects (changeable while playing). */
    private val effects = HashMap<Int, FxAudioProcessor>()
    private val speeds = HashMap<Int, Double>()
    private val pitches = HashMap<Int, Double>()

    fun open(id: Int, source: String) {
        players[id]?.release()
        val fx = FxAudioProcessor(FxSpec.NONE)
        val p = ExoPlayer.Builder(context, FxRenderersFactory(context, fx)).build()
        p.setMediaItem(MediaItem.fromUri(Uri.parse(source)))
        p.prepare()
        players[id] = p
        effects[id] = fx
        applyRate(id)
    }

    /** New sound effects for a player (live, for the sliders). */
    fun effects(id: Int, spec: FxSpec) {
        effects[id]?.update(spec)
        pitches[id] = spec.pitch
        applyRate(id)
    }

    private fun applyRate(id: Int) {
        val speed = speeds[id] ?: 1.0
        val pitch = pitches[id] ?: 1.0
        players[id]?.playbackParameters = PlaybackParameters(speed.toFloat(), pitch.toFloat())
    }

    fun seek(id: Int, sourceUs: Long) {
        players[id]?.seekTo(sourceUs / 1000)
    }

    fun play(id: Int) {
        players[id]?.play()
    }

    fun pause(id: Int) {
        players[id]?.pause()
    }

    fun volume(id: Int, v: Double) {
        players[id]?.volume = v.toFloat().coerceIn(0f, 1f)
    }

    fun rate(id: Int, r: Double) {
        speeds[id] = r
        applyRate(id)
    }

    fun release(id: Int) {
        players.remove(id)?.release()
        effects.remove(id)
        speeds.remove(id)
        pitches.remove(id)
    }

    fun releaseAll() {
        players.values.forEach { it.release() }
        players.clear()
        effects.clear()
        speeds.clear()
        pitches.clear()
    }
}

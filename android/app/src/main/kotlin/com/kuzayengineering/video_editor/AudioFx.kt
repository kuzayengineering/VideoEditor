package com.kuzayengineering.video_editor

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * A clip's sound effects, as sent by the Flutter side (AudioFx.toEngineMap):
 * pitch factor, equalizer bands [Hz, Q, dB] and echo taps [ms, gain] for
 * the delay and the reverb.
 */
data class FxSpec(
    val pitch: Double = 1.0,
    val eq: List<DoubleArray> = emptyList(),
    val delayTaps: List<DoubleArray> = emptyList(),
    val reverbTaps: List<DoubleArray> = emptyList(),
) {
    val hasFilters: Boolean get() = eq.isNotEmpty() || delayTaps.isNotEmpty() || reverbTaps.isNotEmpty()

    companion object {
        val NONE = FxSpec()

        fun from(m: Map<*, *>?): FxSpec? {
            if (m == null) return null
            fun rows(key: String) = (m[key] as List<*>?)?.map { row ->
                (row as List<*>).map { (it as Number).toDouble() }.toDoubleArray()
            } ?: emptyList()
            return FxSpec(
                (m["pitch"] as Number?)?.toDouble() ?: 1.0,
                rows("eq"),
                rows("delayTaps"),
                rows("reverbTaps"),
            )
        }
    }
}

/**
 * Equalizer, then delay, then reverb, with the same maths as the Windows
 * version's FFmpeg filters: peaking bands from the Audio EQ Cookbook (as
 * FFmpeg's "equalizer"), and echoes as FFmpeg's "aecho" (the dry sound
 * plus delayed copies of it). The values can change while playing
 * ([update]), for the preview's sliders.
 */
class FxAudioProcessor(initial: FxSpec) : BaseAudioProcessor() {
    @Volatile private var spec: FxSpec = initial
    private var built: FxSpec? = null
    private var builtRate = 0

    // Per band: b0, b1, b2, a1, a2 (divided by a0); per band and channel:
    // the last two inputs and outputs.
    private var coeffs = Array(0) { DoubleArray(5) }
    private var state = Array(0) { DoubleArray(4) }
    private var stages = emptyList<EchoStage>()

    fun update(s: FxSpec) {
        spec = s
    }

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT &&
            inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT
        ) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        return inputAudioFormat
    }

    private fun rebuild(channels: Int, rate: Int) {
        val s = spec
        if (s === built && rate == builtRate && state.size == s.eq.size * channels) return
        built = s
        builtRate = rate
        coeffs = Array(s.eq.size) { i ->
            val (f, q, g) = Triple(s.eq[i][0], s.eq[i][1], s.eq[i][2])
            val a = 10.0.pow(g / 40)
            val w0 = 2 * Math.PI * f / rate
            val alpha = sin(w0) / (2 * q)
            val cw = cos(w0)
            val a0 = 1 + alpha / a
            doubleArrayOf(
                (1 + alpha * a) / a0,
                -2 * cw / a0,
                (1 - alpha * a) / a0,
                -2 * cw / a0,
                (1 - alpha / a) / a0,
            )
        }
        if (state.size != s.eq.size * channels) state = Array(s.eq.size * channels) { DoubleArray(4) }
        stages = listOf(s.delayTaps, s.reverbTaps).filter { it.isNotEmpty() }.map { taps ->
            EchoStage(taps.map { Math.round(it[0] * rate / 1000.0).toInt().coerceAtLeast(1) }.toIntArray(),
                taps.map { it[1] }.toDoubleArray(), channels)
        }
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val format = inputAudioFormat
        val channels = format.channelCount
        val isFloat = format.encoding == C.ENCODING_PCM_FLOAT
        val bytesPerFrame = channels * (if (isFloat) 4 else 2)
        rebuild(channels, format.sampleRate)
        val out = replaceOutputBuffer(inputBuffer.remaining())
        inputBuffer.order(ByteOrder.nativeOrder())
        while (inputBuffer.remaining() >= bytesPerFrame) {
            for (c in 0 until channels) {
                var x = if (isFloat) inputBuffer.float.toDouble() else inputBuffer.short / 32768.0
                for (b in coeffs.indices) {
                    val k = coeffs[b]
                    val st = state[b * channels + c]
                    val y = k[0] * x + k[1] * st[0] + k[2] * st[1] - k[3] * st[2] - k[4] * st[3]
                    st[1] = st[0]; st[0] = x; st[3] = st[2]; st[2] = y
                    x = y
                }
                for (stage in stages) x = stage.process(c, x)
                if (isFloat) {
                    out.putFloat(x.toFloat())
                } else {
                    out.putShort(max(-32768, min(32767, (x * 32768).roundToInt())).toShort())
                }
            }
            for (stage in stages) stage.advance()
        }
        inputBuffer.position(inputBuffer.limit())
        out.flip()
    }

    override fun onFlush() {
        state.forEach { it.fill(0.0) }
        stages.forEach { it.clear() }
    }

    override fun onReset() {
        built = null
        state = Array(0) { DoubleArray(4) }
        stages = emptyList()
    }

    /** One "aecho": the input plus delayed copies of it. */
    private class EchoStage(val delays: IntArray, val gains: DoubleArray, val channels: Int) {
        private val size = (delays.maxOrNull() ?: 1) + 1
        private val history = Array(channels) { DoubleArray(size) }
        private var pos = 0

        fun process(c: Int, x: Double): Double {
            val h = history[c]
            var y = x
            for (i in delays.indices) {
                y += gains[i] * h[(pos - delays[i] + size) % size]
            }
            h[pos] = x
            return y
        }

        fun advance() {
            pos = (pos + 1) % size
        }

        fun clear() {
            history.forEach { it.fill(0.0) }
            pos = 0
        }
    }
}

/** Pitch up or down without changing the length (and keeping the pitch
 * through any speed change). */
fun pitchProcessor(speed: Double, pitch: Double): List<AudioProcessor> {
    val p = pitch / speed
    if (Math.abs(p - 1.0) < 0.0001) return listOf()
    return listOf(SonicAudioProcessor().apply { setPitch(p.toFloat()) })
}

/** An ExoPlayer setup whose sound goes through [fx] (preview players). */
class FxRenderersFactory(context: Context, private val fx: FxAudioProcessor) :
    DefaultRenderersFactory(context) {
    override fun buildAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioOutputPlaybackParams: Boolean,
    ): AudioSink = DefaultAudioSink.Builder(context)
        .setAudioProcessors(arrayOf(fx))
        .build()
}

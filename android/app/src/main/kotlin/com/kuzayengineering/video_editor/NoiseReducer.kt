package com.kuzayengineering.video_editor

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/** Noise reduction settings from the Flutter side (AudioFx.toEngineMap). */
data class NoiseSpec(
    /** ["hp" | "notch", Hz, Q] or ["peak", Hz, Q, dB]. */
    val filters: List<List<Any>> = emptyList(),
    val denoiseDb: Double = 0.0,
    val gateThreshold: Double = 0.0,
    val gateRangeDb: Double = 0.0,
) {
    companion object {
        val NONE = NoiseSpec()

        fun from(m: Map<*, *>?): NoiseSpec? {
            if (m == null) return null
            return NoiseSpec(
                (m["filters"] as List<*>?)?.map { (it as List<*>).map { v -> v!! } } ?: emptyList(),
                (m["denoiseDb"] as Number?)?.toDouble() ?: 0.0,
                (m["gateThreshold"] as Number?)?.toDouble() ?: 0.0,
                (m["gateRangeDb"] as Number?)?.toDouble() ?: 0.0,
            )
        }
    }
}

/**
 * Noise reduction: fixed filters for the kind of noise (high-pass for
 * rumble, notches for hum: the same cookbook maths as FFmpeg's highpass and
 * bandreject on Windows), then a spectral denoiser that learns the steady
 * background as it goes and turns it down (Windows uses FFmpeg's afftdn for
 * this part), then, for breathing, a gate that quietens soft sounds.
 *
 * The denoiser works in 1024-sample blocks; its delay is taken back out, so
 * sound stays in step with the picture.
 */
class NoiseReducer(initial: NoiseSpec) : BaseAudioProcessor() {
    @Volatile private var spec = initial
    private var built: NoiseSpec? = null
    private var channels = 0
    private var rate = 0

    private var biquads = Array(0) { DoubleArray(5) }
    private var bState = Array(0) { DoubleArray(4) }
    private var denoisers = emptyArray<Denoiser>()
    private var gateEnv = DoubleArray(0)
    private var gateGain = DoubleArray(0)

    /** Samples (per channel) still to drop at the start: the denoiser's delay. */
    private var toSkip = 0
    private var ending = false

    /** Frames taken in and given out, so the output is exactly as long. */
    private var inCount = 0L
    private var outCount = 0L

    fun update(s: NoiseSpec) {
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

    private fun rebuild(ch: Int, sr: Int) {
        val s = spec
        if (s === built && ch == channels && sr == rate) return
        val structureChanged = ch != channels || sr != rate ||
            (built?.denoiseDb ?: 0.0) > 0.5 != s.denoiseDb > 0.5
        built = s
        channels = ch
        rate = sr
        biquads = s.filters.map { f -> coefficients(f, sr) }.toTypedArray()
        if (bState.size != biquads.size * ch) bState = Array(biquads.size * ch) { DoubleArray(4) }
        if (structureChanged) {
            denoisers = if (s.denoiseDb > 0.5) Array(ch) { Denoiser() } else emptyArray()
            toSkip = if (denoisers.isNotEmpty()) Denoiser.HOP else 0
            gateEnv = DoubleArray(ch)
            gateGain = DoubleArray(ch) { 1.0 }
        }
        denoisers.forEach { it.reductionDb = s.denoiseDb }
    }

    private fun coefficients(f: List<Any>, sr: Int): DoubleArray {
        val type = f[0] as String
        val hz = (f[1] as Number).toDouble()
        val q = (f[2] as Number).toDouble()
        val w0 = 2 * PI * hz / sr
        val alpha = sin(w0) / (2 * q)
        val cw = cos(w0)
        val (b, a) = when (type) {
            "hp" -> doubleArrayOf((1 + cw) / 2, -(1 + cw), (1 + cw) / 2) to
                doubleArrayOf(1 + alpha, -2 * cw, 1 - alpha)
            "notch" -> doubleArrayOf(1.0, -2 * cw, 1.0) to doubleArrayOf(1 + alpha, -2 * cw, 1 - alpha)
            else -> {
                val g = 10.0.pow((f[3] as Number).toDouble() / 40)
                doubleArrayOf(1 + alpha * g, -2 * cw, 1 - alpha * g) to
                    doubleArrayOf(1 + alpha / g, -2 * cw, 1 - alpha / g)
            }
        }
        return doubleArrayOf(b[0] / a[0], b[1] / a[0], b[2] / a[0], a[1] / a[0], a[2] / a[0])
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val format = inputAudioFormat
        rebuild(format.channelCount, format.sampleRate)
        val isFloat = format.encoding == C.ENCODING_PCM_FLOAT
        val ch = channels
        val bytesPerFrame = ch * (if (isFloat) 4 else 2)
        val frames = inputBuffer.remaining() / bytesPerFrame
        inputBuffer.order(ByteOrder.nativeOrder())
        val samples = Array(ch) { DoubleArray(frames) }
        for (i in 0 until frames) {
            for (c in 0 until ch) {
                samples[c][i] = if (isFloat) inputBuffer.float.toDouble() else inputBuffer.short / 32768.0
            }
        }
        inputBuffer.position(inputBuffer.limit())
        inCount += frames
        emit(process(samples, frames), isFloat)
    }

    private fun process(samples: Array<DoubleArray>, frames: Int): Array<DoubleArray> {
        val ch = channels
        val s = spec
        // 1. Fixed filters.
        for (c in 0 until ch) {
            val x = samples[c]
            for (b in biquads.indices) {
                val k = biquads[b]
                val st = bState[b * ch + c]
                for (i in 0 until frames) {
                    val y = k[0] * x[i] + k[1] * st[0] + k[2] * st[1] - k[3] * st[2] - k[4] * st[3]
                    st[1] = st[0]; st[0] = x[i]; st[3] = st[2]; st[2] = y
                    x[i] = y
                }
            }
        }
        // 2. Spectral denoiser (delays by one hop).
        var out = samples
        if (denoisers.isNotEmpty()) {
            out = Array(ch) { c -> denoisers[c].push(samples[c], frames) }
        }
        // 3. Gate for breathing.
        if (s.gateRangeDb > 0.1 && s.gateThreshold > 0) {
            val floor = 10.0.pow(-s.gateRangeDb / 20)
            val attack = exp(-1.0 / (0.005 * rate))
            val release = exp(-1.0 / (0.150 * rate))
            val n = out.firstOrNull()?.size ?: 0
            for (i in 0 until n) {
                var level = 0.0
                for (c in 0 until ch) level = max(level, abs(out[c][i]))
                for (c in 0 until ch) {
                    val e = gateEnv[c]
                    gateEnv[c] = if (level > e) attack * e + (1 - attack) * level else release * e + (1 - release) * level
                    // Below the threshold: down in proportion (ratio 4), no
                    // further than the floor.
                    val env = gateEnv[c]
                    val target = if (env >= s.gateThreshold) 1.0
                    else max(floor, (env / s.gateThreshold).pow(3.0))
                    val coeff = if (target > gateGain[c]) attack else release
                    gateGain[c] = coeff * gateGain[c] + (1 - coeff) * target
                    out[c][i] *= gateGain[c]
                }
            }
        }
        return out
    }

    private fun emit(out: Array<DoubleArray>, isFloat: Boolean) {
        val ch = channels
        val skip = min(toSkip, out.firstOrNull()?.size ?: 0)
        toSkip -= skip
        // Never more than came in (the end's flush adds silence).
        val n = min((out.firstOrNull()?.size ?: 0).toLong(), skip + inCount - outCount).toInt()
        val frames = max(0, n - skip)
        outCount += frames
        val buf = replaceOutputBuffer(max(0, frames) * ch * (if (isFloat) 4 else 2))
        for (i in skip until n) {
            for (c in 0 until ch) {
                val v = out[c][i]
                if (isFloat) buf.putFloat(v.toFloat())
                else buf.putShort(max(-32768, min(32767, (v * 32768).roundToInt())).toShort())
            }
        }
        buf.flip()
    }

    override fun onQueueEndOfStream() {
        // Let the last block out (the denoiser holds one hop back).
        if (denoisers.isEmpty() || ending) return
        ending = true
        val tail = Array(channels) { DoubleArray(2 * Denoiser.HOP) }
        emit(process(tail, 2 * Denoiser.HOP), inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT)
    }

    override fun onFlush() {
        bState.forEach { it.fill(0.0) }
        denoisers.forEach { it.clear() }
        toSkip = if (denoisers.isNotEmpty()) Denoiser.HOP else 0
        ending = false
        inCount = 0
        outCount = 0
        gateEnv.fill(0.0)
        gateGain.fill(1.0)
    }

    override fun onReset() {
        built = null
        channels = 0
        rate = 0
        denoisers = emptyArray()
        toSkip = 0
        ending = false
        inCount = 0
        outCount = 0
    }

    /**
     * Spectral noise reduction for one channel: blocks of 1024 samples with
     * half overlap; the noise level in each frequency is the slowly-rising
     * minimum of the recent sound there, and each frequency is turned down
     * by how much of it is noise (never by more than [reductionDb]).
     */
    private class Denoiser {
        companion object {
            const val N = 1024
            const val HOP = N / 2
            // sqrt-Hann in and out: the overlapping halves add back to 1.
            val window = DoubleArray(N) { sqrt(0.5 - 0.5 * cos(2 * PI * it / N)) }
        }

        var reductionDb = 12.0
        private val inBuf = DoubleArray(N)
        private var inFill = HOP
        private val outAcc = DoubleArray(N)
        private val pending = ArrayDeque<Double>()
        private val power = DoubleArray(N / 2 + 1)
        private val noise = DoubleArray(N / 2 + 1) { Double.MAX_VALUE }
        private val gains = DoubleArray(N / 2 + 1) { 1.0 }
        private val re = DoubleArray(N)
        private val im = DoubleArray(N)

        fun clear() {
            inBuf.fill(0.0)
            inFill = HOP
            outAcc.fill(0.0)
            pending.clear()
            power.fill(0.0)
            noise.fill(Double.MAX_VALUE)
            gains.fill(1.0)
        }

        /** Takes [n] samples; gives back what is ready (one hop late). */
        fun push(x: DoubleArray, n: Int): DoubleArray {
            for (i in 0 until n) {
                inBuf[inFill++] = x[i]
                if (inFill == N) {
                    block()
                    System.arraycopy(inBuf, HOP, inBuf, 0, HOP)
                    inFill = HOP
                }
            }
            val out = DoubleArray(pending.size)
            for (i in out.indices) out[i] = pending.removeFirst()
            return out
        }

        private fun block() {
            for (i in 0 until N) {
                re[i] = inBuf[i] * window[i]
                im[i] = 0.0
            }
            fft(re, im, false)
            val floor = 10.0.pow(-reductionDb / 20)
            for (k in 0..N / 2) {
                val p = re[k] * re[k] + im[k] * im[k]
                power[k] = 0.8 * power[k] + 0.2 * p
                noise[k] = if (power[k] < noise[k]) power[k] else noise[k] * 1.004 + 1e-12
                val g = max(floor, 1.0 - 4.0 * noise[k] / max(power[k], 1e-12))
                gains[k] = 0.5 * gains[k] + 0.5 * g
            }
            for (k in 0..N / 2) {
                re[k] *= gains[k]; im[k] *= gains[k]
                if (k in 1 until N / 2) {
                    re[N - k] *= gains[k]; im[N - k] *= gains[k]
                }
            }
            fft(re, im, true)
            for (i in 0 until N) outAcc[i] += re[i] * window[i]
            for (i in 0 until HOP) pending.addLast(outAcc[i])
            System.arraycopy(outAcc, HOP, outAcc, 0, HOP)
            java.util.Arrays.fill(outAcc, HOP, N, 0.0)
        }

        /** In-place radix-2 FFT ([inverse] includes the 1/N). */
        private fun fft(re: DoubleArray, im: DoubleArray, inverse: Boolean) {
            val n = re.size
            var j = 0
            for (i in 1 until n) {
                var bit = n shr 1
                while (j and bit != 0) {
                    j = j xor bit
                    bit = bit shr 1
                }
                j = j xor bit
                if (i < j) {
                    var t = re[i]; re[i] = re[j]; re[j] = t
                    t = im[i]; im[i] = im[j]; im[j] = t
                }
            }
            var len = 2
            while (len <= n) {
                val ang = 2 * PI / len * (if (inverse) 1 else -1)
                val wr = cos(ang)
                val wi = sin(ang)
                var i = 0
                while (i < n) {
                    var cr = 1.0
                    var ci = 0.0
                    for (k in 0 until len / 2) {
                        val ur = re[i + k]
                        val ui = im[i + k]
                        val vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci
                        val vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr
                        re[i + k] = ur + vr; im[i + k] = ui + vi
                        re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi
                        val nr = cr * wr - ci * wi
                        ci = cr * wi + ci * wr
                        cr = nr
                    }
                    i += len
                }
                len = len shl 1
            }
            if (inverse) for (i in 0 until n) {
                re[i] /= n; im[i] /= n
            }
        }
    }
}

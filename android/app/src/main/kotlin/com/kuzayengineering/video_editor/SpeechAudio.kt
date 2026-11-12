package com.kuzayengineering.video_editor

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import android.media.AudioFormat as PlatformAudioFormat

/**
 * The sound of part of a file for speech recognition (auto captions):
 * decoded, mixed to mono and brought down to 16,000 samples a second, as
 * little-endian 32-bit floats (the same as FFmpeg's "f32le" on Windows).
 */
object SpeechAudio {
    private const val RATE = 16000

    fun write(context: Context, source: String, inUs: Long, outUs: Long, output: String) {
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
        val out = BufferedOutputStream(FileOutputStream(File(output)), 1 shl 16)
        if (track < 0 || format == null) {
            // No sound: an empty file (no captions).
            extractor.release()
            out.close()
            return
        }
        extractor.selectTrack(track)
        extractor.seekTo(inUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()

        var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var isFloat = false
        // Area-averaging resampler: each output sample is the mean of the
        // input samples it covers (a gentle low-pass, fine for speech).
        var ratio = sampleRate.toDouble() / RATE
        var inCount = 0L
        var outCount = 0L
        var acc = 0.0
        var accN = 0
        val chunk = ByteBuffer.allocate(4096 * 4).order(ByteOrder.LITTLE_ENDIAN)
        fun emit(v: Float) {
            chunk.putFloat(v)
            if (!chunk.hasRemaining()) {
                out.write(chunk.array(), 0, chunk.position())
                chunk.clear()
            }
        }

        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var done = false
        try {
            while (!done) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buf = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0 || extractor.sampleTime > outUs) {
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
                    ratio = sampleRate.toDouble() / RATE
                } else if (outIndex >= 0) {
                    val buf = codec.getOutputBuffer(outIndex)!!.order(ByteOrder.nativeOrder())
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val bytesPerSample = if (isFloat) 4 else 2
                    var frame = 0L
                    while (buf.remaining() >= bytesPerSample * channels) {
                        var sum = 0f
                        for (c in 0 until channels) {
                            sum += if (isFloat) buf.float else buf.short / 32768f
                        }
                        val t = info.presentationTimeUs + frame * 1_000_000L / sampleRate
                        frame++
                        if (t < inUs) continue
                        if (t >= outUs) { done = true; break }
                        acc += sum / channels
                        accN++
                        inCount++
                        if (inCount >= ((outCount + 1) * ratio).toLong()) {
                            emit((acc / accN).toFloat())
                            outCount++
                            acc = 0.0
                            accN = 0
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) done = true
                }
            }
            if (accN > 0) emit((acc / accN).toFloat())
            out.write(chunk.array(), 0, chunk.position())
        } finally {
            out.close()
            codec.stop()
            codec.release()
            extractor.release()
        }
    }
}

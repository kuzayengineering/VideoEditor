package com.kuzayengineering.video_editor

import android.content.Context
import android.media.AudioFormat as PlatformAudioFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min

/**
 * Makes a backwards copy of part of a video.
 *
 * Picture: frames are produced last-to-first. For each one the hardware
 * decoder jumps to the nearest key frame before it and decodes forward to it;
 * that frame goes straight from the decoder to the encoder (no copying, so
 * HDR is kept and memory use stays tiny). Slower than keeping frames in
 * memory, but safe for long 4K clips.
 *
 * Sound: decoded, reversed sample by sample, and re-encoded.
 */
object Reverser {
    @Volatile var progress = 0.0
        private set

    private const val TIMEOUT_US = 10_000L

    fun reverse(context: Context, source: String, inUs: Long, outUs: Long, output: String) {
        progress = 0.0
        val uri = Uri.parse(source)
        val part = File("$output.part")
        part.delete()

        val rotation = MediaMetadataRetriever().let { r ->
            try {
                r.setDataSource(context, uri)
                r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            } finally {
                r.release()
            }
        }

        val audio = try {
            reverseAudio(context, uri, inUs, outUs)
        } catch (e: Exception) {
            null // keep going without sound rather than failing
        }
        progress = 0.1

        val muxer = MediaMuxer(part.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        muxer.setOrientationHint(rotation)
        try {
            reverseVideo(context, uri, inUs, outUs, muxer, audio)
        } finally {
            try {
                muxer.release()
            } catch (_: Exception) {
            }
        }
        if (!part.renameTo(File(output))) throw IllegalStateException("Could not save the reversed copy.")
        progress = 1.0
    }

    // -------------------------------------------------------------------------
    // Sound
    // -------------------------------------------------------------------------

    private class EncodedAudio(
        val format: MediaFormat,
        val samples: List<Pair<ByteArray, MediaCodec.BufferInfo>>,
    )

    private fun reverseAudio(context: Context, uri: Uri, inUs: Long, outUs: Long): EncodedAudio? {
        val ex = MediaExtractor()
        ex.setDataSource(context, uri, null)
        var track = -1
        for (i in 0 until ex.trackCount) {
            if (ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                track = i
                break
            }
        }
        if (track < 0) {
            ex.release()
            return null
        }
        val inFormat = ex.getTrackFormat(track)
        ex.selectTrack(track)
        ex.seekTo(inUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val decoder = MediaCodec.createDecoderByType(inFormat.getString(MediaFormat.KEY_MIME)!!)
        decoder.configure(inFormat, null, null, 0)
        decoder.start()
        var rate = inFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = inFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var isFloat = false
        var pcm = ShortArray(1 shl 20)
        var count = 0 // shorts stored
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        try {
            loop@ while (true) {
                if (!inputDone) {
                    val i = decoder.dequeueInputBuffer(TIMEOUT_US)
                    if (i >= 0) {
                        val size = ex.readSampleData(decoder.getInputBuffer(i)!!, 0)
                        if (size < 0 || ex.sampleTime > outUs + 100_000) {
                            decoder.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(i, 0, size, ex.sampleTime, 0)
                            ex.advance()
                        }
                    }
                }
                val o = decoder.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = decoder.outputFormat
                        rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        isFloat = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                            f.getInteger(MediaFormat.KEY_PCM_ENCODING) == PlatformAudioFormat.ENCODING_PCM_FLOAT
                    }
                    o >= 0 -> {
                        val buf = decoder.getOutputBuffer(o)!!.order(ByteOrder.nativeOrder())
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val bytesPer = if (isFloat) 4 else 2
                        var t = info.presentationTimeUs
                        val frameUs = 1_000_000.0 / rate
                        var frameIndex = 0L
                        while (buf.remaining() >= bytesPer * channels) {
                            val ts = t + (frameIndex * frameUs).toLong()
                            val keep = ts >= inUs && ts < outUs
                            for (c in 0 until channels) {
                                val v: Short = if (isFloat) {
                                    (buf.float.coerceIn(-1f, 1f) * 32767).toInt().toShort()
                                } else buf.short
                                if (keep) {
                                    if (count == pcm.size) pcm = pcm.copyOf(pcm.size * 2)
                                    pcm[count++] = v
                                }
                            }
                            frameIndex++
                        }
                        decoder.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break@loop
                    }
                }
            }
        } finally {
            decoder.stop()
            decoder.release()
            ex.release()
        }
        if (count == 0) return null

        // Reverse whole frames (all channels of one moment stay together).
        val frames = count / channels
        val reversed = ShortArray(frames * channels)
        for (f in 0 until frames) {
            val src = (frames - 1 - f) * channels
            for (c in 0 until channels) reversed[f * channels + c] = pcm[src + c]
        }
        return encodeAac(reversed, rate, channels)
    }

    private fun encodeAac(pcm: ShortArray, rate: Int, channels: Int): EncodedAudio {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, channels).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, 256_000)
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 64 * 1024)
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        enc.start()
        val out = mutableListOf<Pair<ByteArray, MediaCodec.BufferInfo>>()
        var outFormat: MediaFormat? = null
        val info = MediaCodec.BufferInfo()
        var pos = 0
        var inputDone = false
        try {
            while (true) {
                if (!inputDone) {
                    val i = enc.dequeueInputBuffer(TIMEOUT_US)
                    if (i >= 0) {
                        val buf = enc.getInputBuffer(i)!!.order(ByteOrder.nativeOrder())
                        buf.clear()
                        val n = min(buf.capacity() / 2, pcm.size - pos)
                        if (n <= 0) {
                            enc.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            val frames = n / channels
                            val shorts = frames * channels
                            buf.asShortBuffer().put(pcm, pos, shorts)
                            val ptsUs = (pos / channels) * 1_000_000L / rate
                            enc.queueInputBuffer(i, 0, shorts * 2, ptsUs, 0)
                            pos += shorts
                            if (shorts == 0) {
                                pos = pcm.size
                            }
                        }
                    }
                }
                val o = enc.dequeueOutputBuffer(info, TIMEOUT_US)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    outFormat = enc.outputFormat
                } else if (o >= 0) {
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                        val buf = enc.getOutputBuffer(o)!!
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val bytes = ByteArray(info.size)
                        buf.get(bytes)
                        val copy = MediaCodec.BufferInfo()
                        copy.set(0, info.size, info.presentationTimeUs, info.flags)
                        out += bytes to copy
                    }
                    enc.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } finally {
            enc.stop()
            enc.release()
        }
        return EncodedAudio(outFormat ?: throw IllegalStateException("AAC encoder gave no format"), out)
    }

    // -------------------------------------------------------------------------
    // Picture
    // -------------------------------------------------------------------------

    private fun reverseVideo(
        context: Context,
        uri: Uri,
        inUs: Long,
        outUs: Long,
        muxer: MediaMuxer,
        audio: EncodedAudio?,
    ) {
        val ex = MediaExtractor()
        ex.setDataSource(context, uri, null)
        var track = -1
        for (i in 0 until ex.trackCount) {
            if (ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                track = i
                break
            }
        }
        if (track < 0) throw IllegalStateException("The file has no video picture.")
        val src = ex.getTrackFormat(track)
        ex.selectTrack(track)

        // Every frame time in the range, and every key frame (decoding has
        // to start from one).
        val frameTimes = ArrayList<Long>()
        val keyFrames = ArrayList<Long>()
        ex.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        while (true) {
            val t = ex.sampleTime
            if (t < 0) break
            if (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) keyFrames += t
            if (t in inUs until outUs) frameTimes += t
            if (t > outUs + 2_000_000) break
            ex.advance()
        }
        frameTimes.sort()
        keyFrames.sort()
        if (frameTimes.isEmpty()) throw IllegalStateException("No video frames in that part of the file.")

        val srcMime = src.getString(MediaFormat.KEY_MIME)!!
        val width = src.getInteger(MediaFormat.KEY_WIDTH)
        val height = src.getInteger(MediaFormat.KEY_HEIGHT)
        val fps = if (frameTimes.size > 1) {
            (frameTimes.size - 1) * 1_000_000.0 / (frameTimes.last() - frameTimes.first())
        } else 30.0
        val transfer = if (src.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) src.getInteger(MediaFormat.KEY_COLOR_TRANSFER) else -1
        val hdr = transfer == MediaFormat.COLOR_TRANSFER_HLG || transfer == MediaFormat.COLOR_TRANSFER_ST2084
        val outMime = if (hdr || srcMime == MediaFormat.MIMETYPE_VIDEO_HEVC) {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        } else MediaFormat.MIMETYPE_VIDEO_AVC

        val encFormat = MediaFormat.createVideoFormat(outMime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            // High quality: this copy is edited and re-encoded again later.
            setInteger(MediaFormat.KEY_BIT_RATE, min(200_000_000.0, width * height * fps * 0.25).toInt())
            setInteger(MediaFormat.KEY_FRAME_RATE, max(1, Math.round(fps).toInt()))
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            for (key in listOf(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.KEY_COLOR_RANGE)) {
                if (src.containsKey(key)) setInteger(key, src.getInteger(key))
            }
            if (src.containsKey(MediaFormat.KEY_HDR_STATIC_INFO)) {
                setByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO, src.getByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO))
            }
            if (hdr) setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10)
        }
        val encoder = MediaCodec.createEncoderByType(outMime)
        encoder.configure(encFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = encoder.createInputSurface()
        encoder.start()

        val decoder = MediaCodec.createDecoderByType(srcMime)
        decoder.configure(src, surface, null, 0)
        decoder.start()

        var muxerStarted = false
        var videoTrack = -1
        val encInfo = MediaCodec.BufferInfo()

        fun drainEncoder(endOfStream: Boolean) {
            while (true) {
                val o = encoder.dequeueOutputBuffer(encInfo, if (endOfStream) TIMEOUT_US else 0)
                when {
                    o == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        videoTrack = muxer.addTrack(encoder.outputFormat)
                        val audioTrack = audio?.let { muxer.addTrack(it.format) }
                        muxer.start()
                        muxerStarted = true
                        if (audio != null && audioTrack != null) {
                            for ((bytes, info) in audio.samples) {
                                muxer.writeSampleData(audioTrack, ByteBuffer.wrap(bytes), info)
                            }
                        }
                    }
                    o >= 0 -> {
                        val buf = encoder.getOutputBuffer(o)!!
                        if (encInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 &&
                            encInfo.size > 0 && muxerStarted
                        ) {
                            buf.position(encInfo.offset)
                            buf.limit(encInfo.offset + encInfo.size)
                            muxer.writeSampleData(videoTrack, buf, encInfo)
                        }
                        encoder.releaseOutputBuffer(o, false)
                        if (encInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    }
                }
            }
        }

        val decInfo = MediaCodec.BufferInfo()
        try {
            val n = frameTimes.size
            for (k in 0 until n) {
                val target = frameTimes[n - 1 - k]
                // How long this frame was shown, so the reversed timing matches.
                val next = if (n - k < n) frameTimes[n - k] else outUs
                val outPts = max(0L, outUs - next)

                val key = keyFrames.lastOrNull { it <= target } ?: keyFrames.first()
                ex.seekTo(key, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                decoder.flush()
                var inputDone = false
                var rendered = false
                while (!rendered) {
                    if (!inputDone) {
                        val i = decoder.dequeueInputBuffer(TIMEOUT_US)
                        if (i >= 0) {
                            val size = ex.readSampleData(decoder.getInputBuffer(i)!!, 0)
                            if (size < 0) {
                                decoder.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                decoder.queueInputBuffer(i, 0, size, ex.sampleTime, 0)
                                ex.advance()
                            }
                        }
                    }
                    val o = decoder.dequeueOutputBuffer(decInfo, TIMEOUT_US)
                    if (o >= 0) {
                        val eos = decInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        if (decInfo.presentationTimeUs >= target || (eos && decInfo.size > 0)) {
                            decoder.releaseOutputBuffer(o, outPts * 1000)
                            rendered = true
                        } else {
                            decoder.releaseOutputBuffer(o, false)
                            if (eos) rendered = true // nothing more to show
                        }
                    }
                    drainEncoder(false)
                }
                progress = 0.1 + 0.88 * (k + 1) / n
            }
            encoder.signalEndOfInputStream()
            drainEncoder(true)
        } finally {
            decoder.stop()
            decoder.release()
            encoder.stop()
            encoder.release()
            surface.release()
            ex.release()
        }
        if (!muxerStarted) throw IllegalStateException("The encoder produced no video.")
        muxer.stop()
    }
}

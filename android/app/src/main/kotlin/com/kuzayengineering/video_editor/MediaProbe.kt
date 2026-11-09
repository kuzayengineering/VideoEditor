package com.kuzayengineering.video_editor

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import java.io.File
import java.io.FileOutputStream

/** One stretch of a source file, as sent from the Flutter side. */
data class Segment(
    val source: String,
    val inUs: Long,
    val outUs: Long,
    val hasAudio: Boolean = true,
    val frameRate: Double = 30.0,
) {
    val lengthUs: Long get() = outUs - inUs

    companion object {
        fun from(map: Map<String, Any?>) = Segment(
            source = map["source"] as String,
            inUs = (map["inUs"] as Number).toLong(),
            outUs = (map["outUs"] as Number).toLong(),
            hasAudio = map["hasAudio"] as Boolean? ?: true,
            frameRate = (map["frameRate"] as Number?)?.toDouble() ?: 30.0,
        )

        fun listFrom(list: List<Map<String, Any?>>) = list.map(::from)
    }
}

/** Reads facts about videos and makes thumbnail pictures. */
object MediaProbe {
    // MediaFormat color constants (spelled out to avoid API-level lookups).
    private const val TRANSFER_ST2084 = 6
    private const val TRANSFER_HLG = 7
    private const val STANDARD_BT2020 = 6

    fun probe(context: Context, source: String): Map<String, Any?> {
        val uri = Uri.parse(source)
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, uri)
            fun meta(key: Int) = retriever.extractMetadata(key)
            val durationMs = meta(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            var width = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            var height = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val rotation = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            if (rotation % 180 != 0) {
                val t = width; width = height; height = t
            }
            val hasVideo = meta(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
            val hasAudio = meta(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
            val frameCount = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toLongOrNull()

            var fps = 0.0
            var transfer = "sdr"
            var wideGamut = false
            var bitDepth = 8
            var codec: String? = null
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(context, uri, null)
                for (i in 0 until extractor.trackCount) {
                    val f = extractor.getTrackFormat(i)
                    val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                    if (!mime.startsWith("video/")) continue
                    codec = when (mime) {
                        MediaFormat.MIMETYPE_VIDEO_HEVC -> "hevc"
                        MediaFormat.MIMETYPE_VIDEO_AVC -> "h264"
                        MediaFormat.MIMETYPE_VIDEO_AV1 -> "av1"
                        MediaFormat.MIMETYPE_VIDEO_VP9 -> "vp9"
                        MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION -> "dolby-vision"
                        else -> mime.removePrefix("video/")
                    }
                    if (f.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                        fps = f.getNumber(MediaFormat.KEY_FRAME_RATE)?.toDouble() ?: 0.0
                    }
                    if (f.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                        transfer = when (f.getInteger(MediaFormat.KEY_COLOR_TRANSFER)) {
                            TRANSFER_HLG -> "hlg"
                            TRANSFER_ST2084 -> "pq"
                            else -> "sdr"
                        }
                    }
                    if (f.containsKey(MediaFormat.KEY_COLOR_STANDARD)) {
                        wideGamut = f.getInteger(MediaFormat.KEY_COLOR_STANDARD) == STANDARD_BT2020
                    }
                    if (f.containsKey(MediaFormat.KEY_PROFILE) && mime == MediaFormat.MIMETYPE_VIDEO_HEVC) {
                        val p = f.getInteger(MediaFormat.KEY_PROFILE)
                        if (p == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 ||
                            p == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10 ||
                            p == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10Plus
                        ) bitDepth = 10
                    }
                    break
                }
            } finally {
                extractor.release()
            }
            if (transfer != "sdr") bitDepth = maxOf(bitDepth, 10)
            if (fps <= 0 && frameCount != null && durationMs > 0) {
                fps = frameCount * 1000.0 / durationMs
            }
            return mapOf(
                "durationUs" to durationMs * 1000,
                "width" to width,
                "height" to height,
                "frameRate" to (if (fps > 0) fps else 30.0),
                "transfer" to transfer,
                "bitDepth" to bitDepth,
                "hasVideo" to hasVideo,
                "hasAudio" to hasAudio,
                "codec" to codec,
                "wideGamut" to wideGamut,
            )
        } finally {
            retriever.release()
        }
    }

    fun thumbnails(context: Context, source: String, timesUs: List<Long>, height: Int): List<String?> {
        val dir = File(context.cacheDir, "thumbnails").apply { mkdirs() }
        val key = Integer.toHexString(source.hashCode())
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, Uri.parse(source))
            var w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 16
            var h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 9
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            if (rotation % 180 != 0) {
                val t = w; w = h; h = t
            }
            val targetW = maxOf(2, (height.toLong() * w / maxOf(1, h)).toInt())
            return timesUs.map { t ->
                val file = File(dir, "${key}_${t}_$height.jpg")
                if (file.exists()) return@map file.absolutePath
                try {
                    val bmp = retriever.getScaledFrameAtTime(
                        t, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, targetW, height) ?: return@map null
                    FileOutputStream(file).use { bmp.compress(Bitmap.CompressFormat.JPEG, 80, it) }
                    bmp.recycle()
                    file.absolutePath
                } catch (_: Exception) {
                    null
                }
            }
        } finally {
            retriever.release()
        }
    }
}

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
    /** Length of the whole source file. */
    val sourceDurationUs: Long = 0,
    val speed: Double = 1.0,
    /** Quarter turns clockwise. */
    val rotation: Int = 0,
    val flipH: Boolean = false,
    val flipV: Boolean = false,
    /** left, top, right, bottom as fractions of the turned picture. */
    val crop: List<Double> = listOf(0.0, 0.0, 1.0, 1.0),
    val opacity: Double = 1.0,
    val volume: Double = 1.0,
    val fadeInUs: Long = 0,
    val fadeOutUs: Long = 0,
    /** Where an audio-track clip starts on the timeline. */
    val startUs: Long = 0,
    /** True when the file also has a picture (its sound is used alone). */
    val hasVideo: Boolean = true,
    /** The sound fades out over this long under a mixing transition. */
    val blendOutUs: Long = 0,
    /** Picture size for picture-in-picture pieces (0: the canvas). */
    val boxW: Int = 0,
    val boxH: Int = 0,
    /** Picture only (its sound is played elsewhere, or not at all). */
    val silent: Boolean = false,
    /** Filter values (brightness, contrast, saturation, warmth, tint,
     * fade), or null for none. */
    val grade: List<Double>? = null,
    /** The clip's signal: "sdr", "hlg" or "pq". */
    val transfer: String = "sdr",
    /** The clip this piece comes from (for live filter changes). */
    val clipId: Int? = null,
) {
    val timelineUs: Long get() = Math.round(lengthUs / speed)

    val lengthUs: Long get() = outUs - inUs

    val hasEffects: Boolean
        get() = rotation != 0 || flipH || flipV || opacity < 0.999 ||
            Math.abs(speed - 1.0) > 0.0001 || grade != null ||
            crop[0] > 0.0005 || crop[1] > 0.0005 || crop[2] < 0.9995 || crop[3] < 0.9995

    companion object {
        fun from(map: Map<String, Any?>) = Segment(
            source = map["source"] as String,
            inUs = (map["inUs"] as Number).toLong(),
            outUs = (map["outUs"] as Number).toLong(),
            hasAudio = map["hasAudio"] as Boolean? ?: true,
            frameRate = (map["frameRate"] as Number?)?.toDouble() ?: 30.0,
            sourceDurationUs = (map["sourceDurationUs"] as Number?)?.toLong() ?: 0L,
            speed = (map["speed"] as Number?)?.toDouble() ?: 1.0,
            rotation = (map["rotation"] as Number?)?.toInt() ?: 0,
            flipH = map["flipH"] as Boolean? ?: false,
            flipV = map["flipV"] as Boolean? ?: false,
            crop = (map["crop"] as List<*>?)?.map { (it as Number).toDouble() }
                ?: listOf(0.0, 0.0, 1.0, 1.0),
            opacity = (map["opacity"] as Number?)?.toDouble() ?: 1.0,
            volume = (map["volume"] as Number?)?.toDouble() ?: 1.0,
            fadeInUs = (map["fadeInUs"] as Number?)?.toLong() ?: 0L,
            fadeOutUs = (map["fadeOutUs"] as Number?)?.toLong() ?: 0L,
            startUs = (map["startUs"] as Number?)?.toLong() ?: 0L,
            hasVideo = map["hasVideo"] as Boolean? ?: true,
            blendOutUs = (map["blendOutUs"] as Number?)?.toLong() ?: 0L,
            boxW = (map["boxW"] as Number?)?.toInt() ?: 0,
            boxH = (map["boxH"] as Number?)?.toInt() ?: 0,
            silent = map["silent"] as Boolean? ?: false,
            grade = (map["grade"] as List<*>?)?.map { (it as Number).toDouble() },
            transfer = map["transfer"] as String? ?: "sdr",
            clipId = (map["clipId"] as Number?)?.toInt(),
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
                "createdAtMs" to recordedAt(meta(MediaMetadataRetriever.METADATA_KEY_DATE)),
            )
        } finally {
            retriever.release()
        }
    }

    /** "20261105T123456.000Z" (the file's recording date) → ms since 1970. */
    private fun recordedAt(text: String?): Long? {
        if (text.isNullOrBlank()) return null
        for (pattern in listOf("yyyyMMdd'T'HHmmss.SSS'Z'", "yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss")) {
            try {
                val f = java.text.SimpleDateFormat(pattern, java.util.Locale.US)
                f.timeZone = java.util.TimeZone.getTimeZone("UTC")
                val ms = f.parse(text)?.time ?: continue
                // Files without a real date say 1904 or 1970.
                return if (ms > 86_400_000L * 366) ms else null
            } catch (_: Exception) {
            }
        }
        return null
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

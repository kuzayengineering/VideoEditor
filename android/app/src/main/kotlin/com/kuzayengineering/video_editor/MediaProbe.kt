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
    /** Make in-between frames when exporting (slowed-down clips). */
    val smooth: Boolean = false,
    /** Picture-in-picture person cutout: the background see-through. */
    val cutout: Boolean = false,
    /** Main-video cutout: the colour (ARGB) behind the people. Null: the
     * background becomes see-through (picture in picture). */
    val cutoutFill: Int? = null,
    /** Hair, skin and clothes colours (ARGB, 0: unchanged), how strongly,
     * and the downloaded model that finds them. */
    val recolor: List<Int>? = null,
    val recolorStrength: Float = 0.8f,
    val partsModel: String? = null,
    /** Eye colour (ARGB, 0: none), how strongly, and the face model. */
    val eyeColor: Int = 0,
    val eyeStrength: Float = 0.7f,
    val eyeBright: Float = 0f,
    val faceModel: String? = null,
    /** Outfit: shirt, gloves, socks, stockings colours (0: none), sleeves
     * (0 none, 1 short, 2 long), stockings' top on the thigh, how sheer,
     * and the body model. */
    val outfit: List<Int>? = null,
    val outfitSleeves: Int = 2,
    val outfitTop: Float = 0.35f,
    val outfitSheer: Float = 0f,
    val outfitPattern: Int = 0,
    val poseModel: String? = null,
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
    /** Sound effects (equalizer, pitch, delay, reverb), if any. */
    val fx: FxSpec? = null,
) {
    val timelineUs: Long get() = Math.round(lengthUs / speed)

    val lengthUs: Long get() = outUs - inUs

    val hasEffects: Boolean
        get() = rotation != 0 || flipH || flipV || opacity < 0.999 || cutout ||
            (recolor != null && partsModel != null) ||
            ((eyeColor != 0 || eyeBright > 0f) && faceModel != null) ||
            (outfit != null && poseModel != null && partsModel != null) ||
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
            smooth = map["smooth"] as Boolean? ?: false,
            cutout = map["cutout"] as Boolean? ?: false,
            cutoutFill = (map["cutoutFill"] as Number?)?.toInt(),
            recolor = (map["recolor"] as List<*>?)
                ?.map { (it as Number).toLong().toInt() },
            recolorStrength = (map["recolorStrength"] as Number?)?.toFloat() ?: 0.8f,
            partsModel = map["partsModel"] as String?,
            eyeColor = (map["eyeColor"] as Number?)?.toLong()?.toInt() ?: 0,
            eyeStrength = (map["eyeStrength"] as Number?)?.toFloat() ?: 0.7f,
            eyeBright = (map["eyeBright"] as Number?)?.toFloat() ?: 0f,
            faceModel = map["faceModel"] as String?,
            outfit = (map["outfit"] as List<*>?)?.map { (it as Number).toLong().toInt() },
            outfitSleeves = (map["outfitSleeves"] as Number?)?.toInt() ?: 2,
            outfitTop = (map["outfitTop"] as Number?)?.toFloat() ?: 0.35f,
            outfitSheer = (map["outfitSheer"] as Number?)?.toFloat() ?: 0f,
            outfitPattern = (map["outfitPattern"] as Number?)?.toInt() ?: 0,
            poseModel = map["poseModel"] as String?,
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
            fx = FxSpec.from(map["audioFx"] as Map<*, *>?),
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
            var bitRate: Int? = null
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
                    if (f.containsKey(MediaFormat.KEY_BIT_RATE)) {
                        bitRate = f.getNumber(MediaFormat.KEY_BIT_RATE)?.toInt()
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
                "videoBitRate" to bitRate,
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

    fun thumbnails(
        context: Context,
        source: String,
        timesUs: List<Long>,
        height: Int,
        exact: Boolean = false,
    ): List<String?> {
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
                val file = File(dir, "${key}_${t}_$height${if (exact) "x" else ""}.jpg")
                if (file.exists()) return@map file.absolutePath
                try {
                    val bmp = retriever.getScaledFrameAtTime(
                        t,
                        // Exact: the frame itself (a clip's first frame);
                        // otherwise the nearest key frame (much faster).
                        if (exact) MediaMetadataRetriever.OPTION_CLOSEST
                        else MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        targetW, height) ?: return@map null
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

package com.kuzayengineering.video_editor

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.media3.common.OverlaySettings
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TextureOverlay
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.pow

/**
 * One text overlay for the export. The picture was drawn by the app (the
 * same drawing the preview shows); here it is placed and animated with the
 * same formulas as textFrameAt() in lib/model/text_spec.dart.
 */
data class TextLayer(
    val startUs: Long,
    val durationUs: Long,
    val x: Double,
    val y: Double,
    val animIn: String,
    val animInUs: Long,
    val animOut: String,
    val animOutUs: Long,
    val fullPath: String,
    val typewriterPaths: List<String>,
    val charCount: Int,
) {
    companion object {
        fun from(m: Map<String, Any?>) = TextLayer(
            startUs = (m["startUs"] as Number).toLong(),
            durationUs = (m["durationUs"] as Number).toLong(),
            x = (m["x"] as Number).toDouble(),
            y = (m["y"] as Number).toDouble(),
            animIn = m["animIn"] as String,
            animInUs = (m["animInUs"] as Number).toLong(),
            animOut = m["animOut"] as String,
            animOutUs = (m["animOutUs"] as Number).toLong(),
            fullPath = m["full"] as String,
            @Suppress("UNCHECKED_CAST")
            typewriterPaths = (m["typewriter"] as List<String>?) ?: emptyList(),
            charCount = (m["charCount"] as Number?)?.toInt() ?: 0,
        )
    }
}

private const val SLIDE = 0.12

private fun ease(p: Double): Double = 1 - (1 - p.coerceIn(0.0, 1.0)).pow(3)

private class Frame(var alpha: Double = 1.0, var dx: Double = 0.0, var dy: Double = 0.0,
                    var scale: Double = 1.0, var chars: Int? = null)

private fun frameAt(t: TextLayer, offsetUs: Long): Frame {
    val f = Frame()
    fun apply(a: String, p: Double, leaving: Boolean) {
        val e = ease(p)
        val sign = if (leaving) -1.0 else 1.0
        when (a) {
            "fade" -> f.alpha *= p
            "slideUp" -> { f.dy += sign * (1 - e) * SLIDE; f.alpha *= p }
            "slideDown" -> { f.dy -= sign * (1 - e) * SLIDE; f.alpha *= p }
            "slideLeft" -> { f.dx += sign * (1 - e) * SLIDE; f.alpha *= p }
            "slideRight" -> { f.dx -= sign * (1 - e) * SLIDE; f.alpha *= p }
            "pop" -> { f.scale *= 0.5 + 0.5 * e; f.alpha *= p }
            "typewriter" -> {
                val shown = ceil(t.charCount * p).toInt().coerceIn(0, t.charCount)
                f.chars = f.chars?.let { min(it, shown) } ?: shown
            }
        }
    }
    val inLen = if (t.animIn == "none") 0 else min(t.animInUs, t.durationUs / 2)
    val outLen = if (t.animOut == "none") 0 else min(t.animOutUs, t.durationUs / 2)
    if (inLen > 0 && offsetUs < inLen) apply(t.animIn, offsetUs.toDouble() / inLen, false)
    val fromEnd = t.durationUs - offsetUs
    if (outLen > 0 && fromEnd < outLen) {
        apply(t.animOut, (fromEnd.toDouble() / outLen).coerceIn(0.0, 1.0), true)
    }
    f.alpha = f.alpha.coerceIn(0.0, 1.0)
    return f
}

/** A text overlay that animates over time. */
private class AnimatedTextOverlay(private val t: TextLayer) : BitmapOverlay() {
    private val full: Bitmap = BitmapFactory.decodeFile(t.fullPath)
        ?: throw IllegalStateException("Text picture missing: ${t.fullPath}")
    private val steps = HashMap<Int, Bitmap>()

    private fun step(i: Int): Bitmap = steps.getOrPut(i) {
        BitmapFactory.decodeFile(t.typewriterPaths[i]) ?: full
    }

    override fun getBitmap(presentationTimeUs: Long): Bitmap {
        val offset = presentationTimeUs - t.startUs
        if (offset < 0 || offset >= t.durationUs) return full
        val chars = frameAt(t, offset).chars
        return if (chars != null && t.typewriterPaths.isNotEmpty()) {
            step(chars.coerceIn(0, t.typewriterPaths.size - 1))
        } else full
    }

    override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings {
        val offset = presentationTimeUs - t.startUs
        if (offset < 0 || offset >= t.durationUs) {
            return StaticOverlaySettings.Builder().setAlphaScale(0f).build()
        }
        val f = frameAt(t, offset)
        // Media3 places overlays in -1…1 coordinates with up as positive.
        val ax = (2 * (t.x + f.dx) - 1).toFloat().coerceIn(-1f, 1f)
        val ay = (1 - 2 * (t.y + f.dy)).toFloat().coerceIn(-1f, 1f)
        return StaticOverlaySettings.Builder()
            .setAlphaScale(f.alpha.toFloat())
            .setScale(f.scale.toFloat(), f.scale.toFloat())
            .setOverlayFrameAnchor(0f, 0f)
            .setBackgroundFrameAnchor(ax, ay)
            .build()
    }
}

object TextOverlays {
    fun create(layers: List<TextLayer>): List<TextureOverlay> =
        layers.map { AnimatedTextOverlay(it) }
}

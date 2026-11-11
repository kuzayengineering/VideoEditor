package com.kuzayengineering.video_editor

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram

/**
 * A clip's filter (brightness, contrast, saturation, warmth, tint, fade).
 *
 * The filter maths (the same as the Flutter side's applyGrade and the
 * Windows lookup table) works on the video signal. For SDR output Media3
 * already hands effects the signal; for HDR it hands linear light, so each
 * pixel is turned into the signal of [transfer] ("hlg" or "pq"), filtered,
 * and turned into light again. Every step keeps 0 at 0 and 1 at 1, so HDR
 * highlights don't clip.
 */
class GradeEffect(
    private val params: FloatArray,
    private val transfer: String,
    /** Preview only: the clip whose live values (from the sliders) to use. */
    private val liveClipId: Int? = null,
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        GradeShaderProgram(params, transfer, useHdr, liveClipId)
}

/** Filter values being adjusted right now, by clip id (preview). */
object LiveGrades {
    private val values = java.util.concurrent.ConcurrentHashMap<Int, FloatArray>()

    fun get(clipId: Int): FloatArray? = values[clipId]

    fun set(all: Map<Int, FloatArray>) {
        values.clear()
        values.putAll(all)
    }
}

private class GradeShaderProgram(
    private val params: FloatArray,
    transfer: String,
    useHdr: Boolean,
    private val liveClipId: Int?,
) : BaseGlShaderProgram(useHdr, 1) {
    private val program: GlProgram

    init {
        try {
            program = GlProgram(VERTEX, FRAGMENT)
            program.setBufferAttribute(
                "aFramePosition",
                GlUtil.getNormalizedCoordinateBounds(),
                GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
            )
            setValues(params)
            program.setIntUniform(
                "uTransfer",
                when {
                    !useHdr -> 0
                    transfer == "pq" -> 2
                    else -> 1
                },
            )
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e)
        }
    }

    override fun configure(inputWidth: Int, inputHeight: Int): Size = Size(inputWidth, inputHeight)

    private fun setValues(p: FloatArray) {
        program.setFloatUniform("uBrightness", p.getOrElse(0) { 0f })
        program.setFloatUniform("uContrast", p.getOrElse(1) { 0f })
        program.setFloatUniform("uSaturation", p.getOrElse(2) { 0f })
        program.setFloatUniform("uWarmth", p.getOrElse(3) { 0f })
        program.setFloatUniform("uTint", p.getOrElse(4) { 0f })
        program.setFloatUniform("uFade", p.getOrElse(5) { 0f })
        program.setFloatUniform("uShadows", p.getOrElse(6) { 0f })
        program.setFloatUniform("uHighlights", p.getOrElse(7) { 0f })
        program.setFloatUniform("uHdr", p.getOrElse(8) { 0f })
    }

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        try {
            // While a slider moves, its newest values (no rebuild needed).
            liveClipId?.let { id -> LiveGrades.get(id)?.let { setValues(it) } }
            program.use()
            program.setSamplerTexIdUniform("uTex", inputTexId, 0)
            program.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e, presentationTimeUs)
        }
    }

    override fun release() {
        super.release()
        try {
            program.delete()
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e)
        }
    }

    private companion object {
        const val VERTEX = """#version 100
attribute vec4 aFramePosition;
varying vec2 vUv;
void main() {
  gl_Position = aFramePosition;
  vUv = vec2(aFramePosition.x * 0.5 + 0.5, aFramePosition.y * 0.5 + 0.5);
}
"""

        // Signal <-> light conversions are Media3's own (BT.2100 HLG, and PQ
        // scaled so 1.0 is 1000 nits as Media3 keeps it). uTransfer 0: the
        // values already are the signal (SDR).
        const val FRAGMENT = """#version 100
precision highp float;
uniform sampler2D uTex;
uniform int uTransfer;
uniform float uBrightness;
uniform float uContrast;
uniform float uSaturation;
uniform float uWarmth;
uniform float uTint;
uniform float uFade;
uniform float uShadows;
uniform float uHighlights;
uniform float uHdr;
varying vec2 vUv;

const float HA = 0.17883277;
const float HB = 0.28466892;
const float HC = 0.55991073;
const float M1 = 2610.0 / 16384.0;
const float M2 = (2523.0 / 4096.0) * 128.0;
const float C1 = 3424.0 / 4096.0;
const float C2 = (2413.0 / 4096.0) * 32.0;
const float C3 = (2392.0 / 4096.0) * 32.0;

float toSignal(float l) {
  l = max(l, 0.0);
  if (uTransfer == 1) {
    return l <= 1.0 / 12.0 ? sqrt(3.0 * l) : HA * log(12.0 * l - HB) + HC;
  } else if (uTransfer == 2) {
    float t = pow(l / 10.0, M1);
    return pow((C1 + C2 * t) / (1.0 + C3 * t), M2);
  }
  return l;
}

float toLight(float s) {
  s = clamp(s, 0.0, 1.0);
  if (uTransfer == 1) {
    return s <= 0.5 ? s * s / 3.0 : (HB + exp((s - HC) / HA)) / 12.0;
  } else if (uTransfer == 2) {
    float t = pow(s, 1.0 / M2);
    t = max(t - C1, 0.0) / (C2 - C3 * t);
    return pow(t, 1.0 / M1) * 10.0;
  }
  return s;
}

float curve(float x) {
  x = pow(x, pow(2.0, -uBrightness));
  x = x + uShadows * x * (1.0 - x) * (1.0 - x);
  x = x + uHighlights * x * x * (1.0 - x);
  x = x + uContrast * (x * x * (3.0 - 2.0 * x) - x);
  // Paper white in this signal: above it is HDR's extra range.
  float knee = uTransfer == 2 ? 0.58 : 0.75;
  if (x > knee) {
    float t = (x - knee) / (1.0 - knee);
    float scale = uHdr < 0.0 ? 1.0 + 0.5 * uHdr : 1.0;
    x = knee + (1.0 - knee) * pow(t, pow(2.0, -uHdr)) * scale;
  }
  float f = 0.12 * uFade;
  return f + x * (1.0 - f);
}

void main() {
  vec4 lin = texture2D(uTex, vUv);
  vec3 c = vec3(toSignal(lin.r), toSignal(lin.g), toSignal(lin.b));
  float y = dot(c, vec3(0.2126, 0.7152, 0.0722));
  c = y + (c - y) * (1.0 + uSaturation);
  if (uWarmth > 0.0) {
    c.g *= 1.0 - 0.06 * uWarmth;
    c.b *= 1.0 - 0.22 * uWarmth;
  } else {
    c.r *= 1.0 + 0.22 * uWarmth;
    c.g *= 1.0 + 0.06 * uWarmth;
  }
  if (uTint > 0.0) {
    c.g *= 1.0 - 0.15 * uTint;
  } else {
    c.r *= 1.0 + 0.15 * uTint;
    c.b *= 1.0 + 0.15 * uTint;
  }
  c = clamp(c, 0.0, 1.0);
  c = vec3(curve(c.r), curve(c.g), curve(c.b));
  gl_FragColor = vec4(toLight(c.r), toLight(c.g), toLight(c.b), lin.a);
}
"""
    }
}

package com.kuzayengineering.video_editor

import android.opengl.GLES20
import androidx.media3.common.GlTextureInfo
import androidx.media3.common.OverlaySettings
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.effect.CustomVideoBlender
import androidx.media3.effect.StaticOverlaySettings

/** One transition that mixes two clips, in timeline time. */
data class Blend(val startUs: Long, val durationUs: Long, val code: Int) {
    companion object {
        fun from(m: Map<*, *>) = Blend(
            (m["startUs"] as Number).toLong(),
            (m["durationUs"] as Number).toLong(),
            (m["code"] as Number).toInt(),
        )
    }
}

/**
 * Tells Media3's (patched) video blender to mix the two picture layers with
 * [TransitionBlender]. Layer 0 holds each clip with its end; layer 1 holds
 * each clip with its start (see blendLayersOf on the Flutter side), so during
 * a transition layer 0 shows the outgoing clip and layer 1 the incoming one.
 */
class BlendSettings(
    private val blends: List<Blend>,
    private val pips: List<PipDraw> = emptyList(),
    private val inputCount: Int = 2,
) : CustomVideoBlender.Provider {
    override fun createBlender(): CustomVideoBlender =
        TransitionBlender(blends, pips, hasLayerB = blends.isNotEmpty())

    override fun getInputCount(): Int = inputCount

    // Both layers are already fitted to the canvas.
    override fun getOutputSize(inputSizes: List<Size>): Size = inputSizes[0]

    override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings =
        StaticOverlaySettings.Builder().build()
}

/**
 * Draws one frame: layer 0 alone, or during a transition both layers mixed
 * by the transition's picture. The maths matches FFmpeg's xfade filter
 * (used by the Windows version), so both look the same.
 */
/** A picture-in-picture layer to draw: its input number and clips' places. */
class PipDraw(val input: Int, val windows: List<PipWindow>)

class TransitionBlender(
    private val blends: List<Blend>,
    private val pips: List<PipDraw> = emptyList(),
    private val hasLayerB: Boolean = true,
) : CustomVideoBlender {
    private var program: GlProgram? = null
    private var pipProgram: GlProgram? = null

    override fun draw(
        inputs: Array<out GlTextureInfo>,
        presentationTimeUs: Long,
        outputWidth: Int,
        outputHeight: Int,
        hdr: Boolean,
    ) {
        val a = inputs.getOrNull(0) ?: return
        var b = if (hasLayerB) inputs.getOrNull(1) else null
        var code = 0
        var t = 0f
        for (blend in blends) {
            if (presentationTimeUs >= blend.startUs &&
                presentationTimeUs < blend.startUs + blend.durationUs
            ) {
                code = blend.code
                t = ((presentationTimeUs - blend.startUs).toFloat() / blend.durationUs)
                    .coerceIn(0f, 1f)
            }
        }
        if (b == null) {
            b = a
            code = 0
        }
        val p = program ?: GlProgram(VERTEX, FRAGMENT).also {
            it.setBufferAttribute(
                "aFramePosition",
                GlUtil.getNormalizedCoordinateBounds(),
                GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
            )
            program = it
        }
        p.use()
        p.setSamplerTexIdUniform("uA", a.texId, 0)
        p.setSamplerTexIdUniform("uB", b.texId, 1)
        p.setIntUniform("uKind", code)
        p.setFloatUniform("uT", t)
        p.setFloatsUniform("uSize", floatArrayOf(outputWidth.toFloat(), outputHeight.toFloat()))
        p.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GlUtil.checkGlError()
        drawPips(inputs, presentationTimeUs, outputWidth.toFloat(), outputHeight.toFloat())
    }

    /** Picture-in-picture clips showing now, each a turned, see-through box. */
    private fun drawPips(inputs: Array<out GlTextureInfo>, timeUs: Long, cw: Float, ch: Float) {
        var blending = false
        for (layer in pips) {
            val win = layer.windows.firstOrNull { timeUs >= it.startUs && timeUs < it.endUs }
                ?: continue
            val tex = inputs.getOrNull(layer.input) ?: continue
            val p = pipProgram ?: GlProgram(PIP_VERTEX, PIP_FRAGMENT).also { pipProgram = it }
            // The box's corners in pixels (y down), turned clockwise about
            // its centre, then in GL's -1…1 space (y up).
            val cx = win.x * cw
            val cy = win.y * ch
            val w = win.w * cw
            val h = win.h * ch
            val a = Math.toRadians(win.angle.toDouble())
            val cos = Math.cos(a).toFloat()
            val sin = Math.sin(a).toFloat()
            val corners = floatArrayOf(-0.5f, -0.5f, -0.5f, 0.5f, 0.5f, -0.5f, 0.5f, 0.5f)
            val pos = FloatArray(8)
            val uv = FloatArray(8)
            for (i in 0 until 4) {
                val qx = corners[2 * i]
                val qy = corners[2 * i + 1]
                val px = cx + qx * w * cos - qy * h * sin
                val py = cy + qx * w * sin + qy * h * cos
                pos[2 * i] = px / cw * 2f - 1f
                pos[2 * i + 1] = 1f - py / ch * 2f
                uv[2 * i] = qx + 0.5f
                uv[2 * i + 1] = 0.5f - qy
            }
            if (!blending) {
                GLES20.glEnable(GLES20.GL_BLEND)
                GLES20.glBlendFuncSeparate(
                    GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA,
                    GLES20.GL_ZERO, GLES20.GL_ONE,
                )
                blending = true
            }
            p.use()
            p.setBufferAttribute("aPos", pos, 2)
            p.setBufferAttribute("aTex", uv, 2)
            p.setSamplerTexIdUniform("uTex", tex.texId, 0)
            p.setFloatUniform("uAlpha", win.opacity.coerceIn(0f, 1f))
            p.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GlUtil.checkGlError()
        }
        if (blending) GLES20.glDisable(GLES20.GL_BLEND)
    }

    override fun release() {
        program?.delete()
        program = null
        pipProgram?.delete()
        pipProgram = null
    }

    private companion object {
        const val PIP_VERTEX = """#version 100
attribute vec2 aPos;
attribute vec2 aTex;
varying vec2 vTex;
void main() {
  gl_Position = vec4(aPos, 0.0, 1.0);
  vTex = aTex;
}
"""

        const val PIP_FRAGMENT = """#version 100
precision highp float;
uniform sampler2D uTex;
uniform float uAlpha;
varying vec2 vTex;
void main() {
  gl_FragColor = vec4(texture2D(uTex, vTex).rgb, uAlpha);
}
"""

        const val VERTEX = """#version 100
attribute vec4 aFramePosition;
varying vec2 vUv;
void main() {
  gl_Position = aFramePosition;
  vUv = vec2(aFramePosition.x * 0.5 + 0.5, aFramePosition.y * 0.5 + 0.5);
}
"""

        // p: position with (0,0) at the top left and (1,1) at the bottom
        // right, like FFmpeg's pixel rows. t: 0 at the start of the
        // transition, 1 at the end; P = 1 - t is FFmpeg's "progress".
        const val FRAGMENT = """#version 100
precision highp float;
uniform sampler2D uA;
uniform sampler2D uB;
uniform int uKind;
uniform float uT;
uniform vec2 uSize;
varying vec2 vUv;

vec4 sa(vec2 p) { return texture2D(uA, vec2(p.x, 1.0 - p.y)); }
vec4 sb(vec2 p) { return texture2D(uB, vec2(p.x, 1.0 - p.y)); }
float rnd(vec2 q) { return fract(sin(q.x * 12.9898 + q.y * 78.233) * 43758.545); }

void main() {
  vec2 p = vec2(vUv.x, 1.0 - vUv.y);
  float t = clamp(uT, 0.0, 1.0);
  float P = 1.0 - t;
  vec4 a = sa(p);
  vec4 b = sb(p);
  vec4 black = vec4(0.0, 0.0, 0.0, 1.0);
  vec4 c = a;
  float s;
  if (uKind == 1) {                 // crossfade
    c = mix(a, b, t);
  } else if (uKind == 2) {          // dissolve
    s = rnd(floor(p * uSize)) * 2.0 + P * 2.0 - 1.5;
    c = s >= 0.5 ? a : b;
  } else if (uKind == 3) {          // pixelate
    float d = min(P, 1.0 - P);
    float dist = ceil(d * 50.0) / 50.0;
    float sq = 2.0 * dist * min(uSize.x, uSize.y) / 20.0;
    vec2 q = p;
    if (dist > 0.0) {
      q = min((floor(p * uSize / sq) + 0.5) * sq, uSize - 1.0) / uSize;
    }
    c = mix(sa(q), sb(q), t);
  } else if (uKind == 4) {          // zoom in
    float zf = smoothstep(0.5, 1.0, P);
    vec4 za = sa(0.5 + (p - 0.5) * zf);
    c = mix(b, za, smoothstep(0.0, 0.5, P));
  } else if (uKind == 10) {         // slide left
    s = p.x + t - 1.0;
    c = s >= 0.0 ? sb(vec2(s, p.y)) : sa(vec2(p.x + t, p.y));
  } else if (uKind == 11) {         // slide right
    s = p.x + 1.0 - t;
    c = s < 1.0 ? sb(vec2(s, p.y)) : sa(vec2(s - 1.0, p.y));
  } else if (uKind == 12) {         // slide up
    s = p.y + t - 1.0;
    c = s >= 0.0 ? sb(vec2(p.x, s)) : sa(vec2(p.x, p.y + t));
  } else if (uKind == 13) {         // slide down
    s = p.y + 1.0 - t;
    c = s < 1.0 ? sb(vec2(p.x, s)) : sa(vec2(p.x, s - 1.0));
  } else if (uKind == 14) {         // cover left
    s = p.x + t - 1.0;
    c = s >= 0.0 ? sb(vec2(s, p.y)) : a;
  } else if (uKind == 15) {         // cover right
    s = p.x + 1.0 - t;
    c = s < 1.0 ? sb(vec2(s, p.y)) : a;
  } else if (uKind == 16) {         // cover up
    s = p.y + t - 1.0;
    c = s >= 0.0 ? sb(vec2(p.x, s)) : a;
  } else if (uKind == 17) {         // cover down
    s = p.y + 1.0 - t;
    c = s < 1.0 ? sb(vec2(p.x, s)) : a;
  } else if (uKind == 18) {         // reveal left
    s = p.x + t - 1.0;
    c = s >= 0.0 ? b : sa(vec2(p.x + t, p.y));
  } else if (uKind == 19) {         // reveal right
    s = p.x + 1.0 - t;
    c = s < 1.0 ? b : sa(vec2(s - 1.0, p.y));
  } else if (uKind == 20) {         // reveal up
    s = p.y + t - 1.0;
    c = s >= 0.0 ? b : sa(vec2(p.x, p.y + t));
  } else if (uKind == 21) {         // reveal down
    s = p.y + 1.0 - t;
    c = s < 1.0 ? b : sa(vec2(p.x, s - 1.0));
  } else if (uKind == 30) {         // wipe left
    c = p.x > P ? b : a;
  } else if (uKind == 31) {         // wipe right
    c = p.x > t ? a : b;
  } else if (uKind == 32) {         // wipe up
    c = p.y > P ? b : a;
  } else if (uKind == 33) {         // wipe down
    c = p.y > t ? a : b;
  } else if (uKind == 34) {         // soft wipe left
    c = mix(a, b, smoothstep(0.0, 1.0, 1.0 + p.x - 2.0 * P));
  } else if (uKind == 35) {         // soft wipe right
    c = mix(a, b, smoothstep(0.0, 1.0, 2.0 - p.x - 2.0 * P));
  } else if (uKind == 36) {         // soft wipe up
    c = mix(a, b, smoothstep(0.0, 1.0, 1.0 + p.y - 2.0 * P));
  } else if (uKind == 37) {         // soft wipe down
    c = mix(a, b, smoothstep(0.0, 1.0, 2.0 - p.y - 2.0 * P));
  } else if (uKind == 38) {         // corner, to the top left
    c = (p.y <= P && p.x <= P) ? a : b;
  } else if (uKind == 39) {         // corner, to the top right
    c = (p.y <= P && p.x > t) ? a : b;
  } else if (uKind == 40) {         // corner, to the bottom left
    c = (p.y > t && p.x <= P) ? a : b;
  } else if (uKind == 41) {         // corner, to the bottom right
    c = (p.y > t && p.x > t) ? a : b;
  } else if (uKind == 42) {         // clock
    vec2 dp = (p - 0.5) * uSize;
    s = atan(dp.x, dp.y) - (P - 0.5) * 7.853982;
    c = mix(a, b, smoothstep(0.0, 1.0, s));
  } else if (uKind == 50) {         // circle open
    s = length((p - 0.5) * uSize) / length(uSize * 0.5) + (P - 0.5) * 3.0;
    c = mix(b, a, smoothstep(0.0, 1.0, s));
  } else if (uKind == 51) {         // circle close
    s = length((p - 0.5) * uSize) / length(uSize * 0.5) + (t - 0.5) * 3.0;
    c = mix(a, b, smoothstep(0.0, 1.0, s));
  } else if (uKind == 52) {         // iris (through black)
    float r = pow(2.0 * abs(P - 0.5), 3.0) * length(uSize * 0.5);
    c = r < length((p - 0.5) * uSize) ? black : (P < 0.5 ? b : a);
  } else if (uKind == 53) {         // box (through black)
    float h = abs(P - 0.5);
    bool inside = abs(p.x - 0.5) < h && abs(p.y - 0.5) < h;
    c = inside ? (P < 0.5 ? b : a) : black;
  } else if (uKind == 54) {         // doors open
    c = mix(a, b, smoothstep(0.0, 1.0, 2.0 - abs(p.x - 0.5) * 2.0 - 2.0 * P));
  } else if (uKind == 55) {         // doors close
    c = mix(a, b, smoothstep(0.0, 1.0, 1.0 + abs(p.x - 0.5) * 2.0 - 2.0 * P));
  } else if (uKind == 56) {         // split open
    c = mix(a, b, smoothstep(0.0, 1.0, 2.0 - abs(p.y - 0.5) * 2.0 - 2.0 * P));
  } else if (uKind == 57) {         // split close
    c = mix(a, b, smoothstep(0.0, 1.0, 1.0 + abs(p.y - 0.5) * 2.0 - 2.0 * P));
  }
  gl_FragColor = c;
}
"""
    }
}

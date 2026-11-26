package com.kuzayengineering.video_editor

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.GlTextureInfo
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlRect
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.effect.ByteBufferGlEffect
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.ListeningExecutorService
import com.google.common.util.concurrent.MoreExecutors
import org.tensorflow.lite.Interpreter
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/**
 * Recolours parts of the people in a picture: hair, skin and clothes, each
 * with its own colour (or left alone), keeping their shading.
 *
 * Each frame is shrunk to 256 × 256 and Google's MediaPipe "selfie
 * multiclass" model (Apache 2.0, downloaded once, runs on the phone) marks
 * how much each spot is hair, skin or clothes. The colour is then mixed in
 * by that amount.
 */
class PartsRecolor(
    private val model: String,
    /** ARGB colours for hair, skin and clothes; 0 leaves that part alone. */
    private val colors: IntArray,
    private val strength: Float,
    /** Find people at most this often (video time); frames between reuse
     * the latest answer. */
    private val everyUs: Long = 0,
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        ByteBufferGlEffect(Processor(model, colors, strength, everyUs, useHdr))
            .toGlShaderProgram(context, useHdr)

    private class Processor(
        private val model: String,
        private val colors: IntArray,
        private val strength: Float,
        private val everyUs: Long,
        private val useHdr: Boolean,
    ) : ByteBufferGlEffect.Processor<ByteArray> {
        private var lastFuture: ListenableFuture<ByteArray>? = null
        private var lastAskedUs = 0L
        private val executor: ListeningExecutorService =
            MoreExecutors.listeningDecorator(Executors.newSingleThreadExecutor())
        private var interpreter: Interpreter? = null
        private val input = ByteBuffer.allocateDirect(SIZE * SIZE * 3 * 4).order(ByteOrder.nativeOrder())
        private val output = ByteBuffer.allocateDirect(SIZE * SIZE * CLASSES * 4).order(ByteOrder.nativeOrder())
        /** Last frame's amounts (hair, skin, clothes), mixed in a little to
         * stop edges flickering. */
        private val previous = FloatArray(SIZE * SIZE * 3)
        private var previousUs = Long.MIN_VALUE
        private val meanLight = floatArrayOf(30f, 60f, 50f)
        private val lightSum = FloatArray(3)
        private val lightWeight = FloatArray(3)
        @Volatile private var broken = false
        private var inputW = 0
        private var inputH = 0
        private var program: GlProgram? = null
        private var maskTex = 0
        private var smallTex = 0
        private var frameCopy: GlTextureInfo? = null
        private val maskBuffer = ByteBuffer.allocateDirect(SIZE * SIZE * 3)

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            inputW = inputWidth
            inputH = inputHeight
            return Size(SIZE, SIZE)
        }

        override fun getScaledRegion(presentationTimeUs: Long) = GlRect(inputW, inputH)

        override fun processImage(
            image: ByteBufferGlEffect.Image,
            presentationTimeUs: Long,
        ): ListenableFuture<ByteArray> {
            // Reuse the latest answer for frames close to it.
            val near = lastFuture
            if (near != null && Math.abs(presentationTimeUs - lastAskedUs) < everyUs) return near
            lastAskedUs = presentationTimeUs
            val px = ByteArray(image.width * image.height * 4)
            image.pixelBuffer.rewind()
            image.pixelBuffer.get(px)
            val f = executor.submit<ByteArray> {
                // Counted from when the work starts (not while queued).
                val job = EffectStatus.start("Recolor")
                try {
                    if (broken) ByteArray(RESULT)
                    else classify(px, image.width, image.height, presentationTimeUs)
                } catch (t: Throwable) {
                    // An empty mask leaves the picture as it is.
                    broken = true
                    EffectStatus.fail("Recolor", t)
                    ByteArray(RESULT)
                } finally {
                    EffectStatus.end(job)
                }
            }
            lastFuture = f
            return f
        }

        private fun classify(px: ByteArray, w: Int, h: Int, timeUs: Long): ByteArray {
            val interp = interpreter ?: Interpreter(
                File(model),
                Interpreter.Options().setNumThreads(4),
            ).also { interpreter = it }
            // The small picture, top row first (people upright). It is also
            // sent back with the result: the edges are snapped to it.
            val out = ByteArray(RESULT)
            var green = 0L
            for (y in 0 until SIZE) {
                val row = (h - 1 - y * h / SIZE) * w
                for (x in 0 until SIZE) {
                    val i = (row + x * w / SIZE) * 4
                    val o = SIZE * SIZE * 3 + (y * SIZE + x) * 3
                    out[o] = px[i]
                    out[o + 1] = px[i + 1]
                    out[o + 2] = px[i + 2]
                    green += (px[i + 1].toInt() and 0xff)
                }
            }
            // Dim pictures (HDR video seen in ordinary brightness, or a
            // dark room) are brightened for the model, which was trained
            // on well-lit ones.
            val mean = green.toFloat() / (SIZE * SIZE) / 255f
            val gain = (0.45f / max(mean, 0.05f)).coerceIn(1f, 3f)
            input.rewind()
            for (k in 0 until SIZE * SIZE) {
                val o = SIZE * SIZE * 3 + k * 3
                for (c in 0 until 3) {
                    val v = min(1f, (out[o + c].toInt() and 0xff) / 255f * gain)
                    input.putFloat(v * 2f - 1f)
                }
            }
            input.rewind()
            output.rewind()
            interp.run(input, output)
            output.rewind()
            val steady = previousUs != Long.MIN_VALUE && Math.abs(timeUs - previousUs) < 100_000
            previousUs = timeUs
            val score = FloatArray(CLASSES)
            fun lin(b: Byte): Float {
                val v = (b.toInt() and 0xff) / 255f
                return if (v <= 0.04045f) v / 12.92f else Math.pow((v + 0.055) / 1.055, 2.4).toFloat()
            }
            for (i in 0 until SIZE * SIZE) {
                // Scores to shares (background, hair, body skin, face skin,
                // clothes, other).
                var top = -Float.MAX_VALUE
                for (k in 0 until CLASSES) {
                    score[k] = output.getFloat()
                    top = max(top, score[k])
                }
                var sum = 0f
                for (k in 0 until CLASSES) {
                    score[k] = exp(score[k] - top)
                    sum += score[k]
                }
                val parts = floatArrayOf(
                    score[1] / sum,
                    (score[2] + score[3]) / sum,
                    score[4] / sum,
                )
                val o = SIZE * SIZE * 3 + i * 3
                val y = 0.2126f * lin(out[o]) + 0.7152f * lin(out[o + 1]) + 0.0722f * lin(out[o + 2])
                val lStar = if (y > 0.008856f) 116f * Math.cbrt(y.toDouble()).toFloat() - 16f else 903.3f * y
                for (k in 0 until 3) {
                    var m = parts[k]
                    if (steady) m = 0.65f * m + 0.35f * previous[i * 3 + k]
                    previous[i * 3 + k] = m
                    out[i * 3 + k] = (m * 255f + 0.5f).toInt().coerceIn(0, 255).toByte()
                    if (m > 0.5f) {
                        lightSum[k] += m * lStar
                        lightWeight[k] += m
                    }
                }
            }
            // Each part's average lightness (L*, 0-100), steadied across
            // frames: the new colour is centred on it.
            for (k in 0 until 3) {
                var mean = if (lightWeight[k] > 1f) lightSum[k] / lightWeight[k] else meanLight[k]
                if (steady) mean = 0.8f * meanLight[k] + 0.2f * mean
                meanLight[k] = mean
                out[SIZE * SIZE * 6 + k] = (mean / 100f * 255f).toInt().coerceIn(0, 255).toByte()
                lightSum[k] = 0f
                lightWeight[k] = 0f
            }
            return out
        }

        override fun finishProcessingAndBlend(
            outputFrame: GlTextureInfo,
            presentationTimeUs: Long,
            result: ByteArray,
        ) {
            try {
                draw(outputFrame, result)
            } catch (e: GlUtil.GlException) {
                throw VideoFrameProcessingException(e)
            }
        }

        private fun draw(outputFrame: GlTextureInfo, result: ByteArray) {
            val p = program ?: GlProgram(VERTEX, FRAGMENT).also {
                it.setBufferAttribute(
                    "aFramePosition",
                    GlUtil.getNormalizedCoordinateBounds(),
                    GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
                )
                program = it
            }
            if (maskTex == 0) {
                val ids = IntArray(2)
                GLES20.glGenTextures(2, ids, 0)
                maskTex = ids[0]
                smallTex = ids[1]
                for (t in ids) {
                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, t)
                    // Exact texels: the shader does its own blending.
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                }
            }
            GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
            for ((tex, from) in listOf(maskTex to 0, smallTex to SIZE * SIZE * 3)) {
                maskBuffer.rewind()
                maskBuffer.put(result, from, SIZE * SIZE * 3)
                maskBuffer.rewind()
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex)
                GLES20.glTexImage2D(
                    GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGB, SIZE, SIZE, 0,
                    GLES20.GL_RGB, GLES20.GL_UNSIGNED_BYTE, maskBuffer,
                )
            }
            GlUtil.checkGlError()

            // The frame is read from a copy while the result is drawn over it.
            var copy = frameCopy
            if (copy == null || copy.width != outputFrame.width || copy.height != outputFrame.height) {
                copy?.release()
                val id = GlUtil.createTexture(outputFrame.width, outputFrame.height, useHdr)
                copy = GlTextureInfo(
                    id, GlUtil.createFboForTexture(id), -1, outputFrame.width, outputFrame.height,
                )
                frameCopy = copy
            }
            val all = GlRect(outputFrame.width, outputFrame.height)
            GlUtil.blitFrameBuffer(outputFrame.fboId, all, copy.fboId, all)

            GlUtil.focusFramebufferUsingCurrentContext(outputFrame.fboId, outputFrame.width, outputFrame.height)
            GLES20.glDisable(GLES20.GL_BLEND)
            p.use()
            p.setSamplerTexIdUniform("uFrame", copy.texId, 0)
            p.setSamplerTexIdUniform("uMask", maskTex, 1)
            p.setSamplerTexIdUniform("uSmall", smallTex, 2)
            p.setFloatUniform("uHdr", if (useHdr) 1f else 0f)
            p.setFloatsUniform("uHair", lab(colors.getOrElse(0) { 0 }))
            p.setFloatsUniform("uSkin", lab(colors.getOrElse(1) { 0 }))
            p.setFloatsUniform("uClothes", lab(colors.getOrElse(2) { 0 }))
            val base = SIZE * SIZE * 6
            p.setFloatsUniform(
                "uMeanL",
                FloatArray(3) { (result[base + it].toInt() and 0xff) / 255f * 100f },
            )
            p.setFloatsUniform(
                "uOn",
                floatArrayOf(
                    if (colors.getOrElse(0) { 0 } != 0) strength else 0f,
                    if (colors.getOrElse(1) { 0 } != 0) strength else 0f,
                    if (colors.getOrElse(2) { 0 } != 0) strength else 0f,
                ),
            )
            p.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GlUtil.checkGlError()
        }

        override fun release() {
            program?.delete()
            program = null
            frameCopy?.release()
            frameCopy = null
            if (maskTex != 0) {
                GLES20.glDeleteTextures(2, intArrayOf(maskTex, smallTex), 0)
                maskTex = 0
                smallTex = 0
            }
            executor.execute {
                interpreter?.close()
                interpreter = null
            }
            executor.shutdown()
        }
    }

    private companion object {
        const val SIZE = 256
        const val CLASSES = 6
        /** Masks, the small picture, and each part's average lightness. */
        const val RESULT = SIZE * SIZE * 6 + 3

        /** An sRGB colour as CIE L*a*b* (D65). */
        fun lab(c: Int): FloatArray {
            fun lin(v: Int): Double {
                val x = v / 255.0
                return if (x <= 0.04045) x / 12.92 else Math.pow((x + 0.055) / 1.055, 2.4)
            }
            val r = lin((c shr 16) and 0xff)
            val g = lin((c shr 8) and 0xff)
            val b = lin(c and 0xff)
            val x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
            val y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            val z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
            fun f(t: Double) = if (t > 0.008856) Math.cbrt(t) else 7.787 * t + 16.0 / 116.0
            return floatArrayOf(
                (116 * f(y) - 16).toFloat(),
                (500 * (f(x) - f(y))).toFloat(),
                (200 * (f(y) - f(z))).toFloat(),
            )
        }

        const val VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vTex;
void main() {
  gl_Position = aFramePosition;
  vTex = aFramePosition.xy * 0.5 + 0.5;
}
"""

        // Like a hair dye: each part keeps its own light and shade (strands,
        // folds, shine), moved so its average lands on the new colour's
        // lightness, with the new colour's hue and strength (in CIE L*a*b*,
        // so a brown is a natural brown).
        //
        // The model's 256 × 256 answer is snapped to the real edges: each
        // nearby answer counts more when its spot in the small picture has
        // the same colour as this pixel (so the wall between loose strands
        // of hair stays the wall, and a strand stays hair).
        const val FRAGMENT = """
precision highp float;
uniform sampler2D uFrame;
uniform sampler2D uMask;
uniform sampler2D uSmall;
uniform float uHdr;
uniform vec3 uHair;
uniform vec3 uSkin;
uniform vec3 uClothes;
uniform vec3 uOn;
uniform vec3 uMeanL;
varying vec2 vTex;
const float N = 256.0;
const vec3 WP = vec3(0.95047, 1.0, 1.08883);

vec3 toLin(vec3 c) {
  c = clamp(c, 0.0, 1.0);
  return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}
vec3 fromLin(vec3 c) {
  c = clamp(c, 0.0, 1.0);
  return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}
vec3 labF(vec3 t) {
  return mix(7.787 * t + 16.0 / 116.0, pow(max(t, 1e-6), vec3(1.0 / 3.0)), step(0.008856, t));
}
vec3 labFi(vec3 t) {
  return mix((t - 16.0 / 116.0) / 7.787, t * t * t, step(0.2069, t));
}
vec3 rgbToLab(vec3 c) {
  vec3 l = toLin(c);
  vec3 xyz = vec3(
    dot(l, vec3(0.4124, 0.3576, 0.1805)),
    dot(l, vec3(0.2126, 0.7152, 0.0722)),
    dot(l, vec3(0.0193, 0.1192, 0.9505))) / WP;
  vec3 f = labF(xyz);
  return vec3(116.0 * f.y - 16.0, 500.0 * (f.x - f.y), 200.0 * (f.y - f.z));
}
vec3 labToRgb(vec3 lab) {
  float fy = (lab.x + 16.0) / 116.0;
  vec3 xyz = labFi(vec3(fy + lab.y / 500.0, fy, fy - lab.z / 200.0)) * WP;
  vec3 l = vec3(
    dot(xyz, vec3(3.2406, -1.5372, -0.4986)),
    dot(xyz, vec3(-0.9689, 1.8758, 0.0415)),
    dot(xyz, vec3(0.0557, -0.2040, 1.0570)));
  return fromLin(l);
}
vec3 dye(vec3 c, vec3 target, float meanL, float amount) {
  if (amount <= 0.001) return c;
  vec3 lab = rgbToLab(c);
  // Detail a little stronger when going much lighter (dark hair to blonde).
  float k = clamp((target.x + 15.0) / (meanL + 15.0), 0.7, 1.8);
  float L = clamp(target.x + (lab.x - meanL) * k, 0.0, 100.0);
  // Shadows less coloured, as in real hair and cloth.
  float ch = clamp(L / max(target.x, 1.0), 0.3, 1.2);
  vec3 n = labToRgb(vec3(L, target.yz * ch));
  return mix(c, n, clamp(amount, 0.0, 1.0));
}
void main() {
  vec4 c = texture2D(uFrame, vTex);
  // This pixel as the small picture has it (HDR frames are in linear light).
  vec3 here = uHdr > 0.5 ? pow(clamp(c.rgb, 0.0, 1.0), vec3(1.0 / 2.2)) : c.rgb;
  vec2 p = vec2(vTex.x, 1.0 - vTex.y) * N - 0.5;
  vec2 b = floor(p);
  vec3 acc = vec3(0.0);
  float wsum = 0.0;
  for (int j = -1; j <= 2; j++) {
    for (int i = -1; i <= 2; i++) {
      vec2 q = b + vec2(float(i), float(j));
      vec2 t = (clamp(q, 0.0, N - 1.0) + 0.5) / N;
      vec3 d = texture2D(uSmall, t).rgb - here;
      vec2 e = q - p;
      float w = exp(-0.5 * dot(e, e) - dot(d, d) * 50.0) + 1e-5;
      acc += w * texture2D(uMask, t).rgb;
      wsum += w;
    }
  }
  // Weak guesses (stray specks away from the person) are left alone.
  vec3 m = smoothstep(0.3, 0.7, acc / wsum);
  // Worked on as an ordinary picture (HDR: its light seen as one).
  vec3 col = here;
  col = dye(col, uHair, uMeanL.x, m.r * uOn.x);
  col = dye(col, uSkin, uMeanL.y, m.g * uOn.y);
  col = dye(col, uClothes, uMeanL.z, m.b * uOn.z);
  // HDR: only the change is added, so untouched light (highlights above
  // the ordinary range included) stays exactly as it was.
  if (uHdr > 0.5) col = c.rgb + (pow(col, vec3(2.2)) - pow(here, vec3(2.2)));
  gl_FragColor = vec4(col, c.a);
}
"""
    }
}

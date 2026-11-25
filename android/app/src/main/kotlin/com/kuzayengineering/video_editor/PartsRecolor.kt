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
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        ByteBufferGlEffect(Processor(model, colors, strength, useHdr))
            .toGlShaderProgram(context, useHdr)

    private class Processor(
        private val model: String,
        private val colors: IntArray,
        private val strength: Float,
        private val useHdr: Boolean,
    ) : ByteBufferGlEffect.Processor<ByteArray> {
        private val executor: ListeningExecutorService =
            MoreExecutors.listeningDecorator(Executors.newSingleThreadExecutor())
        private var interpreter: Interpreter? = null
        private val input = ByteBuffer.allocateDirect(SIZE * SIZE * 3 * 4).order(ByteOrder.nativeOrder())
        private val output = ByteBuffer.allocateDirect(SIZE * SIZE * CLASSES * 4).order(ByteOrder.nativeOrder())
        /** Last frame's amounts (hair, skin, clothes), mixed in a little to
         * stop edges flickering. */
        private val previous = FloatArray(SIZE * SIZE * 3)
        private var previousUs = Long.MIN_VALUE
        private var inputW = 0
        private var inputH = 0
        private var program: GlProgram? = null
        private var maskTex = 0
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
            val px = ByteArray(image.width * image.height * 4)
            image.pixelBuffer.rewind()
            image.pixelBuffer.get(px)
            return executor.submit<ByteArray> { classify(px, image.width, image.height, presentationTimeUs) }
        }

        private fun classify(px: ByteArray, w: Int, h: Int, timeUs: Long): ByteArray {
            val interp = interpreter ?: Interpreter(
                File(model),
                Interpreter.Options().setNumThreads(4),
            ).also { interpreter = it }
            // Top row first (people upright); colours from -1 to 1.
            input.rewind()
            for (y in 0 until SIZE) {
                val row = (h - 1 - y * h / SIZE) * w
                for (x in 0 until SIZE) {
                    val i = (row + x * w / SIZE) * 4
                    input.putFloat((px[i].toInt() and 0xff) / 127.5f - 1f)
                    input.putFloat((px[i + 1].toInt() and 0xff) / 127.5f - 1f)
                    input.putFloat((px[i + 2].toInt() and 0xff) / 127.5f - 1f)
                }
            }
            input.rewind()
            output.rewind()
            interp.run(input, output)
            output.rewind()
            val steady = previousUs != Long.MIN_VALUE && Math.abs(timeUs - previousUs) < 100_000
            previousUs = timeUs
            val out = ByteArray(SIZE * SIZE * 3)
            val score = FloatArray(CLASSES)
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
                for (k in 0 until 3) {
                    var m = parts[k]
                    if (steady) m = 0.65f * m + 0.35f * previous[i * 3 + k]
                    previous[i * 3 + k] = m
                    out[i * 3 + k] = (m * 255f + 0.5f).toInt().coerceIn(0, 255).toByte()
                }
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
                val ids = IntArray(1)
                GLES20.glGenTextures(1, ids, 0)
                maskTex = ids[0]
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTex)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            }
            maskBuffer.rewind()
            maskBuffer.put(result)
            maskBuffer.rewind()
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTex)
            GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGB, SIZE, SIZE, 0,
                GLES20.GL_RGB, GLES20.GL_UNSIGNED_BYTE, maskBuffer,
            )
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
            fun rgb(c: Int): FloatArray {
                val v = floatArrayOf(
                    ((c shr 16) and 0xff) / 255f,
                    ((c shr 8) and 0xff) / 255f,
                    (c and 0xff) / 255f,
                )
                // HDR pictures are in linear light: the colour too.
                return if (useHdr) FloatArray(3) { Math.pow(v[it].toDouble(), 2.2).toFloat() } else v
            }
            p.setFloatsUniform("uHair", rgb(colors.getOrElse(0) { 0 }))
            p.setFloatsUniform("uSkin", rgb(colors.getOrElse(1) { 0 }))
            p.setFloatsUniform("uClothes", rgb(colors.getOrElse(2) { 0 }))
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
                GLES20.glDeleteTextures(1, intArrayOf(maskTex), 0)
                maskTex = 0
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

        const val VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vTex;
void main() {
  gl_Position = aFramePosition;
  vTex = aFramePosition.xy * 0.5 + 0.5;
}
"""

        // The new colour keeps the part's shading: dark spots get a deep
        // shade of it, bright spots a light one (so dark hair can turn
        // red or blue, not just stay dark).
        const val FRAGMENT = """
precision mediump float;
uniform sampler2D uFrame;
uniform sampler2D uMask;
uniform vec3 uHair;
uniform vec3 uSkin;
uniform vec3 uClothes;
uniform vec3 uOn;
varying vec2 vTex;
vec3 dye(vec3 c, float l, vec3 target, float amount) {
  vec3 dyed = clamp(target * (0.35 + 1.3 * l), 0.0, max(1.0, l));
  return mix(c, dyed, clamp(amount, 0.0, 1.0));
}
void main() {
  vec4 c = texture2D(uFrame, vTex);
  // Weak guesses (stray specks away from the person) are left alone.
  vec3 m = smoothstep(0.3, 0.7, texture2D(uMask, vec2(vTex.x, 1.0 - vTex.y)).rgb);
  float l = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
  vec3 col = c.rgb;
  col = dye(col, l, uHair, m.r * uOn.x);
  col = dye(col, l, uSkin, m.g * uOn.y);
  col = dye(col, l, uClothes, m.b * uOn.z);
  gl_FragColor = vec4(col, c.a);
}
"""
    }
}

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
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.ListeningExecutorService
import com.google.common.util.concurrent.MoreExecutors
import org.tensorflow.lite.Interpreter
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

/**
 * Person cutout: hides everything but the people in a picture, so a
 * picture-in-picture clip shows only the person over the clips below.
 *
 * Each frame is shrunk to 256 × 256, Google's MediaPipe "selfie segmenter"
 * (Apache 2.0, in the app's assets) marks how much each spot is a person,
 * and that mark becomes the picture's see-through amount (its alpha). The
 * picture-in-picture drawing then mixes by that alpha.
 */
object PersonCutout {
    private const val MODEL = "selfie_segmenter.tflite"
    private const val SIZE = 256

    /**
     * [fill]: null makes the background see-through (picture in picture);
     * a colour (ARGB) paints it over the background instead (main video).
     */
    fun effect(context: Context, fill: Int? = null) =
        ByteBufferGlEffect(Processor(context.applicationContext, fill))

    private class Processor(
        private val context: Context,
        private val fill: Int?,
    ) : ByteBufferGlEffect.Processor<ByteArray> {
        private val executor: ListeningExecutorService =
            MoreExecutors.listeningDecorator(Executors.newSingleThreadExecutor())
        private var interpreter: Interpreter? = null
        private val input = ByteBuffer.allocateDirect(SIZE * SIZE * 3 * 4).order(ByteOrder.nativeOrder())
        private val output = ByteBuffer.allocateDirect(SIZE * SIZE * 4).order(ByteOrder.nativeOrder())
        /** Last frame's mark (0…1), mixed in a little to stop edges flickering. */
        private val previous = FloatArray(SIZE * SIZE)
        private var previousUs = Long.MIN_VALUE
        private var inputW = 0
        private var inputH = 0
        private var program: GlProgram? = null
        private var maskTex = 0
        private val maskBuffer = ByteBuffer.allocateDirect(SIZE * SIZE)

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
            // Copy the pixels now: the buffer is only ours until this returns.
            val px = ByteArray(image.width * image.height * 4)
            image.pixelBuffer.rewind()
            image.pixelBuffer.get(px)
            return executor.submit<ByteArray> { segment(px, image.width, image.height, presentationTimeUs) }
        }

        private fun segment(px: ByteArray, w: Int, h: Int, timeUs: Long): ByteArray {
            val interp = interpreter ?: Interpreter(loadModel(), Interpreter.Options().setNumThreads(2))
                .also { interpreter = it }
            // The read-back picture starts at the bottom row; the model wants
            // the top row first (people upright).
            input.rewind()
            for (y in 0 until SIZE) {
                val row = (h - 1 - y * h / SIZE) * w
                for (x in 0 until SIZE) {
                    val i = (row + x * w / SIZE) * 4
                    input.putFloat((px[i].toInt() and 0xff) / 255f)
                    input.putFloat((px[i + 1].toInt() and 0xff) / 255f)
                    input.putFloat((px[i + 2].toInt() and 0xff) / 255f)
                }
            }
            input.rewind()
            output.rewind()
            interp.run(input, output)
            output.rewind()
            // Close in time to the last frame (not after a jump): smooth a bit.
            val steady = previousUs != Long.MIN_VALUE && Math.abs(timeUs - previousUs) < 100_000
            previousUs = timeUs
            val out = ByteArray(SIZE * SIZE)
            for (i in 0 until SIZE * SIZE) {
                var m = output.getFloat().coerceIn(0f, 1f)
                if (steady) m = 0.65f * m + 0.35f * previous[i]
                previous[i] = m
                out[i] = (m * 255f + 0.5f).toInt().toByte()
            }
            return out
        }

        private fun loadModel(): ByteBuffer {
            val bytes = context.assets.open(MODEL).use { it.readBytes() }
            return ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).apply {
                put(bytes)
                rewind()
            }
        }

        override fun finishProcessingAndBlend(
            outputFrame: GlTextureInfo,
            presentationTimeUs: Long,
            result: ByteArray,
        ) {
            try {
                drawMask(outputFrame, result)
            } catch (e: GlUtil.GlException) {
                throw VideoFrameProcessingException(e)
            }
        }

        private fun drawMask(outputFrame: GlTextureInfo, result: ByteArray) {
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
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE, SIZE, SIZE, 0,
                GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, maskBuffer,
            )
            GlUtil.checkGlError()
            GlUtil.focusFramebufferUsingCurrentContext(outputFrame.fboId, outputFrame.width, outputFrame.height)
            p.use()
            p.setSamplerTexIdUniform("uMask", maskTex, 0)
            val f = fill
            if (f == null) {
                // Write only the see-through amount; the colours stay.
                GLES20.glDisable(GLES20.GL_BLEND)
                GLES20.glColorMask(false, false, false, true)
                p.setIntUniform("uPaint", 0)
            } else {
                // Paint the colour over everything but the people.
                GLES20.glEnable(GLES20.GL_BLEND)
                GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
                GLES20.glColorMask(true, true, true, false)
                p.setIntUniform("uPaint", 1)
                p.setFloatsUniform(
                    "uFill",
                    floatArrayOf(
                        ((f shr 16) and 0xff) / 255f,
                        ((f shr 8) and 0xff) / 255f,
                        (f and 0xff) / 255f,
                    ),
                )
            }
            p.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glColorMask(true, true, true, true)
            GLES20.glDisable(GLES20.GL_BLEND)
            GlUtil.checkGlError()
        }

        override fun release() {
            program?.delete()
            program = null
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

    private const val VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vTex;
void main() {
  gl_Position = aFramePosition;
  vTex = aFramePosition.xy * 0.5 + 0.5;
}
"""

    // The mask's first row is the picture's top, so it is read upside down.
    // A soft edge: mostly-person spots are fully shown, mostly-background
    // spots fully hidden, with a short blend between.
    private const val FRAGMENT = """
precision mediump float;
uniform sampler2D uMask;
uniform int uPaint;
uniform vec3 uFill;
varying vec2 vTex;
void main() {
  float m = smoothstep(0.25, 0.75, texture2D(uMask, vec2(vTex.x, 1.0 - vTex.y)).r);
  // See-through amount, or the colour where there is no person.
  gl_FragColor = uPaint == 1 ? vec4(uFill, 1.0 - m) : vec4(0.0, 0.0, 0.0, m);
}
"""
}

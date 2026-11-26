package com.kuzayengineering.video_editor

import android.content.Context
import android.graphics.Bitmap
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
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.components.containers.NormalizedLandmark
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import org.tensorflow.lite.Interpreter
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.util.concurrent.Executors
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Looks that follow the people in a picture, found frame by frame by
 * Google's MediaPipe models (Apache 2.0; downloaded once, run on the phone):
 *
 * - [EyeColorEffect]: a new iris colour (face landmarks with irises).
 * - [OutfitEffect]: tight-fitting clothes on bare skin (a shirt with or
 *   without sleeves, gloves, socks, stockings), from the body's joints
 *   (pose landmarks) and where the skin is (selfie multiclass).
 *
 * The same steps were tried in Python on test photos first. Coordinates in
 * the shaders: x across the picture times its width/height, y from the top
 * / height (so circles stay round).
 */
private const val READ_LONG_SIDE = 512

private fun mapped(path: String): ByteBuffer = FileInputStream(File(path)).use {
    it.channel.map(FileChannel.MapMode.READ_ONLY, 0, it.channel.size())
}

/** The read-back picture (bottom row first) as an upright bitmap. */
private fun uprightBitmap(px: ByteArray, w: Int, h: Int): Bitmap {
    val rows = ByteBuffer.allocateDirect(w * h * 4)
    for (y in h - 1 downTo 0) rows.put(px, y * w * 4, w * 4)
    rows.rewind()
    return Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply { copyPixelsFromBuffer(rows) }
}

private fun readSize(w: Int, h: Int): Size {
    val s = READ_LONG_SIDE.toFloat() / max(w, h)
    return Size(max(16, (w * s).roundToInt()), max(16, (h * s).roundToInt()))
}

private fun rgb(c: Int, hdr: Boolean): FloatArray {
    val v = floatArrayOf(((c shr 16) and 0xff) / 255f, ((c shr 8) and 0xff) / 255f, (c and 0xff) / 255f)
    return if (hdr) FloatArray(3) { Math.pow(v[it].toDouble(), 2.2).toFloat() } else v
}

/** A copy of the frame to read from while drawing over it. */
private class FrameCopy(private val hdr: Boolean) {
    private var copy: GlTextureInfo? = null
    fun of(frame: GlTextureInfo): GlTextureInfo {
        var c = copy
        if (c == null || c.width != frame.width || c.height != frame.height) {
            c?.release()
            val id = GlUtil.createTexture(frame.width, frame.height, hdr)
            c = GlTextureInfo(id, GlUtil.createFboForTexture(id), -1, frame.width, frame.height)
            copy = c
        }
        val all = GlRect(frame.width, frame.height)
        GlUtil.blitFrameBuffer(frame.fboId, all, c.fboId, all)
        return c
    }
    fun release() {
        copy?.release()
        copy = null
    }
}

private fun program(fragment: String) = GlProgram(VERTEX, fragment).apply {
    setBufferAttribute(
        "aFramePosition",
        GlUtil.getNormalizedCoordinateBounds(),
        GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
    )
}

private const val VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vTex;
void main() {
  gl_Position = aFramePosition;
  vTex = aFramePosition.xy * 0.5 + 0.5;
}
"""

// The new colour keeps the shading (dark spots a deep shade of it, bright
// spots a light one), as in PartsRecolor.
private const val DYE = """
vec3 dye(vec3 c, vec3 target, float amount) {
  float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
  vec3 dyed = clamp(target * (0.35 + 1.3 * l), 0.0, max(1.0, l));
  return mix(c, dyed, clamp(amount, 0.0, 1.0));
}
"""

// -----------------------------------------------------------------------------
// Eye colour
// -----------------------------------------------------------------------------

class EyeColorEffect(
    private val context: Context,
    private val model: String,
    /** ARGB; 0: keep the colour. */
    private val color: Int,
    private val strength: Float,
    /** 0 … 1: how much brighter the whole visible eye gets. */
    private val brighten: Float,
    /** Find faces at most this often (video time). */
    private val everyUs: Long = 0,
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        ByteBufferGlEffect(Processor(this.context, model, color, strength, brighten, everyUs, useHdr))
            .toGlShaderProgram(context, useHdr)

    /** Per eye: iris centre and radius, and the eye opening (an ellipse). */
    private class Eye(
        val cx: Float, val cy: Float, val r: Float,
        val ex: Float, val ey: Float, val ux: Float, val uy: Float, val hw: Float, val hh: Float,
    )

    private class Processor(
        private val context: Context,
        private val model: String,
        private val color: Int,
        private val strength: Float,
        private val brighten: Float,
        private val everyUs: Long,
        private val hdr: Boolean,
    ) : ByteBufferGlEffect.Processor<List<Eye>> {
        private var lastFuture: ListenableFuture<List<Eye>>? = null
        private var lastAskedUs = 0L
        private val executor: ListeningExecutorService =
            MoreExecutors.listeningDecorator(Executors.newSingleThreadExecutor())
        private var landmarker: FaceLandmarker? = null
        private var inW = 0
        private var inH = 0
        private var program: GlProgram? = null
        private val copy = FrameCopy(hdr)
        private var last: List<Eye> = emptyList()
        /** The model failed to run once: don't keep trying every frame. */
        @Volatile private var broken = false
        private var lastUs = Long.MIN_VALUE

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            inW = inputWidth
            inH = inputHeight
            return readSize(inputWidth, inputHeight)
        }

        override fun getScaledRegion(presentationTimeUs: Long) = GlRect(inW, inH)

        override fun processImage(image: ByteBufferGlEffect.Image, presentationTimeUs: Long): ListenableFuture<List<Eye>> {
            // Reuse the latest answer for frames close to it.
            val near = lastFuture
            if (near != null && Math.abs(presentationTimeUs - lastAskedUs) < everyUs) return near
            lastAskedUs = presentationTimeUs
            val px = ByteArray(image.width * image.height * 4)
            image.pixelBuffer.rewind()
            image.pixelBuffer.get(px)
            val job = EffectStatus.start("Eye color")
            val f = executor.submit<List<Eye>> {
                try {
                    if (broken) emptyList() else find(px, image.width, image.height, presentationTimeUs)
                } catch (t: Throwable) {
                    // Leave the picture as it is (and say why) rather than
                    // stopping the video.
                    broken = true
                    EffectStatus.fail("Eye color", t)
                    emptyList()
                } finally {
                    EffectStatus.end(job)
                }
            }
            lastFuture = f
            return f
        }

        private fun find(px: ByteArray, w: Int, h: Int, timeUs: Long): List<Eye> {
            val fl = landmarker ?: FaceLandmarker.createFromOptions(
                context,
                FaceLandmarker.FaceLandmarkerOptions.builder()
                    .setBaseOptions(BaseOptions.builder().setModelAssetBuffer(mapped(model)).build())
                    .setRunningMode(RunningMode.IMAGE)
                    .setNumFaces(2)
                    .build(),
            ).also { landmarker = it }
            val bmp = uprightBitmap(px, w, h)
            val faces = try {
                fl.detect(BitmapImageBuilder(bmp).build()).faceLandmarks()
            } finally {
                bmp.recycle()
            }
            val aspect = w.toFloat() / h
            val eyes = mutableListOf<Eye>()
            for (f in faces) {
                if (f.size < 478) continue
                fun p(i: Int) = floatArrayOf(f[i].x() * aspect, f[i].y())
                for ((centre, ring, corners, lids) in listOf(
                    Quad(468, intArrayOf(469, 470, 471, 472), intArrayOf(33, 133), intArrayOf(159, 145)),
                    Quad(473, intArrayOf(474, 475, 476, 477), intArrayOf(362, 263), intArrayOf(386, 374)),
                )) {
                    val c = p(centre)
                    val r = ring.map { val q = p(it); dist(q, c) }.average().toFloat()
                    val a = p(corners[0])
                    val b = p(corners[1])
                    val hw = dist(a, b) / 2
                    if (hw < 1e-5f) continue
                    val ux = (b[0] - a[0]) / (2 * hw)
                    val uy = (b[1] - a[1]) / (2 * hw)
                    val hh = dist(p(lids[0]), p(lids[1])) / 2
                    eyes += Eye(c[0], c[1], r, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2, ux, uy, hw, hh)
                }
            }
            // Steadier: blend with the last frame's eyes when close in time.
            val steady = lastUs != Long.MIN_VALUE && Math.abs(timeUs - lastUs) < 100_000 &&
                last.size == eyes.size
            val out = if (!steady) eyes else eyes.zip(last) { n, o ->
                fun m(x: Float, y: Float) = 0.6f * x + 0.4f * y
                Eye(m(n.cx, o.cx), m(n.cy, o.cy), m(n.r, o.r), m(n.ex, o.ex), m(n.ey, o.ey),
                    n.ux, n.uy, m(n.hw, o.hw), m(n.hh, o.hh))
            }
            last = out
            lastUs = timeUs
            return out
        }

        override fun finishProcessingAndBlend(outputFrame: GlTextureInfo, presentationTimeUs: Long, result: List<Eye>) {
            if (result.isEmpty()) return
            try {
                val p = program ?: program(EYE_FRAGMENT).also { program = it }
                val src = copy.of(outputFrame)
                GlUtil.focusFramebufferUsingCurrentContext(outputFrame.fboId, outputFrame.width, outputFrame.height)
                GLES20.glDisable(GLES20.GL_BLEND)
                p.use()
                p.setSamplerTexIdUniform("uFrame", src.texId, 0)
                p.setFloatUniform("uAspect", outputFrame.width.toFloat() / outputFrame.height)
                p.setFloatsUniform("uColor", rgb(color, hdr))
                p.setFloatUniform("uStrength", if (color != 0) strength else 0f)
                p.setFloatUniform("uBright", brighten)
                for (i in 0 until 4) {
                    val e = result.getOrNull(i)
                    p.setFloatsUniform("uIris$i", if (e == null) floatArrayOf(-9f, -9f, 0f) else floatArrayOf(e.cx, e.cy, e.r))
                    p.setFloatsUniform(
                        "uLid$i",
                        if (e == null) floatArrayOf(-9f, -9f, 1f, 1f) else floatArrayOf(e.ex, e.ey, e.hw, e.hh),
                    )
                    p.setFloatsUniform("uAxis$i", if (e == null) floatArrayOf(1f, 0f) else floatArrayOf(e.ux, e.uy))
                }
                p.bindAttributesAndUniforms()
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                GlUtil.checkGlError()
            } catch (e: GlUtil.GlException) {
                throw VideoFrameProcessingException(e)
            }
        }

        override fun release() {
            program?.delete()
            program = null
            copy.release()
            executor.execute {
                landmarker?.close()
                landmarker = null
            }
            executor.shutdown()
        }
    }

    private data class Quad(val centre: Int, val ring: IntArray, val corners: IntArray, val lids: IntArray)

    private companion object {
        fun dist(a: FloatArray, b: FloatArray): Float {
            val dx = a[0] - b[0]
            val dy = a[1] - b[1]
            return sqrt(dx * dx + dy * dy)
        }

        // Inside the iris (not the pupil), and inside the eye opening (not
        // the eyelids), with soft edges.
        const val EYE_FRAGMENT = """
precision highp float;
uniform sampler2D uFrame;
uniform float uAspect;
uniform vec3 uColor;
uniform float uStrength;
uniform float uBright;
uniform vec3 uIris0; uniform vec4 uLid0; uniform vec2 uAxis0;
uniform vec3 uIris1; uniform vec4 uLid1; uniform vec2 uAxis1;
uniform vec3 uIris2; uniform vec4 uLid2; uniform vec2 uAxis2;
uniform vec3 uIris3; uniform vec4 uLid3; uniform vec2 uAxis3;
varying vec2 vTex;
""" + DYE + """
// x: the iris (not the pupil) inside the eye opening; y: the whole eye
// opening (whites and iris, not the eyelids).
vec2 eye(vec2 q, vec3 iris, vec4 lid, vec2 u) {
  float r = max(iris.z, 1e-5);
  float d = distance(q, iris.xy);
  float ring = clamp((r - d) / (r * 0.15), 0.0, 1.0) * clamp((d - r * 0.38) / (r * 0.15), 0.0, 1.0);
  vec2 v = vec2(-u.y, u.x);
  vec2 o = q - lid.xy;
  float ex = dot(o, u) / max(lid.z, 1e-5);
  float ey = dot(o, v) / max(lid.w, 1e-5);
  float inside = clamp((1.0 - (ex * ex + ey * ey)) / 0.25, 0.0, 1.0);
  return vec2(ring * inside, inside);
}
void main() {
  vec4 c = texture2D(uFrame, vTex);
  vec2 q = vec2(vTex.x * uAspect, 1.0 - vTex.y);
  vec2 m = max(max(eye(q, uIris0, uLid0, uAxis0), eye(q, uIris1, uLid1, uAxis1)),
               max(eye(q, uIris2, uLid2, uAxis2), eye(q, uIris3, uLid3, uAxis3)));
  vec3 col = dye(c.rgb, uColor, m.x * uStrength);
  // Brighter eyes, colour kept: lighten towards white (dark parts least).
  col = col + (vec3(1.0) - col) * (0.35 * uBright * m.y) * clamp(col * 2.0, 0.0, 1.0);
  gl_FragColor = vec4(col, c.a);
}
"""
    }
}

// -----------------------------------------------------------------------------
// Tight-fitting outfits
// -----------------------------------------------------------------------------

/**
 * [colors]: shirt, gloves, socks, stockings (ARGB; 0: none). [sleeves]: 0
 * none, 1 short, 2 long. [stockingTop]: where stockings end, as a share of
 * the thigh from the hip (0.35: thigh-high). [sheer]: 0 solid … 0.9 sheer.
 */
class OutfitEffect(
    private val context: Context,
    private val poseModel: String,
    private val partsModel: String,
    private val colors: IntArray,
    private val sleeves: Int,
    private val stockingTop: Float,
    private val sheer: Float,
    /** 0 solid, 1 plaid, 2 stripes. */
    private val pattern: Int = 0,
    /** Find the body at most this often (video time). */
    private val everyUs: Long = 0,
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        ByteBufferGlEffect(Processor(this, useHdr)).toGlShaderProgram(context, useHdr)

    /** Where the joints are (18 points as x, y pairs; far away if unseen),
     * the body's scale, and where bare skin is (256 × 256). */
    private class Body(val points: FloatArray, val scale: Float, val skin: ByteArray)

    private class Processor(private val e: OutfitEffect, private val hdr: Boolean) :
        ByteBufferGlEffect.Processor<Body> {
        private var lastFuture: ListenableFuture<Body>? = null
        private var lastAskedUs = 0L
        /** No one found in the frame. */
        private val none = Body(FloatArray(0), 0f, ByteArray(0))
        private val executor: ListeningExecutorService =
            MoreExecutors.listeningDecorator(Executors.newSingleThreadExecutor())
        private var pose: PoseLandmarker? = null
        private var parts: Interpreter? = null
        private val input = ByteBuffer.allocateDirect(SIZE * SIZE * 3 * 4).order(ByteOrder.nativeOrder())
        private val output = ByteBuffer.allocateDirect(SIZE * SIZE * 6 * 4).order(ByteOrder.nativeOrder())
        private var inW = 0
        private var inH = 0
        private var program: GlProgram? = null
        private val copy = FrameCopy(hdr)
        private var skinTex = 0
        private val skinBuffer = ByteBuffer.allocateDirect(SIZE * SIZE)
        private var lastPoints: FloatArray? = null
        @Volatile private var broken = false
        private var lastUs = Long.MIN_VALUE

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            inW = inputWidth
            inH = inputHeight
            return readSize(inputWidth, inputHeight)
        }

        override fun getScaledRegion(presentationTimeUs: Long) = GlRect(inW, inH)

        override fun processImage(image: ByteBufferGlEffect.Image, presentationTimeUs: Long): ListenableFuture<Body> {
            // Reuse the latest answer for frames close to it.
            val near = lastFuture
            if (near != null && Math.abs(presentationTimeUs - lastAskedUs) < e.everyUs) return near
            lastAskedUs = presentationTimeUs
            val px = ByteArray(image.width * image.height * 4)
            image.pixelBuffer.rewind()
            image.pixelBuffer.get(px)
            val f = executor.submit<Body> {
                // Counted from when the work starts (not while queued).
                val job = EffectStatus.start("Outfit")
                try {
                    if (broken) none else find(px, image.width, image.height, presentationTimeUs)
                } catch (t: Throwable) {
                    broken = true
                    EffectStatus.fail("Outfit", t)
                    none
                } finally {
                    EffectStatus.end(job)
                }
            }
            lastFuture = f
            return f
        }

        private fun find(px: ByteArray, w: Int, h: Int, timeUs: Long): Body {
            val pl = pose ?: PoseLandmarker.createFromOptions(
                e.context,
                PoseLandmarker.PoseLandmarkerOptions.builder()
                    .setBaseOptions(BaseOptions.builder().setModelAssetBuffer(mapped(e.poseModel)).build())
                    .setRunningMode(RunningMode.IMAGE)
                    .setNumPoses(1)
                    .build(),
            ).also { pose = it }
            val bmp = uprightBitmap(px, w, h)
            val people = try {
                pl.detect(BitmapImageBuilder(bmp).build()).landmarks()
            } finally {
                bmp.recycle()
            }
            val lm = people.firstOrNull() ?: return none
            if (lm.size < 33) return none
            val aspect = w.toFloat() / h
            fun seen(l: NormalizedLandmark) = l.visibility().orElse(1f) > 0.5f
            fun pt(i: Int) = if (seen(lm[i])) floatArrayOf(lm[i].x() * aspect, lm[i].y()) else floatArrayOf(-9f, -9f)
            fun mean(vararg ids: Int): FloatArray {
                if (ids.any { !seen(lm[it]) }) return floatArrayOf(-9f, -9f)
                return floatArrayOf(ids.map { lm[it].x() * aspect }.average().toFloat(), ids.map { lm[it].y() }.average().toFloat())
            }
            // Shoulders, elbows, wrists, hand centres, hips, knees, ankles,
            // heels, toes (left, right each).
            val list = listOf(
                pt(11), pt(12), pt(13), pt(14), pt(15), pt(16),
                mean(17, 19, 21), mean(18, 20, 22),
                pt(23), pt(24), pt(25), pt(26), pt(27), pt(28),
                pt(29), pt(30), pt(31), pt(32),
            )
            var points = FloatArray(36) { list[it / 2][it % 2] }
            val prev = lastPoints
            if (prev != null && lastUs != Long.MIN_VALUE && Math.abs(timeUs - lastUs) < 100_000) {
                points = FloatArray(36) { i ->
                    if (points[i] < -5f || prev[i] < -5f) points[i] else 0.6f * points[i] + 0.4f * prev[i]
                }
            }
            lastPoints = points
            lastUs = timeUs
            val sx = (lm[11].x() - lm[12].x()) * aspect
            val sy = lm[11].y() - lm[12].y()
            val scale = max(sqrt(sx * sx + sy * sy), 0.02f)
            return Body(points, scale, skin(px, w, h))
        }

        /** Where bare skin of the body is (not the face), 256 × 256, top row first. */
        private fun skin(px: ByteArray, w: Int, h: Int): ByteArray {
            val interp = parts ?: Interpreter(File(e.partsModel), Interpreter.Options().setNumThreads(4))
                .also { parts = it }
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
            val out = ByteArray(SIZE * SIZE)
            val s = FloatArray(6)
            for (i in 0 until SIZE * SIZE) {
                var top = -Float.MAX_VALUE
                for (k in 0 until 6) {
                    s[k] = output.getFloat()
                    top = max(top, s[k])
                }
                var sum = 0f
                for (k in 0 until 6) {
                    s[k] = exp(s[k] - top)
                    sum += s[k]
                }
                out[i] = ((s[2] / sum) * 255f + 0.5f).toInt().coerceIn(0, 255).toByte()
            }
            return out
        }

        override fun finishProcessingAndBlend(outputFrame: GlTextureInfo, presentationTimeUs: Long, result: Body) {
            if (result === none) return
            try {
                val p = program ?: program(OUTFIT_FRAGMENT).also { program = it }
                if (skinTex == 0) {
                    val ids = IntArray(1)
                    GLES20.glGenTextures(1, ids, 0)
                    skinTex = ids[0]
                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, skinTex)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                }
                skinBuffer.rewind()
                skinBuffer.put(result.skin)
                skinBuffer.rewind()
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, skinTex)
                GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
                GLES20.glTexImage2D(
                    GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE, SIZE, SIZE, 0,
                    GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, skinBuffer,
                )
                val src = copy.of(outputFrame)
                GlUtil.focusFramebufferUsingCurrentContext(outputFrame.fboId, outputFrame.width, outputFrame.height)
                GLES20.glDisable(GLES20.GL_BLEND)
                p.use()
                p.setSamplerTexIdUniform("uFrame", src.texId, 0)
                p.setSamplerTexIdUniform("uSkin", skinTex, 1)
                p.setFloatUniform("uAspect", outputFrame.width.toFloat() / outputFrame.height)
                p.setFloatUniform("uS", result.scale)
                for (i in 0 until 18) {
                    p.setFloatsUniform("uP$i", floatArrayOf(result.points[2 * i], result.points[2 * i + 1]))
                }
                val names = listOf("uShirt", "uGloves", "uSocks", "uStockings")
                for ((i, n) in names.withIndex()) {
                    val c = e.colors.getOrElse(i) { 0 }
                    val v = rgb(c, hdr)
                    p.setFloatsUniform(n, floatArrayOf(v[0], v[1], v[2], if (c != 0) 1f else 0f))
                }
                p.setFloatUniform("uSleeves", e.sleeves.toFloat())
                p.setFloatUniform("uTop", e.stockingTop)
                p.setFloatUniform("uSheer", e.sheer)
                p.setFloatUniform("uPattern", e.pattern.toFloat())
                p.bindAttributesAndUniforms()
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                GlUtil.checkGlError()
            } catch (ex: GlUtil.GlException) {
                throw VideoFrameProcessingException(ex)
            }
        }

        override fun release() {
            program?.delete()
            program = null
            copy.release()
            if (skinTex != 0) {
                GLES20.glDeleteTextures(1, intArrayOf(skinTex), 0)
                skinTex = 0
            }
            executor.execute {
                pose?.close()
                pose = null
                parts?.close()
                parts = null
            }
            executor.shutdown()
        }
    }

    private companion object {
        const val SIZE = 256

        // Points: 0/1 shoulders, 2/3 elbows, 4/5 wrists, 6/7 hand centres,
        // 8/9 hips, 10/11 knees, 12/13 ankles, 14/15 heels, 16/17 toes.
        const val OUTFIT_FRAGMENT = """
precision highp float;
uniform sampler2D uFrame;
uniform sampler2D uSkin;
uniform float uAspect;
uniform float uS;
uniform vec2 uP0; uniform vec2 uP1; uniform vec2 uP2; uniform vec2 uP3;
uniform vec2 uP4; uniform vec2 uP5; uniform vec2 uP6; uniform vec2 uP7;
uniform vec2 uP8; uniform vec2 uP9; uniform vec2 uP10; uniform vec2 uP11;
uniform vec2 uP12; uniform vec2 uP13; uniform vec2 uP14; uniform vec2 uP15;
uniform vec2 uP16; uniform vec2 uP17;
uniform vec4 uShirt;
uniform vec4 uGloves;
uniform vec4 uSocks;
uniform vec4 uStockings;
uniform float uSleeves;
uniform float uTop;
uniform float uSheer;
uniform float uPattern;
varying vec2 vTex;
""" + DYE + """
vec2 X;
float ss(float x) { float t = clamp(x, 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
bool seen(vec2 p) { return p.x > -5.0; }
float segd(vec2 a, vec2 b) {
  vec2 ab = b - a;
  float t = clamp(dot(X - a, ab) / max(dot(ab, ab), 1e-9), 0.0, 1.0);
  return length(X - (a + t * ab));
}
// Inside a rounded stick from a to b of radius r (soft edge).
float cap(vec2 a, vec2 b, float r) {
  if (!seen(a) || !seen(b)) return 0.0;
  return ss((1.0 - segd(a, b) / r) / 0.3);
}
// On the side of the line through a (across a→b) that b is on.
float beyond(vec2 a, vec2 b) {
  vec2 d = b - a;
  return ss(dot(X - a, d) / max(length(d), 1e-6) / (0.03 * uS));
}
float edge(vec2 a, vec2 b, vec2 c, float m) {
  vec2 n = normalize(vec2(-(b - a).y, (b - a).x));
  if (dot(c - a, n) < 0.0) n = -n;
  return ss((dot(X - a, n) + m) / (0.05 * uS));
}
float torso() {
  if (!seen(uP0) || !seen(uP1) || !seen(uP8) || !seen(uP9)) return 0.0;
  vec2 c = (uP0 + uP1 + uP8 + uP9) * 0.25;
  float m = 0.18 * uS;
  return min(min(edge(uP0, uP1, c, m), edge(uP1, uP9, c, m)),
             min(edge(uP9, uP8, c, m), edge(uP8, uP0, c, m)));
}
float arm(vec2 sh, vec2 el, vec2 wr) {
  if (uSleeves < 0.5) return 0.0;
  if (uSleeves < 1.5) return cap(sh, sh + (el - sh) * 0.5, 0.22 * uS);
  float fore = seen(wr) ? cap(el, wr, 0.2 * uS) * (1.0 - beyond(wr, wr + (wr - el))) : 0.0;
  return max(cap(sh, el, 0.22 * uS), fore);
}
float hand(vec2 wr, vec2 el, vec2 h) {
  if (!seen(wr) || !seen(el) || !seen(h)) return 0.0;
  vec2 tip = wr + (h - wr) * 1.6;
  return cap(wr, tip, 0.22 * uS) * beyond(wr - (wr - el) * 0.08, wr + (wr - el));
}
float foot(vec2 an, vec2 kn, vec2 he, vec2 to, float up) {
  if (!seen(an)) return 0.0;
  vec2 cuff = seen(kn) ? an + (kn - an) * up : an;
  return max(cap(cuff, an, 0.16 * uS), max(cap(an, he, 0.16 * uS), cap(he, to, 0.15 * uS)));
}
float leg(vec2 hip, vec2 kn, vec2 an, vec2 he, vec2 to) {
  float f = foot(an, kn, he, to, 0.0);
  if (!seen(hip) || !seen(kn)) return f;
  vec2 cuff = hip + (kn - hip) * uTop;
  return max(max(cap(cuff, kn, 0.3 * uS), cap(kn, an, 0.22 * uS)), f);
}
// Plaid or stripes, laid out across the body (from the shoulders, turning
// with them), so the pattern moves with the person.
float band(float t, float w) { return ss((w - abs(fract(t) - 0.5)) / 0.04); }
vec3 pat(vec3 t) {
  if (uPattern < 0.5 || !seen(uP0) || !seen(uP1)) return t;
  vec2 o = (uP0 + uP1) * 0.5;
  vec2 u = normalize(uP1 - uP0);
  vec2 v = vec2(-u.y, u.x);
  vec2 k = vec2(dot(X - o, u), dot(X - o, v)) / uS * 2.5;
  if (uPattern < 1.5) {
    // Tartan: wide darker bands both ways, thin light lines between.
    vec3 c = t * (1.0 - 0.38 * band(k.x, 0.18)) * (1.0 - 0.38 * band(k.y, 0.18));
    float thin = max(band(k.x + 0.5, 0.03), band(k.y + 0.5, 0.03));
    return mix(c, mix(t, vec3(1.0), 0.6), thin * 0.8);
  }
  // Stripes across the body.
  return t * (1.0 - 0.45 * band(k.y, 0.22));
}
void main() {
  vec4 c = texture2D(uFrame, vTex);
  X = vec2(vTex.x * uAspect, 1.0 - vTex.y);
  float skin = ss((texture2D(uSkin, vec2(vTex.x, 1.0 - vTex.y)).r - 0.3) / 0.4);
  vec3 col = c.rgb;
  if (uShirt.a > 0.5) {
    float m = max(torso(), max(arm(uP0, uP2, uP4), arm(uP1, uP3, uP5)));
    col = dye(col, pat(uShirt.rgb), m * skin * (1.0 - uSheer));
  }
  if (uGloves.a > 0.5) {
    float m = max(hand(uP4, uP2, uP6), hand(uP5, uP3, uP7));
    col = dye(col, pat(uGloves.rgb), m * skin * (1.0 - uSheer));
  }
  if (uStockings.a > 0.5) {
    float m = max(leg(uP8, uP10, uP12, uP14, uP16), leg(uP9, uP11, uP13, uP15, uP17));
    col = dye(col, pat(uStockings.rgb), m * skin * (1.0 - uSheer));
  }
  if (uSocks.a > 0.5) {
    float m = max(foot(uP12, uP10, uP14, uP16, 0.3), foot(uP13, uP11, uP15, uP17, 0.3));
    col = dye(col, pat(uSocks.rgb), m * skin * (1.0 - uSheer));
  }
  gl_FragColor = vec4(col, c.a);
}
"""
    }
}

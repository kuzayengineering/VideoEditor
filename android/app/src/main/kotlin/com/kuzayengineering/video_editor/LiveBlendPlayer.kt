package com.kuzayengineering.video_editor

import android.content.Context
import android.graphics.SurfaceTexture
import android.net.Uri
import android.opengl.EGL14
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Choreographer
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.media3.common.C
import androidx.media3.common.GlTextureInfo
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The preview with transitions mixed live, as YouCut does it: two players
 * play the timeline side by side, layer A holding each clip with its end
 * and layer B each clip with its start (the same layers the export mixes),
 * and our own drawing code shows A, or during a transition both mixed by
 * the transition's picture (the export's own shaders, [TransitionBlender]).
 *
 * Each layer is fitted to the picture with bars and given its filter on
 * the way. HDR clips stay HDR (the screen is drawn in HLG once one shows).
 * Only used when every piece plays as is or with just a filter (Flutter
 * checks; see liveBlendable): other effects use the slower ways.
 */
class LiveBlendPlayer(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())

    val a: ExoPlayer = ExoPlayer.Builder(
        context,
        DefaultRenderersFactory(context).experimentalSetEnableMediaCodecVideoRendererPrewarming(true),
    ).build()

    /** Silent: the sound comes from layer A. */
    val b: ExoPlayer = ExoPlayer.Builder(context).build().apply {
        volume = 0f
        trackSelectionParameters = trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
            .build()
    }

    private var segA: List<Segment> = emptyList()
    private var segB: List<Segment> = emptyList()
    private var startsA = LongArray(0)
    private var startsB = LongArray(0)
    @Volatile private var windows: List<Blend> = emptyList()
    @Volatile private var gradesA: List<Segment> = emptyList()
    @Volatile private var gradesB: List<Segment> = emptyList()

    /** What the drawing needs from the players (read on the main thread). */
    private class Snapshot(
        val posUs: Long,
        val atNs: Long,
        val playing: Boolean,
        val indexA: Int,
        val indexB: Int,
    )

    @Volatile private var snap = Snapshot(0, 0, false, 0, 0)
    @Volatile private var sizeA = floatArrayOf(16f, 9f)
    @Volatile private var sizeB = floatArrayOf(16f, 9f)
    @Volatile private var hdrA = false
    @Volatile private var hdrB = false
    /** HDR has been seen: the screen is drawn in HLG from then on. */
    @Volatile private var hdrWanted = false
    private var released = false

    // --- Drawing (all on [gl]'s thread) ---------------------------------
    private val glThread = HandlerThread("live-preview").apply { start() }
    private val gl = Handler(glThread.looper)
    private var display: EGLDisplay? = null
    private var eglContext: EGLContext? = null
    private var placeholder: EGLSurface? = null
    private var texA = 0
    private var texB = 0
    private var stA: SurfaceTexture? = null
    private var stB: SurfaceTexture? = null
    private val matA = FloatArray(16)
    private val matB = FloatArray(16)
    private var windowSurface: Surface? = null
    private var eglWindow: EGLSurface? = null
    private var winW = 0
    private var winH = 0
    private var outHlg = false
    private var fboA: GlTextureInfo? = null
    private var fboB: GlTextureInfo? = null
    private var layerProgram: GlProgram? = null
    private var blender: TransitionBlender? = null
    private var blenderFor: List<Blend>? = null
    private var drawPosted = false
    private var broken = false

    /** Every screen refresh: where the players are, kept in step. */
    private val tick = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (released) return
            update()
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    init {
        val ready = CountDownLatch(1)
        var surfaces: Pair<Surface, Surface>? = null
        gl.post {
            try {
                surfaces = setUpGl()
            } catch (e: Throwable) {
                Log.e(TAG, "live preview: GL set-up failed", e)
                broken = true
            }
            ready.countDown()
        }
        ready.await(5, TimeUnit.SECONDS)
        surfaces?.let { (sa, sb) ->
            a.setVideoSurface(sa)
            b.setVideoSurface(sb)
        }
        a.addListener(object : Player.Listener {
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    sizeA = floatArrayOf(videoSize.width * videoSize.pixelWidthHeightRatio, videoSize.height.toFloat())
                    requestDraw()
                }
            }
        })
        b.addListener(object : Player.Listener {
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    sizeB = floatArrayOf(videoSize.width * videoSize.pixelWidthHeightRatio, videoSize.height.toFloat())
                    requestDraw()
                }
            }
        })
        Choreographer.getInstance().postFrameCallback(tick)
    }

    private fun update() {
        val ia = a.currentMediaItemIndex.coerceIn(0, maxOf(0, startsA.size - 1))
        val ib = b.currentMediaItemIndex.coerceIn(0, maxOf(0, startsB.size - 1))
        val posA = (startsA.getOrElse(ia) { 0L }) + a.currentPosition * 1000
        snap = Snapshot(posA, System.nanoTime(), a.isPlaying, ia, ib)
        hdrA = isHdr(a)
        hdrB = isHdr(b)
        if ((hdrA || hdrB) && !hdrWanted) {
            hdrWanted = true
            gl.post { remakeWindow() }
        }
        // Layer B follows A. It is only corrected away from transitions
        // (a jump shows as a short stall).
        if (startsB.isNotEmpty() && a.playWhenReady) {
            if (!b.playWhenReady) b.play()
            val posB = startsB[ib] + b.currentPosition * 1000
            if (Math.abs(posA - posB) > 60_000 && !nearWindow(posA, 400_000)) {
                seekLayerB(posA + 30_000)
            }
        }
    }

    private fun isHdr(p: ExoPlayer): Boolean {
        val t = p.videoFormat?.colorInfo?.colorTransfer
        return t == C.COLOR_TRANSFER_HLG || t == C.COLOR_TRANSFER_ST2084
    }

    private fun nearWindow(t: Long, marginUs: Long) =
        windows.any { t >= it.startUs - marginUs && t < it.startUs + it.durationUs + marginUs }

    // --- Timeline -----------------------------------------------------------

    fun setTimeline(layerA: List<Segment>, layerB: List<Segment>, blends: List<Blend>, keepUs: Long) {
        segA = layerA
        segB = layerB
        gradesA = layerA
        gradesB = layerB
        startsA = starts(layerA)
        startsB = starts(layerB)
        windows = blends
        val keep = keepUs.coerceAtLeast(0)
        val (ia, oa) = locate(startsA, layerA, keep)
        val (ib, ob) = locate(startsB, layerB, keep)
        a.setMediaItems(items(layerA), ia, oa)
        b.setMediaItems(items(layerB), ib, ob)
        a.prepare()
        b.prepare()
        requestDraw()
    }

    private fun starts(list: List<Segment>): LongArray {
        val out = LongArray(list.size)
        var t = 0L
        list.forEachIndexed { i, s ->
            out[i] = t
            t += s.timelineUs
        }
        return out
    }

    private fun items(list: List<Segment>) = list.map { s ->
        MediaItem.Builder()
            .setUri(Uri.parse(s.source))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(s.inUs / 1000)
                    .setEndPositionMs(s.outUs / 1000)
                    .build()
            )
            .build()
    }

    private fun locate(starts: LongArray, list: List<Segment>, timeUs: Long): Pair<Int, Long> {
        if (list.isEmpty()) return 0 to 0L
        var i = starts.indexOfLast { it <= timeUs }
        if (i < 0) i = 0
        val offset = (timeUs - starts[i]).coerceIn(0, list[i].lengthUs)
        return i to offset / 1000
    }

    private fun seekLayerB(timeUs: Long) {
        if (segB.isEmpty()) return
        val (i, off) = locate(startsB, segB, timeUs)
        b.seekTo(i, off)
    }

    fun play() {
        a.play()
        b.play()
    }

    fun pause() {
        a.pause()
        b.pause()
    }

    fun seek(timeUs: Long, exact: Boolean, toleranceUs: Long) {
        if (segA.isEmpty()) return
        val params = if (exact || toleranceUs <= 0) SeekParameters.EXACT
        else SeekParameters(toleranceUs, toleranceUs)
        a.setSeekParameters(params)
        // Layer B always lands on its exact frame (it is only seen during
        // transitions, where both must match).
        b.setSeekParameters(SeekParameters.EXACT)
        val (i, off) = locate(startsA, segA, timeUs)
        a.seekTo(i, off)
        seekLayerB(timeUs)
    }

    fun positionUs(): Long {
        if (segA.isEmpty()) return 0
        val i = a.currentMediaItemIndex.coerceIn(0, startsA.size - 1)
        return startsA[i] + a.currentPosition * 1000
    }

    fun setScrubbing(on: Boolean) {
        a.setScrubbingModeEnabled(on)
        b.setScrubbingModeEnabled(on)
    }

    fun setVolume(v: Float) {
        a.volume = v
    }

    /** New filter values (see LiveGrades): redraw. */
    fun gradesChanged() = requestDraw()

    // --- The screen ---------------------------------------------------------

    private var view: SurfaceView? = null
    private val holderCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {}

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            val s = holder.surface
            gl.post { setWindow(s, width, height) }
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            onGlAndWait { dropWindow() }
        }
    }

    fun attach(v: SurfaceView) {
        view = v
        v.holder.addCallback(holderCallback)
        val s = v.holder.surface
        if (s != null && s.isValid) {
            val f = v.holder.surfaceFrame
            gl.post { setWindow(s, f.width(), f.height()) }
        }
    }

    fun detach(v: SurfaceView) {
        if (view !== v) return
        v.holder.removeCallback(holderCallback)
        onGlAndWait { dropWindow() }
        view = null
    }

    fun release() {
        if (released) return
        released = true
        Choreographer.getInstance().removeFrameCallback(tick)
        view?.let { detach(it) }
        a.release()
        b.release()
        onGlAndWait {
            try {
                dropWindow()
                layerProgram?.delete()
                blender?.release()
                fboA?.release()
                fboB?.release()
                stA?.release()
                stB?.release()
                if (texA != 0) GLES20.glDeleteTextures(2, intArrayOf(texA, texB), 0)
                display?.let { d ->
                    placeholder?.let { GlUtil.destroyEglSurface(d, it) }
                    eglContext?.let { GlUtil.destroyEglContext(d, it) }
                }
            } catch (e: Throwable) {
                Log.w(TAG, "live preview: release", e)
            }
        }
        glThread.quitSafely()
    }

    private fun onGlAndWait(work: () -> Unit) {
        if (Looper.myLooper() == glThread.looper) {
            work()
            return
        }
        val done = CountDownLatch(1)
        gl.post {
            try {
                work()
            } finally {
                done.countDown()
            }
        }
        done.await(3, TimeUnit.SECONDS)
    }

    private fun requestDraw() {
        gl.post { drawNow() }
    }

    // --- GL thread ----------------------------------------------------------

    private fun setUpGl(): Pair<Surface, Surface> {
        val d = GlUtil.getDefaultEglDisplay()
        display = d
        val ctx = try {
            GlUtil.createEglContext(EGL14.EGL_NO_CONTEXT, d, 3, GlUtil.EGL_CONFIG_ATTRIBUTES_RGBA_1010102)
        } catch (e: GlUtil.GlException) {
            GlUtil.createEglContext(EGL14.EGL_NO_CONTEXT, d, 3, GlUtil.EGL_CONFIG_ATTRIBUTES_RGBA_8888)
        }
        eglContext = ctx
        placeholder = GlUtil.createFocusedPlaceholderEglSurface(ctx, d)
        texA = GlUtil.createExternalTexture()
        texB = GlUtil.createExternalTexture()
        val sa = SurfaceTexture(texA).apply {
            setOnFrameAvailableListener({ scheduleDraw() }, gl)
        }
        val sb = SurfaceTexture(texB).apply {
            setOnFrameAvailableListener({ scheduleDraw() }, gl)
        }
        stA = sa
        stB = sb
        android.opengl.Matrix.setIdentityM(matA, 0)
        android.opengl.Matrix.setIdentityM(matB, 0)
        return Surface(sa) to Surface(sb)
    }

    /** New frames: one draw for however many arrived together. */
    private fun scheduleDraw() {
        if (drawPosted) return
        drawPosted = true
        gl.post {
            drawPosted = false
            drawNow()
        }
    }

    private fun setWindow(s: Surface, w: Int, h: Int) {
        if (released || broken) return
        if (s !== windowSurface || eglWindow == null) {
            dropWindow()
            windowSurface = s
            makeWindow()
        }
        if (w != winW || h != winH) {
            winW = w
            winH = h
            makeFbos()
        }
        drawNow()
    }

    private fun makeWindow() {
        val s = windowSurface ?: return
        val d = display ?: return
        if (!s.isValid) return
        outHlg = false
        eglWindow = try {
            if (hdrWanted) {
                GlUtil.createEglSurface(d, s, C.COLOR_TRANSFER_HLG, false).also { outHlg = true }
            } else {
                GlUtil.createEglSurface(d, s, C.COLOR_TRANSFER_SDR, false)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "live preview: HDR screen not available", e)
            try {
                GlUtil.createEglSurface(d, s, C.COLOR_TRANSFER_SDR, false)
            } catch (e2: Throwable) {
                Log.e(TAG, "live preview: no screen", e2)
                null
            }
        }
    }

    private fun remakeWindow() {
        if (eglWindow == null || outHlg == hdrWanted) return
        val s = windowSurface
        dropWindow()
        windowSurface = s
        makeWindow()
        makeFbos()
        drawNow()
    }

    private fun dropWindow() {
        val d = display ?: return
        eglWindow?.let {
            try {
                val c = eglContext
                val ph = placeholder
                if (c != null && ph != null) GlUtil.focusEglSurface(d, c, ph, 1, 1)
                GlUtil.destroyEglSurface(d, it)
            } catch (e: Throwable) {
                Log.w(TAG, "live preview: drop screen", e)
            }
        }
        eglWindow = null
        windowSurface = null
    }

    private fun makeFbos() {
        if (winW <= 0 || winH <= 0) return
        fboA?.release()
        fboB?.release()
        fboA = fbo()
        fboB = fbo()
    }

    private fun fbo(): GlTextureInfo {
        // 10 bits a colour for HDR (no banding in skies), 8 otherwise.
        val id = GlUtil.createTexture(winW, winH, /* useHighPrecisionColorComponents= */ outHlg)
        return GlTextureInfo(id, GlUtil.createFboForTexture(id), -1, winW, winH)
    }

    private fun drawNow() {
        if (released || broken) return
        // The newest frames (each must be taken, or its player stalls).
        try {
            stA?.updateTexImage()
            stA?.getTransformMatrix(matA)
            stB?.updateTexImage()
            stB?.getTransformMatrix(matB)
        } catch (e: Throwable) {
            return
        }
        val surface = eglWindow ?: return
        val d = display ?: return
        val c = eglContext ?: return
        val fa = fboA ?: return
        val fb = fboB ?: return
        try {
            GlUtil.focusEglSurface(d, c, surface, winW, winH)
            val s = snap
            val t = s.posUs + if (s.playing) (System.nanoTime() - s.atNs) / 1000 else 0L
            val inWindow = windows.any { t >= it.startUs && t < it.startUs + it.durationUs }
            drawLayer(texA, matA, sizeA, hdrA, gradesA.getOrNull(s.indexA), fa)
            if (inWindow) drawLayer(texB, matB, sizeB, hdrB, gradesB.getOrNull(s.indexB), fb)
            val w = windows
            val blend = blender.takeIf { blenderFor === w } ?: run {
                blender?.release()
                TransitionBlender(w).also {
                    blender = it
                    blenderFor = w
                }
            }
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            GLES20.glViewport(0, 0, winW, winH)
            blend.draw(arrayOf(fa, if (inWindow) fb else fa), t, winW, winH, outHlg)
            EGL14.eglSwapBuffers(d, surface)
        } catch (e: Throwable) {
            Log.e(TAG, "live preview: draw", e)
            EffectStatus.fail("The live preview", e)
            broken = true
        }
    }

    /** One layer into [target]: fitted with bars, its filter, its colours
     * matched to the screen (SDR in an HDR picture, or the other way). */
    private fun drawLayer(
        tex: Int,
        mat: FloatArray,
        size: FloatArray,
        hdr: Boolean,
        seg: Segment?,
        target: GlTextureInfo,
    ) {
        val p = layerProgram ?: GlProgram(LAYER_VERTEX, LAYER_FRAGMENT).also {
            it.setBufferAttribute(
                "aFramePosition",
                GlUtil.getNormalizedCoordinateBounds(),
                GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
            )
            layerProgram = it
        }
        GlUtil.focusFramebufferUsingCurrentContext(target.fboId, target.width, target.height)
        GLES20.glDisable(GLES20.GL_BLEND)
        p.use()
        p.setSamplerTexIdUniform("uTex", tex, 0)
        p.setFloatsUniform("uMat", mat)
        // Fitted inside the picture, bars either side.
        val va = size[0] / size[1]
        val ca = target.width.toFloat() / target.height
        val rect = if (va > ca) {
            val h = ca / va
            floatArrayOf(0f, (1f - h) / 2f, 1f, (1f + h) / 2f)
        } else {
            val w = va / ca
            floatArrayOf((1f - w) / 2f, 0f, (1f + w) / 2f, 1f)
        }
        p.setFloatsUniform("uRect", rect)
        p.setIntUniform("uConvert", if (outHlg && !hdr) 1 else if (!outHlg && hdr) 2 else 0)
        p.setIntUniform("uTransfer", 0)
        val g = seg?.let { s -> s.clipId?.let { LiveGrades.get(it) } ?: s.grade?.map { it.toFloat() }?.toFloatArray() }
        fun v(i: Int) = g?.getOrNull(i) ?: 0f
        p.setFloatUniform("uBrightness", v(0))
        p.setFloatUniform("uContrast", v(1))
        p.setFloatUniform("uSaturation", v(2))
        p.setFloatUniform("uWarmth", v(3))
        p.setFloatUniform("uTint", v(4))
        p.setFloatUniform("uFade", v(5))
        p.setFloatUniform("uShadows", v(6))
        p.setFloatUniform("uHighlights", v(7))
        p.setFloatUniform("uHdr", v(8))
        p.setFloatUniform("uBlack", v(9))
        p.setFloatUniform("uWhite", v(10))
        p.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GlUtil.checkGlError()
    }

    companion object {
        private const val TAG = "LiveBlendPlayer"

        const val LAYER_VERTEX = """#version 100
attribute vec4 aFramePosition;
varying vec2 vUv;
void main() {
  gl_Position = aFramePosition;
  vUv = vec2(aFramePosition.x * 0.5 + 0.5, aFramePosition.y * 0.5 + 0.5);
}
"""

        /** The filter shader, reading the player's picture (external
         * texture) fitted into the frame, with colour matching added. */
        val LAYER_FRAGMENT: String = GRADE_FRAGMENT
            .replace(
                "#version 100\n",
                "#version 100\n#extension GL_OES_EGL_image_external : require\n",
            )
            .replace(
                "uniform sampler2D uTex;",
                "uniform samplerExternalOES uTex;\nuniform mat4 uMat;\nuniform vec4 uRect;\nuniform int uConvert;",
            )
            .replace(
                "void main() {",
                """
// SDR (BT.709) into the HLG (BT.2020) picture, white at HLG's reference
// white; or HLG into an SDR picture, highlights rolled off.
float hlgOetf(float e) {
  e = max(e, 0.0);
  return e <= 1.0 / 12.0 ? sqrt(3.0 * e) : HA * log(12.0 * e - HB) + HC;
}
float hlgInverse(float s) {
  s = clamp(s, 0.0, 1.0);
  return s <= 0.5 ? s * s / 3.0 : (HB + exp((s - HC) / HA)) / 12.0;
}
vec3 matchColors(vec3 c) {
  if (uConvert == 1) {
    vec3 l = pow(clamp(c, 0.0, 1.0), vec3(2.4));
    l = mat3(0.6274, 0.0691, 0.0164, 0.3293, 0.9195, 0.0880, 0.0433, 0.0114, 0.8956) * l;
    l *= 0.2647;
    return vec3(hlgOetf(l.r), hlgOetf(l.g), hlgOetf(l.b));
  } else if (uConvert == 2) {
    vec3 l = vec3(hlgInverse(c.r), hlgInverse(c.g), hlgInverse(c.b)) / 0.2647;
    l = mat3(1.6605, -0.1246, -0.0182, -0.5876, 1.1329, -0.1006, -0.0728, -0.0083, 1.1187) * l;
    l = max(l, 0.0);
    vec3 over = max(l - 0.8, 0.0);
    l = min(l, 0.8) + 0.2 * over / (over + 0.6);
    return pow(l, vec3(1.0 / 2.4));
  }
  return c;
}

void main() {""",
            )
            .replace(
                "vec4 lin = texture2D(uTex, vUv);",
                """vec2 q = (vUv - uRect.xy) / (uRect.zw - uRect.xy);
  if (q.x < 0.0 || q.x > 1.0 || q.y < 0.0 || q.y > 1.0) {
    gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }
  vec4 lin = texture2D(uTex, (uMat * vec4(q, 0.0, 1.0)).xy);""",
            )
            .replace(
                "gl_FragColor = vec4(toLight(c.r), toLight(c.g), toLight(c.b), lin.a);",
                "gl_FragColor = vec4(matchColors(c), 1.0);",
            )
    }
}

/*
 * Added for Video Editor (not part of Media3): smooth slow motion.
 */
package androidx.media3.effect;

import android.content.Context;
import android.opengl.GLES20;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.GlObjectsProvider;
import androidx.media3.common.GlTextureInfo;
import androidx.media3.common.VideoFrameProcessingException;
import androidx.media3.common.util.GlProgram;
import androidx.media3.common.util.GlUtil;
import androidx.media3.common.util.UnstableApi;
import com.google.common.util.concurrent.MoreExecutors;
import java.util.concurrent.Executor;

/**
 * Smooth slow motion: makes {@code factor - 1} new frames between each pair
 * of frames, by estimating how each part of the picture moved (block
 * matching on a small brightness copy) and drawing it part of the way
 * along. Where the estimate doesn't hold (something revealed or hidden),
 * it falls back to blending the two frames.
 */
@UnstableApi
public final class MotionInterpolation implements GlEffect {
  private final int factor;

  public MotionInterpolation(int factor) {
    this.factor = Math.max(1, Math.min(4, factor));
  }

  @Override
  public GlShaderProgram toGlShaderProgram(Context context, boolean useHdr)
      throws VideoFrameProcessingException {
    return new MotionInterpolationShaderProgram(factor, useHdr);
  }
}

/* package */ final class MotionInterpolationShaderProgram implements GlShaderProgram {
  /** The brightness copy is this many times smaller than the picture. */
  private static final int SCALE = 8;

  private static final String VERTEX =
      "#version 100\n"
          + "attribute vec4 aFramePosition;\n"
          + "varying vec2 vUv;\n"
          + "void main() {\n"
          + "  gl_Position = aFramePosition;\n"
          + "  vUv = aFramePosition.xy * 0.5 + 0.5;\n"
          + "}\n";

  private static final String COPY =
      "#version 100\n"
          + "precision highp float;\n"
          + "uniform sampler2D uTex;\n"
          + "varying vec2 vUv;\n"
          + "void main() { gl_FragColor = texture2D(uTex, vUv); }\n";

  // Brightness (compressed, so HDR's wide range matches sensibly), averaged
  // over each SCALE x SCALE block with 16 bilinear taps.
  private static final String LUMA =
      "float lum(vec3 c) {\n"
          + "  return pow(max(dot(c, vec3(0.2627, 0.678, 0.0593)), 0.0), 0.4);\n"
          + "}\n";

  private static final String DOWN =
      "#version 100\n"
          + "precision highp float;\n"
          + "uniform sampler2D uTex;\n"
          + "uniform vec2 uTexel;\n"
          + "varying vec2 vUv;\n"
          + LUMA
          + "void main() {\n"
          + "  float s = 0.0;\n"
          + "  for (int j = 0; j < 4; j++) {\n"
          + "    for (int i = 0; i < 4; i++) {\n"
          + "      vec2 o = (vec2(float(i), float(j)) - 1.5) * 2.0 * uTexel;\n"
          + "      s += lum(texture2D(uTex, vUv + o).rgb);\n"
          + "    }\n"
          + "  }\n"
          + "  gl_FragColor = vec4(s / 16.0, 0.0, 0.0, 1.0);\n"
          + "}\n";

  // Symmetric block matching: the motion d (in brightness-copy pixels) for
  // which the earlier frame at p - d/2 best matches the later one at p + d/2.
  // Stored as d / (2 R) + 0.5. A small cost for longer moves keeps still
  // areas still.
  private static final int RADIUS = 5;
  private static final String MATCH =
      "#version 100\n"
          + "precision highp float;\n"
          + "uniform sampler2D uA;\n"
          + "uniform sampler2D uB;\n"
          + "uniform vec2 uTexel;\n"
          + "varying vec2 vUv;\n"
          + "const int R = " + RADIUS + ";\n"
          + "void main() {\n"
          + "  float best = 1e9;\n"
          + "  vec2 bestD = vec2(0.0);\n"
          + "  for (int dy = -R; dy <= R; dy++) {\n"
          + "    for (int dx = -R; dx <= R; dx++) {\n"
          + "      vec2 d = vec2(float(dx), float(dy));\n"
          + "      vec2 h = 0.5 * d * uTexel;\n"
          + "      float cost = 0.0;\n"
          + "      for (int j = -1; j <= 1; j++) {\n"
          + "        for (int i = -1; i <= 1; i++) {\n"
          + "          vec2 o = vec2(float(i), float(j)) * uTexel;\n"
          + "          cost += abs(texture2D(uA, vUv + o - h).r - texture2D(uB, vUv + o + h).r);\n"
          + "        }\n"
          + "      }\n"
          + "      cost += 0.004 * length(d);\n"
          + "      if (cost < best) { best = cost; bestD = d; }\n"
          + "    }\n"
          + "  }\n"
          + "  gl_FragColor = vec4(bestD / (2.0 * float(R)) + 0.5, 0.0, 1.0);\n"
          + "}\n";

  // Evens out the motion estimates (an average of each 3 x 3 neighbourhood).
  private static final String SMOOTH =
      "#version 100\n"
          + "precision highp float;\n"
          + "uniform sampler2D uTex;\n"
          + "uniform vec2 uTexel;\n"
          + "varying vec2 vUv;\n"
          + "void main() {\n"
          + "  vec2 s = vec2(0.0);\n"
          + "  for (int j = -1; j <= 1; j++) {\n"
          + "    for (int i = -1; i <= 1; i++) {\n"
          + "      s += texture2D(uTex, vUv + vec2(float(i), float(j)) * uTexel).rg;\n"
          + "    }\n"
          + "  }\n"
          + "  gl_FragColor = vec4(s / 9.0, 0.0, 1.0);\n"
          + "}\n";

  // The new frame at uAlpha (0 = earlier, 1 = later frame).
  private static final String WARP =
      "#version 100\n"
          + "precision highp float;\n"
          + "uniform sampler2D uA;\n"
          + "uniform sampler2D uB;\n"
          + "uniform sampler2D uFlow;\n"
          + "uniform vec2 uLowTexel;\n"
          + "uniform float uAlpha;\n"
          + "varying vec2 vUv;\n"
          + "const float R = " + RADIUS + ".0;\n"
          + LUMA
          + "void main() {\n"
          + "  vec2 d = (texture2D(uFlow, vUv).rg - 0.5) * 2.0 * R * uLowTexel;\n"
          + "  vec4 a = texture2D(uA, vUv - uAlpha * d);\n"
          + "  vec4 b = texture2D(uB, vUv + (1.0 - uAlpha) * d);\n"
          + "  vec4 moved = mix(a, b, uAlpha);\n"
          + "  vec4 plain = mix(texture2D(uA, vUv), texture2D(uB, vUv), uAlpha);\n"
          + "  float err = abs(lum(a.rgb) - lum(b.rgb));\n"
          + "  gl_FragColor = mix(moved, plain, smoothstep(0.06, 0.2, err));\n"
          + "}\n";

  private final int factor;
  private final boolean useHdr;
  private final TexturePool pool;
  private final GlProgram copy;
  private final GlProgram down;
  private final GlProgram match;
  private final GlProgram smooth;
  private final GlProgram warp;

  private InputListener inputListener = new InputListener() {};
  private OutputListener outputListener = new OutputListener() {};
  private ErrorListener errorListener = e -> {};
  private Executor errorExecutor = MoreExecutors.directExecutor();

  @Nullable private GlTextureInfo prev;
  @Nullable private GlTextureInfo lowPrev;
  @Nullable private GlTextureInfo lowCur;
  @Nullable private GlTextureInfo flow;
  @Nullable private GlTextureInfo flowSmooth;
  private boolean havePrev;
  private long prevTimeUs = C.TIME_UNSET;
  private long lastDeltaUs = C.TIME_UNSET;
  private boolean awaitingInput;

  MotionInterpolationShaderProgram(int factor, boolean useHdr)
      throws VideoFrameProcessingException {
    this.factor = factor;
    this.useHdr = useHdr;
    // Room for one input's worth of frames, plus as many again downstream.
    pool = new TexturePool(useHdr, 2 * factor);
    try {
      copy = program(COPY);
      down = program(DOWN);
      match = program(MATCH);
      smooth = program(SMOOTH);
      warp = program(WARP);
    } catch (GlUtil.GlException e) {
      throw VideoFrameProcessingException.from(e);
    }
  }

  private static GlProgram program(String fragment) throws GlUtil.GlException {
    GlProgram p = new GlProgram(VERTEX, fragment);
    p.setBufferAttribute(
        "aFramePosition",
        GlUtil.getNormalizedCoordinateBounds(),
        GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE);
    return p;
  }

  @Override
  public void setInputListener(InputListener inputListener) {
    this.inputListener = inputListener;
    awaitingInput = false;
    maybeReady();
  }

  @Override
  public void setOutputListener(OutputListener outputListener) {
    this.outputListener = outputListener;
  }

  @Override
  public void setErrorListener(Executor executor, ErrorListener errorListener) {
    this.errorExecutor = executor;
    this.errorListener = errorListener;
  }

  /** Asks for the next input only when one input's worth of frames fits. */
  private void maybeReady() {
    if (awaitingInput) return;
    if (!pool.isConfigured() || pool.freeTextureCount() >= factor) {
      awaitingInput = true;
      inputListener.onReadyToAcceptInputFrame();
    }
  }

  private GlTextureInfo owned(
      GlObjectsProvider objects, @Nullable GlTextureInfo t, int w, int h, boolean precise)
      throws GlUtil.GlException {
    if (t != null && t.width == w && t.height == h) return t;
    if (t != null) t.release();
    int id = GlUtil.createTexture(w, h, precise);
    return objects.createBuffersForTexture(id, w, h);
  }

  private void draw(GlProgram p, GlTextureInfo target) throws GlUtil.GlException {
    GlUtil.focusFramebufferUsingCurrentContext(target.fboId, target.width, target.height);
    p.bindAttributesAndUniforms();
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
  }

  private void copyTo(int texId, GlTextureInfo target) throws GlUtil.GlException {
    copy.use();
    copy.setSamplerTexIdUniform("uTex", texId, 0);
    draw(copy, target);
  }

  @Override
  public void queueInputFrame(
      GlObjectsProvider objects, GlTextureInfo input, long presentationTimeUs) {
    awaitingInput = false;
    try {
      int w = input.width;
      int h = input.height;
      int lw = Math.max(16, w / SCALE);
      int lh = Math.max(16, h / SCALE);
      pool.ensureConfigured(objects, w, h);
      prev = owned(objects, prev, w, h, useHdr);
      lowPrev = owned(objects, lowPrev, lw, lh, false);
      lowCur = owned(objects, lowCur, lw, lh, false);
      flow = owned(objects, flow, lw, lh, false);
      flowSmooth = owned(objects, flowSmooth, lw, lh, false);

      // This frame's brightness copy.
      down.use();
      down.setSamplerTexIdUniform("uTex", input.texId, 0);
      down.setFloatsUniform("uTexel", new float[] {1f / w, 1f / h});
      draw(down, lowCur);

      boolean consecutive =
          havePrev
              && presentationTimeUs > prevTimeUs
              && (lastDeltaUs == C.TIME_UNSET
                  || presentationTimeUs - prevTimeUs <= 3 * lastDeltaUs);
      if (consecutive && factor > 1) {
        float[] lowTexel = new float[] {1f / lw, 1f / lh};
        match.use();
        match.setSamplerTexIdUniform("uA", lowPrev.texId, 0);
        match.setSamplerTexIdUniform("uB", lowCur.texId, 1);
        match.setFloatsUniform("uTexel", lowTexel);
        draw(match, flow);
        smooth.use();
        smooth.setSamplerTexIdUniform("uTex", flow.texId, 0);
        smooth.setFloatsUniform("uTexel", lowTexel);
        draw(smooth, flowSmooth);
        for (int k = 1; k < factor; k++) {
          float alpha = (float) k / factor;
          GlTextureInfo out = pool.useTexture();
          warp.use();
          warp.setSamplerTexIdUniform("uA", prev.texId, 0);
          warp.setSamplerTexIdUniform("uB", input.texId, 1);
          warp.setSamplerTexIdUniform("uFlow", flowSmooth.texId, 2);
          warp.setFloatsUniform("uLowTexel", lowTexel);
          warp.setFloatUniform("uAlpha", alpha);
          draw(warp, out);
          long t = prevTimeUs + (presentationTimeUs - prevTimeUs) * k / factor;
          outputListener.onOutputFrameAvailable(out, t);
        }
      }
      if (havePrev && presentationTimeUs > prevTimeUs) {
        lastDeltaUs = presentationTimeUs - prevTimeUs;
      }

      // Keep this frame for the next pair, then pass it on.
      copyTo(input.texId, prev);
      havePrev = true;
      prevTimeUs = presentationTimeUs;
      GlTextureInfo swap = lowPrev;
      lowPrev = lowCur;
      lowCur = swap;

      GlTextureInfo out = pool.useTexture();
      copyTo(input.texId, out);
      inputListener.onInputFrameProcessed(input);
      outputListener.onOutputFrameAvailable(out, presentationTimeUs);
    } catch (GlUtil.GlException | RuntimeException e) {
      errorExecutor.execute(() -> errorListener.onError(VideoFrameProcessingException.from(e)));
    }
    maybeReady();
  }

  @Override
  public void releaseOutputFrame(GlTextureInfo outputTexture) {
    if (pool.isUsingTexture(outputTexture)) {
      pool.freeTexture(outputTexture);
    }
    maybeReady();
  }

  private void forgetPrevious() {
    havePrev = false;
    prevTimeUs = C.TIME_UNSET;
    lastDeltaUs = C.TIME_UNSET;
  }

  @Override
  public void signalEndOfCurrentInputStream() {
    forgetPrevious();
    outputListener.onCurrentOutputStreamEnded();
  }

  @Override
  public void flush() {
    pool.freeAllTextures();
    forgetPrevious();
    inputListener.onFlush();
    awaitingInput = false;
    maybeReady();
  }

  @Override
  public void release() throws VideoFrameProcessingException {
    try {
      pool.deleteAllTextures();
      for (GlTextureInfo t : new GlTextureInfo[] {prev, lowPrev, lowCur, flow, flowSmooth}) {
        if (t != null) t.release();
      }
      copy.delete();
      down.delete();
      match.delete();
      smooth.delete();
      warp.delete();
    } catch (GlUtil.GlException e) {
      throw new VideoFrameProcessingException(e);
    }
  }
}

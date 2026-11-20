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
 * of frames, by estimating how each part of the picture moved and drawing
 * it part of the way along. The movement is found coarse to fine: first on
 * a tiny brightness copy (large moves), then refined on bigger copies down
 * to a quarter of the picture's size, to a fraction of a pixel, with stray
 * estimates removed and the result smoothed at each step. Where the
 * estimate doesn't hold (something uncovered or hidden), it fades to a
 * plain mix of the two frames.
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
      + "varying vec2 vUv;\n"
      + "uniform sampler2D uTex;\n"
      + "void main() { gl_FragColor = texture2D(uTex, vUv); }\n";

  private static final String DOWN =
      "#version 100\n"
      + "precision highp float;\n"
      + "varying vec2 vUv;\n"
      + "uniform sampler2D uTex;\n"
      + "uniform vec2 uTexel;\n"
      + "uniform float uStep;\n"
      + "\n"
      + "float lum(vec3 c) {\n"
      + "  return pow(max(dot(c, vec3(0.2627, 0.678, 0.0593)), 0.0), 0.4);\n"
      + "}\n"
      + "\n"
      + "void main() {\n"
      + "  float s = 0.0;\n"
      + "  for (int j = 0; j < 4; j++) {\n"
      + "    for (int i = 0; i < 4; i++) {\n"
      + "      vec2 o = (vec2(float(i), float(j)) - 1.5) * (uStep / 4.0) * uTexel;\n"
      + "      s += lum(texture2D(uTex, vUv + o).rgb);\n"
      + "    }\n"
      + "  }\n"
      + "  gl_FragColor = vec4(s / 16.0, 0.0, 0.0, 1.0);\n"
      + "}\n";

  private static final String HALF =
      "#version 100\n"
      + "precision highp float;\n"
      + "varying vec2 vUv;\n"
      + "uniform sampler2D uTex;\n"
      + "void main() { gl_FragColor = texture2D(uTex, vUv); }\n";

  private static final String MATCH4 =
      "#version 100\n"
      + "precision highp float;\n"
      + "varying vec2 vUv;\n"
      + "\n"
      + "vec4 pack(vec2 d) {\n"
      + "  vec2 v = clamp(d * 2.0 + 0.5, 0.0, 1.0) * 255.0;\n"
      + "  vec2 hi = floor(v);\n"
      + "  vec2 lo = v - hi;\n"
      + "  return vec4(hi.x / 255.0, lo.x, hi.y / 255.0, lo.y);\n"
      + "}\n"
      + "vec2 unpackAt(sampler2D t, vec2 uv) {\n"
      + "  vec4 c = texture2D(t, uv);\n"
      + "  vec2 v = (vec2(c.r, c.b) * 255.0 + vec2(c.g, c.a)) / 255.0;\n"
      + "  return (v - 0.5) * 0.5;\n"
      + "}\n"
      + "// Bilinear between the 4 nearest flow texels (the packed form can't be\n"
      + "// mixed by the graphics chip itself).\n"
      + "vec2 flowAt(sampler2D t, vec2 size, vec2 uv) {\n"
      + "  vec2 p = uv * size - 0.5;\n"
      + "  vec2 f = fract(p);\n"
      + "  vec2 b = (floor(p) + 0.5) / size;\n"
      + "  vec2 s = 1.0 / size;\n"
      + "  vec2 f00 = unpackAt(t, b);\n"
      + "  vec2 f10 = unpackAt(t, b + vec2(s.x, 0.0));\n"
      + "  vec2 f01 = unpackAt(t, b + vec2(0.0, s.y));\n"
      + "  vec2 f11 = unpackAt(t, b + s);\n"
      + "  return mix(mix(f00, f10, f.x), mix(f01, f11, f.x), f.y);\n"
      + "}\n"
      + "uniform sampler2D uA;\n"
      + "uniform sampler2D uB;\n"
      + "uniform sampler2D uGuess;\n"
      + "uniform vec2 uGuessSize;\n"
      + "uniform float uHasGuess;\n"
      + "uniform vec2 uTexel;\n"
      + "const int R = 4;\n"
      + "float costAt(vec2 d) {\n"
      + "  vec2 h = 0.5 * d;\n"
      + "  float c = 0.0;\n"
      + "  for (int j = -2; j <= 2; j++) {\n"
      + "    for (int i = -2; i <= 2; i++) {\n"
      + "      vec2 o = vec2(float(i), float(j)) * uTexel;\n"
      + "      c += abs(texture2D(uA, vUv + o - h).r - texture2D(uB, vUv + o + h).r);\n"
      + "    }\n"
      + "  }\n"
      + "  return c;\n"
      + "}\n"
      + "void main() {\n"
      + "  // The coarser level's estimate, refined here within R texels.\n"
      + "  vec2 g = uHasGuess > 0.5 ? flowAt(uGuess, uGuessSize, vUv) : vec2(0.0);\n"
      + "  g = floor(g / uTexel + 0.5) * uTexel;\n"
      + "  float best = 1e9;\n"
      + "  vec2 bestD = g;\n"
      + "  for (int dy = -R; dy <= R; dy++) {\n"
      + "    for (int dx = -R; dx <= R; dx++) {\n"
      + "      vec2 d = g + vec2(float(dx), float(dy)) * uTexel;\n"
      + "      // Slightly prefer staying close to the guess (or still, at first).\n"
      + "      float c = costAt(d) + 0.01 * length(vec2(float(dx), float(dy)));\n"
      + "      if (c < best) { best = c; bestD = d; }\n"
      + "    }\n"
      + "  }\n"
      + "  // A fraction of a texel more, from the costs on each side.\n"
      + "  float cl = costAt(bestD - vec2(uTexel.x, 0.0));\n"
      + "  float cr = costAt(bestD + vec2(uTexel.x, 0.0));\n"
      + "  float cd = costAt(bestD - vec2(0.0, uTexel.y));\n"
      + "  float cu = costAt(bestD + vec2(0.0, uTexel.y));\n"
      + "  float sx = cl - 2.0 * best + cr;\n"
      + "  float sy = cd - 2.0 * best + cu;\n"
      + "  vec2 sub = vec2(sx > 1e-5 ? clamp(0.5 * (cl - cr) / sx, -0.5, 0.5) : 0.0,\n"
      + "                  sy > 1e-5 ? clamp(0.5 * (cd - cu) / sy, -0.5, 0.5) : 0.0);\n"
      + "  gl_FragColor = pack(bestD + sub * uTexel);\n"
      + "}\n";

  private static final String MATCH2 =
      "#version 100\n"
      + "precision highp float;\n"
      + "varying vec2 vUv;\n"
      + "\n"
      + "vec4 pack(vec2 d) {\n"
      + "  vec2 v = clamp(d * 2.0 + 0.5, 0.0, 1.0) * 255.0;\n"
      + "  vec2 hi = floor(v);\n"
      + "  vec2 lo = v - hi;\n"
      + "  return vec4(hi.x / 255.0, lo.x, hi.y / 255.0, lo.y);\n"
      + "}\n"
      + "vec2 unpackAt(sampler2D t, vec2 uv) {\n"
      + "  vec4 c = texture2D(t, uv);\n"
      + "  vec2 v = (vec2(c.r, c.b) * 255.0 + vec2(c.g, c.a)) / 255.0;\n"
      + "  return (v - 0.5) * 0.5;\n"
      + "}\n"
      + "// Bilinear between the 4 nearest flow texels (the packed form can't be\n"
      + "// mixed by the graphics chip itself).\n"
      + "vec2 flowAt(sampler2D t, vec2 size, vec2 uv) {\n"
      + "  vec2 p = uv * size - 0.5;\n"
      + "  vec2 f = fract(p);\n"
      + "  vec2 b = (floor(p) + 0.5) / size;\n"
      + "  vec2 s = 1.0 / size;\n"
      + "  vec2 f00 = unpackAt(t, b);\n"
      + "  vec2 f10 = unpackAt(t, b + vec2(s.x, 0.0));\n"
      + "  vec2 f01 = unpackAt(t, b + vec2(0.0, s.y));\n"
      + "  vec2 f11 = unpackAt(t, b + s);\n"
      + "  return mix(mix(f00, f10, f.x), mix(f01, f11, f.x), f.y);\n"
      + "}\n"
      + "uniform sampler2D uA;\n"
      + "uniform sampler2D uB;\n"
      + "uniform sampler2D uGuess;\n"
      + "uniform vec2 uGuessSize;\n"
      + "uniform float uHasGuess;\n"
      + "uniform vec2 uTexel;\n"
      + "const int R = 2;\n"
      + "float costAt(vec2 d) {\n"
      + "  vec2 h = 0.5 * d;\n"
      + "  float c = 0.0;\n"
      + "  for (int j = -2; j <= 2; j++) {\n"
      + "    for (int i = -2; i <= 2; i++) {\n"
      + "      vec2 o = vec2(float(i), float(j)) * uTexel;\n"
      + "      c += abs(texture2D(uA, vUv + o - h).r - texture2D(uB, vUv + o + h).r);\n"
      + "    }\n"
      + "  }\n"
      + "  return c;\n"
      + "}\n"
      + "void main() {\n"
      + "  // The coarser level's estimate, refined here within R texels.\n"
      + "  vec2 g = uHasGuess > 0.5 ? flowAt(uGuess, uGuessSize, vUv) : vec2(0.0);\n"
      + "  g = floor(g / uTexel + 0.5) * uTexel;\n"
      + "  float best = 1e9;\n"
      + "  vec2 bestD = g;\n"
      + "  for (int dy = -R; dy <= R; dy++) {\n"
      + "    for (int dx = -R; dx <= R; dx++) {\n"
      + "      vec2 d = g + vec2(float(dx), float(dy)) * uTexel;\n"
      + "      // Slightly prefer staying close to the guess (or still, at first).\n"
      + "      float c = costAt(d) + 0.01 * length(vec2(float(dx), float(dy)));\n"
      + "      if (c < best) { best = c; bestD = d; }\n"
      + "    }\n"
      + "  }\n"
      + "  // A fraction of a texel more, from the costs on each side.\n"
      + "  float cl = costAt(bestD - vec2(uTexel.x, 0.0));\n"
      + "  float cr = costAt(bestD + vec2(uTexel.x, 0.0));\n"
      + "  float cd = costAt(bestD - vec2(0.0, uTexel.y));\n"
      + "  float cu = costAt(bestD + vec2(0.0, uTexel.y));\n"
      + "  float sx = cl - 2.0 * best + cr;\n"
      + "  float sy = cd - 2.0 * best + cu;\n"
      + "  vec2 sub = vec2(sx > 1e-5 ? clamp(0.5 * (cl - cr) / sx, -0.5, 0.5) : 0.0,\n"
      + "                  sy > 1e-5 ? clamp(0.5 * (cd - cu) / sy, -0.5, 0.5) : 0.0);\n"
      + "  gl_FragColor = pack(bestD + sub * uTexel);\n"
      + "}\n";

  private static final String MEDIAN =
      "#version 100\n"
      + "precision highp float;\n"
      + "varying vec2 vUv;\n"
      + "\n"
      + "vec4 pack(vec2 d) {\n"
      + "  vec2 v = clamp(d * 2.0 + 0.5, 0.0, 1.0) * 255.0;\n"
      + "  vec2 hi = floor(v);\n"
      + "  vec2 lo = v - hi;\n"
      + "  return vec4(hi.x / 255.0, lo.x, hi.y / 255.0, lo.y);\n"
      + "}\n"
      + "vec2 unpackAt(sampler2D t, vec2 uv) {\n"
      + "  vec4 c = texture2D(t, uv);\n"
      + "  vec2 v = (vec2(c.r, c.b) * 255.0 + vec2(c.g, c.a)) / 255.0;\n"
      + "  return (v - 0.5) * 0.5;\n"
      + "}\n"
      + "// Bilinear between the 4 nearest flow texels (the packed form can't be\n"
      + "// mixed by the graphics chip itself).\n"
      + "vec2 flowAt(sampler2D t, vec2 size, vec2 uv) {\n"
      + "  vec2 p = uv * size - 0.5;\n"
      + "  vec2 f = fract(p);\n"
      + "  vec2 b = (floor(p) + 0.5) / size;\n"
      + "  vec2 s = 1.0 / size;\n"
      + "  vec2 f00 = unpackAt(t, b);\n"
      + "  vec2 f10 = unpackAt(t, b + vec2(s.x, 0.0));\n"
      + "  vec2 f01 = unpackAt(t, b + vec2(0.0, s.y));\n"
      + "  vec2 f11 = unpackAt(t, b + s);\n"
      + "  return mix(mix(f00, f10, f.x), mix(f01, f11, f.x), f.y);\n"
      + "}\n"
      + "uniform sampler2D uTex;\n"
      + "uniform vec2 uTexel;\n"
      + "void main() {\n"
      + "  vec2 v[9];\n"
      + "  for (int j = 0; j < 3; j++) {\n"
      + "    for (int i = 0; i < 3; i++) {\n"
      + "      v[j * 3 + i] = unpackAt(uTex, vUv + vec2(float(i - 1), float(j - 1)) * uTexel);\n"
      + "    }\n"
      + "  }\n"
      + "  float best = 1e9;\n"
      + "  vec2 pick = v[4];\n"
      + "  for (int a = 0; a < 9; a++) {\n"
      + "    float s = 0.0;\n"
      + "    for (int b = 0; b < 9; b++) s += length(v[a] - v[b]);\n"
      + "    if (s < best) { best = s; pick = v[a]; }\n"
      + "  }\n"
      + "  gl_FragColor = pack(pick);\n"
      + "}\n";

  private static final String AVG =
      "#version 100\n"
      + "precision highp float;\n"
      + "varying vec2 vUv;\n"
      + "\n"
      + "vec4 pack(vec2 d) {\n"
      + "  vec2 v = clamp(d * 2.0 + 0.5, 0.0, 1.0) * 255.0;\n"
      + "  vec2 hi = floor(v);\n"
      + "  vec2 lo = v - hi;\n"
      + "  return vec4(hi.x / 255.0, lo.x, hi.y / 255.0, lo.y);\n"
      + "}\n"
      + "vec2 unpackAt(sampler2D t, vec2 uv) {\n"
      + "  vec4 c = texture2D(t, uv);\n"
      + "  vec2 v = (vec2(c.r, c.b) * 255.0 + vec2(c.g, c.a)) / 255.0;\n"
      + "  return (v - 0.5) * 0.5;\n"
      + "}\n"
      + "// Bilinear between the 4 nearest flow texels (the packed form can't be\n"
      + "// mixed by the graphics chip itself).\n"
      + "vec2 flowAt(sampler2D t, vec2 size, vec2 uv) {\n"
      + "  vec2 p = uv * size - 0.5;\n"
      + "  vec2 f = fract(p);\n"
      + "  vec2 b = (floor(p) + 0.5) / size;\n"
      + "  vec2 s = 1.0 / size;\n"
      + "  vec2 f00 = unpackAt(t, b);\n"
      + "  vec2 f10 = unpackAt(t, b + vec2(s.x, 0.0));\n"
      + "  vec2 f01 = unpackAt(t, b + vec2(0.0, s.y));\n"
      + "  vec2 f11 = unpackAt(t, b + s);\n"
      + "  return mix(mix(f00, f10, f.x), mix(f01, f11, f.x), f.y);\n"
      + "}\n"
      + "uniform sampler2D uTex;\n"
      + "uniform vec2 uTexel;\n"
      + "void main() {\n"
      + "  vec2 s = vec2(0.0);\n"
      + "  for (int j = -1; j <= 1; j++) {\n"
      + "    for (int i = -1; i <= 1; i++) {\n"
      + "      s += unpackAt(uTex, vUv + vec2(float(i), float(j)) * uTexel);\n"
      + "    }\n"
      + "  }\n"
      + "  gl_FragColor = pack(s / 9.0);\n"
      + "}\n";

  private static final String WARP =
      "#version 100\n"
      + "precision highp float;\n"
      + "varying vec2 vUv;\n"
      + "\n"
      + "vec4 pack(vec2 d) {\n"
      + "  vec2 v = clamp(d * 2.0 + 0.5, 0.0, 1.0) * 255.0;\n"
      + "  vec2 hi = floor(v);\n"
      + "  vec2 lo = v - hi;\n"
      + "  return vec4(hi.x / 255.0, lo.x, hi.y / 255.0, lo.y);\n"
      + "}\n"
      + "vec2 unpackAt(sampler2D t, vec2 uv) {\n"
      + "  vec4 c = texture2D(t, uv);\n"
      + "  vec2 v = (vec2(c.r, c.b) * 255.0 + vec2(c.g, c.a)) / 255.0;\n"
      + "  return (v - 0.5) * 0.5;\n"
      + "}\n"
      + "// Bilinear between the 4 nearest flow texels (the packed form can't be\n"
      + "// mixed by the graphics chip itself).\n"
      + "vec2 flowAt(sampler2D t, vec2 size, vec2 uv) {\n"
      + "  vec2 p = uv * size - 0.5;\n"
      + "  vec2 f = fract(p);\n"
      + "  vec2 b = (floor(p) + 0.5) / size;\n"
      + "  vec2 s = 1.0 / size;\n"
      + "  vec2 f00 = unpackAt(t, b);\n"
      + "  vec2 f10 = unpackAt(t, b + vec2(s.x, 0.0));\n"
      + "  vec2 f01 = unpackAt(t, b + vec2(0.0, s.y));\n"
      + "  vec2 f11 = unpackAt(t, b + s);\n"
      + "  return mix(mix(f00, f10, f.x), mix(f01, f11, f.x), f.y);\n"
      + "}\n"
      + "\n"
      + "float lum(vec3 c) {\n"
      + "  return pow(max(dot(c, vec3(0.2627, 0.678, 0.0593)), 0.0), 0.4);\n"
      + "}\n"
      + "uniform sampler2D uA;\n"
      + "uniform sampler2D uB;\n"
      + "uniform sampler2D uFlow;\n"
      + "uniform vec2 uFlowSize;\n"
      + "uniform float uAlpha;\n"
      + "void main() {\n"
      + "  vec2 d = flowAt(uFlow, uFlowSize, vUv);\n"
      + "  vec4 a = texture2D(uA, vUv - uAlpha * d);\n"
      + "  vec4 b = texture2D(uB, vUv + (1.0 - uAlpha) * d);\n"
      + "  float err = abs(lum(a.rgb) - lum(b.rgb));\n"
      + "  // Where the two disagree (something uncovered or hidden), fade to a\n"
      + "  // plain mix of the two frames rather than show a wrong guess.\n"
      + "  vec4 plain = mix(texture2D(uA, vUv), texture2D(uB, vUv), uAlpha);\n"
      + "  gl_FragColor = mix(mix(a, b, uAlpha), plain, smoothstep(0.06, 0.2, err));\n"
      + "}\n";

  /** The finest brightness copy is this many times smaller than the picture. */
  private static final int SCALE = 4;
  /** Coarser copies are halved until about this wide. */
  private static final int MIN_WIDTH = 80;
  private static final int MAX_LEVELS = 6;
  /** Rounds of smoothing (two passes each) at each level. */
  private static final int SMOOTHING = 2;

  private final int factor;
  private final boolean useHdr;
  private final TexturePool pool;
  private final GlProgram copy;
  private final GlProgram down;
  private final GlProgram half;
  private final GlProgram matchWide;
  private final GlProgram matchNear;
  private final GlProgram median;
  private final GlProgram avg;
  private final GlProgram warp;

  private InputListener inputListener = new InputListener() {};
  private OutputListener outputListener = new OutputListener() {};
  private ErrorListener errorListener = e -> {};
  private Executor errorExecutor = MoreExecutors.directExecutor();

  @Nullable private GlTextureInfo prev;
  /** Per level (0: finest): brightness of the previous and this frame,
   * and the movement estimate (raw and cleaned up). */
  private GlTextureInfo[] lowPrev = new GlTextureInfo[0];
  private GlTextureInfo[] lowCur = new GlTextureInfo[0];
  private GlTextureInfo[] flowRaw = new GlTextureInfo[0];
  private GlTextureInfo[] flow = new GlTextureInfo[0];
  private int levelsForWidth = -1;
  private int levelsForHeight = -1;
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
      half = program(HALF);
      matchWide = program(MATCH4);
      matchNear = program(MATCH2);
      median = program(MEDIAN);
      avg = program(AVG);
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

  private static void releaseAll(GlTextureInfo[] list) throws GlUtil.GlException {
    for (GlTextureInfo t : list) {
      if (t != null) t.release();
    }
  }

  /** The brightness copies and movement estimates for a w x h picture. */
  private void ensureLevels(GlObjectsProvider objects, int w, int h) throws GlUtil.GlException {
    if (w == levelsForWidth && h == levelsForHeight) return;
    releaseAll(lowPrev);
    releaseAll(lowCur);
    releaseAll(flowRaw);
    releaseAll(flow);
    int lw = Math.max(16, Math.round(w / (float) SCALE));
    int lh = Math.max(16, Math.round(h / (float) SCALE));
    java.util.ArrayList<int[]> sizes = new java.util.ArrayList<>();
    sizes.add(new int[] {lw, lh});
    while (lw > MIN_WIDTH && sizes.size() < MAX_LEVELS) {
      lw = Math.max(8, Math.round(lw / 2f));
      lh = Math.max(8, Math.round(lh / 2f));
      sizes.add(new int[] {lw, lh});
    }
    int n = sizes.size();
    lowPrev = new GlTextureInfo[n];
    lowCur = new GlTextureInfo[n];
    flowRaw = new GlTextureInfo[n];
    flow = new GlTextureInfo[n];
    for (int i = 0; i < n; i++) {
      int[] s = sizes.get(i);
      lowPrev[i] = owned(objects, null, s[0], s[1], false);
      lowCur[i] = owned(objects, null, s[0], s[1], false);
      flowRaw[i] = owned(objects, null, s[0], s[1], false);
      flow[i] = owned(objects, null, s[0], s[1], false);
    }
    levelsForWidth = w;
    levelsForHeight = h;
    havePrev = false;
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

  private static float[] texel(GlTextureInfo t) {
    return new float[] {1f / t.width, 1f / t.height};
  }

  /** This frame's brightness copies (finest first, then halved). */
  private void makeLevels(GlTextureInfo input) throws GlUtil.GlException {
    down.use();
    down.setSamplerTexIdUniform("uTex", input.texId, 0);
    down.setFloatsUniform("uTexel", new float[] {1f / input.width, 1f / input.height});
    down.setFloatUniform("uStep", input.width / (float) lowCur[0].width);
    draw(down, lowCur[0]);
    for (int i = 1; i < lowCur.length; i++) {
      half.use();
      half.setSamplerTexIdUniform("uTex", lowCur[i - 1].texId, 0);
      draw(half, lowCur[i]);
    }
  }

  /** How everything moved from the previous frame to this one, coarse to fine. */
  private void estimateMovement() throws GlUtil.GlException {
    for (int i = lowCur.length - 1; i >= 0; i--) {
      boolean coarsest = i == lowCur.length - 1;
      GlProgram m = coarsest ? matchWide : matchNear;
      GlTextureInfo guess = coarsest ? lowCur[i] : flow[i + 1];
      m.use();
      m.setSamplerTexIdUniform("uA", lowPrev[i].texId, 0);
      m.setSamplerTexIdUniform("uB", lowCur[i].texId, 1);
      m.setSamplerTexIdUniform("uGuess", guess.texId, 2);
      m.setFloatsUniform("uGuessSize", new float[] {guess.width, guess.height});
      m.setFloatUniform("uHasGuess", coarsest ? 0f : 1f);
      m.setFloatsUniform("uTexel", texel(lowCur[i]));
      draw(m, flowRaw[i]);
      median.use();
      median.setSamplerTexIdUniform("uTex", flowRaw[i].texId, 0);
      median.setFloatsUniform("uTexel", texel(flow[i]));
      draw(median, flow[i]);
      for (int k = 0; k < SMOOTHING; k++) {
        avg.use();
        avg.setSamplerTexIdUniform("uTex", flow[i].texId, 0);
        avg.setFloatsUniform("uTexel", texel(flow[i]));
        draw(avg, flowRaw[i]);
        avg.setSamplerTexIdUniform("uTex", flowRaw[i].texId, 0);
        draw(avg, flow[i]);
      }
    }
  }

  @Override
  public void queueInputFrame(
      GlObjectsProvider objects, GlTextureInfo input, long presentationTimeUs) {
    awaitingInput = false;
    try {
      int w = input.width;
      int h = input.height;
      pool.ensureConfigured(objects, w, h);
      prev = owned(objects, prev, w, h, useHdr);
      ensureLevels(objects, w, h);
      makeLevels(input);

      boolean consecutive =
          havePrev
              && presentationTimeUs > prevTimeUs
              && (lastDeltaUs == C.TIME_UNSET
                  || presentationTimeUs - prevTimeUs <= 3 * lastDeltaUs);
      if (consecutive && factor > 1) {
        estimateMovement();
        for (int k = 1; k < factor; k++) {
          float alpha = (float) k / factor;
          GlTextureInfo out = pool.useTexture();
          warp.use();
          warp.setSamplerTexIdUniform("uA", prev.texId, 0);
          warp.setSamplerTexIdUniform("uB", input.texId, 1);
          warp.setSamplerTexIdUniform("uFlow", flow[0].texId, 2);
          warp.setFloatsUniform("uFlowSize", new float[] {flow[0].width, flow[0].height});
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
      GlTextureInfo[] swap = lowPrev;
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
      if (prev != null) prev.release();
      releaseAll(lowPrev);
      releaseAll(lowCur);
      releaseAll(flowRaw);
      releaseAll(flow);
      for (GlProgram p : new GlProgram[] {copy, down, half, matchWide, matchNear, median, avg, warp}) {
        p.delete();
      }
    } catch (GlUtil.GlException e) {
      throw new VideoFrameProcessingException(e);
    }
  }
}

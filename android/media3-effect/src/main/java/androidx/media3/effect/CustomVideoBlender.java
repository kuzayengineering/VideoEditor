/*
 * Added for the Video Editor app (not part of Media3). Licensed under the
 * Apache License, Version 2.0, like the rest of this module.
 */
package androidx.media3.effect;

import androidx.media3.common.GlTextureInfo;
import androidx.media3.common.VideoCompositorSettings;
import androidx.media3.common.util.GlUtil;
import androidx.media3.common.util.UnstableApi;

/**
 * Draws how {@link DefaultVideoCompositor}'s inputs are blended into each output frame, in place
 * of the default layering. Used for transitions and picture in picture.
 */
@UnstableApi
public interface CustomVideoBlender {

  /**
   * Draws one frame. Called on the GL thread, with the output framebuffer bound, sized and
   * cleared.
   *
   * @param inputs The current frame of each input, by input index (an input without a frame gets
   *     the primary input's frame).
   * @param presentationTimeUs The frame's time from the start of the composition.
   * @param hdr Whether the pictures are HDR (high-precision textures).
   */
  void draw(
      GlTextureInfo[] inputs,
      long presentationTimeUs,
      int outputWidth,
      int outputHeight,
      boolean hdr)
      throws GlUtil.GlException;

  /** Frees GL objects. Called on the GL thread. */
  void release() throws GlUtil.GlException;

  /**
   * {@link VideoCompositorSettings} that make the compositor use a {@link CustomVideoBlender}.
   */
  interface Provider extends VideoCompositorSettings {

    /** Creates the blender. Called once, on the GL thread. */
    CustomVideoBlender createBlender();

    /** How many video inputs to wait for before blending the first frame. */
    int getInputCount();
  }
}

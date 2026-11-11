# Video Editor — Project Plan

A YouCut-style video editor for **Android and Windows** that keeps **4K, 60 fps,
HDR (HLG and HDR10)** video intact from import to export, and adds real
**audio editing**.

This document is written for the project owner (not a programmer). Technical
details for developers are collected at the end.

---

## 1. The big picture

Think of the app as three layers, like a building:

| Layer | What it is | What it does |
|---|---|---|
| **The screens** (Flutter) | Everything you see and tap: buttons, timeline, menus | Written once, runs on both Android and Windows, so the app looks and works the same everywhere |
| **The project file** | A small file describing your edit (which clips, where they're cut, effects, text, audio) | Your original videos are never changed. The edit is a "recipe" that gets applied when you preview or export |
| **The engine** (shared C++) | The part that decodes, mixes, applies effects to and re-encodes video and audio | Written once and used on both platforms, so a filter or reverb sounds and looks identical on phone and PC |

The engine uses each device's **dedicated video chip** for the heaviest work
(decoding and encoding). That's how 4K60 HDR stays fast on a phone.

- **Pixel 11 Pro:** Android's built-in hardware video encoder/decoder.
- **Your PC (i7-14700K):** Intel's built-in Quick Sync video engine can already
  encode 4K 10-bit HDR HEVC. *(This only works if the processor's built-in
  graphics are enabled. A "14700K" has them; a "14700KF" does not.)* When you
  add a graphics card later, any recent NVIDIA, AMD or Intel Arc card under
  $1,000 can do 4K60 HDR encoding, and the app will use whichever is fastest.

## 2. How HDR is kept intact

This is the main reason the app exists, so it's built in from day one rather
than added later.

- Inside the engine, every frame is processed in a **wide-color, high-brightness
  workspace** (BT.2020 colors, 16-bit precision). HDR clips are never squashed
  down to SDR during editing.
- Regular (SDR) clips can be mixed in with HDR clips. They're converted into the
  HDR workspace so they sit naturally next to HDR footage instead of looking dim.
- On export you choose:
  - **HDR – HLG** (what most phones record; plays well on phones, YouTube and
    TVs)
  - **HDR – HDR10** (common for TVs and streaming)
  - **SDR** (for older screens and sharing). HDR footage is "tone mapped" so
    highlights roll off smoothly instead of blowing out or looking grey.
- HDR exports are saved as **10-bit HEVC (H.265)** in a normal `.mp4` file.
  SDR exports can be H.264 for maximum compatibility, or HEVC.
- **Preview:** on the Pixel's HDR screen the goal is a true HDR preview. On
  Windows the first versions will show an accurate SDR preview, with HDR
  preview added later for HDR monitors. *Your export is HDR either way.* The
  preview is just a window into it.

## 3. Reliable background export (avoiding frozen frames)

Other apps glitch here because they render the export like playback: tied to
the clock and to the screen. If the app is minimized or the screen turns off,
they skip or repeat frames.

This app avoids that by design:

1. **Export never uses the clock.** Every frame is calculated from its exact
   timestamp ("frame 1,234 = 20.566 seconds") and handed to the encoder only
   when it's fully finished. If the phone gets slower, the export takes longer,
   but no frame is ever skipped or frozen.
2. **Export runs off-screen.** It doesn't draw to the display at all, so it
   doesn't care whether the app is open, minimized or the screen is off.
3. **On Android** the export runs as a *foreground service*, Android's official
   way to say "important work in progress." You'll see a progress notification
   and Android won't pause it.
4. **Self-check.** When an export finishes, the app checks the frame count and
   duration against what was expected and warns you if something is off. This
   should never happen, but if it does you'll know before you share the video.

## 4. Features and when they arrive

The work is split into **stages**. Each stage ends with an app you can install
and try. The order puts the hardest, riskiest part (HDR in → HDR out, reliable
export) first, so we know the foundation is solid before adding features.

### Stage 0 — Foundation *(this first delivery)*
- App skeleton for Android and Windows with the YouCut-style layout: home
  screen, preview area, timeline with the playhead in the center, scrollable
  tool bar along the bottom, and an export settings sheet.
- The editing "brain" behind the timeline: split, trim, copy, delete,
  **undo/redo**. You can try these on a demo project with colored placeholder
  clips. Real video arrives in Stage 1.
- Automatic builds and **automatic updates**: every change to the main branch
  publishes a GitHub Release. **Obtainium** on your phone picks it up as an
  update (setup steps in [UPDATES.md](UPDATES.md)).

### Stage 1 — Core video engine (the hard part) *(in testing)*

Status notes:
- **Android** uses Google's Media3 (ExoPlayer preview on a native HDR
  surface, Transformer export in a foreground service). HDR exports keep the
  clips' own HDR format (HLG for Pixel video). Mixing HDR and SDR clips in one
  HDR export comes in a later update.
- **Windows** uses FFmpeg for export (hardware encoders, measured HDR↔SDR
  conversions, exact frame counts) and mpv for preview (tone-mapped SDR
  preview; the export keeps full HDR). Mixing HDR and SDR clips works.

- Import videos from your phone/PC, with thumbnails on the timeline
- Smooth playback/preview, including 4K60 HDR
- Trim / split
- **Frame forward / frame back** buttons
- Export: resolution (up to 4K), frame rate (up to 60 fps), quality with
  **variable bit rate**, **HDR (HLG/HDR10) or SDR**
- **Choose the folder to save to**
- Reliable background export (section 3)
- Save and reopen projects (drafts)
- Windows app checks for new releases itself and offers a one-click update

### Stage 2 — Basic editing tools *(in testing)*

Status notes:
- **Windows:** everything below works, including reverse (a backwards copy
  is prepared in short pieces, so 4K needs little memory) and colored or
  blurred backgrounds.
- **Android:** rotate, mirror, crop, speed (sound keeps its pitch),
  opacity and reverse work. Reverse makes a backwards copy on the phone's
  video chip (HDR kept): frames are decoded in batches and handed to the
  encoder newest-first, falling back to a slower frame-by-frame method on
  phones that can't. It runs in the background while you keep editing. **Colored/blurred
  backgrounds** still need custom work and come in a later update.

- Rotate, mirror (flip), crop
- Aspect ratios: 16:9, 9:16, 1:1, 4:5, 4:3, 21:9 and custom, with a background
  fill (color or blur)
- Copy (duplicate) clip
- Video opacity
- Speed adjustment (normal speed changes; smoothing comes in Stage 7)
- Reverse playback

### Stage 3 — Audio, part 1 *(in testing)*

Status notes:
- Works on both Android and Windows: music/sound files and the sound of
  other videos on any number of audio tracks, drag to move, split/copy/
  delete, volume 0–200 %, fade in/out, "Extract audio" (puts a video's sound
  on its own track and mutes the video), voice-over recording, real
  waveforms on the timeline.
- The preview plays volumes up to 100 %; louder settings are heard in the
  export.

- Multiple audio tracks
- Insert audio from an audio file (MP3, WAV, M4A, FLAC, and so on)
- Insert audio taken from another video file
- Volume per clip, **fade in / fade out with custom durations**
- **Record a voice-over** in the app

### Stage 4 — Layers and text *(in testing)*

Status notes:
- **Text** works on both platforms: 10 bundled fonts, size, colour, bold,
  italic, shadow, alignment, outline, background box, drag/pinch/twist on
  the preview, and appear/disappear animations (fade, four slides, pop,
  typewriter). The app draws the text itself, so preview and export match;
  white text sits at HDR reference white in HDR exports. Dragging text
  snaps to the centre lines of the video.
- **Transitions** work on both platforms: 39 types in four groups (Basic,
  Slide, Wipe, Shape), including a true crossfade, with a length slider and
  "Use for all". The two clips overlap while it plays. On Android the app
  blends the two clips itself, in HDR, using a patched copy of Google's
  video library (android/media3-effect); the maths matches the Windows
  version exactly (checked against FFmpeg by a test).
- **Tool menus open below the video** (in place of the timeline), so the
  picture is never covered while you adjust things.
- **Picture in picture** works: videos on their own rows above the main
  video; drag, pinch and twist on the preview; see-through, crop, turn,
  mirror, speed and sound like any clip. On Android an HDR export needs
  the PiP clips to be HDR too (or export SDR), for now.
- **Settings**: optional neutral (gray) interface.
- **Text overlays** with fonts, colors and outlines, plus in/out **animations**
  (fade, slide, pop, typewriter, and so on)
- **Transitions** between clips (fade, dissolve, wipe, slide, zoom, and so on)

### Stage 5 — Filters *(in testing)*

Status notes:
- 16 ready-made looks (with strength) and Brightness, Contrast,
  Saturation, Warmth, Tint, Fade, Shadows, Highlights and HDR intensity, per clip (main and PiP), with "Use
  for all". One set of maths runs everywhere: Android applies it in a GPU
  effect (exact in the preview and the export), the Windows export through
  a lookup table (tested against the maths), and the Windows preview shows
  the closest live colour mix.

- **Filter effects** (looks/presets) plus basic adjustments (brightness,
  contrast, saturation, warmth). All of them are HDR-safe, so they don't clip
  your highlights.

### Stage 6 — Audio, part 2
- **Multi-band visual EQ**: drag points on a frequency curve and see the change
- **Reverb** and **delay/echo**
- **Pitch up / pitch down** for video audio, music or voice-overs, without
  changing speed
- **Noise reduction** with noise-type presets:
  - *Wind:* strong low-rumble cut plus smart noise removal tuned for gusts
  - *Road/traffic:* steady background hum removal
  - *Breathing:* targets breath sounds between words (the hardest of the
    three; results will vary)
  - *General:* a balanced default

### Stage 7 — Smart (AI) features
These run **on the device itself**, so there's no internet requirement and
your videos aren't uploaded anywhere.
- **Auto captions:** speech-to-text that creates editable text overlays timed
  to the words
- **Cutout person (remove background):** separates people from the background
  so you can replace or blur it
- **Slow-motion smoothing (frame interpolation):** creates in-between frames for
  smooth slow motion. This is heavy work, so it's done during export rather
  than live, and it will be noticeably slower on the phone than on the PC.

### Stage 8 — Polish
- Performance tuning, more transitions/filters/text styles, keyboard shortcuts
  on Windows, app icon and name, and (if you decide) preparing for the Google
  Play Store / Microsoft Store.

### Feature checklist

| Feature | Stage |
|---|---|
| Speed adjustment | 2 |
| Slow-motion smoothing (frame interpolation) | 7 |
| Transition effects | 4 |
| Filter effects | 5 |
| Common and custom aspect ratios | 2 |
| Picture in picture | 4 |
| Export resolution up to 4K | 1 |
| Export frame rate up to 60 fps | 1 |
| Export quality, variable bit rate | 1 |
| Export HDR or SDR | 1 |
| Trim / split | 0 (timeline), 1 (real video) |
| Text overlay with animations and transitions | 4 |
| Auto captions | 7 |
| Rotate | 2 |
| Mirror | 2 |
| Reverse playback | 2 |
| Crop | 2 |
| Cutout person (remove background) | 7 |
| Copy video | 0 (timeline), 2 |
| Video opacity | 2 |
| Frame forward / frame back | 1 |
| Choose save folder | 1 |
| Reliable background export | 1 |
| Insert audio from audio file | 3 |
| Insert audio from video file | 3 |
| Fade in / out, custom durations | 3 |
| Record voice-over | 3 |
| Pitch up / down | 6 |
| Noise reduction with noise types | 6 |
| Multi-band visual EQ | 6 |
| Reverb and delay | 6 |
| Multiple audio tracks | 3 |
| Undo / redo | 0 |

## 5. How you test each stage

1. When a stage (or a smaller update) is ready, GitHub automatically
   publishes a release with:
   - an **Android app file** (`.apk`). Obtainium offers it as an update.
   - a **Windows program** (`.zip`): unzip it and run `video_editor.exe`
2. You try it and tell me what feels wrong, confusing or missing. Screenshots
   or screen recordings help a lot.
3. I fix and adjust, and the next build appears automatically.

## 6. Open decisions

- **Personal use or app store?** Everything chosen so far keeps the store option
  open: no components whose licenses would force the app's code to be public,
  and video encoding through the hardware (which also avoids most H.265 patent
  licensing issues). This needs a firm answer before Stage 8.
- **App name and icon.** "Video Editor" is a placeholder.

---

## Technical notes (for developers)

**UI:** Flutter (Dart), targets `android` and `windows`. State lives in a pure
Dart project model (`lib/model/`) with an immutable timeline and an undo/redo
history. The UI never talks to codecs directly.

**Engine (Stage 1+):** a shared C++17 library (`engine/`) called from Dart via
`dart:ffi`. The project model is serialized to JSON and handed to the engine,
which builds its own render graph for preview and export.

- **Demux/mux:** FFmpeg (libavformat), built **LGPL-only** (no `--enable-gpl`,
  no x264/x265).
- **Decode/encode:**
  - Android: NDK `AMediaCodec` (HEVC Main10, `KEY_COLOR_TRANSFER` HLG/ST2084,
    BT.2020, HDR static metadata)
  - Windows: FFmpeg with D3D11VA decode, and `hevc_qsv` / `hevc_nvenc` /
    `hevc_amf` encode (Main10)
  - Software fallback for decode only
- **GPU compositing:** OpenGL ES 3.x. On Android via EGL, with `AHardwareBuffer`
  / external textures. On Windows via ANGLE (D3D11 backend), with D3D11 texture
  sharing. One shader codebase for both. The working space is linear-light
  BT.2020 in `RGBA16F`, with SDR reference white at 203 nits (BT.2408).
  Output transforms are HLG OETF, PQ (ST 2084) with static metadata, or SDR
  with BT.2390 EETF tone mapping and BT.709 gamut mapping.
- **Export determinism:** an offline render loop driven by the output frame
  index (PTS = n / fps), with no wall-clock pacing and back-pressure from the
  encoder input queue. On Android it runs in a `foregroundServiceType=
  "mediaProcessing"` service with its own off-screen EGL context and a partial
  wake lock. A post-export probe verifies frame count and duration.
- **Preview:** the same render graph, clocked by audio playback. On Android it
  targets a `SurfaceView` (platform view) with an HDR dataspace. On Windows it
  starts with an SDR tone-mapped Flutter texture, with an HDR swap chain later.
- **Audio:** shared C++ DSP at 48 kHz float. Mixer with per-clip gain envelopes
  (fades), biquad multi-band EQ, Freeverb-style reverb, delay, pitch via
  Signalsmith Stretch (MIT), and noise reduction via RNNoise (BSD) /
  DeepFilterNet (MIT/Apache) plus spectral gating with noise-type presets.
  Output via Oboe (Android) / WASAPI (Windows).
- **AI:**
  - Captions: whisper.cpp (MIT)
  - Segmentation: MediaPipe selfie/multiclass segmentation (Apache-2.0). Avoid
    GPL-licensed matting models.
  - Frame interpolation: RIFE (MIT) via ncnn-Vulkan (BSD)
- **Builds and releases:** GitHub Actions (`.github/workflows/build.yml`) runs
  analyze and tests, then builds the arm64 APK and the Windows release zip.
  On the default branch it publishes a GitHub Release (`v<major.minor>.<run
  number>`), signed with the release key from repository secrets, for
  Obtainium.

# Third-party parts

| Part | Where | Licence |
|---|---|---|
| whisper.cpp (auto captions) | `native/whisper.cpp` | MIT |
| Media3 effect library (patched copy) | `android/media3-effect` | Apache 2.0 |
| MediaPipe selfie segmenter model (person cutout) | `android/app/src/main/assets/selfie_segmenter.tflite` | Apache 2.0 (Google) |
| LiteRT (runs the cutout model) | Gradle dependency | Apache 2.0 |
| gl-transitions (94 transitions, picker strips drawn from them) | `GlTransitions.kt`, `assets/transitions` | MIT (each by its author named in the code) |
| MediaPipe selfie multiclass, face landmarker, pose landmarker models (Recolour, Eye colour, Outfit) | downloaded on first use | Apache 2.0 (Google) |
| MediaPipe Tasks Vision (runs the face and body models) | Gradle dependency | Apache 2.0 |

# whisper.cpp (vendored)

Speech recognition for auto captions. MIT licence (see LICENSE).

- Version: v1.9.5 (commit d1be6fde11ac6e0407606b4e42fe72d34add8037)
- Source: https://github.com/ggml-org/whisper.cpp
- Kept: the build files, `include/`, `src/` and `ggml/` with only the CPU
  backend (`ggml/src/ggml-cpu`). The GPU backends, examples, tests, bindings
  and sample files were left out. Nothing else was changed.

Built by `native/captions/CMakeLists.txt` (Android: Gradle's CMake; Windows:
`windows/CMakeLists.txt`).

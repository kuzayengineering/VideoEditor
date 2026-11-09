# Video Editor

A user-friendly, YouCut-style video editor for **Android and Windows** that
keeps **4K · 60 fps · HDR (HLG / HDR10)** video intact, with real audio
editing (multiple tracks, fades, EQ, reverb, delay, pitch, noise reduction,
voice-over).

- **Plan, stages and feature list:** [docs/PLAN.md](docs/PLAN.md)
- **Installing and automatic updates (Obtainium):** [docs/UPDATES.md](docs/UPDATES.md)

## Status

**Stage 0 (foundation).** The app layout, timeline editing (split, trim, copy,
delete, undo/redo, frame stepping), canvas shapes and export settings work on
a demo project with placeholder clips. Real video import, preview and export
arrive in Stage 1.

## For developers

- Flutter 3.47 (stable). `flutter test` runs the tests; `flutter run -d windows`
  or `-d <android device>` runs the app.
- `lib/model/`: the project model (pure Dart, immutable, fully unit-tested)
- `lib/ui/`: screens and widgets
- `.github/workflows/build.yml`: CI that tests, builds the APK and the Windows
  zip, and publishes releases from the default branch

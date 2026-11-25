#!/usr/bin/env python3
"""Builds the extra transitions from gl-transitions (MIT licence).

Usage: python3 tool/gen_gl_transitions.py <gl-transitions repo>/transitions

Writes:
  android/.../GlTransitions.kt   the shader of each (Android draws them)
  tool/glt_render/sources.json   the same, for the thumbnail renderer
and prints the Dart enum entries (pasted between the "gl-transitions"
markers in lib/model/clip.dart).

The list below is the curated choice. Append only: the numbers (100 + place
in the list) are saved in projects.
"""
import json
import os
import re
import sys

# (file, label, group, FFmpeg stand-in on Windows)
CHOSEN = [
    # Basic
    ("FadeGrayscale", "Fade to gray", "basic", "fade"),
    ("ColorPhase", "Color phase", "basic", "fade"),
    ("PerlinDissolve", "Soft dissolve", "basic", "dissolve"),
    ("Morph", "Morph", "basic", "fade"),
    ("DefocusBlur", "Blur", "basic", "fade"),
    ("CrossZoom", "Cross zoom", "basic", "zoomin"),
    ("SimpleZoomOut", "Zoom out", "basic", "fade"),
    ("ZoomInOut", "Zoom in-out", "basic", "zoomin"),
    ("Dreamy", "Dreamy", "basic", "fade"),
    # Slide
    ("WhipPan", "Whip pan", "slide", "slideleft"),
    ("DirectionalScaled", "Push zoom", "slide", "slideleft"),
    ("StretchSlide", "Stretch", "slide", "slideleft"),
    ("Bounce", "Bounce", "slide", "slidedown"),
    ("SplitSlideInOutHorizontal", "Split slide", "slide", "horzopen"),
    ("Comb", "Comb", "slide", "slideleft"),
    ("CardSwipe", "Card swipe", "slide", "slideleft"),
    ("ParallaxPush", "Parallax", "slide", "slideleft"),
    ("LensPush", "Lens push", "slide", "slideleft"),
    # Wipe
    ("WindowBlinds", "Blinds", "wipe", "fade"),
    ("SquaresWipe", "Squares", "wipe", "wipeleft"),
    ("BandWipe", "Bands", "wipe", "wipeleft"),
    ("CurvedWipe", "Curved", "wipe", "wipeleft"),
    ("BrushWipe", "Brush", "wipe", "wipeleft"),
    ("WedgeWipe", "Wedge", "wipe", "radial"),
    ("RandomSquares", "Random squares", "wipe", "dissolve"),
    ("WaveWipe", "Wave", "wipe", "wipeleft"),
    ("InkBleed", "Ink", "wipe", "fade"),
    ("SplatterWipe", "Splatter", "wipe", "fade"),
    ("SpiralBlockWipe", "Spiral blocks", "wipe", "wipeleft"),
    # Shape
    ("HeartWipe", "Heart", "shape", "circleopen"),
    ("StarWipe", "Star", "shape", "circleopen"),
    ("DiamondWipe", "Diamond", "shape", "circleopen"),
    ("KeyholeWipe", "Keyhole", "shape", "circleopen"),
    ("ApertureWipe", "Aperture", "shape", "circleopen"),
    ("PlusWipe", "Plus", "shape", "circleopen"),
    ("FlowerWipe", "Flower", "shape", "circleopen"),
    ("Pinwheel", "Pinwheel", "shape", "radial"),
    ("ArrowWipe", "Arrow", "shape", "wipeleft"),
    ("Hexagonalize", "Hexagons", "shape", "pixelize"),
    ("ZoomInCircles", "Circles", "shape", "circleopen"),
    ("PolkaDotsCurtain", "Polka dots", "shape", "dissolve"),
    # 3D
    ("Cube", "Cube", "threeD", "slideleft"),
    ("Doorway", "Doorway", "threeD", "vertopen"),
    ("BookFlip", "Page flip", "threeD", "slideleft"),
    ("Swap", "Swap", "threeD", "slideleft"),
    ("Tumble", "Tumble", "threeD", "fade"),
    ("Curtains", "Curtains", "threeD", "vertopen"),
    ("GridFlip", "Grid flip", "threeD", "fade"),
    ("Sphere", "Sphere", "threeD", "fade"),
    ("Accordion", "Accordion", "threeD", "slideleft"),
    ("Prisms", "Prisms", "threeD", "fade"),
    ("SimpleFlip", "Flip", "threeD", "fade"),
    ("FallOver", "Fall over", "threeD", "slidedown"),
    ("Gallery", "Gallery", "threeD", "slideleft"),
    # Light
    ("FilmBurn", "Film burn", "light", "fadewhite"),
    ("Overexposure", "Overexposure", "light", "fadewhite"),
    ("FlashFade", "Flash", "light", "fadewhite"),
    ("LensFlare", "Lens flare", "light", "fadewhite"),
    ("LightRays", "Light rays", "light", "fadewhite"),
    ("BloomDissolve", "Glow", "light", "fadewhite"),
    ("LightStreaks", "Light streaks", "light", "fadewhite"),
    ("LightWipe", "Light wipe", "light", "wipeleft"),
    ("BurnThrough", "Burn", "light", "fade"),
    ("FlameWipe", "Flame", "light", "wipeleft"),
    ("GlintDissolve", "Glints", "light", "fade"),
    ("BokehDissolve", "Bokeh", "light", "fade"),
    ("WarpSpeed", "Warp speed", "light", "zoomin"),
    # Warp
    ("Ripple", "Ripple", "warp", "fade"),
    ("WaterDrop", "Water drop", "warp", "fade"),
    ("Swirl", "Swirl", "warp", "fade"),
    ("Kaleidoscope", "Kaleidoscope", "warp", "fade"),
    ("FlyEye", "Fly eye", "warp", "fade"),
    ("Fisheye", "Fisheye", "warp", "fade"),
    ("CrossWarp", "Cross warp", "warp", "fade"),
    ("DirectionalWarp", "Warp wipe", "warp", "wipeleft"),
    ("ButterflyWaveScrawler", "Wavy", "warp", "fade"),
    ("Tunnel", "Tunnel", "warp", "zoomin"),
    ("Revolve", "Revolve", "warp", "fade"),
    ("GravityLens", "Black hole", "warp", "fade"),
    ("HeatHaze", "Heat haze", "warp", "fade"),
    ("DreamyZoom", "Dreamy zoom", "warp", "zoomin"),
    # Glitch
    ("GlitchMemories", "Glitch", "glitch", "fade"),
    ("GlitchDisplace", "Displace", "glitch", "fade"),
    ("GlitchFlicker", "Flicker", "glitch", "fade"),
    ("VhsTracking", "VHS", "glitch", "fade"),
    ("TvLostSignal", "Lost signal", "glitch", "fade"),
    ("TvStatic", "Static", "glitch", "fade"),
    ("TvTurnOff", "TV off", "glitch", "fadeblack"),
    ("StripDatamoshGlitch", "Datamosh", "glitch", "fade"),
    ("CameraShake", "Shake", "glitch", "fade"),
    ("Hologram", "Hologram", "glitch", "fade"),
    ("HorizontalHold", "Rolling", "glitch", "fade"),
    ("PixelStretch", "Pixel stretch", "glitch", "fade"),
    ("DoomMelt", "Melt", "glitch", "fade"),
    # Added later (append only: numbers are saved in projects)
    ("EyeBlink", "Eye blink", "basic", "fadeblack"),
]

FIRST_CODE = 100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KOTLIN = os.path.join(
    ROOT, "android/app/src/main/kotlin/com/kuzayengineering/video_editor/GlTransitions.kt")
JSON_OUT = os.path.join(ROOT, "tool/glt_render/sources.json")

UNIFORM = re.compile(
    r"^\s*uniform\s+(\w+)\s+(\w+)\s*(?:;\s*//\s*=\s*(.+?)\s*;?\s*$|/\*\s*=\s*(.+?)\s*\*/\s*;\s*$)")


def body_of(path):
    """The transition's code with its settings fixed at their defaults."""
    out = []
    for line in open(path, encoding="utf-8").read().splitlines():
        m = UNIFORM.match(line)
        if m:
            ty, name, v1, v2 = m.groups()
            value = (v1 or v2).rstrip(";").strip()
            if ty in ("float",) and re.fullmatch(r"-?\d+", value):
                value += ".0"
            out.append(f"const {ty} {name} = {value};")
        elif line.strip().startswith("uniform "):
            raise ValueError(f"{path}: setting without a default: {line}")
        else:
            out.append(line)
    return "\n".join(out) + "\n"


def lower_camel(s):
    return s[0].lower() + s[1:]


def main():
    src_dir = sys.argv[1]
    entries = []
    for i, (name, label, group, ff) in enumerate(CHOSEN):
        body = body_of(os.path.join(src_dir, name + ".glsl"))
        assert "$" not in body and '"""' not in body, name
        entries.append(dict(name=name, label=label, group=group, ffmpeg=ff,
                            code=FIRST_CODE + i, body=body))
    os.makedirs(os.path.dirname(JSON_OUT), exist_ok=True)
    json.dump(entries, open(JSON_OUT, "w"), indent=1)

    kt = [
        "// Generated by tool/gen_gl_transitions.py from gl-transitions",
        "// (https://github.com/gl-transitions/gl-transitions, MIT licence,",
        "// each by its author named in the code). Do not edit by hand.",
        "package com.kuzayengineering.video_editor",
        "",
        "object GlTransitions {",
        "    /** The transition code of each number (see TransitionKind). */",
        "    val sources: Map<Int, String> = mapOf(",
    ]
    for e in entries:
        kt.append(f'        {e["code"]} to """')
        kt.append(e["body"].rstrip("\n"))
        kt.append('""",')
    kt += ["    )", "}", ""]
    open(KOTLIN, "w").write("\n".join(kt))

    for e in entries:
        print(f"  gl{e['name']}('{e['label']}', '{e['ffmpeg']}', {e['code']}, "
              f"TransitionGroup.{e['group']}, gl: true),")


if __name__ == "__main__":
    main()

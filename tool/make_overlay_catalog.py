#!/usr/bin/env python3
"""Turns a folder of downloaded overlay videos into the app's effects list.

Usage: python3 tool/make_overlay_catalog.py <folder with videos> <output folder>

For each video (sorted into a kind by words in its file name, e.g.
"fire", "spark", "smoke", "light leak", "dust", "snow"):
  * a copy at most 1920 px wide and 15 s long, H.264 without sound, goes in
    <output folder> (these go on the "overlays" branch);
  * a small picture goes in assets/overlays/;
  * an entry goes in assets/overlays/catalog.json.
Effects filmed on white (dust, scratches, paper) get Multiply; the rest
Screen. Needs ffmpeg and ffprobe.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets/overlays")

# (words in the file name, kind)
KINDS = [
    (("fire", "flame", "burn", "ember"), "fire"),
    (("spark", "firework", "glitter", "sparkle"), "sparks"),
    (("smoke", "fog", "mist", "steam", "haze"), "smoke"),
    (("leak", "flare", "light", "glow", "sun"), "light"),
    (("bokeh",), "bokeh"),
    (("film", "grain", "dust", "scratch", "vintage", "old", "super8", "8mm"), "film"),
    (("snow", "rain", "storm", "lightning"), "weather"),
    (("particle", "confetti", "bubble", "star", "magic"), "particles"),
]
ON_WHITE = ("white", "dust", "scratch", "paper")
VIDEO = (".mp4", ".mov", ".m4v", ".webm", ".mkv")


def kind_of(name):
    n = name.lower()
    for words, kind in KINDS:
        if any(w in n for w in words):
            return kind
    return "other"


def title_of(stem):
    t = re.sub(r"[-_]+", " ", stem)
    t = re.sub(r"\b\d{5,}\b", "", t)  # long stock ID numbers
    t = re.sub(r"\b(\d{3,4}x\d{3,4}|uhd|hd|4k|\d+fps)\b", "", t, flags=re.I)
    t = re.sub(r"\s+", " ", t).strip()
    return (t[:1].upper() + t[1:]) if t else stem


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    os.makedirs(ASSETS, exist_ok=True)
    entries, counts = [], {}
    for name in sorted(os.listdir(src)):
        stem, ext = os.path.splitext(name)
        if ext.lower() not in VIDEO:
            continue
        kind = kind_of(name)
        counts[kind] = counts.get(kind, 0) + 1
        ident = f"{kind}-{counts[kind]:02d}"
        dest = os.path.join(out, ident + ".mp4")
        subprocess.run([
            "ffmpeg", "-v", "error", "-y", "-i", os.path.join(src, name),
            "-t", "15", "-an",
            "-vf", "scale='min(1920,iw)':-2,format=yuv420p",
            "-c:v", "libx264", "-preset", "slow", "-crf", "20",
            "-movflags", "+faststart", dest,
        ], check=True)
        thumb = os.path.join(ASSETS, ident + ".webp")
        subprocess.run([
            "ffmpeg", "-v", "error", "-y", "-ss", "2", "-i", dest,
            "-frames:v", "1", "-vf", "scale=240:-2", "-q:v", "70", thumb,
        ], check=True)
        data = open(dest, "rb").read()
        entries.append({
            "id": ident,
            "title": title_of(stem),
            "group": kind,
            "blend": "multiply" if any(w in name.lower() for w in ON_WHITE) else "screen",
            "file": ident + ".mp4",
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "thumb": f"assets/overlays/{ident}.webp",
            "from": name,
        })
        print(f"{ident:14} {entries[-1]['blend']:9} {len(data) / 1e6:6.1f} MB  {name}")
    json.dump(entries, open(os.path.join(ASSETS, "catalog.json"), "w"), indent=1)
    print(f"{len(entries)} effects")


if __name__ == "__main__":
    main()

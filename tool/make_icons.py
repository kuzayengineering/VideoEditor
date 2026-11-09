"""Builds every app icon from assets/branding/icon_concept.jpg.

Run from the project folder:  python3 tool/make_icons.py . preview.png
(needs Python with Pillow and NumPy)."""
import sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

repo = Path(sys.argv[1])
src = Image.open(repo / 'assets/branding/icon_concept.jpg').convert('RGB')
a = np.asarray(src).astype(np.float32)

# 1. The gold artwork, lifted off its dark background. Opacity follows how
#    much brighter than the background a pixel is, so edges stay smooth.
x0, y0, x1, y1 = 74, 238, 709, 902          # measured gold bounds
pad = 6
crop = a[y0 - pad:y1 + pad, x0 - pad:x1 + pad]
lum = crop.max(axis=2)
alpha = np.clip((lum - 18.0) / (150.0 - 18.0), 0, 1)
# Only gold counts (grey frame edges and shading are dropped).
warmth = crop[..., 0] - crop[..., 2]
alpha *= np.clip((warmth - 12.0) / 30.0, 0, 1)
rgb = crop.copy()
# Un-darken the anti-aliased edge pixels (they were mixed with black).
safe = np.maximum(alpha, 1e-3)[..., None]
rgb = np.clip(rgb / safe, 0, 255)
art = Image.fromarray(np.dstack([rgb, alpha * 255]).astype(np.uint8), 'RGBA')

BG = (13, 13, 13)

def fitted(canvas, fraction):
    """Art scaled so its larger side is `fraction` of the canvas, centred."""
    out = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
    scale = canvas * fraction / max(art.size)
    w, h = round(art.width * scale), round(art.height * scale)
    out.alpha_composite(art.resize((w, h), Image.LANCZOS),
                        ((canvas - w) // 2, (canvas - h) // 2))
    return out

def vignette(size):
    """Dark background, a touch lighter in the middle (like the concept)."""
    yy, xx = np.mgrid[0:size, 0:size] / (size - 1) - 0.5
    r = np.sqrt(xx ** 2 + yy ** 2) / 0.7071
    v = 16 - 11 * np.clip(r, 0, 1)
    img = np.dstack([v, v, v, np.full_like(v, 255)]).astype(np.uint8)
    return Image.fromarray(img, 'RGBA')

def rounded_icon(size):
    """The full icon: dark rounded square with a thin grey frame."""
    s = 4  # draw big, shrink for smooth edges
    big = size * s
    radius = int(big * 0.2)
    frame = max(2, int(big * 0.022))
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius, fill=255)
    out = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    frame_layer = Image.new('RGBA', (big, big), (30, 30, 30, 255))
    out.paste(frame_layer, (0, 0), mask)
    inner_mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(inner_mask).rounded_rectangle(
        [frame, frame, big - 1 - frame, big - 1 - frame], radius - frame, fill=255)
    out.paste(vignette(big), (0, 0), inner_mask)
    out.alpha_composite(fitted(big, 0.80))
    return out.resize((size, size), Image.LANCZOS)

master = rounded_icon(1024)
master.save(repo / 'assets/branding/app_icon_1024.png')
rounded_icon(512).save(repo / 'assets/branding/logo_512.png')

# 2. Android adaptive icon (Android 8+): background colour + foreground
#    layer. Launchers cut the icon to a circle or rounded shape, keeping only
#    the middle 72 of 108 units, so the art sits well inside.
res = repo / 'android/app/src/main/res'
dens = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
for name, f in dens.items():
    d = res / f'mipmap-{name}'
    d.mkdir(parents=True, exist_ok=True)
    fg = fitted(round(108 * f), 0.50)
    fg.save(d / 'ic_launcher_foreground.png')
    # Themed (single-colour) icon for Android 13+: white silhouette.
    mono = fg.copy()
    alpha_ch = mono.getchannel('A')
    white = Image.new('RGBA', mono.size, (255, 255, 255, 0))
    white.putalpha(alpha_ch)
    white.save(d / 'ic_launcher_monochrome.png')
    # Classic square icon for anything that doesn't use the adaptive one.
    rounded_icon(round(48 * f)).save(d / 'ic_launcher.png')

anydpi = res / 'mipmap-anydpi-v26'
anydpi.mkdir(exist_ok=True)
(anydpi / 'ic_launcher.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
''')
values = res / 'values'
(values / 'ic_launcher_background.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#0D0D0D</color>
</resources>
''')

# 3. Windows .ico with all the sizes Windows uses.
master.save(repo / 'windows/runner/resources/app_icon.ico',
            sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48),
                   (64, 64), (128, 128), (256, 256)])

# 4. Preview sheet for checking by eye.
sheet = Image.new('RGBA', (1180, 420), (40, 40, 40, 255))
sheet.alpha_composite(master.resize((360, 360), Image.LANCZOS), (20, 30))
circle = Image.new('L', (360, 360), 0)
ImageDraw.Draw(circle).ellipse([0, 0, 359, 359], fill=255)
adaptive = Image.new('RGBA', (360, 360), BG + (255,))
fg = fitted(round(360 * 108 / 72), 0.50)
off = (fg.width - 360) // 2
adaptive.alpha_composite(fg.crop((off, off, off + 360, off + 360)))
pix = Image.new('RGBA', (360, 360), (0, 0, 0, 0))
pix.paste(adaptive, (0, 0), circle)
sheet.alpha_composite(pix, (410, 30))
squircle = Image.new('L', (360, 360), 0)
ImageDraw.Draw(squircle).rounded_rectangle([0, 0, 359, 359], 90, fill=255)
sq = Image.new('RGBA', (360, 360), (0, 0, 0, 0))
sq.paste(adaptive, (0, 0), squircle)
sheet.alpha_composite(sq, (800, 30))
for i, s in enumerate([16, 32, 48]):
    small = master.resize((s, s), Image.LANCZOS)
    sheet.alpha_composite(small, (20 + i * 70, 395 - s))
sheet.save(sys.argv[2])
print('ok')

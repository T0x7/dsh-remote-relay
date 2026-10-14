#!/usr/bin/env python3
"""Cut every platform icon size out of the two rendered masters.

Inputs (checked in, rendered by render_masters.py + headless Chrome at 2x):
  master-2048.png              full-bleed artwork, opaque
  master-foreground-2048.png   glyph only, painted on black by the render page

Chrome is the rasteriser because this box has no rsvg/cairo/inkscape; its 2x
device pixel ratio is a gift here — every output below is a LANCZOS downscale
from a supersampled source rather than a downscale of a 1:1 raster.

Outputs:
  ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png   (15 files, RGB)
  android/app/src/main/res/mipmap-*/{ic_launcher,ic_launcher_round}.png
  android/app/src/main/res/mipmap-*/ic_launcher_foreground.png
  playstore-512.png

Run:  python3 generate_icons.py      (idempotent)
"""
import pathlib

from PIL import Image, ImageDraw

HERE = pathlib.Path(__file__).resolve().parent
APP = HERE.parent.parent
IOS = APP / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
RES = APP / "android/app/src/main/res"

# --- the black-key threshold -------------------------------------------------
# render-fg.html paints the page black, so every pixel is artwork over black and
# luminance stands in for coverage. The artwork has no black fills, so a low
# cut keys out the page and nothing else.
#
# Do NOT raise this to "clean up" the dim bars: their left ends composite to
# roughly luminance 21 (#2BB98A at stop-opacity 0.25 * rect opacity 0.55 over
# black), so anything at/above ~25 eats the streams' fade-out and leaves three
# stubs. 10 keeps the anti-aliased rim and the full fade.
KEY_LUMA = 10
# Artwork averages to this emerald; RGB under transparent pixels is set to it so
# PIL's LANCZOS downscale blends colour, not black, and leaves no dark halo.
FRINGE_RGB = (52, 211, 153)

# filename -> pixels
IOS_SIZES = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}

# Android density bucket -> (legacy px, adaptive foreground px). Both drawables
# sit on a 108dp canvas; the legacy PNGs are the pre-API-26 fallback.
DENSITIES = {"mdpi": (48, 108), "hdpi": (72, 162), "xhdpi": (96, 216),
             "xxhdpi": (144, 324), "xxxhdpi": (192, 432)}


def load_masters():
    full = Image.open(HERE / "master-2048.png").convert("RGB")
    fg = Image.open(HERE / "master-foreground-2048.png").convert("RGB")

    # Recover transparency from the black render page.
    rgba = fg.convert("RGBA")
    px = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            r, g, b, _ = px[x, y]
            if 0.2126 * r + 0.7152 * g + 0.0722 * b < KEY_LUMA:
                px[x, y] = (*FRINGE_RGB, 0)
    return full, rgba


def rounded_mask(size, circle=False):
    """Mask a legacy icon the way pre-26 launchers expect to receive it."""
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    if circle:
        d.ellipse((0, 0, size - 1, size - 1), fill=255)
    else:
        # ~22% matches the continuous-corner ratio iOS uses, so the legacy
        # Android icon and the masked iOS one read as the same shape.
        d.rounded_rectangle((0, 0, size - 1, size - 1), radius=round(size * 0.22), fill=255)
    return mask


def main():
    full, fg = load_masters()
    written = []

    for name, px in sorted(IOS_SIZES.items(), key=lambda kv: kv[1]):
        # iOS rejects an alpha channel, and the OS supplies its own mask, so
        # this stays a full-bleed square.
        out = full.resize((px, px), Image.LANCZOS).convert("RGB")
        out.save(IOS / name)
        written.append((f"ios/{name}", out.size, out.mode))

    for bucket, (legacy_px, fg_px) in sorted(DENSITIES.items()):
        d = RES / f"mipmap-{bucket}"
        base = full.resize((legacy_px, legacy_px), Image.LANCZOS)
        for variant in ("ic_launcher.png", "ic_launcher_round.png"):
            icon = base.convert("RGBA")
            icon.putalpha(rounded_mask(legacy_px, circle=variant.endswith("_round.png")))
            icon.save(d / variant)
            written.append((f"android/mipmap-{bucket}/{variant}", icon.size, icon.mode))
        layer = fg.resize((fg_px, fg_px), Image.LANCZOS)
        layer.save(d / "ic_launcher_foreground.png")
        written.append((f"android/mipmap-{bucket}/ic_launcher_foreground.png", layer.size, layer.mode))

    ps = full.resize((512, 512), Image.LANCZOS).convert("RGB")
    ps.save(HERE / "playstore-512.png")
    written.append(("playstore-512.png", ps.size, ps.mode))

    for path, size, mode in written:
        print(f"{size[0]:>4}x{size[1]:<4} {mode:<5} {path}")
    print(f"\n{len(written)} files written.")


if __name__ == "__main__":
    main()

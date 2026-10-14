#!/usr/bin/env python3
"""Wrap each icon SVG master in a bare 1024x1024 page for headless-Chrome capture.

Chrome is the rasteriser of record here (no rsvg/cairo/inkscape on this box).
Each page is exactly one SVG at exactly 1024px with zero page chrome, so a
viewport-sized screenshot lands on a clean 1024x1024 raster.

The foreground page paints the canvas BLACK on purpose: the artwork is
entirely emerald and contains no dark pixels, so generate_icons.py can key the
black out to recover real transparency without fringing.

    python3 render_masters.py   ->  render-master.html, render-fg.html
    (screenshot each at a 1024x1024 viewport)
"""
import pathlib

HERE = pathlib.Path(__file__).resolve().parent

PAGE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
  html,body {{ margin:0; padding:0; background:{bg}; }}
  svg {{ display:block; width:1024px; height:1024px; }}
</style></head>
<body>
{svg}
</body></html>
"""


def page(svg_name: str, bg: str, out: str) -> None:
    svg = (HERE / svg_name).read_text()
    # Drop the XML prolog if any; inline SVG inside HTML tolerates it, but the
    # capture is easier to reason about when the file starts at <svg>.
    (HERE / out).write_text(PAGE.format(bg=bg, svg=svg))
    print(f"wrote {HERE / out}")


page("app-icon.svg", "#FFFFFF", "render-master.html")
page("app-icon-foreground.svg", "#000000", "render-fg.html")

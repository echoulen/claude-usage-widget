#!/usr/bin/env python3
"""Generate the ClaudeUsage app icon.

Draws a gauge-style icon at 4x resolution (4096x4096) for clean
antialiasing, downsamples it to the 1024x1024 master, then produces every
derived size macOS's AppIcon.appiconset requires.

Usage:
    python3 Tools/make-icon.py
"""

from __future__ import annotations

import math
import os

from PIL import Image, ImageDraw

# ---------------------------------------------------------------------------
# Design constants (all in "1x" 1024x1024 space; SCALE blows them up for
# antialiased drawing, then we downsample back down).
# ---------------------------------------------------------------------------

SCALE = 4
CANVAS = 1024 * SCALE

SQUIRCLE_SIZE = 824 * SCALE
SQUIRCLE_INSET = (CANVAS - SQUIRCLE_SIZE) // 2  # 100px at 1x on every side
SQUIRCLE_RADIUS = 185 * SCALE

BG_TOP = (0x2B, 0x2A, 0x27, 255)
BG_BOTTOM = (0x1A, 0x19, 0x17, 255)

ARC_RADIUS = 230 * SCALE
ARC_STROKE = 96 * SCALE
TRACK_COLOR = (0x3D, 0x3B, 0x37, 255)
VALUE_COLOR = (0xD9, 0x77, 0x57, 255)

# PIL's ImageDraw.arc(box, ..., width=W) does NOT center the stroke on the
# circle described by `box` - it draws the band entirely *inside* that
# circle, from radius (R - W) to radius R. (Verified empirically: a test
# arc with R=300, W=80 painted pixels from radius 220 to radius 300, not
# 260 to 340.) So the band's true centerline sits at (R - W/2), not R.
# Round caps must be centered there too, or they overshoot the outer edge
# and undershoot the inner edge by W/2 each - producing a "ball on a
# stick" bulge instead of a flush cap.
ARC_BAND_CENTERLINE = ARC_RADIUS - ARC_STROKE / 2

# PIL measures angles clockwise from the 3 o'clock position (its y axis
# already points down, so "clockwise" here also reads as clockwise on
# screen). start=135 -> sweep 270 clockwise -> end=405 (=45) leaves a 90
# degree gap centered on the bottom (90 deg), i.e. the classic gauge
# opening at the bottom.
ARC_START = 135.0
ARC_SWEEP = 270.0
ARC_END = ARC_START + ARC_SWEEP

VALUE_FRACTION = 0.62
VALUE_END = ARC_START + ARC_SWEEP * VALUE_FRACTION

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPICONSET_DIR = os.path.join(
    REPO_ROOT,
    "Sources/ClaudeUsageApp/Assets.xcassets/AppIcon.appiconset",
)
# The master render is a build artifact, not part of the asset catalog -
# keep it out of AppIcon.appiconset so Contents.json stays exactly in sync
# with what's on disk. `build/` is already git-ignored.
MASTER_PATH = os.path.join(REPO_ROOT, "build", "icon-1024.png")

# (filename, point size, scale) -> pixel size is point_size * scale
ICON_SPECS = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2),
]


def make_vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    """Return an RGBA image of size x size with a top-to-bottom gradient."""
    gradient = Image.new("RGBA", (1, size), color=0)
    for y in range(size):
        t = y / (size - 1)
        r = round(top[0] + (bottom[0] - top[0]) * t)
        g = round(top[1] + (bottom[1] - top[1]) * t)
        b = round(top[2] + (bottom[2] - top[2]) * t)
        gradient.putpixel((0, y), (r, g, b, 255))
    return gradient.resize((size, size), Image.NEAREST)


def draw_master() -> Image.Image:
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    # --- background squircle, vertical gradient fill ---
    squircle_mask = Image.new("L", (CANVAS, CANVAS), 0)
    mask_draw = ImageDraw.Draw(squircle_mask)
    box = [
        SQUIRCLE_INSET,
        SQUIRCLE_INSET,
        SQUIRCLE_INSET + SQUIRCLE_SIZE,
        SQUIRCLE_INSET + SQUIRCLE_SIZE,
    ]
    mask_draw.rounded_rectangle(box, radius=SQUIRCLE_RADIUS, fill=255)

    gradient = make_vertical_gradient(CANVAS, BG_TOP, BG_BOTTOM)
    canvas.paste(gradient, (0, 0), squircle_mask)

    # --- gauge arcs, centered in the squircle ---
    center = CANVAS / 2
    arc_box = [
        center - ARC_RADIUS,
        center - ARC_RADIUS,
        center + ARC_RADIUS,
        center + ARC_RADIUS,
    ]

    draw = ImageDraw.Draw(canvas)
    draw.arc(arc_box, ARC_START, ARC_END, fill=TRACK_COLOR, width=ARC_STROKE)
    draw.arc(arc_box, ARC_START, VALUE_END, fill=VALUE_COLOR, width=ARC_STROKE)

    # ImageDraw.arc does not support round caps directly; emulate them by
    # stamping filled circles at each arc's endpoints, centered on the
    # band's true centerline (see ARC_BAND_CENTERLINE comment above) so the
    # cap is flush with the stroke rather than bulging past its outer edge.
    def cap(angle_deg: float, color: tuple) -> None:
        rad = math.radians(angle_deg)
        x = center + ARC_BAND_CENTERLINE * math.cos(rad)
        y = center + ARC_BAND_CENTERLINE * math.sin(rad)
        r = ARC_STROKE / 2
        draw.ellipse([x - r, y - r, x + r, y + r], fill=color)

    cap(ARC_START, TRACK_COLOR)
    cap(ARC_END, TRACK_COLOR)
    cap(ARC_START, VALUE_COLOR)
    cap(VALUE_END, VALUE_COLOR)

    # Downsample for clean antialiased edges.
    master = canvas.resize((1024, 1024), Image.LANCZOS)
    return master


def main() -> None:
    os.makedirs(APPICONSET_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(MASTER_PATH), exist_ok=True)

    master = draw_master()
    master.save(MASTER_PATH)
    print(f"wrote {MASTER_PATH} ({master.size[0]}x{master.size[1]})")

    for filename, point_size, scale in ICON_SPECS:
        px = point_size * scale
        resized = master.resize((px, px), Image.LANCZOS)
        out_path = os.path.join(APPICONSET_DIR, filename)
        resized.save(out_path)
        print(f"wrote {out_path} ({px}x{px})")


if __name__ == "__main__":
    main()

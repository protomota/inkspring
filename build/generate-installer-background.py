"""Render the Inkspring Finder background at 1x and 2x. Requires Pillow."""

import argparse
import math
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/SFNS.ttf"
INK = "#24251f"
SECONDARY = "#63584a"
BORDER = "#c9bca9"
ACCENT = "#a6482d"


def draw_arrow(canvas: Image.Image, scale: int) -> None:
    # Finder can use the 1x TIFF page. Render the arrow at 4x before downsampling
    # either page so the diagonals and their joins have smooth edge coverage.
    left, top, width, height = 315, 210, 89, 40
    resolution = 4 * scale
    mask = Image.new("L", (width * resolution, height * resolution))
    draw = ImageDraw.Draw(mask)
    radius = 1.5 * resolution
    for path in ([(321, 230), (397, 230)], [(382, 215), (397, 230), (382, 245)]):
        points = [((x - left) * resolution, (y - top) * resolution) for x, y in path]
        draw.line(points, fill=255, width=3 * resolution)
        for x, y in points:
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=255)
    coverage = mask.resize((width * scale, height * scale), Image.Resampling.LANCZOS)
    canvas.paste(ACCENT, (left * scale, top * scale), coverage)


def render(scale: int, target: Path) -> None:
    width, height = 720 * scale, 460 * scale
    canvas = Image.new("RGB", (width, height))
    base, glow = (236, 228, 215), (251, 248, 241)
    canvas.putdata([
        tuple(round(start + (end - start) * amount) for start, end in zip(base, glow))
        for y in range(height)
        for x in range(width)
        for amount in [math.exp(-(((x / scale - 360) / 410) ** 2
                                  + ((y / scale - 230) / 300) ** 2))]
    ])
    draw = ImageDraw.Draw(canvas)

    def points(*values: float) -> tuple[int, ...]:
        return tuple(round(value * scale) for value in values)

    def text(value: str, y: int, size: int, color: str, bold: bool = False) -> None:
        font = ImageFont.truetype(FONT, size * scale)
        font.set_variation_by_name("Bold" if bold else "Regular")
        draw.text(points(360, y), value, font=font, fill=color, anchor="mt")

    draw.rounded_rectangle(points(18, 18, 702, 442), radius=22 * scale, outline=BORDER, width=scale)
    text("Install Inkspring", 48, 30, INK, bold=True)
    text("Drag Inkspring to Applications to get started.", 95, 16, SECONDARY)
    for left in (109, 439):
        draw.rounded_rectangle(points(left, 154, left + 172, 320), radius=22 * scale, fill="#fdfaf5")

    # Finder overlays the real movable app and Applications shortcut.
    left, top, right, bottom, radius = 102, 147, 288, 327, 29
    dots = []
    for start, end, fixed, horizontal in (
        (left + radius, right - radius, top, True),
        (left + radius, right - radius, bottom, True),
        (top + radius, bottom - radius, left, False),
        (top + radius, bottom - radius, right, False),
    ):
        count = round((end - start) / 9)
        for index in range(count + 1):
            value = start + (end - start) * index / count
            dots.append((value, fixed) if horizontal else (fixed, value))
    for cx, cy, start in ((left + radius, top + radius, 180),
                          (right - radius, top + radius, 270),
                          (right - radius, bottom - radius, 0),
                          (left + radius, bottom - radius, 90)):
        for angle in range(start + 15, start + 90, 20):
            dots.append((cx + radius * math.cos(math.radians(angle)),
                         cy + radius * math.sin(math.radians(angle))))
    for x, y in dots:
        draw.ellipse(points(x - 1.15, y - 1.15, x + 1.15, y + 1.15), fill="#b75635")

    draw_arrow(canvas, scale)
    draw.line(points(88, 355, 632, 355), fill=BORDER, width=scale)
    text("Eject the disk image when copying is complete.", 378, 15, INK)
    text("Open Inkspring from your Applications folder.", 410, 14, SECONDARY)
    canvas.save(target, dpi=(72 * scale, 72 * scale))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_directory", type=Path)
    output = parser.parse_args().output_directory
    output.mkdir(parents=True, exist_ok=True)
    standard, retina = output / "background.png", output / "background@2x.png"
    render(1, standard)
    render(2, retina)
    subprocess.run(["tiffutil", "-cathidpicheck", str(standard), str(retina),
                    "-out", str(output / "installer-background.tiff")], check=True)


if __name__ == "__main__":
    main()

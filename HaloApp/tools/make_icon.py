"""Draws Halo's app icon: one ring, 80% filled in near-white, the rest in the quiet track grey,
with the accent dot at the tip. Same stroke (54 px at 1024) as the old icon's outer ring.

    python3 tools/make_icon.py   # writes Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4                      # draw large, then shrink, for smooth edges
RADIUS = 299.5                 # centre of the stroke
STROKE = 54
FILL = 0.80                    # share of the ring drawn in white
INK = (242, 242, 237)          # near-white
TRACK = (51, 51, 54)           # the minimal grey of the empty part
ACCENT = (255, 97, 41)
CENTER = (24, 25, 28)          # background, lightest near the middle
CORNER = (11, 11, 14)          # darkest at the bottom-right corner


def background(size):
    img = Image.new("RGB", (size, size))
    px = img.load()
    cx, cy = size * 0.42, size * 0.40
    far = math.hypot(size - cx, size - cy)
    for y in range(size):
        for x in range(size):
            t = min(1.0, math.hypot(x - cx, y - cy) / far) ** 1.4
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(CENTER, CORNER))
    return img


def main():
    s = SIZE * SCALE
    img = background(SIZE).resize((s, s), Image.BICUBIC)
    d = ImageDraw.Draw(img)
    c, r, w = s / 2, RADIUS * SCALE, STROKE * SCALE
    box = [c - r - w / 2, c - r - w / 2, c + r + w / 2, c + r + w / 2]

    def point(fraction):
        a = math.radians(-90 + 360 * fraction)
        return c + r * math.cos(a), c + r * math.sin(a)

    def cap(fraction, colour, diameter):
        x, y = point(fraction)
        d.ellipse([x - diameter / 2, y - diameter / 2, x + diameter / 2, y + diameter / 2], fill=colour)

    # The empty part first, then the filled part over it, starting at twelve o'clock.
    d.arc(box, start=-90 + 360 * FILL, end=270, fill=TRACK, width=round(w))
    d.arc(box, start=-90, end=-90 + 360 * FILL, fill=INK, width=round(w))
    cap(0, INK, w)
    cap(FILL, INK, w)
    cap(FILL, ACCENT, w * 0.56)

    out = Path(__file__).resolve().parent.parent / "Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    img.resize((SIZE, SIZE), Image.LANCZOS).save(out, optimize=True)
    print("wrote", out)


if __name__ == "__main__":
    main()

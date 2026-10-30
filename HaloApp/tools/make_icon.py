"""Draws Halo's app icon: one ring, 80% filled in near-white, the rest in the quiet track grey,
with the accent dot at the tip. Stroke 108 px at 1024: twice the old icon's outer ring.

    python3 tools/make_icon.py   # writes AppIcon, the color sets' icons (AppIcon-Ocean …) and their previews
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4                      # draw large, then shrink, for smooth edges
RADIUS = 299.5                 # centre of the stroke
STROKE = 108                   # twice the old icon's outer ring
FILL = 0.80                    # share of the ring drawn in white
INK = (242, 242, 237)          # near-white
TRACK = (51, 51, 54)           # the minimal grey of the empty part
ACCENT = (255, 97, 41)
CENTER = (24, 25, 28)          # background, lightest near the middle
CORNER = (11, 11, 14)          # darkest at the bottom-right corner


def background(size, center=CENTER, corner=CORNER):
    img = Image.new("RGB", (size, size))
    px = img.load()
    cx, cy = size * 0.42, size * 0.40
    far = math.hypot(size - cx, size - cy)
    for y in range(size):
        for x in range(size):
            t = min(1.0, math.hypot(x - cx, y - cy) / far) ** 1.4
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(center, corner))
    return img


def draw(ink=INK, track=TRACK, accent=ACCENT, center=CENTER, corner=CORNER):
    s = SIZE * SCALE
    img = background(SIZE, center, corner).resize((s, s), Image.BICUBIC)
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
    d.arc(box, start=-90 + 360 * FILL, end=270, fill=track, width=round(w))
    d.arc(box, start=-90, end=-90 + 360 * FILL, fill=ink, width=round(w))
    cap(0, ink, w)
    cap(FILL, ink, w)
    cap(FILL, accent, w * 0.56)
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def hexrgb(h):
    return ((h >> 16) & 255, (h >> 8) & 255, h & 255)


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


# The color sets' icons, chosen in Settings (Halo Plus): ink, background and accent from each
# set's dark colors; Light is the Original set on its light background.
LOOKS = {
    "Ocean": (0xE4EEF7, 0x07111C, 0x1FC8B4),
    "Forest": (0xE5EFE6, 0x08100B, 0xE8B04A),
    "Mono": (0xFFFFFF, 0x000000, 0xE5484D),
    "Dusk": (0xECE9F6, 0x0D0B14, 0xFF8A65),
    "Sand": (0xF3ECE4, 0x120E0B, 0x3D8BFD),
    "Light": (0x121214, 0xF4F4F1, 0xFF6129),
}


def look(ink, bg, accent):
    ink, bg, accent = hexrgb(ink), hexrgb(bg), hexrgb(accent)
    light = sum(bg) > 384
    center = mix(bg, (255, 255, 255), 0.06) if not light else mix(bg, (255, 255, 255), 0.6)
    corner = mix(bg, (0, 0, 0), 0.35) if not light else mix(bg, (0, 0, 0), 0.06)
    track = mix(center, ink, 0.16)
    return draw(ink, track, accent, center, corner)


ASSETS = Path(__file__).resolve().parent.parent / "Sources/Assets.xcassets"


def write_icon(name, img):
    folder = ASSETS / f"{name}.appiconset"
    folder.mkdir(exist_ok=True)
    img.save(folder / "icon-1024.png", optimize=True)
    (folder / "Contents.json").write_text(
        '{\n  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],\n'
        '  "info" : { "author" : "xcode", "version" : 1 }\n}\n')


def write_preview(name, img):
    folder = ASSETS / f"IconPreview-{name}.imageset"
    folder.mkdir(exist_ok=True)
    img.resize((180, 180), Image.LANCZOS).save(folder / "preview.png", optimize=True)
    (folder / "Contents.json").write_text(
        '{\n  "images" : [ { "filename" : "preview.png", "idiom" : "universal" } ],\n'
        '  "info" : { "author" : "xcode", "version" : 1 }\n}\n')


def main():
    original = draw()
    write_icon("AppIcon", original)
    write_preview("Original", original)
    for name, colors in LOOKS.items():
        img = look(*colors)
        write_icon(f"AppIcon-{name}", img)
        write_preview(name, img)
        print("wrote", name)


if __name__ == "__main__":
    main()

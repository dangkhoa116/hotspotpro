# Generates the package icon: a usage ring wrapped around a broadcast glyph.
#
# The first attempt put small bars under Wi-Fi arcs; at 120px the bars read as
# noise and the arcs read as any Wi-Fi tweak. A ring gauge is legible at icon
# size, says "meter" immediately, and the gap it leaves in the middle is the
# right place for the hotspot glyph.
#
# Drawn at 6x and downsampled: this PIL predates arc(width=), so every thick
# stroke is a stack of 1px arcs, and supersampling is what keeps their edges
# from looking ragged.
#
#   python make-icon.py

import math
from PIL import Image, ImageDraw

SIZE = 120
SS = 6
S = SIZE * SS

BG_TOP = (56, 214, 158)
BG_BOTTOM = (12, 132, 106)
FG = (255, 255, 255)
TRACK = (255, 255, 255, 70)      # the unfilled part of the ring

img = Image.new("RGB", (S, S), BG_TOP)
draw = ImageDraw.Draw(img)

for y in range(S):
    t = y / float(S - 1)
    draw.line([(0, y), (S, y)],
              fill=tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t)
                         for i in range(3)))

cx = cy = S // 2


def thick_arc(radius, thickness, start, end, colour, layer):
    """A stroked arc, built from concentric hairlines."""
    for r in range(radius - thickness // 2, radius + thickness // 2 + 1):
        layer.arc([cx - r, cy - r, cx + r, cy + r], start=start, end=end, fill=colour)


def round_cap(radius, thickness, angle, colour, layer):
    """Circle at an arc end, so the stroke reads as rounded rather than sheared."""
    ax = cx + radius * math.cos(math.radians(angle))
    ay = cy + radius * math.sin(math.radians(angle))
    rr = thickness // 2
    layer.ellipse([ax - rr, ay - rr, ax + rr, ay + rr], fill=colour)


# --- the ring -------------------------------------------------------------
# Opens at the bottom like a gauge, and stops short of full so it reads as a
# measurement in progress rather than a closed circle.
ring_r = int(S * 0.355)
ring_w = int(S * 0.085)
START, SWEEP_END = 135, 405          # 270 degrees of track
FILLED_END = START + int((SWEEP_END - START) * 0.72)

overlay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
odraw = ImageDraw.Draw(overlay)
thick_arc(ring_r, ring_w, START, SWEEP_END, TRACK, odraw)
round_cap(ring_r, ring_w, START, TRACK, odraw)
round_cap(ring_r, ring_w, SWEEP_END, TRACK, odraw)
img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
draw = ImageDraw.Draw(img)

thick_arc(ring_r, ring_w, START, FILLED_END, FG, draw)
round_cap(ring_r, ring_w, START, FG, draw)
round_cap(ring_r, ring_w, FILLED_END, FG, draw)

# --- the broadcast glyph inside -------------------------------------------
origin_y = int(S * 0.60)
for index, ratio in enumerate((0.105, 0.185)):
    r = int(S * ratio)
    w = int(S * (0.050 - index * 0.010))
    for rr in range(r - w // 2, r + w // 2 + 1):
        draw.arc([cx - rr, origin_y - rr, cx + rr, origin_y + rr],
                 start=216, end=324, fill=FG)

dot = int(S * 0.042)
draw.ellipse([cx - dot, origin_y - dot, cx + dot, origin_y + dot], fill=FG)

img = img.resize((SIZE, SIZE), Image.LANCZOS)

# Written next to the script's project root rather than to the current
# directory, so running this from anywhere still updates the real icons that
# repo-build.sh copies into the repo.
import os
ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")
os.makedirs(ASSETS, exist_ok=True)

big = os.path.join(ASSETS, "icon.png")
small = os.path.join(ASSETS, "icon@60.png")
img.save(big)
img.resize((60, 60), Image.LANCZOS).save(small)

print("wrote %s (120x120) and %s (60x60)" % (big, small))

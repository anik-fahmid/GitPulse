#!/usr/bin/env python3
from PIL import Image, ImageDraw
import os, math

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Rounded-rect gradient background (indigo -> violet, diagonal)
c1 = (79, 70, 229)    # indigo-600
c2 = (139, 92, 246)   # violet-500
grad = Image.new("RGB", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    for_x_step = 64
    pass
# faster: vertical-ish diagonal gradient by row blend
for y in range(S):
    t = y / (S - 1)
    r = int(c1[0] + (c2[0]-c1[0]) * t)
    g = int(c1[1] + (c2[1]-c1[1]) * t)
    b = int(c1[2] + (c2[2]-c1[2]) * t)
    gd.line([(0, y), (S, y)], fill=(r, g, b))

# rounded mask (macOS superellipse-ish via rounded rect with margin)
margin = int(S * 0.085)
radius = int(S * 0.225)
mask = Image.new("L", (S, S), 0)
md = ImageDraw.Draw(mask)
md.rounded_rectangle([margin, margin, S - margin, S - margin], radius=radius, fill=255)
img.paste(grad, (0, 0), mask)
d = ImageDraw.Draw(img)

# Bell glyph (white), centered
cx = S / 2
# bell body: a dome + flare
top = S * 0.30
bottom = S * 0.66
width_top = S * 0.10
width_bot = S * 0.30
white = (255, 255, 255, 255)

# dome (top circle)
d.ellipse([cx - width_top, top - width_top, cx + width_top, top + width_top], fill=white)
# body polygon (trapezoid sides curving out)
pts = []
steps = 30
for i in range(steps + 1):
    t = i / steps
    y = top + (bottom - top) * t
    w = width_top + (width_bot - width_top) * (t ** 1.4)
    pts.append((cx - w, y))
right = []
for i in range(steps + 1):
    t = i / steps
    y = top + (bottom - top) * t
    w = width_top + (width_bot - width_top) * (t ** 1.4)
    right.append((cx + w, y))
poly = pts + list(reversed(right))
d.polygon(poly, fill=white)
# bottom rim (rounded bar)
rim_y = bottom
d.rounded_rectangle([cx - width_bot, rim_y - S*0.025, cx + width_bot, rim_y + S*0.025],
                    radius=S*0.025, fill=white)
# clapper
d.ellipse([cx - S*0.045, bottom + S*0.03, cx + S*0.045, bottom + S*0.12], fill=white)
# top nub
d.ellipse([cx - S*0.03, top - width_top - S*0.05, cx + S*0.03, top - width_top + S*0.01], fill=white)

# Notification badge (red dot, top-right of bell)
bx, by, br = cx + width_bot*0.75, top - S*0.02, S*0.085
d.ellipse([bx - br, by - br, bx + br, by + br], fill=(239, 68, 68, 255))
d.ellipse([bx - br, by - br, bx + br, by + br], outline=(255,255,255,255), width=int(S*0.012))

out = os.path.expanduser("~/build/GitPulse/icon_1024.png")
img.save(out)
print("wrote", out)

import math
from PIL import Image, ImageDraw

S = 4096  # draw large, downsample for smooth edges
img = Image.new("RGB", (S, S), (255, 205, 220))
d = ImageDraw.Draw(img)

for y in range(S):
    t = y / S
    c = (int(255 - 25 * t), int(205 - 15 * t), int(220 + 10 * t))
    d.line([(0, y), (S, y)], fill=c)

brown = (166, 108, 72)
dark = (92, 58, 40)
cream = (246, 222, 190)
pink = (255, 150, 170)

def circle(cx, cy, r, fill):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=fill)

cx, cy = S // 2, S // 2

circle(cx, cy, 1650, brown)

for sx in (-1, 1):
    circle(cx + sx * 900, cy + 330, 260, pink)

for sx in (-1, 1):
    ex = cx + sx * 620
    circle(ex, cy - 150, 190, dark)
    circle(ex + 55, cy - 210, 60, (255, 255, 255))
    # arched eyebrows, raised above the eyes (round-brush polyline along an arc)
    acx, acy, ar = ex, cy - 150, 420
    for i in range(61):
        rad = math.radians(238 + i * (302 - 238) / 60)
        circle(int(acx + ar * math.cos(rad)), int(acy + ar * math.sin(rad)), 36, dark)

d.ellipse([cx - 620, cy + 40, cx + 620, cy + 800], fill=cream)

d.ellipse([cx - 190, cy + 130, cx + 190, cy + 370], fill=dark)
circle(cx - 60, cy + 190, 40, (255, 255, 255))

d.line([(cx, cy + 370), (cx, cy + 500)], fill=dark, width=50)
d.arc([cx - 260, cy + 380, cx, cy + 620], 20, 160, fill=dark, width=50)
d.arc([cx, cy + 380, cx + 260, cy + 620], 20, 160, fill=dark, width=50)

out = "Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
img.resize((1024, 1024), Image.LANCZOS).save(out)

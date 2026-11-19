"""生成 GoldCotTracker 的 1024px iOS 主屏幕图标（无透明通道）。"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
import math

SIZE = 1024
SCALE = 3
W = SIZE * SCALE
OUT = Path(__file__).parent / "Sources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"


def sc(value):
    if isinstance(value, (tuple, list)):
        return tuple(int(round(v * SCALE)) for v in value)
    return int(round(value * SCALE))


def mix(a, b, t):
    return tuple(round(a[i] * (1 - t) + b[i] * t) for i in range(3))


# 全出血方形底图；圆角由 iOS 自动裁切，不能在源文件中预裁或留透明。
img = Image.new("RGB", (W, W))
pix = img.load()
top = (20, 31, 49)
bottom = (4, 8, 15)
for y in range(W):
    t = y / (W - 1)
    row = mix(top, bottom, t)
    for x in range(W):
        pix[x, y] = row

# 柔和的金色光晕，让中心图形在小尺寸下仍有清晰层次。
glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
gp = glow.load()
cx, cy, radius = sc(530), sc(430), sc(510)
for y in range(max(0, cy - radius), min(W, cy + radius)):
    for x in range(max(0, cx - radius), min(W, cx + radius)):
        d = math.hypot(x - cx, y - cy) / radius
        if d < 1:
            alpha = int(54 * (1 - d) ** 2)
            gp[x, y] = (245, 184, 65, alpha)
img = Image.alpha_composite(img.convert("RGBA"), glow)

# 低对比度网格，只作背景纹理。
grid = Image.new("RGBA", (W, W), (0, 0, 0, 0))
g = ImageDraw.Draw(grid)
for p in (220, 360, 500, 640, 780):
    g.line((sc(p), sc(170), sc(p), sc(840)), fill=(175, 199, 226, 15), width=sc(2))
for p in (270, 420, 570, 720):
    g.line((sc(155), sc(p), sc(870), sc(p)), fill=(175, 199, 226, 15), width=sc(2))
img = Image.alpha_composite(img, grid)

# 主图形：六根加粗 K 线，金色上涨、灰蓝回撤；轮廓保持简洁。
candles = Image.new("RGBA", (W, W), (0, 0, 0, 0))
d = ImageDraw.Draw(candles)
gold = (247, 190, 74, 255)
gold_hi = (255, 218, 133, 255)
muted = (108, 137, 161, 255)
rows = [
    # x, wick_top, body_top, body_bottom, wick_bottom, color
    (245, 510, 580, 700, 755, muted),
    (355, 420, 485, 630, 690, gold),
    (465, 465, 515, 585, 660, muted),
    (575, 300, 370, 525, 600, gold),
    (685, 345, 405, 470, 555, gold_hi),
    (795, 195, 270, 405, 480, gold),
]
for x, wt, bt, bb, wb, color in rows:
    d.line((sc(x), sc(wt), sc(x), sc(wb)), fill=color, width=sc(18))
    d.rounded_rectangle(
        (sc(x - 37), sc(bt), sc(x + 37), sc(bb)),
        radius=sc(17), fill=color,
    )
    # 极轻的高光边，避免大色块显得扁平。
    if color != muted:
        d.line((sc(x - 19), sc(bt + 16), sc(x - 19), sc(bb - 16)),
               fill=(255, 235, 183, 105), width=sc(4))
img = Image.alpha_composite(img, candles)

# 一条明确的上升趋势线，呼应 COT 与金价联动追踪。
trend = Image.new("RGBA", (W, W), (0, 0, 0, 0))
d = ImageDraw.Draw(trend)
points = [(205, 690), (340, 590), (455, 615), (585, 435), (700, 455), (825, 280)]
d.line([sc(p) for p in points], fill=(255, 232, 173, 230), width=sc(15), joint="curve")
for x, y in points:
    d.ellipse((sc(x - 13), sc(y - 13), sc(x + 13), sc(y + 13)), fill=(255, 239, 198, 255))
# 箭头位于安全区内，避免主屏幕圆角和快捷操作遮挡。
d.polygon([sc((817, 193)), sc((866, 263)), sc((813, 248))], fill=(255, 232, 173, 255))
img = Image.alpha_composite(img, trend)

OUT.parent.mkdir(parents=True, exist_ok=True)
img.convert("RGB").resize((SIZE, SIZE), Image.Resampling.LANCZOS).save(OUT, optimize=True)
print(OUT)

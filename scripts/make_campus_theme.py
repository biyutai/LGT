# -*- coding: utf-8 -*-
"""生成“校园信息发布 / 应急演练”主题的四张演示图。

输出保持现有演示卡的尺寸组合：
  01_campus_daily_640x480.bmp      640x480   日常校园公告（首图）
  02_emergency_warning_640x480.bmp 640x480   应急预警（文字全部烘进图）
  03_exhibition_1280x960.bmp       1280x960  学生创新展（2x2 均值缩放）
  04_evacuation_1024x768.bmp       1024x768  疏散路线图（8:5 相位抽取）

全部为 24 位未压缩、正高度（bottom-up）BMP，可直接被 package_content.py 校验。
控制台只打印文件信息；预览 PNG 放在 preview/ 下，便于人工检查。
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/campus_emergency"
PREVIEW = OUT / "preview"

FONT_BOLD = "C:/Windows/Fonts/msyhbd.ttc"
FONT_REG = "C:/Windows/Fonts/msyh.ttc"

NAVY = (8, 22, 32)
NAVY_2 = (12, 38, 52)
TEAL = (0, 169, 190)
WHITE = (242, 247, 248)
GRAY = (170, 190, 198)
AMBER = (244, 162, 97)
RED = (215, 38, 61)
RED_DARK = (92, 10, 20)
GREEN = (42, 157, 143)
BLUE = (69, 123, 157)


def font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REG, size)


def gradient(width: int, height: int, top: tuple[int, int, int],
             bottom: tuple[int, int, int]) -> Image.Image:
    t = np.linspace(0.0, 1.0, height, dtype=np.float32)[:, None]
    top_a = np.array(top, dtype=np.float32)[None, :]
    bot_a = np.array(bottom, dtype=np.float32)[None, :]
    rows = top_a * (1.0 - t) + bot_a * t
    data = np.repeat(rows[:, None, :], width, axis=1).astype(np.uint8)
    return Image.fromarray(data, "RGB")


def draw_text(draw: ImageDraw.ImageDraw, xy: tuple[int, int], text: str,
              f: ImageFont.FreeTypeFont, fill: tuple[int, int, int],
              anchor: str | None = None) -> None:
    draw.text(xy, text, font=f, fill=fill, anchor=anchor)


def card(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int],
         fill: tuple[int, int, int], outline: tuple[int, int, int] | None = None,
         radius: int = 14, width: int = 2) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def skyline(draw: ImageDraw.ImageDraw, width: int, base_y: int,
            color: tuple[int, int, int]) -> None:
    """极简校园天际线，作为日常封面的背景装饰。"""
    buildings = [
        (0.04, 52, 96), (0.14, 38, 72), (0.23, 66, 120), (0.36, 44, 84),
        (0.47, 58, 104), (0.59, 34, 66), (0.68, 62, 112), (0.81, 40, 76),
        (0.90, 54, 98),
    ]
    for x_ratio, w, h in buildings:
        x = int(width * x_ratio)
        draw.rectangle((x, base_y - h, x + w, base_y), fill=color)
        # 屋顶
        draw.polygon([(x - 6, base_y - h), (x + w // 2, base_y - h - 18),
                      (x + w + 6, base_y - h)], fill=color)
    # 树
    for x_ratio in (0.10, 0.32, 0.55, 0.76, 0.95):
        x = int(width * x_ratio)
        draw.rectangle((x, base_y - 26, x + 5, base_y), fill=color)
        draw.ellipse((x - 12, base_y - 52, x + 17, base_y - 20), fill=color)


def make_daily(path: Path) -> None:
    w, h = 640, 480
    img = gradient(w, h, (10, 30, 42), (7, 16, 24))
    d = ImageDraw.Draw(img)

    # 顶部细线 + 品牌
    d.line((32, 86, w - 32, 86), fill=TEAL, width=3)
    draw_text(d, (w - 24, 20), "LGT-S1", font(20), TEAL, anchor="ra")

    # 天际线（标题右侧的淡背景）
    skyline(d, w, 196, (14, 48, 62))
    draw_text(d, (32, 104), "校园/园区信息发布", font(48), WHITE)
    draw_text(d, (34, 162), "CAMPUS INFORMATION", font(22, bold=False), TEAL)

    # 今日安排卡片
    card(d, (32, 212, 608, 392), (13, 40, 54), TEAL, radius=16, width=2)
    draw_text(d, (56, 228), "今日安排 / TODAY", font(28), WHITE)
    rows = [
        ("08:00", "校园公告 / CAMPUS NOTICE"),
        ("12:00", "学生作品展 / STUDENT EXHIBITION"),
        ("18:00", "图书馆开放 / LIBRARY OPEN"),
    ]
    y = 278
    for t, label in rows:
        draw_text(d, (56, y), t, font(24), AMBER)
        draw_text(d, (146, y), label, font(24, bold=False), WHITE)
        y += 38

    # 底部
    d.rectangle((0, 400, w, h), fill=(10, 30, 40))
    draw_text(d, (32, 418), "教学楼一层 · 校园/园区多媒体信息终端", font(20), TEAL)
    draw_text(d, (32, 450), "1F TEACHING BUILDING", font(16, bold=False), GRAY)

    img.save(path, format="BMP")
    img.save(PREVIEW / (path.stem + ".png"), format="PNG")


def make_warning(path: Path) -> None:
    w, h = 640, 480
    img = gradient(w, h, (128, 16, 30), (54, 6, 14))
    d = ImageDraw.Draw(img)

    # 斜纹背景（低对比度，不抢文字）
    for x in range(-h, w, 56):
        d.line((x, 0, x + h, h), fill=(150, 28, 42), width=10)

    draw_text(d, (w - 24, 20), "LGT-S1", font(20), WHITE, anchor="ra")

    # 警示三角
    cx, cy, r = 320, 150, 62
    d.polygon([(cx, cy - r), (cx - r, cy + r), (cx + r, cy + r)],
              fill=(255, 205, 70), outline=WHITE)
    d.rectangle((cx - 7, cy - 26, cx + 7, cy + 18), fill=(70, 10, 16))
    d.ellipse((cx - 9, cy + 28, cx + 9, cy + 46), fill=(70, 10, 16))

    draw_text(d, (320, 220), "应急通知", font(54), WHITE, anchor="ma")
    draw_text(d, (320, 286), "EMERGENCY NOTICE", font(26), (255, 205, 70), anchor="ma")
    draw_text(d, (320, 326), "消防演练 / FIRE DRILL", font(28), WHITE, anchor="ma")
    draw_text(d, (320, 368), "请沿安全通道有序撤离", font(26), WHITE, anchor="ma")
    draw_text(d, (320, 402), "EVACUATE VIA SAFE ROUTE", font(18, bold=False),
              (255, 225, 190), anchor="ma")

    # 底部集合点
    d.rectangle((0, 432, w, h), fill=(48, 6, 12))
    draw_text(d, (320, 446), "集合点：操场 / ASSEMBLY: PLAYGROUND",
              font(18, bold=False), (255, 225, 190), anchor="ma")

    img.save(path, format="BMP")
    img.save(PREVIEW / (path.stem + ".png"), format="PNG")


def make_exhibition(path: Path) -> None:
    w, h = 1280, 960
    img = gradient(w, h, (8, 28, 42), (5, 12, 20))
    d = ImageDraw.Draw(img)

    # 顶部留出状态栏安全区（输出 640x480 的顶部 80px 对应源图 160px）
    d.rectangle((0, 0, w, 160), fill=(7, 24, 34))
    d.line((64, 158, w - 64, 158), fill=TEAL, width=4)
    draw_text(d, (w - 40, 28), "LGT-S1", font(30), TEAL, anchor="ra")

    d.rectangle((64, 196, 76, 344), fill=TEAL)
    draw_text(d, (104, 188), "校园/园区创新作品展", font(68), WHITE)
    draw_text(d, (108, 282), "CAMPUS & PARK INNOVATION EXHIBITION",
              font(30, bold=False), TEAL)
    draw_text(d, (108, 340), "10.18 — 10.25 · 图书馆一层", font(36), AMBER)
    draw_text(d, (108, 390), "LIBRARY 1F · 10:00-18:00",
              font(24, bold=False), GRAY)

    # 2x2 展项卡片
    cards = [
        ("智能小车", "SMART CAR", "car"),
        ("FPGA 音频", "FPGA AUDIO", "audio"),
        ("视觉识别", "VISION", "eye"),
        ("创意交互", "INTERACTIVE", "button"),
    ]
    x0, y0 = 104, 448
    cw, ch, gap = 520, 200, 32
    for i, (cn, en, icon) in enumerate(cards):
        col, row = i % 2, i // 2
        x = x0 + col * (cw + gap)
        y = y0 + row * (ch + gap)
        card(d, (x, y, x + cw, y + ch), (13, 40, 54), TEAL, radius=18, width=2)
        # 图标区
        ix, iy = x + 34, y + 54
        if icon == "car":
            d.rounded_rectangle((ix, iy + 26, ix + 96, iy + 66), radius=14,
                                fill=TEAL)
            d.ellipse((ix + 12, iy + 58, ix + 34, iy + 80), fill=WHITE)
            d.ellipse((ix + 62, iy + 58, ix + 84, iy + 80), fill=WHITE)
        elif icon == "audio":
            pts = [(ix + i * 6, iy + 48 + (18 if i % 2 else -18))
                   for i in range(17)]
            d.line(pts, fill=TEAL, width=6)
            d.line((ix, iy + 48, ix + 102, iy + 48), fill=(30, 90, 105), width=2)
        elif icon == "eye":
            d.ellipse((ix, iy + 22, ix + 104, iy + 82), outline=TEAL, width=6)
            d.ellipse((ix + 38, iy + 38, ix + 66, iy + 66), fill=TEAL)
        else:
            d.rounded_rectangle((ix + 18, iy + 24, ix + 86, iy + 82),
                                radius=14, outline=TEAL, width=6)
            d.ellipse((ix + 42, iy + 44, ix + 62, iy + 64), fill=TEAL)
        draw_text(d, (x + 168, y + 56), cn, font(38), WHITE)
        draw_text(d, (x + 170, y + 112), en, font(22, bold=False), TEAL)
        draw_text(d, (x + 170, y + 148), "欢迎参观 / WELCOME",
                  font(20, bold=False), GRAY)

    # 底部
    d.rectangle((0, 860, w, h), fill=(9, 28, 38))
    draw_text(d, (64, 884), "LGT 音画同频数字标牌 · 校园/园区多媒体信息终端",
              font(28), TEAL)
    draw_text(d, (w - 64, 892), "WELCOME", font(26, bold=False),
              GRAY, anchor="ra")

    img.save(path, format="BMP")
    img.save(PREVIEW / (path.stem + ".png"), format="PNG")


def make_evacuation(path: Path) -> None:
    # Design at the actual display resolution: source-sized fine print loses
    # strokes when bmp_read keeps only five of every eight pixels/rows.
    w, h = 640, 480
    img = Image.new("RGB", (w, h), (238, 242, 245))
    d = ImageDraw.Draw(img)

    # Status overlay: y=0..79. All essential map labels stay above y=352,
    # where the audio waveform and spectrum start.
    d.rectangle((0, 0, w, 79), fill=NAVY)
    draw_text(d, (w - 22, 18), "LGT-S1", font(18), TEAL, anchor="ra")
    draw_text(d, (28, 88), "疏散路线", font(32), NAVY, anchor="lt")
    draw_text(d, (30, 126), "EVACUATION ROUTE", font(16),
              (0, 100, 116), anchor="lt")

    plan = (20, 152, 620, 322)
    d.rounded_rectangle(plan, radius=10, fill=(250, 252, 253),
                        outline=NAVY, width=3)
    rooms = [
        ((36, 164, 282, 226), "教室 A", "CLASSROOM A"),
        ((300, 164, 604, 226), "教室 B", "CLASSROOM B"),
        ((36, 236, 206, 298), "实验室", "LAB"),
        ((222, 236, 386, 298), "大厅", "HALL"),
        ((402, 236, 604, 298), "楼梯", "STAIRS"),
    ]
    for (x1, y1, x2, y2), cn, en in rooms:
        d.rounded_rectangle((x1, y1, x2, y2), radius=6, fill=(226, 234, 238),
                            outline=(104, 125, 136), width=2)
        cx = (x1 + x2) // 2
        draw_text(d, (cx, y1 + 22), cn, font(23), NAVY, anchor="mm")
        draw_text(d, (cx, y1 + 47), en, font(14), NAVY, anchor="mm")

    # Hall -> stairs -> exit; route stays below the room captions.
    route = [(304, 295), (454, 295), (490, 295), (556, 316)]
    d.line(route, fill=RED, width=6, joint="curve")
    d.polygon([(556, 322), (543, 307), (564, 307)], fill=RED)

    exit_green = (7, 107, 78)
    for x in (316, 556):
        d.rounded_rectangle((x - 33, 311, x + 33, 340), radius=3,
                            fill=exit_green)
        draw_text(d, (x, 325), "出口", font(21), WHITE, anchor="mm")

    assembly_blue = (30, 85, 123)
    d.ellipse((36, 323, 64, 351), fill=assembly_blue)
    draw_text(d, (50, 337), "集", font(20), WHITE, anchor="mm")
    draw_text(d, (72, 337), "集合点", font(19), assembly_blue, anchor="lm")
    draw_text(d, (138, 337), "ASSEMBLY", font(14), assembly_blue, anchor="lm")

    # Leave the waveform/spectrum strip free of map text. The legend fits
    # between that strip and the first subtitle row (y=432).
    for lx, cn, en, color in (
        (24, "路线", "ROUTE", RED),
        (200, "出口", "EXIT", exit_green),
        (354, "集合点", "ASSEMBLY", assembly_blue),
    ):
        d.rectangle((lx, 419, lx + 12, 428), fill=color)
        tx = lx + 20
        draw_text(d, (tx, 416), cn, font(16), NAVY, anchor="lt")
        tx += int(d.textlength(cn, font=font(16))) + 7
        draw_text(d, (tx, 418), en, font(14), NAVY, anchor="lt")

    d.rectangle((0, 440, w, h), fill=NAVY)
    draw_text(d, (w // 2, 451), "请沿安全通道有序撤离 / EVACUATE SAFELY",
              font(20), WHITE, anchor="mt")

    # Invert bmp_read's 8:5 sampling, including bottom-up BMP row order.
    # Retained source x phases: 1,3,4,6,7. Retained top-down y phases:
    # 0,1,3,4,6. Expanding on these boundaries preserves every display pixel.
    pixels = np.asarray(img)
    source_x = np.arange(1024) * 5 // 8
    source_y = 479 - (767 - np.arange(768)) * 5 // 8
    source = Image.fromarray(pixels[source_y[:, None], source_x[None, :]])
    source.save(path, format="BMP")
    source.save(PREVIEW / (path.stem + ".png"), format="PNG")
    img.save(PREVIEW / "04_evacuation_display_640x480.png", format="PNG")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    PREVIEW.mkdir(parents=True, exist_ok=True)
    files = [
        ("01_campus_daily_640x480.bmp", make_daily),
        ("02_emergency_warning_640x480.bmp", make_warning),
        ("03_exhibition_1280x960.bmp", make_exhibition),
        ("04_evacuation_1024x768.bmp", make_evacuation),
    ]
    for name, fn in files:
        path = OUT / name
        fn(path)
        print(f"{name}: {path.stat().st_size} bytes")

    # 联系表：四张图缩略并排，便于快速检查
    thumbs = []
    for name, _ in files:
        im = Image.open(OUT / name).convert("RGB")
        im.thumbnail((480, 360))
        thumbs.append(im)
    sheet = Image.new("RGB", (4 * 480 + 5 * 20, 400), (20, 20, 20))
    for i, im in enumerate(thumbs):
        sheet.paste(im, (20 + i * (480 + 20), 20))
    sheet.save(PREVIEW / "contact_sheet.png", format="PNG")
    print(f"contact sheet: {PREVIEW / 'contact_sheet.png'}")


if __name__ == "__main__":
    main()

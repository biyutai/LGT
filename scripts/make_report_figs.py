#!/usr/bin/env python3
"""Generate design-report figures for LGT-S1 at final print size.

Figures are drawn at roughly 7.2 x 4.5 inches so that, when inserted at
15.5 cm in the DOCX, 8 pt text stays around 7 pt on paper.
"""

from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch, Rectangle, Polygon

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "report_figs"
OUT.mkdir(parents=True, exist_ok=True)

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "Noto Sans SC"]
plt.rcParams["font.family"] = "sans-serif"
plt.rcParams["axes.unicode_minus"] = False

INK = "#1f3a4d"
BLUE = "#dbe7f3"
BLUE_E = "#2f5d8a"
GREEN = "#e2efda"
GREEN_E = "#4b7a3f"
ORANGE = "#fce4d6"
ORANGE_E = "#b45f2a"
GREY = "#f2f4f6"
GREY_E = "#7f8c8d"
TEAL = "#d9f2f5"
TEAL_E = "#008a9b"
PURPLE = "#e8e1f2"
PURPLE_E = "#6a4c93"


def canvas(w=7.2, h=4.6):
    fig, ax = plt.subplots(figsize=(w, h))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 100)
    ax.axis("off")
    fig.patch.set_facecolor("white")
    return fig, ax


def box(ax, x, y, w, h, text, fc=BLUE, ec=BLUE_E, fs=8, bold=False, lw=1.0,
        rounding=0.7, color=INK, z=2):
    patch = FancyBboxPatch((x, y), w, h, boxstyle=f"round,pad=0.02,rounding_size={rounding}",
                           linewidth=lw, edgecolor=ec, facecolor=fc, zorder=z)
    ax.add_patch(patch)
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=fs,
            color=color, fontweight="bold" if bold else "normal", zorder=z + 1,
            linespacing=1.2)
    return patch


def label(ax, x, y, text, fs=7.5, color=INK, ha="left", va="center", bold=False, z=5):
    ax.text(x, y, text, fontsize=fs, color=color, ha=ha, va=va,
            fontweight="bold" if bold else "normal", zorder=z, linespacing=1.2)


def arrow(ax, p1, p2, text="", color=INK, lw=1.0, rad=0.0, fs=7, tpos=0.5,
          toff=(0, 0), style="-|>", z=3):
    a = FancyArrowPatch(p1, p2, arrowstyle=style, mutation_scale=9, linewidth=lw,
                        color=color, connectionstyle=f"arc3,rad={rad}",
                        shrinkA=1.0, shrinkB=1.0, zorder=z)
    ax.add_patch(a)
    if text:
        mx = p1[0] + (p2[0] - p1[0]) * tpos + toff[0]
        my = p1[1] + (p2[1] - p1[1]) * tpos + toff[1]
        ax.text(mx, my, text, fontsize=fs, color=color, ha="center", va="center",
                zorder=z + 1, bbox=dict(boxstyle="round,pad=0.12", fc="white", ec="none", alpha=0.92))


def poly_arrow(ax, points, text="", color=INK, lw=1.0, fs=7, tpos=0.5, toff=(0, 0), z=3):
    pts = [tuple(p) for p in points]
    if len(pts) < 2:
        return
    for a, b in zip(pts[:-2], pts[1:-1]):
        ax.plot([a[0], b[0]], [a[1], b[1]], color=color, lw=lw, zorder=z,
                solid_capstyle="round")
    arrow(ax, pts[-2], pts[-1], text="", color=color, lw=lw, z=z)
    if text:
        segs = list(zip(pts[:-1], pts[1:]))
        seg = max(segs, key=lambda s: abs(s[1][0] - s[0][0]) + abs(s[1][1] - s[0][1]))
        mx = seg[0][0] + (seg[1][0] - seg[0][0]) * tpos + toff[0]
        my = seg[0][1] + (seg[1][1] - seg[0][1]) * tpos + toff[1]
        ax.text(mx, my, text, fontsize=fs, color=color, ha="center", va="center",
                zorder=z + 1, bbox=dict(boxstyle="round,pad=0.12", fc="white", ec="none", alpha=0.92))


def group(ax, x, y, w, h, title, ec=GREY_E, fc="none", fs=8):
    ax.add_patch(Rectangle((x, y), w, h, linewidth=0.9, edgecolor=ec, facecolor=fc,
                           linestyle=(0, (4, 3)), zorder=1))
    ax.text(x + 0.5, y + h - 1.6, title, fontsize=fs, color=ec, fontweight="bold", zorder=2)


def diamond(ax, cx, cy, w, h, text, fc=ORANGE, ec=ORANGE_E, fs=7.5):
    pts = [(cx, cy + h / 2), (cx + w / 2, cy), (cx, cy - h / 2), (cx - w / 2, cy)]
    ax.add_patch(Polygon(pts, closed=True, facecolor=fc, edgecolor=ec, linewidth=1.0, zorder=2))
    ax.text(cx, cy, text, ha="center", va="center", fontsize=fs, color=INK, zorder=3, linespacing=1.15)


def save(fig, name):
    path = OUT / name
    fig.savefig(path, dpi=300, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print("wrote", path)


# ---------------------------------------------------------------------------
def fig_design_flow():
    fig, ax = canvas(7.2, 4.4)
    steps = [
        ("需求/场景", "校园/园区\n无人值守", BLUE, BLUE_E),
        ("总体架构", "时钟/存储\n数据通路", BLUE, BLUE_E),
        ("模块 RTL", "SD/BMP/视频\n音频/OSD", GREEN, GREEN_E),
        ("单元仿真", "逐模块\ntestbench", GREEN, GREEN_E),
        ("整链仿真", "音画/坏图\n掉电/热复位", ORANGE, ORANGE_E),
        ("TD 实现", "综合/布局\n时序约束", ORANGE, ORANGE_E),
        ("多种子收敛", "功能域\n余量为正", PURPLE, PURPLE_E),
        ("上板/交付", "验证/打包\n演示", TEAL, TEAL_E),
    ]
    w, h = 20.5, 16
    top_y, bot_y = 62, 28
    top_xs = [2, 26.5, 51, 75.5]
    bot_xs = [75.5, 51, 26.5, 2]
    for i in range(4):
        title, sub, fc, ec = steps[i]
        box(ax, top_xs[i], top_y, w, h, f"{title}\n{sub}", fc=fc, ec=ec, fs=8.6, bold=True)
        if i < 3:
            arrow(ax, (top_xs[i] + w, top_y + h / 2), (top_xs[i + 1], top_y + h / 2), lw=1.2)
    arrow(ax, (86.75, top_y), (86.75, bot_y + h), lw=1.2)
    for i in range(4):
        title, sub, fc, ec = steps[4 + i]
        box(ax, bot_xs[i], bot_y, w, h, f"{title}\n{sub}", fc=fc, ec=ec, fs=8.6, bold=True)
        if i < 3:
            arrow(ax, (bot_xs[i], bot_y + h / 2), (bot_xs[i + 1] + w, bot_y + h / 2), lw=1.2)
    label(ax, 2, 86, "阶段一：需求与架构", fs=8.2, bold=True, color=BLUE_E)
    label(ax, 51, 86, "阶段二：RTL 与仿真", fs=8.2, bold=True, color=GREEN_E)
    ax.plot([2, 47], [83, 83], color=BLUE_E, lw=1.6)
    ax.plot([51, 96], [83, 83], color=GREEN_E, lw=1.6)
    label(ax, 2, 50, "阶段三：集成、实现与交付", fs=8.2, bold=True, color=ORANGE_E)
    ax.plot([2, 96], [47, 47], color=ORANGE_E, lw=1.6)
    label(ax, 2, 12, "验收门：单元仿真 ALL PASSED → 整链仿真 → 功能域时序为正 → 上板记录 → 版本锁定", fs=7.2, color=GREY_E)
    save(fig, "fig_design_flow.png")


def fig_system_block():
    fig, ax = canvas(7.4, 5.0)
    group(ax, 1, 22, 23, 70, "输入/解析", ec=BLUE_E)
    group(ax, 25, 22, 23, 70, "缓存", ec=GREEN_E)
    group(ax, 49, 22, 24, 70, "处理", ec=ORANGE_E)
    group(ax, 75, 22, 24, 70, "输出", ec=PURPLE_E)
    group(ax, 1, 1, 98, 16, "控制、参数与记录", ec=GREY_E)

    # input
    box(ax, 3, 79, 19, 9, "TF 卡/FAT32\nBMP/WAV/PLAYLIST", fc=BLUE, ec=BLUE_E, fs=7.4)
    box(ax, 3, 62, 19, 12, "SD/FAT32/BMP\nSPI 12.5 MHz\n多尺寸解析", fc=BLUE, ec=BLUE_E, fs=7.2)
    box(ax, 3, 47, 19, 10, "节目单/双语字幕\n最多 16 条", fc=TEAL, ec=TEAL_E, fs=7.2)

    # cache
    box(ax, 27, 79, 19, 9, "写 FIFO 512×32\n50→125 MHz", fc=GREEN, ec=GREEN_E, fs=7.2)
    box(ax, 27, 47, 19, 26, "SDRAM 2M×32\nBUF0~BUF3 四帧\n音频区/缩略图", fc=GREEN, ec=GREEN_E, fs=7.8, bold=True)
    box(ax, 27, 33, 19, 9, "音频第三读口\n64 字突发", fc=GREEN, ec=GREEN_E, fs=7.2)

    # processing
    box(ax, 51, 79, 20, 9, "读 FIFO 512×32\n125→25.2 MHz", fc=GREEN, ec=GREEN_E, fs=7.2)
    box(ax, 51, 60, 20, 15, "视频处理\n转场/特效/调色\nOSD 多图层", fc=ORANGE, ec=ORANGE_E, fs=7.4)
    box(ax, 51, 43, 20, 13, "音频链\nWAV/音量/5 段 EQ\nACR 6144/25200", fc=ORANGE, ec=ORANGE_E, fs=7.0)
    box(ax, 51, 28, 20, 11, "音频可视化\n波形/四柱/LED", fc=ORANGE, ec=ORANGE_E, fs=7.2)

    # output
    box(ax, 77, 62, 20, 16, "HDMI 1.4b TX\n视频+音频", fc=PURPLE, ec=PURPLE_E, fs=7.8, bold=True)
    box(ax, 77, 45, 20, 12, "TMDS 串化\n4 路 LVDS", fc=PURPLE, ec=PURPLE_E, fs=7.4)
    box(ax, 77, 29, 20, 11, "HDMI_B\n640×480@60\n48 kHz", fc=PURPLE, ec=PURPLE_E, fs=7.4)

    # control row
    box(ax, 3, 3, 20, 10, "KEY/SW/矩阵\n4×4", fc=GREY, ec=GREY_E, fs=7.2)
    box(ax, 26, 3, 20, 10, "osd_controls\n切图/页面", fc=GREY, ec=GREY_E, fs=7.2)
    box(ax, 49, 3, 20, 10, "W25Q64\n参数+事件", fc=GREY, ec=GREY_E, fs=7.2)
    box(ax, 72, 3, 20, 10, "UART TXD\n190 B 状态", fc=GREY, ec=GREY_E, fs=7.2)

    # arrows
    arrow(ax, (12.5, 79), (12.5, 74), "", fs=7)
    poly_arrow(ax, [(22, 68), (24, 68), (24, 83.5), (27, 83.5)], "像素", fs=6.5)
    poly_arrow(ax, [(22, 52), (23.5, 52), (23.5, 44.5), (48, 44.5), (48, 67), (51, 67)], "字幕", fs=6.5)
    arrow(ax, (36.5, 79), (36.5, 73), "256 字突发", fs=6.5)
    arrow(ax, (36.5, 47), (36.5, 42), "", fs=7)
    poly_arrow(ax, [(46, 73), (47.2, 73), (47.2, 83.5), (51, 83.5)], "整帧", fs=6.5)
    arrow(ax, (61, 79), (61, 75), "", fs=7)
    arrow(ax, (71, 67), (77, 67), "RGB", fs=6.5)
    arrow(ax, (46, 37.5), (51, 49), "WAV", fs=6.5, rad=-0.1)
    arrow(ax, (61, 43), (61, 39), "PCM", fs=6.5)
    poly_arrow(ax, [(71, 49.5), (74.4, 49.5), (74.4, 66), (77, 66)], "PCM", fs=6.5)
    arrow(ax, (87, 62), (87, 57), "", fs=7)
    arrow(ax, (87, 45), (87, 40), "", fs=7)
    arrow(ax, (23, 8), (26, 8), "", fs=7)
    arrow(ax, (46, 8), (49, 8), "参数/事件", fs=6.5)
    poly_arrow(ax, [(59, 13), (59, 20), (47.2, 20), (47.2, 67), (51, 67)], "", fs=6.2)
    label(ax, 46.6, 23.5, "恢复/LOG", fs=6.2, color=INK, ha="right")

    label(ax, 3, 96, "sd_card_clk 50 MHz", fs=7.2, color=BLUE_E, bold=True)
    label(ax, 27, 96, "ext_mem_clk 125 MHz", fs=7.2, color=GREEN_E, bold=True)
    label(ax, 51, 96, "video_clk 25.2 MHz", fs=7.2, color=ORANGE_E, bold=True)
    label(ax, 77, 96, "hdmi_5x_clk 126 MHz", fs=7.2, color=PURPLE_E, bold=True)
    save(fig, "fig_system_block.png")


def fig_sd_flow():
    fig, ax = canvas(7.0, 5.4)
    box(ax, 30, 93, 30, 5, "上电/复位", fc=BLUE, ec=BLUE_E, fs=8)
    box(ax, 30, 83, 30, 7, "SD 初始化 100 kHz\n清 2600×0xFF", fc=BLUE, ec=BLUE_E, fs=7.2)
    diamond(ax, 45, 74, 22, 7, "初始化完成？", fs=7.2)
    box(ax, 30, 60, 30, 7, "读 LBA0\n识别 FAT32", fc=BLUE, ec=BLUE_E, fs=7.2)
    diamond(ax, 45, 52, 22, 7, "FAT32 有效？", fs=7.2)
    box(ax, 30, 39, 30, 7, "扫描根目录\n4 BMP + WAV", fc=GREEN, ec=GREEN_E, fs=7.2)
    diamond(ax, 45, 31, 22, 7, "找到 BMP？", fs=7.2)
    box(ax, 30, 19, 30, 7, "载入首图\nBMP 头校验", fc=GREEN, ec=GREEN_E, fs=7.2)
    diamond(ax, 45, 10, 22, 7, "图片有效？", fs=7.2)
    box(ax, 68, 4, 29, 12, "提交显示\n后台载 WAV\n进入轮播", fc=GREEN, ec=GREEN_E, fs=7.2)
    box(ax, 70, 69, 27, 8, "看门狗\n2 s/250 ms", fc=ORANGE, ec=ORANGE_E, fs=7.2)
    box(ax, 70, 48, 27, 8, "无内容引导\n保留封面", fc=ORANGE, ec=ORANGE_E, fs=7.2)
    box(ax, 70, 27, 27, 8, "封面+引导\n插卡重扫", fc=ORANGE, ec=ORANGE_E, fs=7.2)
    box(ax, 2, 3, 25, 12, "重试 1 次\n仍坏→下一张\n保留旧帧", fc=ORANGE, ec=ORANGE_E, fs=7.0)

    arrow(ax, (45, 93), (45, 90), fs=7)
    arrow(ax, (45, 83), (45, 77.5), fs=7)
    arrow(ax, (45, 70.5), (45, 67), fs=7)
    arrow(ax, (45, 60), (45, 55.5), fs=7)
    arrow(ax, (45, 48.5), (45, 46), fs=7)
    arrow(ax, (45, 39), (45, 34.5), fs=7)
    arrow(ax, (45, 27.5), (45, 26), fs=7)
    arrow(ax, (45, 19), (45, 13.5), fs=7)
    arrow(ax, (56, 74), (70, 73), "超时", fs=6.5, color=ORANGE_E)
    arrow(ax, (56, 52), (70, 52), "否", fs=6.5, color=ORANGE_E)
    arrow(ax, (56, 31), (70, 31), "否", fs=6.5, color=ORANGE_E)
    arrow(ax, (56, 10), (68, 10), "是", fs=6.5, color=GREEN_E)
    arrow(ax, (34, 10), (27, 10), "否", fs=6.5, color=ORANGE_E)
    arrow(ax, (70, 77), (60, 86), "重初始化", fs=6.2, color=ORANGE_E, rad=-0.1)
    poly_arrow(ax, [(27, 14), (24, 14), (24, 42.5), (30, 42.5)], "下一张", fs=6.2, color=ORANGE_E)
    save(fig, "fig_sd_flow.png")


def fig_image_path():
    fig, ax = canvas(7.4, 3.8)
    stages = [
        ("TF 卡", "FAT32 根目录", BLUE, BLUE_E),
        ("SD/FAT32", "SPI 12.5 MHz\n簇链映射", BLUE, BLUE_E),
        ("BMP 解析", "头校验\n多尺寸缩放", GREEN, GREEN_E),
        ("SDRAM", "四帧常驻\nBUF0~3", GREEN, GREEN_E),
        ("视频流水线", "转场/特效\n调色/OSD", ORANGE, ORANGE_E),
        ("HDMI", "640×480\n@60 / TMDS", PURPLE, PURPLE_E),
    ]
    w, h = 13.5, 22
    gap = 3.0
    x = 2
    y = 48
    for i, (title, sub, fc, ec) in enumerate(stages):
        box(ax, x, y, w, h, f"{title}\n{sub}", fc=fc, ec=ec, fs=8.2, bold=True)
        if i < len(stages) - 1:
            arrow(ax, (x + w, y + h / 2), (x + w + gap, y + h / 2), lw=1.0)
        x += w + gap
    label(ax, 2, 38, "写侧 50 MHz", fs=7.0, color=BLUE_E, bold=True)
    label(ax, 27, 38, "缓存 125 MHz / 256 字突发", fs=7.0, color=GREEN_E, bold=True)
    label(ax, 58, 38, "读侧 25.2 MHz / 帧边界", fs=7.0, color=ORANGE_E, bold=True)
    notes = [
        "1280×960：2×2 均值，避免摩尔纹",
        "1024×768：8:5 相位抽取",
        "320×240/180：最近邻放大",
        "坏图：重试 1 次 → 跳过 → 保留旧帧",
    ]
    for i, n in enumerate(notes):
        label(ax, 3 + (i % 2) * 47, 27 - (i // 2) * 8, "• " + n, fs=7.4)
    save(fig, "fig_image_path.png")


def fig_audio_path():
    fig, ax = canvas(7.4, 3.9)
    stages = [
        ("WAV", "48 kHz/16 bit\n立体声", BLUE, BLUE_E),
        ("SDRAM\n音频区", "714,752 字\n≈14.89 s", GREEN, GREEN_E),
        ("音频读口", "64 字突发\n最低优先", GREEN, GREEN_E),
        ("wav_player", "48 kHz\n16→24 bit", ORANGE, ORANGE_E),
        ("音量 + EQ", "0/35/70/100\n4 档预设", ORANGE, ORANGE_E),
        ("ACR+HDMI", "N=6144\nCTS=25200", PURPLE, PURPLE_E),
    ]
    w, h = 12.8, 22
    gap = 4.0
    x = 2
    y = 52
    for i, (title, sub, fc, ec) in enumerate(stages):
        box(ax, x, y, w, h, f"{title}\n{sub}", fc=fc, ec=ec, fs=7.4, bold=True)
        if i < len(stages) - 1:
            arrow(ax, (x + w, y + h / 2), (x + w + gap, y + h / 2), lw=1.0)
        x += w + gap
    box(ax, 8, 20, 27, 12, "audio_visualizer\n波形/四柱/LED", fc=ORANGE, ec=ORANGE_E, fs=7.4)
    box(ax, 45, 20, 27, 12, "av_sync\n样本计数/切图节拍", fc=ORANGE, ec=ORANGE_E, fs=7.4)
    arrow(ax, (62, 52), (35, 32), "PCM", fs=6.5, color=ORANGE_E, rad=0.1)
    arrow(ax, (62, 52), (58, 32), "样本/节拍", fs=6.5, color=ORANGE_E, rad=-0.1)
    label(ax, 2, 6, "无 WAV 时本版静音；容限 ±8.33 ms，提前 453 样本", fs=7.0, color=GREY_E)
    save(fig, "fig_audio_path.png")


def fig_osd_layers():
    fig, ax = canvas(7.0, 4.2)
    layers = [
        ("① 图片层：转场/特效/调色", 32, 6.5, BLUE, BLUE_E),
        ("② 封面/首图混合", 32, 6.5, BLUE, BLUE_E),
        ("③ 顶部状态栏 512×80", 32, 6.5, GREEN, GREEN_E),
        ("④ 双语字幕 y=432/456", 32, 6.5, GREEN, GREEN_E),
        ("⑤ 信息/LOG/自检/引导", 32, 8.0, ORANGE, ORANGE_E),
        ("⑥ 音频可视化：波形/四柱/LED", 32, 6.5, ORANGE, ORANGE_E),
    ]
    y = 7
    for i, (text, w, h, fc, ec) in enumerate(layers):
        box(ax, 18, y, w, h, text, fc=fc, ec=ec, fs=7.4, bold=(i == 4))
        y += h + 1.0
    box(ax, 56, 7, 22, 46, "输出寄存\nHS/VS/DE/RGB\n→ HDMI 1.4b", fc=PURPLE, ec=PURPLE_E, fs=7.8, bold=True)
    ax.plot([50.5, 52.5], [7, 7], color=INK, lw=1.1)
    ax.plot([52.5, 52.5], [7, 53], color=INK, lw=1.1)
    ax.plot([52.5, 54], [53, 53], color=INK, lw=1.1)
    arrow(ax, (52.5, 30), (56, 30), "", fs=7)
    label(ax, 53.0, 27, "合成", fs=6.8, color=INK, ha="left")
    ax.annotate("", xy=(13, 53), xytext=(13, 7), arrowprops=dict(arrowstyle="-|>", color=GREY_E, lw=1.2))
    label(ax, 10.5, 30, "优先级升高", fs=7.0, color=GREY_E, bold=True, ha="center")
    label(ax, 18, 58, "像素流水线（自下而上叠加）", fs=7.8, bold=True)
    label(ax, 56, 60, "OSD 文字不受图片特效影响\n字幕与可视化不重叠", fs=7.0, color=GREY_E)
    save(fig, "fig_osd_layers.png")


def fig_control_storage():
    fig, ax = canvas(7.4, 4.9)
    box(ax, 2, 84, 20, 9, "按键/矩阵\n4×4", fc=BLUE, ec=BLUE_E, fs=7.2)
    box(ax, 25, 84, 20, 9, "消抖/同步\n20 ms", fc=BLUE, ec=BLUE_E, fs=7.2)
    box(ax, 48, 84, 20, 9, "osd_controls\n编辑链/页面", fc=GREEN, ec=GREEN_E, fs=7.2)
    box(ax, 71, 84, 20, 9, "sd_card_bmp\n切图/直选", fc=GREEN, ec=GREEN_E, fs=7.2)
    arrow(ax, (22, 88.5), (25, 88.5), fs=7)
    arrow(ax, (45, 88.5), (48, 88.5), "按键", fs=6.5)
    arrow(ax, (68, 88.5), (71, 88.5), "切图", fs=6.5)

    group(ax, 1, 40, 85, 37, "product_flash（参数 + 事件）", ec=ORANGE_E)
    box(ax, 4, 62, 22, 11, "parameter\npersistence", fc=ORANGE, ec=ORANGE_E, fs=7.2)
    box(ax, 4, 48, 22, 11, "config_flash\n0x7FE000/12 B", fc=ORANGE, ec=ORANGE_E, fs=7.0)
    box(ax, 30, 62, 22, 11, "事件源\n上电/换图/失败", fc=ORANGE, ec=ORANGE_E, fs=6.8)
    box(ax, 30, 48, 22, 11, "event_log\n0x700000/16 槽", fc=ORANGE, ec=ORANGE_E, fs=6.8)
    box(ax, 56, 62, 22, 11, "arbiter\n参数优先", fc=ORANGE, ec=ORANGE_E, fs=7.2)
    box(ax, 56, 48, 22, 11, "record_store\n擦/写/回读", fc=ORANGE, ec=ORANGE_E, fs=7.0)
    box(ax, 87, 48, 10, 25, "W25Q64\nSPI", fc=GREY, ec=GREY_E, fs=7.2)

    poly_arrow(ax, [(58, 84), (58, 80), (15, 80), (15, 73)], "参数", fs=6.5, toff=(0, 2.0))
    arrow(ax, (15, 62), (15, 59), "加载/保存", fs=6.3)
    arrow(ax, (41, 84), (41, 73), "事件", fs=6.5, tpos=0.1)
    arrow(ax, (41, 62), (41, 59), "", fs=6.5)
    poly_arrow(ax, [(26, 60), (55, 60), (55, 67), (56, 67)], "参数记录", fs=6.3)
    arrow(ax, (52, 67), (56, 67), "事件", fs=6.3)
    arrow(ax, (67, 62), (67, 59), "读写", fs=6.5)
    arrow(ax, (78, 54), (87, 54), "SPI", fs=6.5, style="<|-|>")

    box(ax, 30, 28, 22, 10, "OSD 播放记录\n7 条/中文", fc=TEAL, ec=TEAL_E, fs=7.0)
    box(ax, 56, 28, 22, 10, "UART TXD\n190 B", fc=GREY, ec=GREY_E, fs=7.0)
    box(ax, 4, 8, 48, 9, "健康位 bit0~3：画面/声音/音频口/SD 看门狗", fc=GREY, ec=GREY_E, fs=6.8)
    arrow(ax, (41, 48), (41, 38), "最近 7 条", fs=6.5)
    poly_arrow(ax, [(52, 12.5), (54, 12.5), (54, 33), (56, 33)], "健康/阶段", fs=6.3)
    save(fig, "fig_control_storage.png")


def fig_scene_layout():
    fig, ax = canvas(7.2, 4.1)
    ax.add_patch(Rectangle((3, 14), 55, 72, facecolor="#f7fafc", edgecolor=BLUE_E, lw=1.0, linestyle=(0, (4, 3))))
    ax.add_patch(Rectangle((62, 14), 35, 72, facecolor="#fffaf5", edgecolor=ORANGE_E, lw=1.0, linestyle=(0, (4, 3))))
    label(ax, 5, 82, "信息发布区", fs=9, bold=True, color=BLUE_E)
    label(ax, 64, 82, "值班台", fs=9, bold=True, color=ORANGE_E)
    box(ax, 10, 44, 34, 26, "4:3 显示器\n640×480\n校园/园区信息发布", fc=BLUE, ec=BLUE_E, fs=8.0, bold=True)
    label(ax, 27, 40, "屏幕中心离地 1.1~1.2 m", fs=6.8, color=GREY_E, ha="center")
    box(ax, 47, 44, 9, 14, "开发板\nHX4S20C", fc=GREEN, ec=GREEN_E, fs=7.0)
    label(ax, 51.5, 40, "HDMI_B + TF", fs=6.6, color=GREY_E, ha="center")
    box(ax, 12, 20, 16, 8, "产品立牌\nLGT-S1", fc=TEAL, ec=TEAL_E, fs=7.0)
    box(ax, 65, 50, 28, 20, "控制面板\nS1~S16 / KEY / SW", fc=ORANGE, ec=ORANGE_E, fs=7.6)
    box(ax, 65, 30, 13, 14, "A4 通知\n消防演练", fc=GREY, ec=GREY_E, fs=7.0)
    box(ax, 80, 30, 13, 14, "夹板/工牌\n巡检记录", fc=GREY, ec=GREY_E, fs=7.0)
    for (cx, cy, name) in [(5, 76, "A 机\n广角"), (7, 30, "B 机\n手部"), (58, 6, "C 机\n采集")]:
        ax.plot(cx, cy, marker="^", markersize=8, color=PURPLE_E)
        label(ax, cx + 1.2, cy, name, fs=6.6, color=PURPLE_E, va="center")
    label(ax, 38, 2, "主光 45° 左 / 辅光 45° 右；不要直射屏幕；关顶灯", fs=6.8, color=GREY_E)
    save(fig, "fig_scene_layout.png")


def placeholder(name, title, lines):
    fig, ax = canvas(7.2, 4.5)
    ax.add_patch(Rectangle((2, 2), 96, 96, facecolor="#f7f7f7", edgecolor="#b0b0b0",
                           lw=1.2, linestyle=(0, (6, 4))))
    ax.text(50, 60, title, ha="center", va="center", fontsize=15, color="#555555", fontweight="bold")
    ax.text(50, 40, lines, ha="center", va="center", fontsize=9, color="#777777", linespacing=1.8)
    save(fig, name)


def main():
    fig_design_flow()
    fig_system_block()
    fig_sd_flow()
    fig_image_path()
    fig_audio_path()
    fig_osd_layers()
    fig_control_storage()
    fig_scene_layout()
    placeholder("fig_photo_placeholder.png", "此处插入实物照片",
                "正面 / 斜 45° 全局照\n建议 3000×2000 以上\n保留屏幕、开发板、HDMI_B、TF 卡与供电同框")
    placeholder("fig_screen_placeholder.png", "此处插入屏幕界面照片",
                "品牌封面 / 开机自检 / 信息页 / 播放记录\n四宫格 / 六档特效 / 音频可视化\n建议用采集卡直录 640×480 后裁切")


if __name__ == "__main__":
    main()

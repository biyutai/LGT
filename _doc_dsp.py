"""一次性文档更新（用完即删）：补 Sobel / 直方图均衡 / 音频音效链。

用 newline='' 读写，避免把整份文件的行尾从 LF 改成 CRLF。
"""

from pathlib import Path

README = Path("README.md")
DOC = Path("doc/系统架构与数据通路.md")
AUDIO_MD = Path("_doc_audio.md")

README_PAIRS = [
    ("**特效是 0~6 档逐像素画面特效**", "**特效是 0~8 档逐像素画面特效**"),
    (
        "0 关闭、1 灰度、2 反色、3 棕褐、4 左右镜像、5 上下分屏（下半屏灰度对比）、6 色调分离",
        "0 关闭、1 灰度、2 反色、3 棕褐、4 左右镜像、5 上下分屏（下半屏灰度对比）、6 色调分离、7 Sobel 边缘检测、8 直方图均衡（自动对比度）",
    ),
    (
        "tb_video_effects（画面特效：灰度/反色/棕褐/左右镜像/上下分屏/色调分离）",
        "tb_video_effects（画面特效：灰度/反色/棕褐/左右镜像/上下分屏/色调分离/Sobel/直方图均衡）、tb_audio_dsp（音频音效：低音/明亮/软饱和/回声衰减）",
    ),
    (
        "“操作 正常 → 亮度等级 → 对比度等级 → 特效等级 → 正常”",
        "“操作 正常 → 亮度等级 → 对比度等级 → 特效等级 → 音效等级 → 正常”",
    ),
    (
        "调节模式下 KEY2 加一档、KEY4 减一档；退出后恢复切图和轮播。",
        "调节模式下 KEY2 加一档、KEY4 减一档（音效档另见下条）；退出后恢复切图和轮播。",
    ),
]

DOC_PAIRS = [
    ("（`edit_mode` 0~3）", "（`edit_mode` 0~4）"),
    ("在特效档上加/减一档（0~6，帧边界锁存）", "在特效档上加/减一档（0~8，帧边界锁存）"),
]


def read(p: Path) -> str:
    with open(p, "r", encoding="utf-8", newline="") as f:
        return f.read()


def write(p: Path, text: str) -> None:
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def main() -> None:
    text = read(README)
    for old, new in README_PAIRS:
        if text.count(old) != 1:
            raise SystemExit(f"README 锚点命中 {text.count(old)} 次：{old[:30]}")
        text = text.replace(old, new)
    write(README, text)
    print("README 更新完成")

    text = read(DOC)
    for old, new in DOC_PAIRS:
        if text.count(old) != 1:
            raise SystemExit(f"doc 锚点命中 {text.count(old)} 次：{old[:30]}")
        text = text.replace(old, new)

    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.startswith("| 6 |") and "色调分离" in line:
            lines[i + 1:i + 1] = [
                "| 7 | Sobel 边缘检测 | 两块 2×640×8 行缓存取上一行/上上行 + 3×3 窗口，Gx/Gy 绝对值和折半饱和 |",
                "| 8 | 直方图均衡 | 整帧亮度直方图，消隐期算累积分布映射表，下一帧按亮度差平移三通道（保色相） |",
            ]
            break
    else:
        raise SystemExit("没找到特效表格里的色调分离行")
    text = "\n".join(lines)

    anchor = "本轮顺带修掉两个一直卡着的收尾项："
    if text.count(anchor) != 1:
        raise SystemExit("找不到收尾项锚点")
    text = text.replace(anchor, read(AUDIO_MD).rstrip("\n") + "\n\n" + anchor)
    write(DOC, text)
    print("架构文档更新完成")


if __name__ == "__main__":
    main()

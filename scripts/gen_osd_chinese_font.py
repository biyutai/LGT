"""Generate the small fixed OSD bitmap font from Noto Sans SC (SIL OFL).

产出两部分（都写进 video_osd_overlay.v 的 GENERATED STATUS FONT 区块）：
  1. status_glyph_index：16 位字符码 -> 8 位字形索引（0 号留给空格/未知），只占几十个 LUT；
  2. status_font_rom：4096 x 16bit 点阵 ROM（256 个 16x16 字模），地址 = {索引[7:0], 行[3:0]}，写成 initial
     常量后由 TD 综合成 eRAM（BRAM），把原来散在 LUT 里的上万位常量搬到块 RAM。

256 槽的余量：状态栏原有用字约 90，产品化文案（产品名/版本/读卡提示/信息页/故障提示）
再加 A–Z 与 . - / : 共约 68 个，合计约 158 ≤ 255。
"""

from argparse import ArgumentParser
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


# 运行 + ":" 用于状态栏第 4 行的运行时间戳；特效/自检/帧/读/秒/缓/存/欠/载 用于
# 特效档位与系统自检行
CHARS = "图片播放自动手演示亮度等级对比字幕尺寸显示原样大缩小拉伸操作正常转场淡入左右揭菱形溶解"
CHARS += "0123456789X%音量运行:自检特效帧读秒缓存欠载"
# 产品化文案用字（封面/信息页/读卡提示）
CHARS += "同频多媒体终端版本正在读取卡来源健康率命中退出张"
CHARS += "系统拨下"
# 统一产品身份：LGT 音画同频数字标牌 / LGT-S1 / FW 1.0.0
CHARS += "标准牌型号固件插即人值守储"
# 开机自检页文案用字（顺带补齐原封面/信息页文案里漏掉的字：卡、目、定、回…——
# 生成前的自检断言就是被这些字触发的，之前它们上屏是空框）
CHARS += "开机挂载环回锁定扫描参数就绪检查通析写目单档"
# 数字标牌节目单（PLAYLIST.TXT）与 TEXT.TXT 字幕用字。改节目单文案前先用
# scripts/check_playlist_font.py 查缺字，把缺字补到这一行再重跑本脚本。
CHARS += "交互信切参四备布局息拍换新无智查欢画看能节观设路迎重需面驱驻"
# 16x16 里画 ASCII：大写字母与常见分隔符（滚动字幕仍走 5x7 ROM，这里供信息页/封面/节目单字幕中英混排）
# 节目单字幕是用户自己写的（如 KEY1、LGT、HDMI），所以 26 个字母要齐，不再删未用字母
CHARS += "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-/:"
CHARS += "分辨率"
CHARS += "记录时间事件启失败移除错误未知暂"
# 主题：校园/园区多媒体信息终端（封面/信息页/节目单）
CHARS += "公区发告园均复展巡应急恢日果校用维衡陈"

# 静态文案：信息页 10 行 + 封面 4 行，每行 32 列。
# 动态数值不在 ROM 里——RTL 会复用现有的四个行函数（尺寸/操作/转场/音量/自检/时间戳）现画，
# 这样信息页几乎不增加 LUT，只多一块放静态文案的 BRAM。
PAGE_ROWS = [
    "LGT 音画同频数字标牌",
    "型号 LGT-S1  固件 1.0.0",
    "校园/园区多媒体信息终端",
    "",                       # 图片 / 播放 / 亮度 / 对比度 / 字幕（复用主行）
    "",                       # 尺寸 / 显示 / 操作 / 转场（复用细节行）
    "",                       # 音量（复用音量行）
    "",                       # 自检 V A S 帧率读图缓存欠载（复用自检行）
    "",                       # 运行 HH:MM:SS（复用第 4 行的时间戳分支）
    "-" * 32,
    "SW1 拨下 退出",
]
COVER_ROWS = [
    "LGT 音画同频数字标牌",
    "校园/园区多媒体信息终端",
    "插卡即播 无人值守",
    "正在读取 TF 卡",
]
LOG_ROWS = [
    "播放记录",
    "时间   事件    图片",
    "暂无播放记录",
]
GUIDE_ROWS = [
    "NO CONTENT",
    "PUT BMP ON TF CARD",
    "CHECK FAT32 FORMAT",
    "SW1 DEVICE INFO",
]
# 开机自检页：上电后（品牌封面之后、进片之前）逐项打勾，失败仍进播放。
# 每行 32 列，行号 20~27；右侧的健康点与计数由 RTL 现画（这里是静态标签文字）。
# 行尾留出固定列给"状态点"（第 16 列）与计数（第 17 列起），见 video_osd_overlay 的自检页分支。
SELFCHECK_ROWS = [
    "开机自检 系统就绪检查",
    "TF 卡挂载",
    "图片扫描",
    "SDRAM 读写环回",
    "音频通路",
    "HDMI 显示锁定",
    "存储自检",
    "节目单解析",
]
SOURCE = Path(__file__).resolve().parents[1] / "user_source/hdl_source/video/video_osd_overlay.v"
BEGIN = "    // BEGIN GENERATED STATUS FONT\n"
END = "    // END GENERATED STATUS FONT"


def bitmap_hex(char: str, font: ImageFont.FreeTypeFont) -> str:
    image = Image.new("L", (16, 16))
    ImageDraw.Draw(image).text((8, 8), char, font=font, fill=255, anchor="mm")
    return "".join(
        f"{sum(1 << (15 - x) for x in range(16) if image.getpixel((x, y)) >= 128):04x}"
        for y in range(16)
    )


def main() -> None:
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--font", type=Path, default=Path("C:/Windows/Fonts/Noto Sans SC (TrueType).otf"))
    args = parser.parse_args()
    font = ImageFont.truetype(str(args.font), 16)
    chars = list(dict.fromkeys(CHARS))
    # 自检：本脚本自己写的静态文案（信息页/封面/自检页）用到的字必须都在字库里，
    # 否则上屏就是一个空框，而且不会有任何报错——这类问题只能靠这里拦住。
    missing = sorted({c for text in PAGE_ROWS + COVER_ROWS + LOG_ROWS + GUIDE_ROWS + SELFCHECK_ROWS for c in text
                      if c != " " and c != "-" and c not in chars})
    if missing:
        raise SystemExit("add these characters to CHARS first: " + "".join(missing))
    # 字形索引不再用 180 项 case（TD 会铺成 LUT 锥），改成 4 bank x 256 的表：
    # 低 10 位寻址，高 2 位选 bank，只有低 10 位冲突的码才在 override case 里修正。
    pairs = [(ord(char), n + 1) for n, char in enumerate(chars)]
    buckets: dict[int, list[tuple[int, int]]] = {}
    for code, idx in pairs:
        buckets.setdefault(code & 0x3FF, []).append((code, idx))
    glyph_map_lines = ["    // GLYPH_MAP_GENERATED: 4 x 256 banks + collision overrides."]
    for bank in range(4):
        glyph_map_lines.append(f"    reg [7:0] glyph_map{bank} [0:255];")
    glyph_map_lines += [
        "    reg [15:0] glyph_code_q;",
        "    reg [3:0]  glyph_row_sel_q;",
        "    reg [7:0]  glyph_index_q, glyph_index_d;",
        "    integer gm_i;",
    ]
    for bank in range(4):
        glyph_map_lines.append("    initial begin")
        glyph_map_lines.append(
            f"        for (gm_i = 0; gm_i < 256; gm_i = gm_i + 1) glyph_map{bank}[gm_i] = 8'd0;")
        for low in range(bank * 256, (bank + 1) * 256):
            if low in buckets:
                glyph_map_lines.append(
                    f"        glyph_map{bank}[8'd{low & 255}] = 8'd{buckets[low][0][1]};")
        glyph_map_lines.append("    end")
    glyph_map_lines += [
        "",
        "    always @* begin",
        "        glyph_index_d = glyph_index_q;",
        "        case (glyph_code_q)",
    ]
    for low in range(1024):
        if len(buckets.get(low, [])) > 1:
            for code, idx in buckets[low]:
                glyph_map_lines.append(f"            16'h{code:04x}: glyph_index_d = 8'd{idx};")
    glyph_map_lines += [
        "            default: ;",
        "        endcase",
        "    end",
        "",
        "    // Simulation-only reference for testbenches; RTL uses the registered path.",
        "    function [7:0] status_glyph_index;",
        "        input [15:0] code;",
        "        begin",
        "            case (code[9:8])",
    ]
    for bank in range(4):
        glyph_map_lines.append(
            f"                2'd{bank}: status_glyph_index = glyph_map{bank}[code[7:0]];")
    glyph_map_lines += [
        "                default: status_glyph_index = 8'd0;",
        "            endcase",
        "            case (code)",
    ]
    for low in range(1024):
        if len(buckets.get(low, [])) > 1:
            for code, idx in buckets[low]:
                glyph_map_lines.append(
                    f"                16'h{code:04x}: status_glyph_index = 8'd{idx};")
    glyph_map_lines += [
        "                default: ;",
        "            endcase",
        "        end",
        "    endfunction",
    ]
    rom_lines = []
    for n, char in enumerate(chars):
        rows = bitmap_hex(char, font)
        for row in range(16):
            rom_lines.append(
                f"        status_font_rom[12'd{(n + 1) * 16 + row}] = 16'h{rows[row * 4:row * 4 + 4]};"
                f" // {char} row{row}")
    # 静态文案查表：{行[4:0], 列[4:0]} -> 16 位字符码。
    # 用 case 表而不是 BRAM：128 个字符的稀疏表综合出来只有上百个 LUT（参考现字库
    # 2048 项约 1300 LUT 的量级），但可以和其他行函数同拍出码，不用多一拍流水、不会错位。
    # 信息页占行 0~9，封面固定排在行 16~19（中间留空，和 RTL 的地址约定一致）
    page_rows = (list(PAGE_ROWS) + list(LOG_ROWS) + list(GUIDE_ROWS[:3]) +
                 list(COVER_ROWS) + list(SELFCHECK_ROWS) + ["", "", GUIDE_ROWS[3]])
    page_lines = []
    for line_no, text in enumerate(page_rows):
        padded = (text + " " * 32)[:32]
        for col, char in enumerate(padded):
            if char == " ":
                continue
            page_lines.append(f"        page_text_rom[10'd{line_no * 32 + col}] = 16'h{ord(char):04x}; // 行{line_no} 列{col} {char}")
    generated = (
        BEGIN
        + "    // 汉字码 -> 字形索引（0 = 空格/未知）\n"
        + "\n".join(glyph_map_lines) + "\n"
        + "\n"
        + "    // 16x16 点阵 ROM：地址 = {索引[7:0], 行[3:0]}，4096 x 16bit\n"
        + "    reg [15:0] status_font_rom [0:4095]; // synthesis ram_style = bram\n"
        + "    integer font_init_i;\n"
        + "    initial begin\n"
        + "        for (font_init_i = 0; font_init_i < 4096; font_init_i = font_init_i + 1)\n"
        + "            status_font_rom[font_init_i] = 16'd0;\n"
        + "\n".join(rom_lines) + "\n"
        + "    end\n"
        + "\n"
        + "    // 静态文案 ROM：行 0~9 = 信息页（产品名/版本/分隔线/提示），行 16~19 = 封面，\n"
        + "    // 每行 32 列，值是 16 位字符码（0 = 空白）。放 BRAM：case 表会把面积顶爆（实测 slice 超限）。\n"
        + "    reg [15:0] page_text_rom [0:1023]; // synthesis ram_style = bram\n"
        + "    integer page_init_i;\n"
        + "    initial begin\n"
        + "        for (page_init_i = 0; page_init_i < 1024; page_init_i = page_init_i + 1)\n"
        + "            page_text_rom[page_init_i] = 16'd0;\n"
        + "\n".join(page_lines) + "\n"
        + "    end\n"
    )
    source = SOURCE.read_bytes().decode("utf-8").replace("\r\n", "\n")
    if source.count(BEGIN) != 1 or source.count(END) != 1:
        raise ValueError("status font markers missing or duplicated")
    first = source.index(BEGIN)
    last = source.index(END, first)
    SOURCE.write_bytes((source[:first] + generated + source[last:]).encode("utf-8"))


if __name__ == "__main__":
    main()

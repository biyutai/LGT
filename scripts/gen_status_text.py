"""从 video_osd_overlay.v 的四个状态栏 case 函数里抽取静态文案，生成 status_text_rom。

为什么要有这个脚本：状态栏四行的静态文案现在写死在 case 函数里（产出 16 位 Unicode 码，
再过 status_glyph_index 映射成 8 位字模索引）。把它搬进 BRAM 文本表时，如果靠手工转写，
96 个格子里任何一格错位都会变成"屏幕上少一个/错一个字"。这里改成从现有 RTL 机械抽取：

  * 静态项（`16'hXXXX` / `"c"` 常量）→ 查 status_glyph_index 里现成的码→索引映射，写进表；
  * 动态项（含信号、多行三元、函数调用）→ 表里留空格（索引 0），并在报告里列出来，
    由 RTL 的动态覆盖逻辑补上；
  * 认不出来的 case 项一律报出来，宁可让脚本失败也不静默丢格子。

默认只打印（不改任何文件）：打印生成的 RTL 初始化块 + 动态槽位清单。
用法：python scripts/gen_status_text.py [--rtl <path>] [--emit-block]
"""

import argparse
import pathlib
import re
import sys

ROWS_PER_LINE = 32          # 状态栏每行 32 个字符槽（glyph_lx[8:4]）

# 行分配：0/1/2 = 状态栏前三行，3 = 第四行时间戳变体，4 = 第四行自检变体
FUNC_ROWS = [
    ("status_main_code", None, 0, "状态栏行0 / 信息页第3行"),
    ("status_detail_code", None, 1, "状态栏行1 / 信息页第4行"),
    ("status_volume_code", None, 2, "状态栏行2 / 信息页第5行"),
    ("status_line4_code", 0, 3, "状态栏行3 时间戳变体 / 信息页第7行"),
    ("status_line4_code", 1, 4, "状态栏行3 自检变体 / 信息页第6行"),
]

# 顶层 case 项：形如 `12: status_xxx_code=...` 或 `22: if (...) status_xxx_code=...`。
# 注意槽位分枝里还有**嵌套** case（如 slot 14/15 的 `case (scale)`），那些 `0:`/`1:` 不是槽位，
# 所以解析时必须跟 case/endcase 的嵌套深度，只在深度 1 上认项。
ITEM_LINE_RE = re.compile(
    r"^(\d+(?:\s*,\s*\d+)*)\s*:\s*(?:else\s+)?(?:if\s*\([^)]*\)\s*)*(.*)$"
)
# 切分时项之间的 ';' 会被下一项的起始匹配吃掉，所以分号是可选的
STATIC_HEX_RE = re.compile(r"^16'h([0-9a-fA-F]{4})\s*;?\s*(?://.*)?$")
STATIC_CHAR_RE = re.compile(r'^"(.{1,2})"\s*;?\s*(?://.*)?$')
MAP_RE = re.compile(r"16'h([0-9a-fA-F]{4}):\s*status_glyph_index=8'd(\d+);")


def extract_function(body: str, name: str) -> str:
    start = body.index(f"function [15:0] {name};")
    end = body.index("endfunction", start)
    return body[start:end]


def variant_slices(func: str, sel: int | None):
    """status_line4_code 内部按 sel 分成两段；其余函数整段返回。"""
    if sel is None:
        return [(func, None)]
    head = func.index("if (!sel) begin")
    mid = func.index("end else begin")
    tail = func.rindex("end\n    endfunction") if "end\n    endfunction" in func else len(func)
    if sel == 0:
        return [(func[head:mid], 0)]
    return [(func[mid:tail], 1)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", default="user_source/hdl_source/video/video_osd_overlay.v")
    parser.add_argument("--emit-block", action="store_true", help="打印可粘贴的 RTL 初始化块")
    args = parser.parse_args()

    rtl = pathlib.Path(args.rtl)
    body = rtl.read_text(encoding="utf-8")

    code_to_index = {int(c, 16): int(n) for c, n in MAP_RE.findall(body)}
    if not code_to_index:
        print("ERROR: 没找到 status_glyph_index 映射", file=sys.stderr)
        return 1

    table = {}          # (row, slot) -> index
    dynamic = []        # (row, slot, rhs)
    unclassified = []   # (func, line)

    for fname, sel, row, label in FUNC_ROWS:
        func = extract_function(body, fname)
        for chunk, _ in variant_slices(func, sel):
            # 一行里可能并排写多个 case 项（如 "0: ...=16'h56fe; 1: ...=16'h7247;"），
            # 所以按 `;` 再把一行拆成若干片段，每片单独判定。
            # default: 项没有槽位号，天然跳过（它等价于空格 = 索引 0，正是表里的默认值）。
            depth = 0
            matched = 0
            for raw in chunk.splitlines():
                line = raw.strip()
                # 嵌套 case 可能写在同一行里（如 `14: case (scale)`）：先把它记成动态槽位，
                # 再加深一层，后面那些 `0:`/`1:`（原/放/缩/拉…）才不会被当成槽位。
                head = re.match(r"^(\d+(?:\s*,\s*\d+)*)\s*:\s*case\b", line)
                if head:
                    for slot in re.split(r"[,\s]+", head.group(1).strip()):
                        if slot and int(slot) < ROWS_PER_LINE:
                            dynamic.append((row, int(slot), line))
                    depth += 1
                    matched += 1
                    continue
                if re.search(r"\bcase\b", line):
                    depth += 1
                    continue
                if re.search(r"\bendcase\b", line):
                    depth -= 1
                    continue
                if depth != 1:
                    continue
                # 一行里可能并排写多个项（"0: ...; 1: ...;"），按"项起始位置"切开
                starts = [(m.start(), m.group(1))
                          for m in re.finditer(r"(?:^|;\s*)(\d+(?:\s*,\s*\d+)*)\s*:", line)]
                for i, (pos, slot_text) in enumerate(starts):
                    end = starts[i + 1][0] if i + 1 < len(starts) else len(line)
                    segment_raw = line[pos:end]
                    # 带 `if (...)` 门控的项（哪怕赋值是常量）也是动态的：
                    # 例如 `30: if (transition==3) status_detail_code=16'h89e3;` 只在溶解时是「解」。
                    guarded = bool(re.search(r"\bif\b", segment_raw))
                    segment = re.sub(r"^[;\s]*(\d+(?:\s*,\s*\d+)*)\s*:\s*", "", segment_raw)
                    segment = re.sub(r"^(?:else\s+)?(?:if\s*\([^)]*\)\s*)*", "", segment)
                    segment = re.sub(r"^status_\w+_code\s*=\s*", "", segment)
                    # 保留行尾的 ';'：静态判定用得上（"16'h56fe;" / "\" \";"）
                    segment = segment.strip()
                    slots = [int(s) for s in re.split(r"[,\s]+", slot_text.strip()) if s]
                    matched += 1
                    rhs = " ".join(segment.split())
                    hexm = STATIC_HEX_RE.match(rhs) if not guarded else None
                    charm = STATIC_CHAR_RE.match(rhs) if not guarded else None
                    for slot in slots:
                        if slot >= ROWS_PER_LINE:
                            continue
                        if hexm:
                            code = int(hexm.group(1), 16)
                            table[(row, slot)] = code_to_index.get(code, 0)
                        elif charm:
                            table[(row, slot)] = code_to_index.get(ord(charm.group(1)), 0)
                        else:
                            dynamic.append((row, slot, rhs))
            if matched == 0:
                unclassified.append((fname, f"（{sel}）这个变体里一个 case 项都没解析到"))

    print(f"# 映射表条目：{len(code_to_index)} 个码")
    print(f"# 静态格子：{len(table)} 个")
    print(f"# 动态格子：{len(dynamic)} 个")
    print()
    print("## 动态槽位清单（表里留空格，RTL 覆盖逻辑填）")
    for row, slot, rhs in sorted(dynamic):
        print(f"row{row} slot{slot:2d} <- {rhs}")
    if unclassified:
        print()
        print("## 未识别项（需要人工处理）")
        for fname, raw in unclassified:
            print(f"{fname}: {raw}")
        return 2
    print()
    print("## 静态文案（预览：索引 -> 行内文本）")
    for _, _, row, label in FUNC_ROWS:
        cells = [table.get((row, s), 0) for s in range(ROWS_PER_LINE)]
        print(f"row{row} ({label}): " + " ".join(f"{c:3d}" for c in cells))

    if args.emit_block:
        print()
        print("## RTL 初始化块")
        print("    reg [7:0] status_text_rom [0:255]; // synthesis ram_style = bram")
        print("    integer status_text_i;")
        print("    initial begin")
        print("        for (status_text_i = 0; status_text_i < 256; status_text_i = status_text_i + 1)")
        print("            status_text_rom[status_text_i] = 8'd0;")
        for _, _, row, label in FUNC_ROWS:
            for slot in range(ROWS_PER_LINE):
                idx = table.get((row, slot), 0)
                if idx == 0:
                    continue
                print(f"        status_text_rom[8'd{row * ROWS_PER_LINE + slot}] = 8'd{idx};"
                      f" // 行{row} 列{slot} {label}")
        print("    end")
    return 0


if __name__ == "__main__":
    sys.exit(main())

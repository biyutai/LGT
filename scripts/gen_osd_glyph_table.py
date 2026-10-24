# Replace the OSD status_glyph_index case with a 256-entry low-byte table
# plus a small override case for codes whose low byte collides.
# Run once after changing scripts/gen_osd_chinese_font.py's CHARS list.
import pathlib
import re

path = pathlib.Path("user_source/hdl_source/video/video_osd_overlay.v")
text = path.read_text(encoding="utf-8")
if "GLYPH_MAP_GENERATED" in text:
    print("already generated")
    raise SystemExit(0)

start = text.index("    function [7:0] status_glyph_index;")
end = text.index("    endfunction", start) + len("    endfunction")
func = text[start:end]
pairs = [(int(a, 16), int(b)) for a, b in
         re.findall(r"16'h([0-9a-fA-F]{4})\s*:\s*status_glyph_index\s*=\s*8'd(\d+)", func)]
if len(pairs) < 100:
    raise SystemExit("unexpected mapping size: %d" % len(pairs))

ADDR_BITS = 10
BANK_BITS = 2
BANK_SIZE = 1 << (ADDR_BITS - BANK_BITS)
TABLE_SIZE = 1 << ADDR_BITS

buckets = {}
for code, idx in pairs:
    buckets.setdefault(code & (TABLE_SIZE - 1), []).append((code, idx))

lines = []
lines.append("    // GLYPH_MAP_GENERATED: 4 x 256 banks + collision overrides.")
for b in range(4):
    lines.append("    reg [7:0] glyph_map%d [0:255];" % b)
lines.append("    reg [15:0] glyph_code_q;")
lines.append("    reg [3:0]  glyph_row_sel_q;")
lines.append("    reg [7:0]  glyph_index_q, glyph_index_d;")
lines.append("    integer gm_i;")
for q in range(4):
    lines.append("    initial begin")
    lines.append("        for (gm_i = 0; gm_i < 256; gm_i = gm_i + 1) glyph_map%d[gm_i] = 8'd0;" % q)
    for low in range(q * 256, (q + 1) * 256):
        if low in buckets:
            lines.append("        glyph_map%d[8'd%d] = 8'd%d;" %
                         (q, low & 255, buckets[low][0][1]))
    lines.append("    end")
lines.append("")
lines.append("    always @* begin")
lines.append("        glyph_index_d = glyph_index_q;")
lines.append("        case (glyph_code_q)")
for low in range(TABLE_SIZE):
    if len(buckets.get(low, [])) > 1:
        for code, idx in buckets[low]:
            lines.append("            16'h%04x: glyph_index_d = 8'd%d;" % (code, idx))
lines.append("            default: ;")
lines.append("        endcase")
lines.append("    end")
lines.append("")
lines.append("    // Simulation-only reference for testbenches; RTL uses the registered path.")
lines.append("    function [7:0] status_glyph_index;")
lines.append("        input [15:0] code;")
lines.append("        begin")
lines.append("            case (code[9:8])")
for b in range(4):
    lines.append("                2'd%d: status_glyph_index = glyph_map%d[code[7:0]];" % (b, b))
lines.append("                default: status_glyph_index = 8'd0;")
lines.append("            endcase")
lines.append("            case (code)")
for low in range(TABLE_SIZE):
    if len(buckets.get(low, [])) > 1:
        for code, idx in buckets[low]:
            lines.append("                16'h%04x: status_glyph_index = 8'd%d;" % (code, idx))
lines.append("                default: ;")
lines.append("            endcase")
lines.append("        end")
lines.append("    endfunction")

new_text = text[:start] + "\n".join(lines) + text[end:]
path.write_bytes(new_text.encode("utf-8"))
collisions = sum(1 for v in buckets.values() if len(v) > 1)
print("entries", len(pairs), "buckets", len(buckets), "collision buckets", collisions)

"""生成 user_source/hdl_source/audio/sine_lut.v：1024 点正弦表（只存 1/4 周期 256 点，其余对称得到）

用法：python scripts/gen_sine_lut.py
第 i 点（0~255）= round(32767 * sin((i + 0.5) / 256 * pi / 2))
取 (i + 0.5) 而不是 i，四个象限镜像后正好是 sin((k + 0.5) * 2pi / 1024)，k = 0~1023，没有重复点。
"""
import math
import pathlib

N = 256
AMP = 32767
OUT = pathlib.Path(__file__).resolve().parent.parent / 'user_source' / 'hdl_source' / 'audio' / 'sine_lut.v'


def q(i):
    return int(math.floor(AMP * math.sin((i + 0.5) / N * math.pi / 2) + 0.5))


rows = '\n'.join(f"        8'd{i:<3d}: mag <= 15'd{q(i)};" for i in range(N))

OUT.write_text(f"""// 正弦查找表：1024 点 / 周期，16 位有符号，输出寄存一拍
// 由 scripts/gen_sine_lut.py 生成，不要手改
//
// 只存 1/4 周期 256 点幅度，按象限镜像、取负得到整周期：
//   相位 [9:8] = 0  1  2  3
//   查表下标     i  ~i  i  ~i
//   符号         +  +   -  -
// 第 k 点 = round(32767 * sin((k + 0.5) * 2pi / 1024))
module sine_lut (
    input  wire               clk,
    input  wire        [9:0]  phase,
    output wire signed [15:0] sine
);

wire [7:0] idx = phase[8] ? ~phase[7:0] : phase[7:0];

reg [14:0] mag;
reg        neg;

always @(posedge clk) begin
    neg <= phase[9];
    case (idx)
{rows}
    endcase
end

assign sine = neg ? -$signed({{1'b0, mag}}) : $signed({{1'b0, mag}});

endmodule
""", encoding='utf-8', newline='\n')
print(f'wrote {OUT}  max={q(N - 1)}')

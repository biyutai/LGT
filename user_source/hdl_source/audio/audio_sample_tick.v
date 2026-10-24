// 音频采样节拍：在任意时钟下产生平均频率精确为 FS 的单拍脉冲（分数分频）
//
// 每拍累加 FS，超过 CLK_HZ 就减去 CLK_HZ 并输出一拍 tick。
// 25MHz / 48kHz 时节拍间隔是 520 或 521 拍，每 25000 拍恰好 48 个，
// 所以 HDMI 音频时钟恢复包的 CTS = 25000 × 48 / 48 = 25000 固定不抖动。
// 第 6b 步像素时钟改为 25.2MHz 后正好每 525 拍一个，CTS = 25200。
module audio_sample_tick #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer FS     = 48_000
)(
    input  wire clk,
    input  wire rst,          // 高电平有效，与 clk 同步撤销
    output reg  tick
);

reg  [31:0] acc;
wire [31:0] acc_next = acc + FS;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        acc  <= 32'd0;
        tick <= 1'b0;
    end else if (acc_next >= CLK_HZ) begin
        acc  <= acc_next - CLK_HZ;
        tick <= 1'b1;
    end else begin
        acc  <= acc_next;
        tick <= 1'b0;
    end
end

endmodule

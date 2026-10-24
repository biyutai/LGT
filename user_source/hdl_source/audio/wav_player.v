// WAV 播放：每个 48kHz 节拍从 audio_sdram_stream 的 FIFO 取一个字（{左, 右} 各 16 位），
// 扩成 24 位送 HDMI 发射 IP。没有数据（刚开始、或 SDRAM 一时没跟上）就输出静音并计数。
// 输出时序与 audio_tone_gen 相同：节拍后第 2 拍 audio_valid，两者可以直接二选一。
//
// 读空计数（只在 active 且已经取到过第一个样本之后才计）：
//   underrun_cnt：取样时 FIFO 为空
module wav_player (
    input  wire        clk,                 // video_clk
    input  wire        rst,
    input  wire        sample_tick,         // 48kHz 单拍脉冲
    input  wire        active,              // WAV 已就绪，正在播放（只在这时统计）

    output wire        pop,
    input  wire [31:0] data,                // pop 之后下一拍有效
    input  wire        empty,

    output reg         audio_valid,
    output reg  [23:0] audio_left,
    output reg  [23:0] audio_right,
    output reg         played,              // 与 audio_valid 同拍：这一拍送出的是真实 WAV 样本（不是读空补的静音）
    output reg  [7:0]  underrun_cnt         // 饱和不回绕
);

reg tick_d;
reg got;                                     // 上一拍确实取了数
reg started;                                 // active 之后已经取到过样本

assign pop = sample_tick & ~empty;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        tick_d       <= 1'b0;
        got          <= 1'b0;
        started      <= 1'b0;
        audio_valid  <= 1'b0;
        audio_left   <= 24'd0;
        audio_right  <= 24'd0;
        played       <= 1'b0;
        underrun_cnt <= 8'd0;
    end else begin
        tick_d      <= sample_tick;
        got         <= pop;
        audio_valid <= tick_d;
        played      <= tick_d & got;
        if (!active)
            started <= 1'b0;
        if (tick_d) begin
            audio_left  <= got ? {data[31:16], 8'd0} : 24'd0;
            audio_right <= got ? {data[15:0],  8'd0} : 24'd0;
            if (got) begin
                if (active)
                    started <= 1'b1;
            end else if (active && started && underrun_cnt != 8'hFF) begin
                underrun_cnt <= underrun_cnt + 8'd1;
            end
        end
    end
end

endmodule

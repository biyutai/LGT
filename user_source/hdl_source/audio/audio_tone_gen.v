// 测试音发生器：48kHz 正弦波，C4 → C5 八个音循环（do re mi fa so la si do）
//
// 直接输出 PCM 采样给 HDMI 发射 IP（audio_valid + 左右声道 24 位），不经过 I2S。
// 直接数字频率合成：每个采样节拍相位累加一次，相位高 10 位查 1024 点正弦表。
// 替换官方 hdmi_audio_tone_i2s_64fs（方波）+ I2S_receiver。
module audio_tone_gen #(
    parameter integer NOTE_SAMPLES = 24_000,   // 每个音持续的采样数：24000 = 0.5s @ 48kHz
    parameter integer VOL_SHIFT    = 1         // 音量：满幅右移位数，1 = -6dBFS
)(
    input  wire        clk,
    input  wire        rst,                     // 高电平有效，与 clk 同步撤销
    input  wire        enable,                  // WAV 播放期间暂停备用测试音
    input  wire        sample_tick,             // 48kHz 单拍脉冲（audio_sample_tick）

    output reg         audio_valid,             // 每个采样一拍，与数据对齐
    output reg  [23:0] audio_left,
    output reg  [23:0] audio_right
);

// 相位增量 = 频率 × 2^32 / 48000，四舍五入
// 频率按十二平均律：f = 440 × 2^((MIDI 音号 - 69) / 12)
function [31:0] note_inc;
    input [2:0] idx;
    begin
        case (idx)
            3'd0:    note_inc = 32'd23409859;   // do  C4 261.6256Hz
            3'd1:    note_inc = 32'd26276679;   // re  D4 293.6648Hz
            3'd2:    note_inc = 32'd29494575;   // mi  E4 329.6276Hz
            3'd3:    note_inc = 32'd31248413;   // fa  F4 349.2282Hz
            3'd4:    note_inc = 32'd35075158;   // so  G4 391.9954Hz
            3'd5:    note_inc = 32'd39370534;   // la  A4 440.0000Hz 
            3'd6:    note_inc = 32'd44191930;   // si  B4 493.8833Hz
            default: note_inc = 32'd46819719;   // do  C5 523.2511Hz
        endcase
    end
endfunction

reg [31:0] phase;
reg [2:0]  note;
reg [31:0] note_cnt;
reg        tick_d;                              // 查表延迟 1 拍
wire       tone_tick = sample_tick && enable;

wire signed [15:0] sine;

sine_lut u_sine_lut (
    .clk   (clk),
    .phase (phase[31:22]),
    .sine  (sine)
);

// 节拍到来时用当前相位查表，然后相位前进
always @(posedge clk or posedge rst) begin
    if (rst) begin
        phase    <= 32'd0;
        note     <= 3'd0;
        note_cnt <= 32'd0;
    end else if (tone_tick) begin
        phase <= phase + note_inc(note);
        if (note_cnt == NOTE_SAMPLES - 1) begin
            note_cnt <= 32'd0;
            note     <= note + 3'd1;
        end else begin
            note_cnt <= note_cnt + 32'd1;
        end
    end
end

wire signed [23:0] sample = $signed({sine, 8'd0}) >>> VOL_SHIFT;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        tick_d      <= 1'b0;
        audio_valid <= 1'b0;
        audio_left  <= 24'd0;
        audio_right <= 24'd0;
    end else begin
        tick_d      <= tone_tick;
        audio_valid <= tick_d;
        if (tick_d) begin
            audio_left  <= sample;
            audio_right <= sample;
        end
    end
end

endmodule

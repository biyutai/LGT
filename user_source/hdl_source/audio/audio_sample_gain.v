`timescale 1ns/1ps

module audio_sample_gain (
    input  wire clk,
    input  wire rst,
    input  wire sample_valid,
    input  wire signed [23:0] left_in,
    input  wire signed [23:0] right_in,
    input  wire [2:0] volume_level,
    output wire signed [23:0] left_out,
    output wire signed [23:0] right_out
);
    reg [8:0] volume_gain;
    reg [8:0] volume_target;
    wire signed [9:0] volume = {1'b0,volume_gain};
    wire signed [33:0] left_volume = left_in * volume;
    wire signed [33:0] right_volume = right_in * volume;
    assign left_out = left_volume >>> 8;
    assign right_out = right_volume >>> 8;

    always @* begin
        case (volume_level)
            3'd0: volume_target = 9'd0;
            3'd1: volume_target = 9'd90;
            3'd2: volume_target = 9'd179;
            3'd3: volume_target = 9'd192;
            default: volume_target = 9'd256;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst)
            volume_gain <= 9'd256;
        else if (sample_valid) begin
            if (volume_gain < volume_target)
                volume_gain <= volume_gain + 9'd1;
            else if (volume_gain > volume_target)
                volume_gain <= volume_gain - 9'd1;
        end
    end
endmodule

// 音频数字音效：5 段一阶分频图形均衡 + 输出限幅。
// 挂在音量增益之后、HDMI 音频输入之前，按 48kHz 样本节拍工作。
//   0 原声（逐位旁路）/ 1 低音增强 / 2 明亮 / 3 低音 + 明亮；>3 按 3 处理。
// 5 个频段 = 100Hz 低通 / (300-100) / (1k-300) / (8k-1k) / 8k 以上；
// 每段用 0.5x / 1x / 1.5x / 2x 四档增益（移位+加法），5 段相加恒等于原信号。
// 这是面积受限时保留 5 段现场可调能力的实现；IIR 版本 audio_eq.v 仍留在仓库，
// 频响更精确但集成后 mslice 超限（5,165 > 4,900），未例化。
module audio_dsp (
    input  wire               clk,
    input  wire               rst,
    input  wire               sample_valid,
    input  wire [2:0]         effect,
    input  wire signed [23:0] left_in,
    input  wire signed [23:0] right_in,
    output reg  signed [23:0] left_out,
    output reg  signed [23:0] right_out,
    output reg                out_valid
);
    localparam signed [26:0] CLIP_MAX = 27'sd8388607;     // 2^23 − 1
    reg signed [23:0] lp1_l, lp2_l, lp3_l, lp4_l;
    reg signed [23:0] lp1_r, lp2_r, lp3_r, lp4_r;

    wire signed [23:0] b0_l = lp1_l;
    wire signed [23:0] b1_l = lp2_l - lp1_l;
    wire signed [23:0] b2_l = lp3_l - lp2_l;
    wire signed [23:0] b3_l = lp4_l - lp3_l;
    wire signed [23:0] b4_l = left_in - lp4_l;
    wire signed [23:0] b0_r = lp1_r;
    wire signed [23:0] b1_r = lp2_r - lp1_r;
    wire signed [23:0] b2_r = lp3_r - lp2_r;
    wire signed [23:0] b3_r = lp4_r - lp3_r;
    wire signed [23:0] b4_r = right_in - lp4_r;

    function [1:0] gain_code;
        input [2:0] band;
        input [2:0] eff;
        begin
            case (eff)
                3'd1: case (band)
                    3'd0: gain_code = 2'd2;   // +6dB
                    3'd1: gain_code = 2'd2;   // +6dB（3 档粗调）
                    3'd2: gain_code = 2'd1;
                    3'd3: gain_code = 2'd1;
                    default: gain_code = 2'd0; // -6dB
                endcase
                3'd2: case (band)
                    3'd0: gain_code = 2'd0;
                    3'd1: gain_code = 2'd1;
                    3'd2: gain_code = 2'd1;
                    3'd3: gain_code = 2'd1;
                    default: gain_code = 2'd2;
                endcase
                default: case (band)
                    3'd0: gain_code = 2'd2;
                    3'd1: gain_code = 2'd2;
                    3'd2: gain_code = 2'd1;
                    3'd3: gain_code = 2'd1;
                    default: gain_code = 2'd2;
                endcase
            endcase
        end
    endfunction

    function signed [26:0] band_gain;
        input signed [23:0] x;
        input [1:0] g;
        reg signed [26:0] x27;
        begin
            x27 = {{3{x[23]}}, x};   // 3+24 = 27 位，负数必须补齐符号位
            case (g)
                2'd0: band_gain = x27 >>> 1;
                2'd1: band_gain = x27;
                default: band_gain = x27 <<< 1;
            endcase
        end
    endfunction

    wire [2:0] eff = (effect > 3'd3) ? 3'd3 : effect;
    wire signed [26:0] sum_l =
        band_gain(b0_l, gain_code(3'd0, eff)) +
        band_gain(b1_l, gain_code(3'd1, eff)) +
        band_gain(b2_l, gain_code(3'd2, eff)) +
        band_gain(b3_l, gain_code(3'd3, eff)) +
        band_gain(b4_l, gain_code(3'd4, eff));
    wire signed [26:0] sum_r =
        band_gain(b0_r, gain_code(3'd0, eff)) +
        band_gain(b1_r, gain_code(3'd1, eff)) +
        band_gain(b2_r, gain_code(3'd2, eff)) +
        band_gain(b3_r, gain_code(3'd3, eff)) +
        band_gain(b4_r, gain_code(3'd4, eff));

    // 输出限幅：超过满量程就顶住，避免增强后溢出回绕
    function signed [23:0] sat24;
        input signed [26:0] x;
        begin
            if (x > CLIP_MAX)
                sat24 = CLIP_MAX[23:0];
            else if (x < -CLIP_MAX)
                sat24 = -CLIP_MAX[23:0];
            else
                sat24 = x[23:0];
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lp1_l <= 24'sd0; lp2_l <= 24'sd0; lp3_l <= 24'sd0; lp4_l <= 24'sd0;
            lp1_r <= 24'sd0; lp2_r <= 24'sd0; lp3_r <= 24'sd0; lp4_r <= 24'sd0;
            left_out  <= 24'sd0;
            right_out <= 24'sd0;
            out_valid <= 1'b0;
        end else if (sample_valid) begin
            lp1_l <= lp1_l + ((left_in  - lp1_l) >>> 6);
            lp2_l <= lp2_l + ((left_in  - lp2_l) >>> 5);
            lp3_l <= lp3_l + ((left_in  - lp3_l) >>> 3);
            lp4_l <= lp4_l + ((left_in  - lp4_l) >>> 1);
            lp1_r <= lp1_r + ((right_in - lp1_r) >>> 6);
            lp2_r <= lp2_r + ((right_in - lp2_r) >>> 5);
            lp3_r <= lp3_r + ((right_in - lp3_r) >>> 3);
            lp4_r <= lp4_r + ((right_in - lp4_r) >>> 1);
            if (effect == 3'd0) begin
                left_out  <= left_in;
                right_out <= right_in;
            end else begin
                left_out  <= sat24(sum_l);
                right_out <= sat24(sum_r);
            end
            out_valid <= 1'b1;
        end else begin
            out_valid <= 1'b0;
        end
    end
endmodule

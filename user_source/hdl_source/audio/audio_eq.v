`timescale 1ns/1ps

// 5 段 IIR 均衡引擎（100Hz 低架 / 300 / 1k / 3k 峰值 / 8k 高架）。
// 系数表 audio_eq_coeff_rom.v 由 scripts/gen_audio_eq_coeffs.py 生成（Q3.13）。
// 每拍一个 18x16 MAC，左右声道并行两个乘法器；一个样本 5 段 x 5 拍 = 25 拍，
// 48kHz 节拍有 525 拍预算。节点值 18 位 = 16 位内容 + 2 位小数；输出再左移 6 位回 24 位。
// effect 0 走逐位旁路；1/2/3 是预设曲线，>3 按 3 处理。
module audio_eq (
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
    localparam signed [17:0] NODE_MAX = 18'sd131071;
    localparam signed [17:0] NODE_MIN = -18'sd131072;
    localparam signed [23:0] OUT_MAX  = 24'sd8388607;
    localparam signed [23:0] OUT_MIN  = -24'sd8388607;

    localparam [2:0] E_IDLE = 3'd0, E_LOAD = 3'd1, E_READ = 3'd2,
                     E_PRE = 3'd3, E_MAC = 3'd4, E_UPDATE = 3'd5;
    reg [2:0] state, band, mac;
    reg [2:0] eff_q;
    reg signed [17:0] x_l, x_r;
    reg signed [35:0] acc_l, acc_r;
    reg [7:0] coef_base, coef_addr;
    wire signed [15:0] coef_q;

    reg signed [17:0] sx1 [0:9];
    reg signed [17:0] sx2 [0:9];
    reg signed [17:0] sy1 [0:9];
    reg signed [17:0] sy2 [0:9];

    audio_eq_coeff_rom u_coeff_rom (
        .clk(clk), .addr(coef_addr), .dout(coef_q)
    );

    // 预设曲线 -> 3dB 网格下标（4 = 0dB）
    function [3:0] gain_index;
        input [2:0] b;
        input [2:0] e;
        begin
            case (e)
                3'd1: case (b)
                    3'd0: gain_index = 4'd6;   // +6
                    3'd1: gain_index = 4'd5;   // +3
                    3'd2: gain_index = 4'd4;   //  0
                    3'd3: gain_index = 4'd4;
                    default: gain_index = 4'd3; // -3
                endcase
                3'd2: case (b)
                    3'd0: gain_index = 4'd3;   // -3
                    3'd1: gain_index = 4'd4;
                    3'd2: gain_index = 4'd4;
                    3'd3: gain_index = 4'd5;   // +3
                    default: gain_index = 4'd6; // +6
                endcase
                default: case (b)
                    3'd0: gain_index = 4'd6;
                    3'd1: gain_index = 4'd5;
                    3'd2: gain_index = 4'd4;
                    3'd3: gain_index = 4'd5;
                    default: gain_index = 4'd6;
                endcase
            endcase
        end
    endfunction

    wire [7:0] base_now = band * 8'd45 + {4'd0,gain_index(band,eff_q)} * 8'd5;
    wire [3:0] bi_l = {band,1'b0};
    wire [3:0] bi_r = {band,1'b1};

    wire signed [17:0] term_x_l = (mac == 3'd0) ? x_l :
                                  (mac == 3'd1) ? sx1[bi_l] :
                                  (mac == 3'd2) ? sx2[bi_l] : 18'sd0;
    wire signed [17:0] term_y_l = (mac == 3'd3) ? sy1[bi_l] :
                                  (mac == 3'd4) ? sy2[bi_l] : 18'sd0;
    wire signed [17:0] term_x_r = (mac == 3'd0) ? x_r :
                                  (mac == 3'd1) ? sx1[bi_r] :
                                  (mac == 3'd2) ? sx2[bi_r] : 18'sd0;
    wire signed [17:0] term_y_r = (mac == 3'd3) ? sy1[bi_r] :
                                  (mac == 3'd4) ? sy2[bi_r] : 18'sd0;

    (* dsp_style = "yes" *) wire signed [33:0] mul_x_l = coef_q * term_x_l;
    (* dsp_style = "yes" *) wire signed [33:0] mul_y_l = coef_q * term_y_l;
    (* dsp_style = "yes" *) wire signed [33:0] mul_x_r = coef_q * term_x_r;
    (* dsp_style = "yes" *) wire signed [33:0] mul_y_r = coef_q * term_y_r;

    wire signed [35:0] yfull_l = (acc_l + 36'sd4096) >>> 13;
    wire signed [35:0] yfull_r = (acc_r + 36'sd4096) >>> 13;
    wire signed [17:0] y_l = (yfull_l > NODE_MAX) ? NODE_MAX :
                             (yfull_l < NODE_MIN) ? NODE_MIN : yfull_l[17:0];
    wire signed [17:0] y_r = (yfull_r > NODE_MAX) ? NODE_MAX :
                             (yfull_r < NODE_MIN) ? NODE_MIN : yfull_r[17:0];
    wire signed [29:0] y24_full_l = {{12{y_l[17]}},y_l} <<< 6;
    wire signed [29:0] y24_full_r = {{12{y_r[17]}},y_r} <<< 6;
    wire signed [23:0] y24_l = (y24_full_l > OUT_MAX) ? OUT_MAX :
                               (y24_full_l < OUT_MIN) ? OUT_MIN : y24_full_l[23:0];
    wire signed [23:0] y24_r = (y24_full_r > OUT_MAX) ? OUT_MAX :
                               (y24_full_r < OUT_MIN) ? OUT_MIN : y24_full_r[23:0];

    wire signed [23:0] in_l_rnd = left_in  + 24'sd32;
    wire signed [23:0] in_r_rnd = right_in + 24'sd32;
    wire signed [17:0] x18_l = in_l_rnd[23:6];
    wire signed [17:0] x18_r = in_r_rnd[23:6];

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= E_IDLE; band <= 3'd0; mac <= 3'd0; eff_q <= 3'd0;
            x_l <= 18'sd0; x_r <= 18'sd0;
            acc_l <= 36'sd0; acc_r <= 36'sd0;
            coef_base <= 8'd0; coef_addr <= 8'd0;
            left_out <= 24'sd0; right_out <= 24'sd0; out_valid <= 1'b0;
            for (i = 0; i < 10; i = i + 1) begin
                sx1[i] <= 18'sd0; sx2[i] <= 18'sd0;
                sy1[i] <= 18'sd0; sy2[i] <= 18'sd0;
            end
        end else begin
            out_valid <= 1'b0;
            case (state)
                E_IDLE: if (sample_valid) begin
                    eff_q <= (effect >= 3'd3) ? 3'd3 : effect;
                    if (effect == 3'd0) begin
                        // 原声逐位旁路，滤波器状态不动
                        left_out  <= left_in;
                        right_out <= right_in;
                        out_valid <= 1'b1;
                    end else begin
                        x_l   <= x18_l;
                        x_r   <= x18_r;
                        band  <= 3'd0;
                        acc_l <= 36'sd0;
                        acc_r <= 36'sd0;
                        state <= E_LOAD;
                    end
                end
                E_LOAD: begin
                    coef_base <= base_now;
                    coef_addr <= base_now;
                    acc_l <= 36'sd0;
                    acc_r <= 36'sd0;
                    state <= E_READ;
                end
                E_READ: begin
                    // 地址寄存器与 ROM 各有一拍延迟：E_PRE 让首系数 rom[base] 在 E_MAC0 稳定
                    state <= E_PRE;
                end
                E_PRE: begin
                    coef_addr <= coef_base + 8'd1;
                    mac   <= 3'd0;
                    state <= E_MAC;
                end
                E_MAC: begin
                    if (mac < 3'd5) begin
                        if (mac < 3'd3) begin
                            acc_l <= acc_l + mul_x_l;
                            acc_r <= acc_r + mul_x_r;
                        end else begin
                            acc_l <= acc_l - mul_y_l;
                            acc_r <= acc_r - mul_y_r;
                        end
                        // 地址寄存器 + ROM 寄存器共两拍：这里要提前两格
                        coef_addr <= coef_base + {5'd0,mac} + 8'd2;
                        mac <= mac + 3'd1;
                    end else
                        state <= E_UPDATE;
                end
                E_UPDATE: begin
                    sx2[bi_l] <= sx1[bi_l];
                    sx1[bi_l] <= x_l;
                    sx2[bi_r] <= sx1[bi_r];
                    sx1[bi_r] <= x_r;
                    sy2[bi_l] <= sy1[bi_l];
                    sy1[bi_l] <= y_l;
                    sy2[bi_r] <= sy1[bi_r];
                    sy1[bi_r] <= y_r;
                    if (band < 3'd4) begin
                        x_l   <= y_l;
                        x_r   <= y_r;
                        band  <= band + 3'd1;
                        state <= E_LOAD;
                    end else begin
                        left_out  <= y24_l;
                        right_out <= y24_r;
                        out_valid <= 1'b1;
                        state     <= E_IDLE;
                    end
                end
                default: state <= E_IDLE;
            endcase
        end
    end
endmodule

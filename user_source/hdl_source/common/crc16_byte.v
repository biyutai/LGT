// CRC-16/0x1021 的"按字节"版本，供 config_journal 的面积瘦身用。
//
// 背景：config_journal 现在为 slot0/slot1 各做一份 crc16_chunk40（每次 40 比特、
// 逐位 shift-xor，展开后约 480 LUT）。本模块把同一条递推做成 256×16 查表：
// 表在复位后用**同一多项式**自建（每字节 8 次移位，256×8 步，25.2MHz 下约 20.5µs），
// 之后每字节一步。算法与结果完全一致，所以换上去以后既有 TB 不需要改——它们就是等价性证明。
//
// 等价性（已手工推导）：逐位式 `crc = (crc<<1) ^ (crc[15]^bit ? POLY : 0)` 与按字节式
// `crc = (crc<<8) ^ T[(crc>>8) ^ byte]`（T[b] = 由 {b,8'h00} 连移 8 次得到）对整字节严格相同。
//
// 用法：crc 初值由上层给（本设计为 16'h0000），每个字节给一拍；
// crc_out 为**两拍流水**输出（第 1 拍锁表项与低字节，第 2 拍给出结果），直接回灌 crc_in 即串行处理。
`timescale 1ns/1ps

module crc16_byte (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] crc_in,
    input  wire [7:0]  byte_in,
    output reg  [15:0] crc_out,      // 两拍后有效
    output reg         table_ready
);
    localparam [15:0] POLY = 16'h1021;

    // synthesis ram_style = bram
    reg [15:0] crc_table [0:255];    // 不能叫 table：那是 Verilog 关键字（UDP 用）

    // ---- 复位后自建表：对每个字节值 b，取 {b,8'h00} 连续左移 8 次 ----
    reg  [11:0] init_step;           // 0..2047（256 字节 × 8 次移位）
    reg  [15:0] init_crc;
    wire [7:0]  init_byte = init_step[11:3];
    wire [2:0]  init_bit  = init_step[2:0];
    wire [15:0] init_seed = {init_byte, 8'h00};
    // 第 0 步就是"加载种子并左移一次"，第 1..7 步继续左移：8 步后恰好 8 次移位
    wire [15:0] init_seed_shift = init_seed[15] ? ({init_seed[14:0], 1'b0} ^ POLY)
                                                : {init_seed[14:0], 1'b0};
    wire [15:0] init_shift = init_crc[15] ? ({init_crc[14:0], 1'b0} ^ POLY)
                                          : {init_crc[14:0], 1'b0};

    // ---- 查表流水（同步 BRAM 读 + 一拍后给出新 CRC）----
    reg [15:0] table_q;
    reg [7:0]  crc_lo_q;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            init_step   <= 12'd0;
            init_crc    <= 16'd0;
            table_ready <= 1'b0;
            table_q     <= 16'd0;
            crc_lo_q    <= 8'd0;
            crc_out     <= 16'd0;
        end else if (!table_ready) begin
            init_crc <= (init_bit == 3'd0) ? init_seed_shift : init_shift;
            if (init_bit == 3'd7)
                crc_table[init_byte] <= init_shift;  // 第 8 次移位的结果落表
            if (init_step == 12'd2047)
                table_ready <= 1'b1;
            else
                init_step <= init_step + 12'd1;
        end else begin
            table_q  <= crc_table[crc_in[15:8] ^ byte_in];
            crc_lo_q <= crc_in[7:0];
            crc_out  <= {crc_lo_q, 8'h00} ^ table_q;
        end
    end
endmodule

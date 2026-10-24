// 1280x960 → 640x480 的 2x2 均值降采样（独立模块，插在 bmp_read 与缩放器之间）。
//
// 关键设计：**不要自己数脉冲推行列**。SD 扇区边界等处 `bmp_data_wr_en` 会有空拍，
// 数脉冲会让列号整行漂移（探针 tb 里故意丢一拍就能复现：从那一拍起整行都错）。
// 所以像素坐标由调用方给出（bmp_read 的 bmp_pix_pos = {行低位, 列[10:0]}），本模块只做算术。
//
// 三级流水（SD 域只有 20ns、原本余量不到 0.3ns，所以每级都很浅）：
//   ① 配对完成那拍：寄存"两像素的通道和"（每通道一个 9 位加法器）+ 地址 + 行奇偶；
//   ② sum>>1 得配对均值：行对第 1 行写进行缓存，第 2 行读回上一行同列的值；
//   ③ 第二遍的配对均值与行缓存值再平均 → 输出（最后一级是组合输出，操作数都是寄存器）。
`timescale 1ns / 1ps

module bmp_avg2x (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,      // 每个源像素一个脉冲（可能有空拍）
    input  wire [23:0] in_data,       // {R,G,B}
    input  wire [11:0] in_pix_pos,    // {行低位, 列[10:0]}：本像素在源图里的坐标
    output reg         out_valid,     // 每个输出像素一个脉冲
    output reg  [23:0] out_data       // 寄存输出：路径只剩"寄存器→加法器→寄存器"
);
    localparam integer OUT_WIDTH = 640;

    wire [10:0] col_now  = in_pix_pos[10:0];
    wire [9:0]  pair_now = col_now[10:1];        // 配对号 = 列/2（0..639）
    wire        second_row = in_pix_pos[11];     // 行对的第 2 行
    wire        pair_end = in_valid && col_now[0];

    reg [23:0] pair_hold;                        // 配对里"偶像素"的三个通道

    // ---------- ① 只寄存通道和 ----------
    reg [8:0]  sum_b, sum_g, sum_r;
    reg [9:0]  addr_q;
    reg        pair_end_q, second_row_q;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sum_b <= 9'd0; sum_g <= 9'd0; sum_r <= 9'd0;
            addr_q <= 10'd0;
            pair_end_q <= 1'b0;
            second_row_q <= 1'b0;
        end else begin
            pair_end_q   <= pair_end;
            second_row_q <= second_row;
            if (pair_end) begin
                sum_b  <= {1'b0, pair_hold[7:0]}   + {1'b0, in_data[7:0]};
                sum_g  <= {1'b0, pair_hold[15:8]}  + {1'b0, in_data[15:8]};
                sum_r  <= {1'b0, pair_hold[23:16]} + {1'b0, in_data[23:16]};
                addr_q <= pair_now;
            end
        end
    end

    wire [23:0] pair_avg = {sum_r[8:1], sum_g[8:1], sum_b[8:1]};

    // ---------- ② 第一遍写行缓存 / 第二遍读回 ----------
    reg [23:0] line_ram [0:OUT_WIDTH-1]; // synthesis ram_style = block
    reg [23:0] line_q;
    always @(posedge clk) begin
        if (pair_end_q && !second_row_q)
            line_ram[addr_q] <= pair_avg;
        if (pair_end_q && second_row_q)
            line_q <= line_ram[addr_q];
    end

    // ---------- ③ 行间平均 → 输出 ----------
    reg [23:0] pair_avg_q;
    reg        out_en_q;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pair_avg_q <= 24'd0;
            out_en_q   <= 1'b0;
            out_valid  <= 1'b0;
            out_data   <= 24'd0;
        end else begin
            pair_avg_q <= pair_avg;
            out_en_q   <= pair_end_q && second_row_q;
            out_valid  <= out_en_q;
            if (out_en_q)
                out_data <= {(line_q[23:16] + pair_avg_q[23:16]) >> 1,
                             (line_q[15:8]  + pair_avg_q[15:8])  >> 1,
                             (line_q[7:0]   + pair_avg_q[7:0])   >> 1};
        end
    end

    // ---------- 偶像素缓存（只按脉冲工作，与坐标无关） ----------
    always @(posedge clk or posedge rst) begin
        if (rst)
            pair_hold <= 24'd0;
        else if (in_valid && !col_now[0])
            pair_hold <= in_data;
    end
endmodule

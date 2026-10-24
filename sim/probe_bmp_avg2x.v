`timescale 1ns/1ps

// bmp_avg2x：1280x960 → 640x480 的 2x2 均值降采样
// 激励每个源像素给可区分的值：B = 行号*0x20、G 恒 0x33、R = 偶列 0x10 / 奇列 0x30
//   → 行对(0,1) 的输出应为 R=0x20 G=0x33 B=0x10；行对(2,3) 的 B 应为 0x50。
module probe_bmp_avg2x;
localparam integer W = 1280, H = 960;

reg clk = 0, rst = 1, in_valid = 0;
reg [23:0] in_data = 0;
reg [11:0] in_pix_pos = 0;
wire out_valid;
wire [23:0] out_data;

always #5 clk = ~clk;

// 参数已去掉（模块改为按调用方给的坐标工作）
bmp_avg2x dut (
    .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(in_data), .in_pix_pos(in_pix_pos),
    .out_valid(out_valid), .out_data(out_data)
);

integer col, row, outs, bad, bad_b;
reg [7:0] expect_b, first_b;
reg [7:0] expect_r, bad_r;
always @(negedge clk) begin
    if (out_valid) begin
        outs = outs + 1;
        // 期望：R 跟着配对号（每 4 个配对一轮）、B 跟行、G 恒定
        expect_b = (outs <= 640) ? 8'h10 : 8'h50;     // 第 1 个输出行来自源行 0/1，第 2 个来自 2/3
        expect_r = 8'h10 + ((outs - 1) % 4) * 8'h04;
        if (out_data[23:16] != expect_r) begin
            if (bad_r < 3)
                $display("    DBGR k=%0d actual=%02h expected=%02h", outs - 1,
                         out_data[23:16], expect_r);
            bad_r = bad_r + 1;
        end
        if (out_data[15:8] != 8'h33) bad = bad + 1;
        if (out_data[7:0] != expect_b) bad_b = bad_b + 1;
        if (first_b == 8'hff) first_b = out_data[7:0];
    end
end

integer i;
initial begin
    outs = 0; bad = 0; bad_b = 0; bad_r = 0; first_b = 8'hff;
    repeat (3) @(negedge clk); rst = 0;
    // 4 个源行 → 2 个输出行
    for (row = 0; row < 4; row = row + 1) begin
        for (col = 0; col < W; col = col + 1) begin
            // R 跟着配对号变化（每个配对差 4），G 恒定，B 跟着行号
            in_data = {8'h10 + ((col/2) % 4) * 8'h04, 8'h33, row[7:0] * 8'h20};
            // 坐标由调用方给出，所以即使中间有空拍也不会漂（这里留一拍空拍做回归）
            @(negedge clk);
            in_pix_pos = {row[0], col[10:0]};
            in_valid = 1;
            @(posedge clk);
            @(negedge clk); in_valid = 0;
        end
    end
    repeat (20) @(negedge clk);

    if (outs != 2 * 640) $fatal(1, "outs=%0d expected=%0d", outs, 2*640);
    if (bad != 0)        $fatal(1, "R/G wrong in %0d outputs", bad);
    if (bad_r != 0)      $fatal(1, "R (pair index) wrong in %0d outputs", bad_r);
    if (bad_b != 0)      $fatal(1, "B wrong in %0d outputs (first B=%02h)", bad_b, first_b);
    if (first_b != 8'h10) $fatal(1, "first output row B=%02h expected 10", first_b);
    $display("ALL PASSED: 2x2 average downscale (1280x960 -> 640x480)");
    $finish;
end

initial begin #5_000_000; $fatal(1, "avg2x module tb timeout"); end
endmodule

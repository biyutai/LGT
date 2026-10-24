`timescale 1ns/1ps
// video_effects：逐像素画面特效
//（灰度 / 反色 / 棕褐 / 左右镜像 / 上下分屏 / 色调分离 / Sobel 边缘检测 / 直方图均衡）
module tb_video_effects;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, frame_start = 0, de = 1;
    reg [11:0] x = 0, y = 0;
    reg [3:0] effect = 4'd0;
    reg [23:0] rgb_in = 24'h804020;
    wire [23:0] rgb_out;
    integer gray_expected, sepia_r, sepia_g, sepia_b, k;

    video_effects dut (
        .clk(clk), .rst(rst), .frame_start(frame_start), .de(de),
        .x(x), .y(y), .effect_in(effect), .rgb_in(rgb_in), .rgb_out(rgb_out)
    );

    task frame;
        begin
            @(negedge clk); frame_start = 1;
            @(negedge clk); frame_start = 0;
            #1;
        end
    endtask

    task check;
        input [23:0] want;
        input [8*48-1:0] msg;
        begin
            @(posedge clk); @(posedge clk); #1;   // 特效内部是一级流水，多等一拍无妨
            if (rgb_out !== want) begin
                $display("FAIL %0s x=%0d y=%0d got=%h want=%h", msg, x, y, rgb_out, want);
                $fatal(1);
            end
        end
    endtask

    // 送一整行：像素 = 列号的低 8 位（镜像用）
    task send_line;
        begin
            for (k = 0; k < 640; k = k + 1) begin
                @(negedge clk);
                x = k[11:0];
                rgb_in = {16'd0, k[7:0]};
            end
        end
    endtask

    // 送一整行：左半屏一种亮度、右半屏另一种（Sobel 用）
    task send_gray;
        input [7:0] left_v, right_v;
        integer c;
        begin
            for (c = 0; c < 640; c = c + 1) begin
                @(negedge clk);
                x = c[11:0];
                rgb_in = (c < 320) ? {left_v, left_v, left_v} : {right_v, right_v, right_v};
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 0;
        frame();
        check(24'h804020, "effect 0 must pass the picture through");

        // 灰度：和 DUT 同样的 BT.601 定点式 (77R+150G+29B)>>8
        gray_expected = (77 * 128 + 150 * 64 + 29 * 32) >> 8;
        effect = 4'd1; frame();
        check({gray_expected[7:0], gray_expected[7:0], gray_expected[7:0]}, "grayscale");

        effect = 4'd2; frame();
        check(~24'h804020, "invert");

        // 棕褐：移位近似 R=r+g/2+b/4、G=r/2+3g/4+b/4、B=r/4+g/2+b/2
        sepia_r = 128 + 32 + 8;
        sepia_g = 64 + 48 + 8;
        sepia_b = 32 + 32 + 16;
        effect = 4'd3; frame();
        check({sepia_r[7:0], sepia_g[7:0], sepia_b[7:0]}, "sepia matrix");
        rgb_in = 24'hffffff;
        check(24'hffffff, "sepia saturates all three rows");
        rgb_in = 24'h804020;

        // 左右镜像：行缓存写地址 639-x、读地址 x，输出 = 上一行的镜像。
        // 三行都送"像素 = 列号"，第三行连续逐拍（真实时序）核对：
        // 第 k 列应看到上一行的第 (639-k) 列。
        effect = 4'd4; frame();
        send_line();                        // 行 1
        send_line();                        // 行 2（输出已是行 1 的镜像）
        for (k = 0; k < 640; k = k + 1) begin
            @(negedge clk);
            x = k[11:0];
            rgb_in = {16'd0, k[7:0]};
            @(posedge clk); #1;
            if ((k == 2) || (k == 100) || (k == 320) || (k == 600) || (k == 639)) begin
                if (rgb_out !== {16'd0, (639 - k) & 8'hff}) begin
                    $display("FAIL mirror at column %0d: got=%h want=%h", k, rgb_out,
                             {16'd0, (639 - k) & 8'hff});
                    $fatal(1);
                end
            end
        end

        // （"上下分屏" 4'd5 与 "色调分离" 4'd6 已按资源方案删除：面积优先下要挤出余量，
        //  主线不受影响；档位重排后 Sobel 从 7 前移到 5。）
        // 边缘检测：左半屏亮度 0、右半屏 200，单像素差分只在 320 列饱和。
        effect = 4'd5; frame();
        send_gray(8'd0, 8'd200);            // 行 1、2 铺满行缓存
        send_gray(8'd0, 8'd200);
        for (k = 0; k < 640; k = k + 1) begin
            @(negedge clk);
            x = k[11:0];
            rgb_in = (k < 320) ? 24'h000000 : 24'hc8c8c8;
            @(posedge clk); #1;
            if ((k == 100) || (k == 319) || (k == 322) || (k == 600)) begin
                if (rgb_out !== 24'h000000)
                    $fatal(1, "sobel must be black away from the edge (column %0d)", k);
            end else if (k == 320) begin
                if (rgb_out !== 24'hffffff)
                    $fatal(1, "sobel must saturate on the vertical edge (column %0d)", k);
            end
        end

// ---- 以下用例对应未例化的 video_histeq，腾出空间后连例化一起打开 ----
// // 直方图均衡（档 8）：先跑一次建表把之前的统计清零，再统计"一行全 0 + 一行亮度 200"
// // 的 1280 个像素（行尾给低电平让待写回缓存落盘），然后建表核对映射与输出。
// // 这里只统计 1280 个像素（真实一帧是 307200），所以映射值很小，这正是 307200 的 1/240。
// effect = 4'd8; frame();
// de = 1'b0; repeat (300) @(negedge clk);   // 等第一次建表结束并把 bin 清零
// de = 1'b1;
// for (k = 0; k < 640; k = k + 1) begin @(negedge clk); x = k[11:0]; rgb_in = 24'h000000; end
// de = 1'b0; repeat (4) @(negedge clk);
// de = 1'b1;
// for (k = 0; k < 640; k = k + 1) begin @(negedge clk); x = k[11:0]; rgb_in = 24'hc8c8c8; end
// de = 1'b0; repeat (4) @(negedge clk);
// frame();
// repeat (300) @(negedge clk);
// if (!dut.u_histeq.ready)
//     $fatal(1, "histogram equalizer must be ready after one frame");
// // 直方图 bin0 = 640、bin200 = 640；curve[k] = CDF(8k-1) 折算，(640*218)>>18 = 0、
// // (1280*218)>>18 = 1，所以 curve[25]（CDF(199)）= 0、curve[26]（CDF(207)）= 1。
// if (dut.u_histeq.curve[5'd25] !== 8'd0 || dut.u_histeq.curve[5'd26] !== 8'd1 ||
//     dut.u_histeq.curve[5'd31] !== 8'd1 || dut.u_histeq.curve[5'd0] !== 8'd0)
//     $fatal(1, "equalization curve must follow the frame histogram");
// // 亮度 200 的像素落在第 25 段、段内偏移 0：200 + (0 - 200) = 0
// de = 1'b1;
// x = 12'd10; y = 12'd0; rgb_in = 24'hc8c8c8;
// check(24'h000000, "equalized output follows the mapping curve");

        effect = 4'd0; frame(); rgb_in = 24'h804020;
        check(24'h804020, "back to bypass");
        $display("ALL PASSED: pixel picture effects");
        $finish;
    end
endmodule

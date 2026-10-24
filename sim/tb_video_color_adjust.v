`timescale 1ns/1ps
module tb_video_color_adjust;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, frame_start = 0;
    reg [2:0] brightness_level = 2, contrast_level = 2;
    reg [23:0] rgb_in = 24'h204060;
    wire [23:0] rgb_out;
    video_color_adjust dut (
        .clk(clk), .rst(rst), .frame_start(frame_start),
        .brightness_level(brightness_level), .contrast_level(contrast_level),
        .rgb_in(rgb_in), .rgb_out(rgb_out)
    );
    task frame;
        begin @(negedge clk); frame_start=1; @(negedge clk); frame_start=0; #1; end
    endtask
    task check;
        input [23:0] expected;
        begin
            #1;
            if (rgb_out !== expected) begin
                $display("FAIL got=%h expected=%h", rgb_out, expected);
                $fatal(1);
            end
        end
    endtask
    initial begin
        repeat (2) @(negedge clk); rst=0;
        frame(); check(24'h204060);
        brightness_level=3; check(24'h204060); // unchanged within frame
        frame(); check(24'h385878);
        brightness_level=2; contrast_level=0;
        frame(); check(24'h506070);
        contrast_level=1;
        frame(); check(24'h385068);
        contrast_level=3;
        frame(); check(24'h083058);
        contrast_level=4;
        frame(); check(24'h002050);
        brightness_level=0; rgb_in=24'h000000;
        frame(); check(24'h000000);
        brightness_level=4; rgb_in=24'hffffff;
        frame(); check(24'hffffff);
        $display("ALL PASSED: video brightness and contrast");
        $finish;
    end
endmodule

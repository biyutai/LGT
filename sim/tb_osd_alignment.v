`timescale 1ns/1ps
module tb_osd_alignment;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, de = 0;
    reg [11:0] x = 0, y = 0;
    wire [11:0] x_aligned, y_aligned;
    wire de_aligned;
    wire unused_hs, unused_vs, unused_read;
    wire [23:0] unused_rgb;
    integer cycle, checks = 0;
    video_coord_delay dut (.clk(clk), .rst(rst), .x(x), .y(y),
        .x_delayed(x_aligned), .y_delayed(y_aligned));
    video_delay ref_delay (.video_clk(clk), .rst(rst), .read_en(unused_read),
        .read_data(24'd0), .hs(1'b1), .vs(1'b1), .de(de),
        .hs_r(unused_hs), .vs_r(unused_vs), .de_r(de_aligned),
        .vout_data(unused_rgb));

    initial begin
        repeat (3) @(negedge clk);
        rst = 0;
        for (cycle=0; cycle<130; cycle=cycle+1) begin
            @(negedge clk);
            de = (cycle % 32 < 16);
            x = cycle % 16;
            y = cycle / 32;
            #1;
            if (cycle >= 21 && de_aligned) begin
                if (x_aligned !== ((cycle-21)%16) ||
                    y_aligned !== ((cycle-21)/32)) begin
                    $display("FAIL cycle=%0d de=%b x=%0d y=%0d", cycle,
                        de_aligned, x_aligned, y_aligned);
                    $fatal(1);
                end
                checks = checks + 1;
            end
        end
        if (checks < 30) $fatal(1, "insufficient aligned pixels");
        $display("ALL PASSED: %0d aligned video pixels", checks);
        $finish;
    end
endmodule

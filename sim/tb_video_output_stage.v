`timescale 1ns/1ps
module tb_video_output_stage;
    reg clk=0, rst=1, hs=0, vs=0, de=0;
    reg [23:0] rgb=24'd0;
    wire hs_out,vs_out,de_out;
    wire [23:0] rgb_out;
    always #5 clk=~clk;
    video_output_stage dut (
        .clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .hs_out(hs_out),.vs_out(vs_out),.de_out(de_out),.rgb_out(rgb_out)
    );
    initial begin
        @(negedge clk);rst=0;hs=1;vs=1;de=1;rgb=24'h123456;
        @(posedge clk);#1;
        if({hs_out,vs_out,de_out,rgb_out}!=={3'b111,24'h123456})
            $fatal(1,"first active pixel must keep its sync and RGB together");
        @(negedge clk);hs=0;vs=0;de=0;rgb=24'hfedcba;
        @(posedge clk);#1;
        if({hs_out,vs_out,de_out,rgb_out}!=={3'b000,24'hfedcba})
            $fatal(1,"blanking and RGB must advance together");
        $display("ALL PASSED: registered video data and sync alignment");
        $finish;
    end
endmodule

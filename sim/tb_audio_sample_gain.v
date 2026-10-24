`timescale 1ns/1ps
module tb_audio_sample_gain;
    reg clk=0,rst=1,sample_valid=0;
    always #5 clk=~clk;
    reg signed [23:0] left_in, right_in;
    reg [2:0] volume;
    wire [23:0] left_out, right_out;
    audio_sample_gain dut (
        .clk(clk),.rst(rst),.sample_valid(sample_valid),
        .left_in(left_in),.right_in(right_in),.volume_level(volume),
        .left_out(left_out),.right_out(right_out)
    );
    task expect;
        input [23:0] left_value,right_value;
        begin
            #1;
            if(left_out!==left_value || right_out!==right_value)
                $fatal(1,"gain mismatch got=%h/%h expected=%h/%h",
                       left_out,right_out,left_value,right_value);
        end
    endtask
    task samples;
        input integer count;
        begin
            sample_valid=1;
            repeat(count) @(negedge clk);
            sample_valid=0;#1;
        end
    endtask
    initial begin
        left_in=24'sd4000000;right_in=-24'sd4000000;
        volume=3'd4;
        repeat(2) @(negedge clk);rst=0;
        expect(24'd4000000,-24'sd4000000);
        volume=3'd1;samples(256);expect(24'd1406250,-24'sd1406250);
        volume=3'd2;samples(256);expect(24'd2796875,-24'sd2796875);
        volume=3'd3;samples(256);expect(24'd3000000,-24'sd3000000);
        volume=3'd0;samples(256);expect(24'd0,24'd0);
        left_in=24'sh7fffff;right_in=24'sh800000;
        volume=3'd4;samples(256);expect(24'h7fffff,24'h800000);
        $display("ALL PASSED: signed stereo volume gain");
        $finish;
    end
endmodule

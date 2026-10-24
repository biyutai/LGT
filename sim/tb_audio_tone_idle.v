`timescale 1ns/1ps
module tb_audio_tone_idle;
    reg clk=0,rst=1,wav_ready=0,tick=0;
    wire valid;
    wire [23:0] left,right;
    reg [31:0] frozen_phase;
    always #5 clk=~clk;
    audio_tone_gen dut (
        .clk(clk),.rst(rst),.sample_tick(tick),.enable(!wav_ready),
        .audio_valid(valid),.audio_left(left),.audio_right(right)
    );
    initial begin
        repeat(3) @(negedge clk);rst=0;
        @(negedge clk);tick=1;
        @(negedge clk);tick=0;
        repeat(3) @(negedge clk);
        frozen_phase=dut.phase;
        wav_ready=1;
        repeat(8) begin
            @(negedge clk);tick=1;
            @(negedge clk);tick=0;
        end
        repeat(3) @(negedge clk);
        if(dut.phase!==frozen_phase || valid)
            $fatal(1,"fallback tone must not advance while WAV is active");
        wav_ready=0;
        @(negedge clk);tick=1;
        @(negedge clk);tick=0;
        repeat(3) @(negedge clk);
        if(dut.phase===frozen_phase || !left || left!==right)
            $fatal(1,"fallback tone must resume when WAV becomes unavailable");
        $display("ALL PASSED: idle fallback tone and resume");
        $finish;
    end
endmodule

`timescale 1ns/1ps
module tb_wav_early_manual;
    tb_wav_load #(.EARLY_MANUAL_TEST(1)) test();
endmodule

`timescale 1ns / 1ps
module tb_wav_first_lap;
    tb_wav_load #(.RESIDENT_TEST(1), .FIRST_LAP_TEST(1)) test();
endmodule

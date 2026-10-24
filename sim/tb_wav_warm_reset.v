`timescale 1ns/1ps
module tb_wav_warm_reset;
    tb_wav_load #(.WARM_RESET_TEST(1)) test();
endmodule

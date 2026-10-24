`timescale 1ns/1ps
module tb_single_card_mode;
    tb_fat32_virtual_disk #(.PRODUCT_MODE(1)) test();
endmodule

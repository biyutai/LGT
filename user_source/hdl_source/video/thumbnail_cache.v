`timescale 1ns/1ps

module thumbnail_cache #(
    parameter integer WIDTH = 640,
    parameter integer HEIGHT = 480
) (
    input  wire        thumb_mode,
    input  wire        focus_enable,
    input  wire [1:0]  focus_index,
    input  wire [23:0] full_rgb,
    input  wire [3:0]  full_valid_mask,
    input  wire [11:0] x,
    input  wire [11:0] y,
    output reg  [23:0] rgb,
    output wire        active
);
    wire right = x >= WIDTH/2;
    wire bottom = y >= HEIGHT/2;
    wire [1:0] bank = {bottom,right};
    wire [8:0] local_x = right ? x - WIDTH/2 : x;
    wire [7:0] local_y = bottom ? y - HEIGHT/2 : y;
    assign active = thumb_mode && x < WIDTH && y < HEIGHT;

    always @* begin
        rgb = full_valid_mask[bank] ? full_rgb : 24'h101820;
        if (focus_enable && bank == focus_index &&
            (local_x < 4 || local_x >= WIDTH/2-4 ||
             local_y < 4 || local_y >= HEIGHT/2-4))
            rgb = 24'h00e5ff;
        if (!active)
            rgb = 24'd0;
    end
endmodule

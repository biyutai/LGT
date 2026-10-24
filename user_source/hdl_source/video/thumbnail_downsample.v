`timescale 1ns/1ps

module thumbnail_downsample #(
    parameter integer WIDTH = 640,
    parameter integer HEIGHT = 480
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        in_valid,
    input  wire [23:0] in_rgb,
    output reg         word_valid,
    output reg  [31:0] word_data
);
    reg [9:0] x;
    reg [8:0] y;
    reg [15:0] first_pixel;
    wire [15:0] rgb565 = {in_rgb[23:19],in_rgb[15:10],in_rgb[7:3]};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x <= 10'd0;
            y <= 9'd0;
            first_pixel <= 16'd0;
            word_valid <= 1'b0;
            word_data <= 32'd0;
        end else if (start) begin
            x <= 10'd0;
            y <= 9'd0;
            first_pixel <= 16'd0;
            word_valid <= 1'b0;
        end else begin
            word_valid <= 1'b0;
            if (in_valid) begin
                if (!y[0] && !x[0]) begin
                    if (!x[1])
                        first_pixel <= rgb565;
                    else begin
                        word_data <= {first_pixel,rgb565};
                        word_valid <= 1'b1;
                    end
                end
                if (x == WIDTH-1) begin
                    x <= 10'd0;
                    if (y != HEIGHT-1)
                        y <= y + 1'b1;
                end else
                    x <= x + 1'b1;
            end
        end
    end
endmodule

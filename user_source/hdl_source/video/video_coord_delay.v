`timescale 1ns/1ps

module video_coord_delay #(
    parameter integer LATENCY = 21
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [11:0] x,
    input  wire [11:0] y,
    output wire [11:0] x_delayed,
    output wire [11:0] y_delayed
);
    reg [11:0] x_pipe [0:LATENCY-1];
    reg [11:0] y_pipe [0:LATENCY-1];
    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i=0; i<LATENCY; i=i+1) begin
                x_pipe[i] <= 12'd0;
                y_pipe[i] <= 12'd0;
            end
        end else begin
            x_pipe[0] <= x;
            y_pipe[0] <= y;
            for (i=1; i<LATENCY; i=i+1) begin
                x_pipe[i] <= x_pipe[i-1];
                y_pipe[i] <= y_pipe[i-1];
            end
        end
    end
    assign x_delayed = x_pipe[LATENCY-1];
    assign y_delayed = y_pipe[LATENCY-1];
endmodule

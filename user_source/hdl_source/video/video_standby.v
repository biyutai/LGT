`timescale 1ns/1ps

// 待机/屏保计时：连续 IDLE_SECONDS 秒没有用户操作、也没有换卡，就拉高 standby；
// 任意操作或换卡立即清零。顶层用 standby 把显示切回品牌封面（video_startup_screen）。
module video_standby #(
    parameter integer IDLE_SECONDS = 60
) (
    input  wire clk,
    input  wire rst,
    input  wire tick_1s,
    input  wire activity,
    input  wire card_change,
    input  wire manual_mode,
    output reg  standby
);
    reg [15:0] idle_sec;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            idle_sec <= 16'd0;
            standby  <= 1'b0;
        end else if (!manual_mode || activity || card_change) begin
            idle_sec <= 16'd0;
            standby  <= 1'b0;
        end else if (tick_1s) begin
            if ({1'b0,idle_sec} + 17'd1 >= IDLE_SECONDS)
                standby <= 1'b1;
            else
                idle_sec <= idle_sec + 16'd1;
        end
    end
endmodule

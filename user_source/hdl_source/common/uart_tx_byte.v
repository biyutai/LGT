`timescale 1ns/1ps

// 单字节 UART 发送器（从 top_tf_hdmi_audio.v 抽出来，便于精简状态行单独仿真）
module uart_tx_byte #(
    parameter integer CLKS_PER_BIT = 219
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy,
    output reg        done
);
    localparam integer COUNT_BITS = (CLKS_PER_BIT < 2) ? 1 : $clog2(CLKS_PER_BIT);
    reg [COUNT_BITS-1:0] count;
    reg [3:0] bit_index;
    reg [9:0] frame_bits;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            count <= {COUNT_BITS{1'b0}};
            bit_index <= 4'd0;
            frame_bits <= 10'h3ff;
            tx <= 1'b1;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                tx <= 1'b1;
                if (start) begin
                    frame_bits <= {1'b1,data,1'b0};
                    count <= {COUNT_BITS{1'b0}};
                    bit_index <= 4'd0;
                    tx <= 1'b0;
                    busy <= 1'b1;
                end
            end else if (count == CLKS_PER_BIT - 1) begin
                count <= {COUNT_BITS{1'b0}};
                if (bit_index == 4'd9) begin
                    busy <= 1'b0;
                    tx <= 1'b1;
                    done <= 1'b1;
                end else begin
                    bit_index <= bit_index + 4'd1;
                    tx <= frame_bits[bit_index + 4'd1];
                end
            end else
                count <= count + 1'b1;
        end
    end
endmodule

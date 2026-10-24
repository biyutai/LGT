`timescale 1ns/1ps

// 单槽参数记录：复用 w25q64_record_store 的 12 字节记录/擦写/回读校验。
// 记录布局（MSB first）：
//   [95:88] marker 0xA5
//   [87:80] version 0x01
//   [79:48] period（volume_code/brightness/contrast）
//   [47:40] mode（transition）
//   [39:8]  reserved
//   [7:0]   前 11 字节的 8 位字节和
// 单槽比原来的双槽 journal 省一半 LUT；掉电写一半时 marker/checksum 不成立，回默认值。
module config_flash_single #(
    parameter integer CLK_DIV = 4,
    parameter [31:0] ERASE_TIMEOUT_CYCLES = 32'd25_200_000,
    parameter [31:0] PROGRAM_TIMEOUT_CYCLES = 32'd2_520_000,
    parameter [23:0] SLOT_ADDRESS = 24'h7fe000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load_start,
    input  wire        save_start,
    input  wire [31:0] save_period,
    input  wire [7:0]  save_volume,
    input  wire [7:0]  save_mode,
    output reg         busy,
    output reg         load_done,
    output reg         save_done,
    output reg         error,
    output reg  [7:0]  error_code,
    output reg         config_valid,
    output reg  [31:0] active_period,
    output reg  [7:0]  active_volume,
    output reg  [7:0]  active_mode,
    output reg         st_start,
    output reg         st_op_write,
    output reg  [23:0] st_address,
    output reg  [95:0] st_write_data,
    input  wire        st_busy,
    input  wire        st_done,
    input  wire        st_error,
    input  wire [3:0]  st_error_code,
    input  wire [95:0] st_read_data
);
    localparam [7:0] MARKER = 8'ha5;
    localparam [7:0] VERSION = 8'h01;
    localparam [1:0] S_IDLE = 2'd0, S_RD = 2'd1, S_WR = 2'd2;

    reg [1:0] state;
    reg [31:0] save_period_q;
    reg [7:0]  save_mode_q;
    reg [7:0]  save_marker_q;
    wire [87:0] save_head = {save_volume, VERSION, save_period, save_mode, 32'd0};
    wire [7:0]  save_sum  = byte_sum(save_head);
    wire [7:0]  read_sum    = byte_sum(st_read_data[95:8]);
    wire        read_good   = (st_read_data[95:88] == MARKER) &&
                              (st_read_data[7:0] == read_sum);

    function [7:0] byte_sum;
        input [87:0] p;
        integer i;
        reg [7:0] s;
        begin
            s = 8'd0;
            for (i = 0; i < 11; i = i + 1)
                s = s + p[87 - i*8 -: 8];
            byte_sum = s;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            save_period_q <= 32'd0;
            save_mode_q <= 8'd0;
            save_marker_q <= MARKER;
            busy <= 1'b0;
            load_done <= 1'b0;
            save_done <= 1'b0;
            error <= 1'b0;
            error_code <= 8'd0;
            config_valid <= 1'b0;
            active_period <= 32'd0;
            active_volume <= 8'd0;
            active_mode <= 8'd0;
            st_start <= 1'b0;
            st_op_write <= 1'b0;
            st_address <= SLOT_ADDRESS;
            st_write_data <= 96'd0;
        end else begin
            st_start <= 1'b0;
            load_done <= 1'b0;
            save_done <= 1'b0;
            error <= 1'b0;
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (load_start) begin
                        busy <= 1'b1;
                        st_op_write <= 1'b0;
                        st_address <= SLOT_ADDRESS;
                        st_start <= 1'b1;
                        state <= S_RD;
                    end else if (save_start) begin
                        busy <= 1'b1;
                        save_period_q <= save_period;
                        save_mode_q <= save_mode;
                        save_marker_q <= save_volume;
                        st_op_write <= 1'b1;
                        st_address <= SLOT_ADDRESS;
                        st_write_data <= {save_head, save_sum};
                        st_start <= 1'b1;
                        state <= S_WR;
                    end
                end
                S_RD: if (st_done) begin
                    busy <= 1'b0;
                    state <= S_IDLE;
                    if (st_error) begin
                        error <= 1'b1;
                        error_code <= {4'h1,st_error_code};
                        config_valid <= 1'b0;
                    end else begin
                        config_valid <= read_good;
                        active_period <= read_good ? st_read_data[79:48] : 32'd0;
                        active_volume <= read_good ? st_read_data[95:88] : 8'd0;
                        active_mode <= read_good ? st_read_data[47:40] : 8'd0;
                        // 空片/坏记录是首次上电的正常情况，不置 error，只回默认值。
                    end
                    load_done <= 1'b1;
                end
                S_WR: if (st_done) begin
                    busy <= 1'b0;
                    state <= S_IDLE;
                    if (st_error) begin
                        error <= 1'b1;
                        error_code <= {4'h2,st_error_code};
                        config_valid <= 1'b0;
                    end else begin
                        config_valid <= 1'b1;
                        active_period <= save_period_q;
                        active_volume <= save_marker_q;
                        active_mode <= save_mode_q;
                    end
                    save_done <= 1'b1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

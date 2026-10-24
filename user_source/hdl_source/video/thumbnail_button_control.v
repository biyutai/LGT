`timescale 1ns/1ps

module thumbnail_button_control #(
    parameter integer CLK_HZ = 50_000_000
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       key1,
    input  wire       key2,
    input  wire       key3,
    input  wire       confirm_toggle,
    input  wire       confirm_long_toggle,
    output reg        thumb_mode,
    output reg [1:0]  focus_index,
    output reg        select_toggle,
    output reg [1:0]  select_index,
    output reg        mode_short_toggle
);
    localparam integer LONG_CYCLES = CLK_HZ;
    localparam integer DEBOUNCE_CYCLES = CLK_HZ / 50;
    reg [2:0] k2, k3;
    reg [31:0] k3_count;
    reg k3_fired;
    reg k2_prev, k3_prev, confirm_prev;
    reg confirm_long_prev;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            k2 <= 3'b111; k3 <= 3'b111;
            k3_count <= 0; k3_fired <= 1'b0;
            k2_prev <= 1'b1; k3_prev <= 1'b1;
            confirm_prev <= 1'b0;
            confirm_long_prev <= 1'b0;
            thumb_mode <= 1'b0;
            focus_index <= 2'd0;
            select_toggle <= 1'b0;
            select_index <= 2'd0;
            mode_short_toggle <= 1'b0;
        end else begin
            k2 <= {k2[1:0], key2};
            k3 <= {k3[1:0], key3};
            k2_prev <= k2[2];
            k3_prev <= k3[2];
            confirm_prev <= confirm_toggle;
            confirm_long_prev <= confirm_long_toggle;
            if (k3[2] == 1'b0) begin
                if (k3_count < LONG_CYCLES-1) k3_count <= k3_count + 1'b1;
                else if (!k3_fired) begin
                    thumb_mode <= ~thumb_mode;
                    k3_fired <= 1'b1;
                end
            end else begin
                if (!k3_prev && k3[2] && !k3_fired &&
                    k3_count >= DEBOUNCE_CYCLES)
                    mode_short_toggle <= ~mode_short_toggle;
                k3_count <= 0;
                k3_fired <= 1'b0;
            end
            if (thumb_mode && k2_prev && !k2[2])
                focus_index <= focus_index == 2'd3 ? 2'd0 : focus_index + 1'b1;
            if (thumb_mode && confirm_toggle != confirm_prev) begin
                select_index <= focus_index;
                select_toggle <= ~select_toggle;
                thumb_mode <= 1'b0;
            end
            // 缩略图模式下长按 KEY1：只退出浏览，不改变当前显示的图片
            if (thumb_mode && confirm_long_toggle != confirm_long_prev)
                thumb_mode <= 1'b0;
        end
    end
endmodule

// Keys are numbered S1..S16 in display order; keys_down[0] is S1.
module matrix_keypad #(
    parameter integer CLK_HZ = 25_200_000,
    parameter integer ROW_HZ = 1000,
    parameter integer DEBOUNCE_SCANS = 5
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [3:0]  col_n,
    output wire [3:0]  row_drive_low,
    output reg  [15:0] keys_down,
    output reg  [15:0] press_pulse,
    output reg  [15:0] release_pulse
);
    localparam integer ROW_CYCLES = CLK_HZ / ROW_HZ;
    localparam integer COUNT_BITS = DEBOUNCE_SCANS < 2 ? 1 : $clog2(DEBOUNCE_SCANS);
    reg [31:0] row_tick;
    reg [1:0] row_index;
    reg [3:0] col_meta, col_sync;
    reg [11:0] first_rows;
    reg [COUNT_BITS-1:0] mismatch_count [0:15];
    wire [15:0] sampled_keys = {~col_sync, first_rows};
    integer key_index;

    assign row_drive_low = 4'b0001 << row_index;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            row_tick <= 32'd0;
            row_index <= 2'd0;
            col_meta <= 4'hf;
            col_sync <= 4'hf;
            first_rows <= 12'd0;
            keys_down <= 16'd0;
            press_pulse <= 16'd0;
            release_pulse <= 16'd0;
            for (key_index = 0; key_index < 16; key_index = key_index + 1)
                mismatch_count[key_index] <= {COUNT_BITS{1'b0}};
        end else begin
            col_meta <= col_n;
            col_sync <= col_meta;
            press_pulse <= 16'd0;
            release_pulse <= 16'd0;
            if (row_tick == ROW_CYCLES - 1) begin
                row_tick <= 32'd0;
                row_index <= row_index + 1'b1;
                case (row_index)
                    2'd0: first_rows[3:0] <= ~col_sync;
                    2'd1: first_rows[7:4] <= ~col_sync;
                    2'd2: first_rows[11:8] <= ~col_sync;
                    2'd3: begin
                        for (key_index = 0; key_index < 16; key_index = key_index + 1) begin
                            if (sampled_keys[key_index] == keys_down[key_index])
                                mismatch_count[key_index] <= {COUNT_BITS{1'b0}};
                            else if (mismatch_count[key_index] == DEBOUNCE_SCANS - 1) begin
                                keys_down[key_index] <= sampled_keys[key_index];
                                press_pulse[key_index] <= sampled_keys[key_index];
                                release_pulse[key_index] <= ~sampled_keys[key_index];
                                mismatch_count[key_index] <= {COUNT_BITS{1'b0}};
                            end else
                                mismatch_count[key_index] <= mismatch_count[key_index] + 1'b1;
                        end
                    end
                endcase
            end else
                row_tick <= row_tick + 1'b1;
        end
    end
endmodule

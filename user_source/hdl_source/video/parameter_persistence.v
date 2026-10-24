`timescale 1ns/1ps

// Bridges the live OSD parameters to the W25Q64 journal. The Flash service
// owns SPI timing; this module only validates fields and schedules quiet saves.
module parameter_persistence #(
    parameter integer CLK_FREQ_HZ = 25_200_000,
    parameter integer SAVE_DELAY_CYCLES = CLK_FREQ_HZ / 2,
    parameter [7:0] RECORD_MARKER = 8'ha5
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [2:0] current_brightness,
    input  wire [2:0] current_contrast,
    input  wire [1:0] current_transition,
    input  wire [2:0] current_volume,
    input  wire       save_enable,
    output reg  [2:0] loaded_brightness,
    output reg  [2:0] loaded_contrast,
    output reg  [1:0] loaded_transition,
    output reg  [2:0] loaded_volume,
    output reg        apply_pulse,
    output reg        ready,
    output reg        flash_load_start,
    input  wire       flash_load_done,
    input  wire       flash_config_valid,
    input  wire [31:0] flash_period,
    input  wire [7:0] flash_volume,
    input  wire [7:0] flash_mode,
    output reg        flash_save_start,
    output reg [31:0] flash_save_period,
    output reg [7:0]  flash_save_volume,
    output reg [7:0]  flash_save_mode,
    input  wire        flash_save_done,
    input  wire        flash_operation_error,
    output reg        flash_error
);
    localparam [1:0] ST_LOAD = 2'd0, ST_READY = 2'd1, ST_SAVE = 2'd2;
    localparam integer DELAY_BITS = (SAVE_DELAY_CYCLES > 1) ? $clog2(SAVE_DELAY_CYCLES) : 1;
    reg [1:0] state;
    reg load_issued;
    reg [DELAY_BITS-1:0] quiet_count;
    reg retry_blocked;
    reg [2:0] applied_brightness, applied_contrast, applied_volume;
    reg [1:0] applied_transition;
    reg [2:0] observed_brightness, observed_contrast, observed_volume;
    reg [1:0] observed_transition;
    reg [2:0] save_brightness, save_contrast, save_volume_level;
    reg [1:0] save_transition;

    wire loaded_fields_valid = flash_config_valid &&
                                flash_volume == RECORD_MARKER &&
                                flash_period[31:10] == 22'd0 &&
                                flash_period[9:6] <= 4'd5 &&
                                flash_period[5:3] <= 3'd4 &&
                                flash_period[2:0] <= 3'd4 &&
                                flash_mode[7:2] == 6'd0 &&
                                flash_mode[1:0] <= 2'd3;
    wire live_changed = current_brightness != applied_brightness ||
                        current_contrast != applied_contrast ||
                        current_transition != applied_transition ||
                        current_volume != applied_volume;
    wire observation_changed = current_brightness != observed_brightness ||
                               current_contrast != observed_contrast ||
                               current_transition != observed_transition ||
                               current_volume != observed_volume;
    wire [3:0] volume_code = {1'b0,current_volume} + 4'd1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_LOAD;
            load_issued <= 1'b0;
            quiet_count <= {DELAY_BITS{1'b0}};
            retry_blocked <= 1'b0;
            loaded_brightness <= 3'd2;
            loaded_contrast <= 3'd2;
            loaded_transition <= 2'd0;
            loaded_volume <= 3'd4;
            applied_brightness <= 3'd2;
            applied_contrast <= 3'd2;
            applied_transition <= 2'd0;
            applied_volume <= 3'd4;
            observed_brightness <= 3'd2;
            observed_contrast <= 3'd2;
            observed_transition <= 2'd0;
            observed_volume <= 3'd4;
            save_brightness <= 3'd2;
            save_contrast <= 3'd2;
            save_transition <= 2'd0;
            save_volume_level <= 3'd4;
            flash_load_start <= 1'b0;
            flash_save_start <= 1'b0;
            flash_save_period <= 32'd0;
            flash_save_volume <= RECORD_MARKER;
            flash_save_mode <= 8'd0;
            apply_pulse <= 1'b0;
            ready <= 1'b0;
            flash_error <= 1'b0;
        end else begin
            flash_load_start <= 1'b0;
            flash_save_start <= 1'b0;
            apply_pulse <= 1'b0;
            flash_error <= 1'b0;
            case (state)
                ST_LOAD: begin
                    if (!load_issued) begin
                        flash_load_start <= 1'b1;
                        load_issued <= 1'b1;
                    end
                    if (flash_load_done) begin
                        if (flash_operation_error)
                            flash_error <= 1'b1;
                        if (loaded_fields_valid) begin
                            loaded_brightness <= flash_period[5:3];
                            loaded_contrast <= flash_period[2:0];
                            loaded_transition <= flash_mode[1:0];
                            loaded_volume <= flash_period[9:6] == 4'd0 ?
                                             3'd4 : flash_period[8:6] - 3'd1;
                            applied_brightness <= flash_period[5:3];
                            applied_contrast <= flash_period[2:0];
                            applied_transition <= flash_mode[1:0];
                            applied_volume <= flash_period[9:6] == 4'd0 ?
                                              3'd4 : flash_period[8:6] - 3'd1;
                            observed_brightness <= flash_period[5:3];
                            observed_contrast <= flash_period[2:0];
                            observed_transition <= flash_mode[1:0];
                            observed_volume <= flash_period[9:6] == 4'd0 ?
                                               3'd4 : flash_period[8:6] - 3'd1;
                        end else begin
                            loaded_brightness <= 3'd2;
                            loaded_contrast <= 3'd2;
                            loaded_transition <= 2'd0;
                            loaded_volume <= 3'd4;
                            applied_brightness <= 3'd2;
                            applied_contrast <= 3'd2;
                            applied_transition <= 2'd0;
                            applied_volume <= 3'd4;
                            observed_brightness <= 3'd2;
                            observed_contrast <= 3'd2;
                            observed_transition <= 2'd0;
                            observed_volume <= 3'd4;
                        end
                        apply_pulse <= 1'b1;
                        ready <= 1'b1;
                        state <= ST_READY;
                    end
                end
                ST_READY: begin
                    if (observation_changed) begin
                        observed_brightness <= current_brightness;
                        observed_contrast <= current_contrast;
                        observed_transition <= current_transition;
                        observed_volume <= current_volume;
                        quiet_count <= {DELAY_BITS{1'b0}};
                        retry_blocked <= 1'b0;
                    end else if (!save_enable || !live_changed || retry_blocked) begin
                        quiet_count <= {DELAY_BITS{1'b0}};
                    end else if (SAVE_DELAY_CYCLES <= 1 || quiet_count == SAVE_DELAY_CYCLES - 2) begin
                            save_brightness <= current_brightness;
                            save_contrast <= current_contrast;
                            save_transition <= current_transition;
                            save_volume_level <= current_volume;
                            flash_save_period <= {22'd0,volume_code,current_brightness,current_contrast};
                            flash_save_volume <= RECORD_MARKER;
                            flash_save_mode <= {6'd0,current_transition};
                            flash_save_start <= 1'b1;
                            quiet_count <= {DELAY_BITS{1'b0}};
                            state <= ST_SAVE;
                    end else begin
                        quiet_count <= quiet_count + 1'b1;
                    end
                end
                ST_SAVE: begin
                    if (flash_save_done) begin
                        if (flash_operation_error) begin
                            flash_error <= 1'b1;
                            retry_blocked <= 1'b1;
                        end else begin
                            applied_brightness <= save_brightness;
                            applied_contrast <= save_contrast;
                            applied_transition <= save_transition;
                            applied_volume <= save_volume_level;
                        end
                        state <= ST_READY;
                    end
                end
                default: state <= ST_LOAD;
            endcase
        end
    end
endmodule

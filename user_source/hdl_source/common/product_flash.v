`timescale 1ns/1ps

module product_flash #(
    parameter integer SAVE_DELAY_CYCLES = 12_600_000,
    parameter integer LOG_SLOTS = 16,
    parameter integer STORE_CLK_DIV = 4,
    parameter integer POLL_INTERVAL_CYCLES = 5000,
    parameter [31:0] ERASE_TIMEOUT_CYCLES = 25_200_000,
    parameter [31:0] PROGRAM_TIMEOUT_CYCLES = 2_520_000
) (
    input  wire clk,
    input  wire rst,
    input  wire [2:0] current_brightness,
    input  wire [2:0] current_contrast,
    input  wire [1:0] current_transition,
    input  wire [2:0] current_volume,
    input  wire save_enable,
    output wire ready,
    output wire apply_pulse,
    output wire [2:0] loaded_brightness,
    output wire [2:0] loaded_contrast,
    output wire [1:0] loaded_transition,
    output wire [2:0] loaded_volume,
    output wire config_valid,
    output wire flash_error,
    input  wire event_pulse,
    input  wire [2:0] event_kind,
    input  wire [3:0] event_item,
    input  wire [7:0] event_detail,
    input  wire [31:0] uptime_s,
    output wire log_busy,
    output wire scan_done,
    output wire append_done,
    output wire log_error,
    output wire newest_valid,
    output wire [15:0] newest_seq,
    output wire [3:0] newest_slot,
    input  wire rd_start,
    input  wire [3:0] rd_slot,
    output wire rd_done,
    output wire rd_valid,
    output wire [95:0] rd_data,
    output wire spi_cs_n,
    output wire spi_sclk,
    output wire spi_mosi,
    input  wire spi_miso,
    output wire spi_wp_n,
    output wire spi_hold_n
);
    wire load_req, save_req, load_start, save_start;
    wire [31:0] save_period, active_period;
    wire [7:0] save_volume, save_mode, active_volume, active_mode;
    wire param_busy, load_done, save_done, param_error, manager_error;
    wire [7:0] param_error_code;
    wire p_st_start, p_st_write, l_st_start, l_st_write;
    wire [23:0] p_st_addr, l_st_addr, st_addr;
    wire [95:0] p_st_data, l_st_data, st_data;
    wire log_req, log_grant, st_start, st_write;
    wire st_busy, st_done, st_error, st_request_dropped;
    wire [3:0] st_error_code;
    wire [95:0] st_read_data;

    assign flash_error = manager_error | param_error | st_request_dropped;

    parameter_persistence #(.SAVE_DELAY_CYCLES(SAVE_DELAY_CYCLES)) u_params (
        .clk(clk), .rst(rst),
        .current_brightness(current_brightness),
        .current_contrast(current_contrast),
        .current_transition(current_transition),
        .current_volume(current_volume), .save_enable(save_enable),
        .loaded_brightness(loaded_brightness),
        .loaded_contrast(loaded_contrast),
        .loaded_transition(loaded_transition),
        .loaded_volume(loaded_volume), .apply_pulse(apply_pulse),
        .ready(ready), .flash_load_start(load_req),
        .flash_load_done(load_done), .flash_config_valid(config_valid),
        .flash_period(active_period), .flash_volume(active_volume),
        .flash_mode(active_mode), .flash_save_start(save_req),
        .flash_save_period(save_period),
        .flash_save_volume(save_volume), .flash_save_mode(save_mode),
        .flash_save_done(save_done), .flash_operation_error(param_error),
        .flash_error(manager_error)
    );

    config_flash_single #(.SLOT_ADDRESS(24'h7fe000)) u_config (
        .clk(clk), .rst_n(~rst),
        .load_start(load_start), .save_start(save_start),
        .save_period(save_period), .save_volume(save_volume),
        .save_mode(save_mode), .busy(param_busy), .load_done(load_done),
        .save_done(save_done), .error(param_error),
        .error_code(param_error_code), .config_valid(config_valid),
        .active_period(active_period), .active_volume(active_volume),
        .active_mode(active_mode),
        .st_start(p_st_start), .st_op_write(p_st_write),
        .st_address(p_st_addr), .st_write_data(p_st_data),
        .st_busy(st_busy), .st_done(st_done), .st_error(st_error),
        .st_error_code(st_error_code), .st_read_data(st_read_data)
    );

    config_event_log #(.SLOTS(LOG_SLOTS), .LOG_BASE(24'h700000)) u_log (
        .clk(clk), .rst_n(~rst), .event_pulse(event_pulse),
        .event_kind(event_kind), .event_item(event_item),
        .event_detail(event_detail), .uptime_s(uptime_s),
        .busy(log_busy), .scan_done(scan_done),
        .append_done(append_done), .error(log_error), .error_code(),
        .newest_valid(newest_valid), .newest_seq(newest_seq),
        .newest_slot(newest_slot), .rd_start(rd_start),
        .rd_slot(rd_slot), .rd_done(rd_done), .rd_valid(rd_valid),
        .rd_data(rd_data), .bus_req(log_req), .bus_grant(log_grant),
        .st_start(l_st_start), .st_op_write(l_st_write),
        .st_address(l_st_addr), .st_write_data(l_st_data),
        .st_busy(st_busy), .st_done(st_done), .st_error(st_error),
        .st_error_code(st_error_code), .st_read_data(st_read_data)
    );

    flash_bus_arbiter u_arbiter (
        .clk(clk), .rst(rst),
        .journal_load_req(load_req), .journal_save_req(save_req),
        .journal_busy(param_busy), .journal_st_start(p_st_start),
        .journal_st_op_write(p_st_write), .journal_st_address(p_st_addr),
        .journal_st_write_data(p_st_data),
        .journal_load_start(load_start), .journal_save_start(save_start),
        .log_req(log_req), .log_busy(log_busy),
        .log_st_start(l_st_start), .log_st_op_write(l_st_write),
        .log_st_address(l_st_addr), .log_st_write_data(l_st_data),
        .log_grant(log_grant), .store_start(st_start),
        .store_op_write(st_write), .store_address(st_addr),
        .store_write_data(st_data)
    );

    w25q64_record_store #(
        .RECORD_BYTES(12), .CLK_DIV(STORE_CLK_DIV),
        .POLL_INTERVAL_CYCLES(POLL_INTERVAL_CYCLES),
        .CS_HIGH_CYCLES(3),
        .ERASE_TIMEOUT_CYCLES(ERASE_TIMEOUT_CYCLES),
        .PROGRAM_TIMEOUT_CYCLES(PROGRAM_TIMEOUT_CYCLES),
        .ALLOWED_BASE(24'h700000), .ALLOWED_LIMIT(24'h800000)
    ) u_store (
        .clk(clk), .rst_n(~rst), .start(st_start),
        .op_write(st_write), .address(st_addr), .write_data(st_data),
        .busy(st_busy), .done(st_done), .error(st_error),
        .error_code(st_error_code), .read_data(st_read_data),
        .request_dropped(st_request_dropped), .spi_cs_n(spi_cs_n),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .spi_wp_n(spi_wp_n), .spi_hold_n(spi_hold_n)
    );
endmodule

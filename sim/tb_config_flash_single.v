`timescale 1ns/1ps

// 单槽参数记录：空片回默认、写入后回读、重启保持、坏校验拒绝。
module tb_config_flash_single;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg load_start = 0, save_start = 0;
    reg [31:0] save_period = 32'h00000159;
    reg [7:0] save_volume = 8'ha5;
    reg [7:0] save_mode = 8'd2;
    wire busy, load_done, save_done, error, config_valid;
    wire [7:0] error_code, active_volume, active_mode;
    wire [31:0] active_period;
    wire st_start, st_op_write;
    wire [23:0] st_address;
    wire [95:0] st_write_data;
    wire st_busy, st_done, st_error;
    wire [3:0] st_error_code;
    wire [95:0] st_read_data;
    wire cs_n, sclk, mosi, miso;

    config_flash_single #(.CLK_DIV(2), .SLOT_ADDRESS(24'h7fe000)) dut (
        .clk(clk), .rst_n(rst_n),
        .load_start(load_start), .save_start(save_start),
        .save_period(save_period), .save_volume(save_volume), .save_mode(save_mode),
        .busy(busy), .load_done(load_done), .save_done(save_done),
        .error(error), .error_code(error_code),
        .config_valid(config_valid),
        .active_period(active_period), .active_volume(active_volume),
        .active_mode(active_mode),
        .st_start(st_start), .st_op_write(st_op_write),
        .st_address(st_address), .st_write_data(st_write_data),
        .st_busy(st_busy), .st_done(st_done), .st_error(st_error),
        .st_error_code(st_error_code), .st_read_data(st_read_data)
    );

    w25q64_record_store #(
        .RECORD_BYTES(12), .CLK_DIV(2), .POLL_INTERVAL_CYCLES(3),
        .ERASE_TIMEOUT_CYCLES(100000), .PROGRAM_TIMEOUT_CYCLES(100000),
        .ALLOWED_BASE(24'h7fe000), .ALLOWED_LIMIT(24'h7ff000)
    ) u_store (
        .clk(clk), .rst_n(rst_n), .start(st_start), .op_write(st_op_write),
        .address(st_address), .write_data(st_write_data),
        .busy(st_busy), .done(st_done), .error(st_error),
        .error_code(st_error_code), .read_data(st_read_data),
        .request_dropped(), .spi_cs_n(cs_n), .spi_sclk(sclk), .spi_mosi(mosi),
        .spi_miso(miso), .spi_wp_n(), .spi_hold_n()
    );

    w25q64_config_model u_model (
        .cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(miso)
    );

    task tick; begin @(negedge clk); #1; end endtask
    task do_load;
        begin
            load_start = 1; tick(); load_start = 0;
            wait (load_done); tick();
        end
    endtask
    task do_save;
        begin
            save_start = 1; tick(); save_start = 0;
            wait (save_done); tick();
        end
    endtask
    task do_reset;
        begin
            rst_n = 0; repeat (3) tick(); rst_n = 1; repeat (2) tick();
        end
    endtask

    initial begin
        do_reset();
        do_load();
        if (config_valid) $fatal(1, "blank record must be invalid");

        do_save();
        if (!config_valid || active_period != 32'h00000159 ||
            active_volume != 8'ha5 || active_mode != 8'd2)
            $fatal(1, "save/readback mismatch: valid=%0d period=%h vol=%h mode=%h",
                   config_valid, active_period, active_volume, active_mode);

        do_reset();
        do_load();
        if (!config_valid || active_period != 32'h00000159 ||
            active_volume != 8'ha5 || active_mode != 8'd2)
            $fatal(1, "restart lost the saved record");

        // 坏校验：清掉 checksum 的最低位，必须回到默认/无效
        u_model.bytes[11] = u_model.bytes[11] ^ 8'h01;
        do_reset();
        do_load();
        if (config_valid) $fatal(1, "bad checksum must be rejected");

        $display("ALL PASSED: single-slot parameter record");
        $finish;
    end
    initial begin #5_000_000; $fatal(1, "single-slot timeout"); end
endmodule

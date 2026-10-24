`timescale 1ns/1ps

module tb_config_flash_journal;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n=0, load_start=0, save_start=0;
    reg [31:0] save_period=0;
    reg [7:0] save_volume=8'ha5, save_mode=0;
    wire busy,load_done,save_done,error,config_valid;
    wire [31:0] active_period,active_version;
    wire [7:0] active_volume,active_mode,error_code;
    wire cs_n,sclk,mosi,miso,wp_n,hold_n;
    wire st_start,st_op_write;
    wire [23:0] st_address;
    wire [95:0] st_write_data;
    wire st_busy,st_done,st_error;
    wire [3:0] st_error_code;
    wire [95:0] st_read_data;

    config_flash_journal #(
        .CLK_DIV(2), .POLL_INTERVAL_CYCLES(3),
        .ERASE_TIMEOUT_CYCLES(100000),
        .PROGRAM_TIMEOUT_CYCLES(100000),
        .SLOT0_ADDRESS(24'h7fe000), .SLOT1_ADDRESS(24'h7ff000),
        .ALLOWED_BASE(24'h7fe000), .ALLOWED_LIMIT(24'h800000)
    ) dut (
        .clk(clk),.rst_n(rst_n),.load_start(load_start),.save_start(save_start),
        .save_period(save_period),.save_volume(save_volume),.save_mode(save_mode),
        .busy(busy),.load_done(load_done),.save_done(save_done),
        .error(error),.error_code(error_code),.request_dropped(),
        .config_valid(config_valid),.active_version(active_version),
        .active_period(active_period),.active_volume(active_volume),
        .active_mode(active_mode),.slot0_present_out(),.slot1_present_out(),
        .slot0_raw(),.slot1_raw(),
        .st_start(st_start),.st_op_write(st_op_write),.st_address(st_address),
        .st_write_data(st_write_data),.st_busy(st_busy),.st_done(st_done),
        .st_error(st_error),.st_error_code(st_error_code),.st_read_data(st_read_data)
    );
    w25q64_record_store #(
        .RECORD_BYTES(12), .CLK_DIV(2), .POLL_INTERVAL_CYCLES(3),
        .ERASE_TIMEOUT_CYCLES(100000), .PROGRAM_TIMEOUT_CYCLES(100000),
        .ALLOWED_BASE(24'h7fe000), .ALLOWED_LIMIT(24'h800000)
    ) u_store (
        .clk(clk),.rst_n(rst_n),.start(st_start),.op_write(st_op_write),
        .address(st_address),.write_data(st_write_data),
        .busy(st_busy),.done(st_done),.error(st_error),.error_code(st_error_code),
        .read_data(st_read_data),.request_dropped(),
        .spi_cs_n(cs_n),.spi_sclk(sclk),.spi_mosi(mosi),.spi_miso(miso),
        .spi_wp_n(wp_n),.spi_hold_n(hold_n)
    );
    w25q64_config_model flash (
        .cs_n(cs_n),.sclk(sclk),.mosi(mosi),.miso(miso)
    );

    task tick;
        begin @(negedge clk); #1; end
    endtask
    task load;
        begin
            load_start=1; tick(); load_start=0;
            wait(load_done); tick();
            if (error) $fatal(1,"load failed: %h",error_code);
        end
    endtask
    task save;
        begin
            save_start=1; tick(); save_start=0;
            wait(save_done); tick();
            if (error) $fatal(1,"save failed: %h",error_code);
        end
    endtask
    initial begin
        repeat(3) tick(); rst_n=1; tick();
        load();
        if (config_valid) $fatal(1,"blank W25Q64 must have no config");
        save_period={26'd0,3'd4,3'd1}; save_mode=8'd3;
        save();
        if (!config_valid || active_period != save_period ||
            active_mode != save_mode || active_version != 1)
            $fatal(1,"first save must verify and become active");
        rst_n=0; repeat(3) tick(); rst_n=1; tick();
        load();
        if (!config_valid || active_period != {26'd0,3'd4,3'd1})
            $fatal(1,"saved values must survive controller restart");
        save_period={26'd0,3'd1,3'd4}; save_mode=8'd2;
        save();
        if (active_version != 2 || active_period != save_period)
            $fatal(1,"second save must select the newer slot");
        flash.bytes[23] = ~flash.bytes[23];
        rst_n=0; repeat(3) tick(); rst_n=1; tick();
        load();
        if (active_version != 1 || active_period != {26'd0,3'd4,3'd1})
            $fatal(1,"bad newer slot must fall back to older record");
        $display("ALL PASSED: W25Q64 SPI save, restart and damaged-slot recovery");
        $finish;
    end
    initial begin
        #20_000_000;
        $fatal(1,"W25Q64 journal timeout");
    end
endmodule

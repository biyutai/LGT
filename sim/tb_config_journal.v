`timescale 1ns/1ps

module tb_config_journal;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg load_start = 0;
    reg save_start = 0;
    reg slot0_present = 0, slot1_present = 0;
    reg [31:0] slot0_version = 0, slot1_version = 0;
    reg [31:0] slot0_period = 0, slot1_period = 0;
    reg [7:0] slot0_volume = 0, slot1_volume = 0;
    reg [7:0] slot0_mode = 0, slot1_mode = 0;
    reg [15:0] slot0_crc = 0, slot1_crc = 0;
    reg [31:0] save_period = 0;
    reg [7:0] save_volume = 0, save_mode = 0;
    wire load_done, config_valid, record_ready, target_slot;
    wire [31:0] active_version, active_period;
    wire [7:0] active_volume, active_mode;
    wire [31:0] record_version, record_period;
    wire [7:0] record_volume, record_mode;
    wire [15:0] record_crc;

    config_journal dut (
        .clk(clk), .rst_n(rst_n), .load_start(load_start),
        .slot0_present(slot0_present), .slot0_version(slot0_version),
        .slot0_period(slot0_period), .slot0_volume(slot0_volume),
        .slot0_mode(slot0_mode), .slot0_crc(slot0_crc),
        .slot1_present(slot1_present), .slot1_version(slot1_version),
        .slot1_period(slot1_period), .slot1_volume(slot1_volume),
        .slot1_mode(slot1_mode), .slot1_crc(slot1_crc),
        .load_done(load_done), .config_valid(config_valid),
        .active_version(active_version), .active_period(active_period),
        .active_volume(active_volume), .active_mode(active_mode),
        .active_slot(), .save_start(save_start),
        .save_period(save_period), .save_volume(save_volume),
        .save_mode(save_mode), .record_ready(record_ready),
        .target_slot(target_slot), .record_version(record_version),
        .record_period(record_period), .record_volume(record_volume),
        .record_mode(record_mode), .record_crc(record_crc)
    );

    task pulse_load;
        begin @(negedge clk); load_start=1; @(negedge clk); load_start=0; end
    endtask
    task pulse_save;
        begin @(negedge clk); save_start=1; @(negedge clk); save_start=0; end
    endtask
    task wait_load;
        begin wait(load_done); @(negedge clk); end
    endtask
    task wait_record;
        begin wait(record_ready); @(negedge clk); end
    endtask

    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        pulse_load(); wait_load();
        if (config_valid || active_version != 0)
            $fatal(1,"blank slots must fall back to invalid/default state");

        save_period=32'd2; save_volume=8'd4; save_mode=8'd3;
        pulse_save(); wait_record();
        if (record_version != 1 || record_period != 2 ||
            record_volume != 4 || record_mode != 3 || record_crc == 0)
            $fatal(1,"save record fields or CRC are wrong");

        slot0_present=1; slot0_version=record_version;
        slot0_period=record_period; slot0_volume=record_volume;
        slot0_mode=record_mode; slot0_crc=record_crc;
        pulse_load(); wait_load();
        if (!config_valid || active_version != 1 || active_period != 2 ||
            active_volume != 4 || active_mode != 3)
            $fatal(1,"valid slot must be restored");

        save_period=32'd4; save_volume=8'd2; save_mode=8'd1;
        pulse_save(); wait_record();
        if (!target_slot || record_version != 2)
            $fatal(1,"newer record must target the other slot");
        $display("ALL PASSED: config journal CRC, recovery and slot rotation");
        $finish;
    end
endmodule

`timescale 1ns/1ps
module tb_product_flash;
    reg clk=0, rst=1;
    always #5 clk=~clk;
    reg [2:0] brightness=2, contrast=2, volume=4;
    reg [1:0] transition=0;
    reg save_enable=1, event_pulse=0;
    reg [2:0] event_kind=0;
    reg [3:0] event_item=0;
    reg [7:0] event_detail=0;
    reg [31:0] uptime_s=0;
    wire ready, apply_pulse, config_valid, flash_error;
    wire [2:0] loaded_brightness, loaded_contrast, loaded_volume;
    wire [1:0] loaded_transition;
    wire log_busy, scan_done, append_done, log_error, newest_valid;
    wire [15:0] newest_seq;
    wire [3:0] newest_slot;
    wire rd_done, rd_valid;
    wire [95:0] rd_data;
    wire cs_n, sclk, mosi, miso;
    reg saw_scan=0, saw_append=0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin saw_scan<=0; saw_append<=0; end
        else begin
            if (scan_done) saw_scan<=1;
            if (append_done) saw_append<=1;
        end
    end

    product_flash #(.SAVE_DELAY_CYCLES(4), .LOG_SLOTS(2),
        .STORE_CLK_DIV(2), .POLL_INTERVAL_CYCLES(3),
        .ERASE_TIMEOUT_CYCLES(100000), .PROGRAM_TIMEOUT_CYCLES(100000)) dut (
        .clk(clk), .rst(rst),
        .current_brightness(brightness), .current_contrast(contrast),
        .current_transition(transition), .current_volume(volume),
        .save_enable(save_enable), .ready(ready), .apply_pulse(apply_pulse),
        .loaded_brightness(loaded_brightness), .loaded_contrast(loaded_contrast),
        .loaded_transition(loaded_transition), .loaded_volume(loaded_volume),
        .config_valid(config_valid), .flash_error(flash_error),
        .event_pulse(event_pulse), .event_kind(event_kind),
        .event_item(event_item), .event_detail(event_detail), .uptime_s(uptime_s),
        .log_busy(log_busy), .scan_done(scan_done), .append_done(append_done),
        .log_error(log_error), .newest_valid(newest_valid),
        .newest_seq(newest_seq), .newest_slot(newest_slot),
        .rd_start(1'b0), .rd_slot(4'd0), .rd_done(rd_done),
        .rd_valid(rd_valid), .rd_data(rd_data),
        .spi_cs_n(cs_n), .spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(miso),
        .spi_wp_n(), .spi_hold_n()
    );
    w25q64_log_model #(.SLOTS(2), .CONFIG_SLOT(1)) flash (
        .cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(miso)
    );

    task tick; begin @(negedge clk); #1; end endtask
    task reset_board;
        begin rst=1; repeat(5) tick(); rst=0; end
    endtask
    integer cycles;
    initial begin
        reset_board();
        cycles=0;
        while ((!ready || !saw_scan) && cycles<500000) begin tick(); cycles=cycles+1; end
        if (!ready || !saw_scan || config_valid || loaded_brightness!=2 ||
            loaded_contrast!=2 || loaded_transition!=0 || loaded_volume!=4)
            $fatal(1,"empty Flash must load defaults before normal operation");

        brightness=3; contrast=4; transition=2; volume=1;
        cycles=0;
        while (!dut.param_busy && cycles<20) begin tick(); cycles=cycles+1; end
        if (!dut.param_busy) $fatal(1,"stable settings did not start a save");
        event_kind=1; event_item=2; event_detail=8'h31; uptime_s=17;
        event_pulse=1; tick(); event_pulse=0;
        cycles=0;
        while ((!config_valid || !saw_append) && cycles<500000) begin tick(); cycles=cycles+1; end
        if (!config_valid || !saw_append || !newest_valid || newest_seq!=1 || flash_error || log_error)
            $fatal(1,"parameter save and concurrent event append must both complete");

        save_enable=0;
        brightness=2; contrast=2; transition=0; volume=4;
        reset_board();
        cycles=0;
        while ((!ready || !saw_scan) && cycles<500000) begin tick(); cycles=cycles+1; end
        if (!ready || !saw_scan || !config_valid || loaded_brightness!=3 || loaded_contrast!=4 ||
            loaded_transition!=2 || loaded_volume!=1 || !newest_valid || newest_seq!=1)
            $fatal(1,"power cycle must restore settings and keep the event record");
        $display("ALL PASSED: shared Flash defaults, save, event, restart");
        $finish;
    end
    initial begin #12_000_000; $fatal(1,"product Flash timeout"); end
endmodule

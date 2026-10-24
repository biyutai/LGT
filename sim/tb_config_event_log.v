`timescale 1ns/1ps

// B1 定向用例：事件日志扫描 / 追加 / 重启 / 坏条 / 满环 / 单槽回读。
// SLOTS=4 让"满环"用例只需要 5 次追加，逻辑与 16 槽一致（地址槽号按参数掩码取模）。
module tb_config_event_log;
    localparam integer SLOTS = 4;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg event_pulse = 0;
    reg [2:0] event_kind = 0;
    reg [3:0] event_item = 0;
    reg [7:0] event_detail = 0;
    reg [31:0] uptime_s = 0;
    reg rd_start = 0;
    reg [3:0] rd_slot = 0;
    wire busy, scan_done, append_done, error, newest_valid;
    wire [7:0] error_code;
    wire [15:0] newest_seq;
    wire [3:0]  newest_slot;
    wire rd_done, rd_valid;
    wire [95:0] rd_data;
    wire bus_req;
    wire st_start, st_op_write;
    wire [23:0] st_address;
    wire [95:0] st_write_data;
    wire st_busy, st_done, st_error;
    wire [3:0] st_error_code;
    wire [95:0] st_read_data;
    wire cs_n, sclk, mosi, miso;

    config_event_log #(
        .CLK_DIV(2), .SLOTS(SLOTS), .POLL_INTERVAL_CYCLES(3),
        .ERASE_TIMEOUT_CYCLES(100000), .PROGRAM_TIMEOUT_CYCLES(100000),
        .LOG_BASE(24'h700000)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .event_pulse(event_pulse), .event_kind(event_kind),
        .event_item(event_item), .event_detail(event_detail),
        .uptime_s(uptime_s),
        .busy(busy), .scan_done(scan_done), .append_done(append_done),
        .error(error), .error_code(error_code),
        .newest_valid(newest_valid), .newest_seq(newest_seq),
        .newest_slot(newest_slot),
        .rd_start(rd_start), .rd_slot(rd_slot),
        .rd_done(rd_done), .rd_valid(rd_valid), .rd_data(rd_data),
        .bus_req(bus_req), .bus_grant(1'b1),
        .st_start(st_start), .st_op_write(st_op_write),
        .st_address(st_address), .st_write_data(st_write_data),
        .st_busy(st_busy), .st_done(st_done), .st_error(st_error),
        .st_error_code(st_error_code), .st_read_data(st_read_data)
    );

    w25q64_record_store #(
        .RECORD_BYTES(12), .CLK_DIV(2), .POLL_INTERVAL_CYCLES(3),
        .ERASE_TIMEOUT_CYCLES(100000), .PROGRAM_TIMEOUT_CYCLES(100000),
        .ALLOWED_BASE(24'h700000), .ALLOWED_LIMIT(24'h710000)
    ) u_store (
        .clk(clk), .rst_n(rst_n), .start(st_start), .op_write(st_op_write),
        .address(st_address), .write_data(st_write_data),
        .busy(st_busy), .done(st_done), .error(st_error),
        .error_code(st_error_code), .read_data(st_read_data),
        .request_dropped(), .spi_cs_n(cs_n), .spi_sclk(sclk), .spi_mosi(mosi),
        .spi_miso(miso), .spi_wp_n(), .spi_hold_n()
    );

    w25q64_log_model #(
        .BASE(24'h700000), .SLOTS(SLOTS), .RECORD(12)
    ) flash (
        .cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(miso)
    );

    task tick;
        begin @(negedge clk); #1; end
    endtask

    task do_reset;
        begin
            rst_n = 0;
            repeat(3) tick();
            rst_n = 1;
            wait(scan_done); tick();
            if (error) $fatal(1,"scan error %h",error_code);
        end
    endtask

    task send_event;
        input [2:0] kind;
        input [3:0] item;
        input [7:0] detail;
        input [31:0] up;
        begin
            event_kind = kind; event_item = item;
            event_detail = detail; uptime_s = up;
            event_pulse = 1; tick(); event_pulse = 0;
            wait(append_done); tick();
            if (error) $fatal(1,"append error %h",error_code);
        end
    endtask

    task read_slot;
        input [3:0] idx;
        begin
            rd_slot = idx; rd_start = 1; tick(); rd_start = 0;
            wait(rd_done); tick();
            if (error) $fatal(1,"read error %h",error_code);
        end
    endtask

    integer i;
    initial begin
        // 1) 空 Flash：扫描后没有有效条目
        do_reset();
        if (newest_valid) $fatal(1,"blank flash must have no event");

        // 2) 连续 3 条：序号 1,2,3
        send_event(3'd1,4'd2,8'h11,32'd100); if (newest_seq != 1) $fatal(1,"seq must be 1");
        send_event(3'd1,4'd3,8'h00,32'd200); if (newest_seq != 2) $fatal(1,"seq must be 2");
        send_event(3'd2,4'd3,8'h05,32'd300);
        if (newest_seq != 3) $fatal(1,"seq must be 3");
        if (newest_slot != 4'd2) $fatal(1,"newest slot must be 2");
        read_slot(4'd2);
        if (!rd_valid || rd_data[87:80] != 8'd2 || rd_data[79:72] != 8'd3 ||
            rd_data[71:64] != 8'h05 || rd_data[47:16] != 32'd300)
            $fatal(1,"stored event fields wrong");

        // 3) 重启：序号来自 Flash 扫描，顺序不变
        do_reset();
        $display("restart scan: valid=%0d seq=%0d", newest_valid,newest_seq);
        if (!newest_valid || newest_seq != 3)
            $fatal(1,"restart lost the newest event");
        if (newest_slot != 4'd2) $fatal(1,"restart newest slot mismatch");

        // 4) 单槽回读
        read_slot(4'd2);
        if (!rd_valid || rd_data[63:48] != 16'd3 || rd_data[95:88] != 8'h5a)
            $fatal(1,"read slot 2 mismatch (valid=%0d seq=%0d)",rd_valid,rd_data[63:48]);
        read_slot(4'd3);
        if (rd_valid) $fatal(1,"blank slot must read invalid");

        // 5) 坏条：翻转 seq=3 那条的 CRC 低字节 -> 最新变成 seq=2
        flash.bytes[2*12+11] = flash.bytes[2*12+11] ^ 8'h01;
        do_reset();
        if (!newest_valid || newest_seq != 2)
            $fatal(1,"corrupt entry must be skipped (newest=%0d)",newest_seq);

        // 6) 满环：SLOTS=4，再追加 3 条到 seq=5，最旧的槽被覆盖
        send_event(3'd1,4'd0,8'h00,32'd400); if (newest_seq != 3) $fatal(1,"seq 3");
        send_event(3'd1,4'd1,8'h00,32'd500); if (newest_seq != 4) $fatal(1,"seq 4");
        send_event(3'd3,4'd0,8'h01,32'd600); if (newest_seq != 5) $fatal(1,"seq 5");
        do_reset();
        if (!newest_valid || newest_seq != 5)
            $fatal(1,"ring wrap lost the newest event");
        if (newest_slot != 4'd0) $fatal(1,"ring wrap newest slot mismatch");

        $display("ALL PASSED: event log scan, append, restart, corrupt-skip and ring wrap");
        $finish;
    end
    initial begin
        #20_000_000;
        $fatal(1,"event log timeout");
    end
endmodule

`timescale 1ns/1ps

// 定向用例：写一条记录写到一半就断电。
//
// 不变量（见 diet 计划）：任何时刻断电，重启后要么读到完整的旧记录、要么落到默认值，
// 绝不允许"半条记录"被采用。
//
// 手法：在 SPI 侧数页编程（命令 02）移出的字节数，到指定字节数就立刻停钟 ——
// 时钟停摆 = 断电，DUT 与芯片模型一起冻结；芯片模型按字节落盘，所以留下的正是
// "半条记录"（比真芯片还苛刻：真芯片会丢掉整次页编程的字节缓冲）。
// 然后上电复位、重新 load，检查被采用的记录仍是断电前那条完整记录。
//
// 三个断电点：
//   1) 15 字节后：命令 + 3 地址 + 11 个数据字节已写入，最后一个数据字节（CRC 低位）缺失；
//   2) 14 字节后：载荷 10 字节全在、CRC 两个字节全缺（最像"完整记录"的陷阱）；
//   3)  4 字节后：只有命令 + 地址，一个数据字节都没写（目标槽只剩擦除态）。
module tb_config_flash_powerloss;
    reg clk = 0;
    reg clock_run = 1;
    always #5 if (clock_run) clk = ~clk;   // 停钟后保持电平，恢复 clock_run 才继续

    reg rst_n = 0, load_start = 0, save_start = 0;
    reg [31:0] save_period = 0;
    reg [7:0]  save_volume = 8'ha5, save_mode = 0;
    wire busy, load_done, save_done, error, config_valid;
    wire [31:0] active_period, active_version;
    wire [7:0]  active_volume, active_mode, error_code;
    wire cs_n, sclk, mosi, miso, wp_n, hold_n;
    wire st_start, st_op_write;
    wire [23:0] st_address;
    wire [95:0] st_write_data;
    wire st_busy, st_done, st_error;
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

    // ---- 断电点检测：页编程命令 02 之后移出的字节数 ----
    integer   cut_bytes = 0;      // 0 = 不检测
    reg [7:0] spi_shift = 8'h00;
    integer   total_bits = 0;     // cs_n 拉低之后收到的 sclk 上升沿数
    reg       is_prog   = 1'b0;

    always @(posedge sclk or posedge cs_n) begin
        if (cs_n) begin
            total_bits = 0;
            spi_shift  = 8'h00;
            is_prog    = 1'b0;
        end else begin
            spi_shift = {spi_shift[6:0],mosi};
            total_bits = total_bits + 1;
            if (total_bits == 8)
                is_prog = (spi_shift == 8'h02);
            if (is_prog && (cut_bytes != 0) && (total_bits == cut_bytes*8))
                clock_run = 0;    // 这一字节收完就断电，下一个字节永远发不出来
        end
    end

    task tick;
        begin @(negedge clk); #1; end
    endtask

    task do_load;
        begin
            load_start = 1; tick(); load_start = 0;
            wait(load_done); tick();
        end
    endtask

    task do_save;
        begin
            save_start = 1; tick(); save_start = 0;
            wait(save_done); tick();
            if (error) $fatal(1,"save failed: %h",error_code);
        end
    endtask

    task power_cycle;
        begin
            clock_run = 0;          // 断电：时钟停摆
            #2000;
            rst_n = 0;              // 上电复位
            clock_run = 1;
            repeat(4) @(negedge clk);
            rst_n = 1;
            @(negedge clk);
        end
    endtask

    task check_old_record;
        input [8*28:1] what;
        begin
            if (error) $fatal(1,"%0s: load reported error %h", what, error_code);
            if (!config_valid)
                $fatal(1,"%0s: power loss lost the previously saved record", what);
            if (active_version !== 32'd1 || active_period !== 32'h00001234)
                $fatal(1,"%0s: partial record adopted (version=%0d period=%h)",
                       what, active_version, active_period);
            $display("  %0s -> kept version %0d period %h", what, active_version, active_period);
        end
    endtask

    initial begin
        repeat(3) tick();
        rst_n = 1; tick();

        // 基线：先写一条完整记录（槽0，版本 1，period 0x00001234）
        save_period = 32'h00001234; save_volume = 8'd7; save_mode = 8'd2;
        do_save();
        if (!config_valid || active_version != 1 || active_period != 32'h00001234)
            $fatal(1,"baseline save did not become active");
        $display("baseline: version 1 period %h written to slot0", active_period);

        // 1) 最后一个数据字节之前断电
        cut_bytes = 15;
        save_period = 32'hdeadbeef; save_mode = 8'd1;
        save_start = 1; tick(); save_start = 0;
        wait (clock_run == 0);
        power_cycle();
        cut_bytes = 0;
        // 先确认"半条记录"真的留在芯片里（否则这条用例什么也没证明）：
        // 槽1 = offset 12..23，记录顺序是 version/period/volume/mode/crc
        if (flash.bytes[12] === 8'hff || flash.bytes[22] === 8'hff || flash.bytes[23] !== 8'hff)
            $fatal(1,"half record not present in flash: %h %h %h",
                   flash.bytes[12], flash.bytes[22], flash.bytes[23]);
        do_load();
        check_old_record("cut before last data byte");

        // 2) 载荷写完、CRC 两字节之前断电
        cut_bytes = 14;
        save_period = 32'hcafef00d; save_mode = 8'd3;
        save_start = 1; tick(); save_start = 0;
        wait (clock_run == 0);
        power_cycle();
        cut_bytes = 0;
        // 载荷 10 字节全在（offset 12..21），CRC 两字节还是擦除态
        if (flash.bytes[12] === 8'hff || flash.bytes[21] === 8'hff ||
            flash.bytes[22] !== 8'hff || flash.bytes[23] !== 8'hff)
            $fatal(1,"payload-only record not present in flash: %h %h %h %h",
                   flash.bytes[12], flash.bytes[21], flash.bytes[22], flash.bytes[23]);
        do_load();
        check_old_record("cut before CRC bytes");

        // 3) 第一个数据字节之前断电（目标槽只剩擦除态）
        cut_bytes = 4;
        save_period = 32'h5a5a5a5a; save_mode = 8'd0;
        save_start = 1; tick(); save_start = 0;
        wait (clock_run == 0);
        power_cycle();
        cut_bytes = 0;
        // 一个数据字节都没写进去：目标槽应当只剩擦除态（= 不存在的槽）
        if (flash.bytes[12] !== 8'hff || flash.bytes[23] !== 8'hff)
            $fatal(1,"erase-only slot is not blank: %h %h", flash.bytes[12], flash.bytes[23]);
        do_load();
        check_old_record("cut before first data byte");

        $display("ALL PASSED: power loss mid-record never adopts a partial record");
        $finish;
    end
    initial begin
        #20_000_000;
        $fatal(1,"power-loss journal timeout");
    end
endmodule

// SD 卡驱动在"读扇区读到一半被复位"之后能否重新初始化
// 复现板上现象：连续按 KEY1 后 TF 卡卡在初始化（数码管显示 0），只有断电能恢复
// 运行：sim/run.sh tb_sd_reinit
`timescale 1ns / 1ps

module tb_sd_reinit;

reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;                       // 100MHz，与 sd_card_clk 相同

wire        sd_ncs, sd_dclk, sd_mosi, sd_miso;
wire        sd_init_done;
wire [2:0]  init_phase;
reg [5:1]   phases_seen = 5'd0;
reg         sd_sec_read = 1'b0;
reg  [31:0] sd_sec_read_addr = 32'd0;
wire [7:0]  sd_sec_read_data;
wire        sd_sec_read_data_valid;
wire        sd_sec_read_end;

// 初始化阶段 SPI 时钟加快到 5MHz、看门狗超时缩短，以缩短仿真时间（板上是 200kHz / 2s / 250ms，逻辑相同）
wire wd_fired;
sd_card_top #(
    .SPI_LOW_SPEED_DIV  (8),
    .SPI_HIGH_SPEED_DIV (0),
    .INIT_TIMEOUT       (2_000_000),    // 20ms
    .READ_TIMEOUT       (500_000)       // 5ms
) dut (
    .clk                    (clk),
    .rst                    (rst),
    .reinit_req             (1'b0),
    .SD_nCS                 (sd_ncs),
    .SD_DCLK                (sd_dclk),
    .SD_MOSI                (sd_mosi),
    .SD_MISO                (sd_miso),
    .sd_init_done           (sd_init_done),
    .init_phase             (init_phase),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       (),
    .wd_fired               (wd_fired)
);

sd_card_model card (
    .cs_n (sd_ncs),
    .sclk (sd_dclk),
    .mosi (sd_mosi),
    .miso (sd_miso)
);

integer errors = 0;
integer nbytes;
integer bad;
reg     ok;
integer cs_high_edges = 0;
integer first_select_edges = -1;
always @(posedge rst) begin
    cs_high_edges = 0;
    first_select_edges = -1;
    phases_seen = 5'd0;
end
always @(posedge clk)
    if (!rst && init_phase >= 3'd1 && init_phase <= 3'd5)
        phases_seen[init_phase] <= 1'b1;
always @(posedge sd_dclk)
    if (!rst && sd_ncs === 1'b1)
        cs_high_edges = cs_high_edges + 1;
always @(negedge sd_ncs)
    if (!rst && first_select_edges < 0)
        first_select_edges = cs_high_edges;

task check(input cond, input [8*72-1:0] msg);
    begin
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s  (t=%0t)", msg, $time); errors = errors + 1; end
    end
endtask

// 等 sd_init_done，最多 max_ns
task wait_init(input integer max_ns, output reg done);
    integer t;
    begin
        t = 0;
        while (!sd_init_done && t < max_ns) begin #1000; t = t + 1000; end
        done = sd_init_done;
    end
endtask

// 读一个扇区并逐字节比对；abort_after > 0 时读到第 abort_after 字节就复位控制器
task read_sector(input [31:0] sec, input integer abort_after, output integer got, output integer mism);
    integer t;
    reg     stop;
    begin
        got = 0; mism = 0; stop = 1'b0; t = 0;
        @(posedge clk);
        sd_sec_read_addr <= sec;
        sd_sec_read      <= 1'b1;
        while (!stop) begin
            @(posedge clk);
            t = t + 1;
            if (sd_sec_read_data_valid) begin
                if (sd_sec_read_data !== card.pattern(sec, got)) mism = mism + 1;
                got = got + 1;
                if (abort_after > 0 && got == abort_after) begin
                    rst <= 1'b1;
                    repeat (20) @(posedge clk);
                    rst <= 1'b0;
                    stop = 1'b1;
                end
            end
            if (sd_sec_read_end) stop = 1'b1;
            if (t > 2_000_000) begin $display("        read timeout"); stop = 1'b1; end
        end
        sd_sec_read <= 1'b0;
        @(posedge clk);
    end
endtask

initial begin
    $display("== 1. power-up init + read one sector");
    repeat (10) @(posedge clk);
    rst <= 1'b0;
    wait_init(20_000_000, ok);
    check(ok, "sd_init_done = 1");
    check(first_select_edges >= 512,
          "card sees CS-high idle clocks before first selection");
    check(phases_seen == 5'b11111,
          "all SD initialization commands have distinct visible phases");
    read_sector(32'd70, 0, nbytes, bad);
    check(nbytes == 512 && bad == 0, "sector 70: 512 bytes, all correct");
    check(!wd_fired, "normal power-up: wd_fired stays 0 (health bit3)");

    $display("== 2. reset controller at byte 100 of a sector read (like KEY1)");
    read_sector(32'd71, 100, nbytes, bad);
    $display("        got %0d bytes before reset; card still has %0d bytes to send", nbytes, card.data_left);
    wait_init(50_000_000, ok);
    check(ok, "re-init within 50ms after mid-read reset");
    check(first_select_edges >= 512,
          "warm reset sends CS-high idle clocks before selecting card");
    check(phases_seen == 5'b11111,
          "warm reset traverses CMD0 through CMD16");
    if (!ok)
        $display("        STUCK: card got CMD0 %0d times, card %0s idle, host init FSM state = %0d",
                 card.cmd0_count, card.idle ? "is" : "NOT", dut.sd_card_sec_read_write_m0.state);
    if (ok) begin
        read_sector(32'd72, 0, nbytes, bad);
        check(nbytes == 512 && bad == 0, "sector 72 after recovery: 512 bytes, all correct");
    end

    $display("== 3. five mid-read resets in a row");
    begin : burst
        integer k;
        for (k = 0; k < 5; k = k + 1) begin
            wait_init(50_000_000, ok);
            if (!ok) disable burst;
            read_sector(32'd80 + k, 37 + 61 * k, nbytes, bad);
        end
    end
    wait_init(50_000_000, ok);
    check(ok, "re-init after 5 mid-read resets");
    if (ok) begin
        read_sector(32'd90, 0, nbytes, bad);
        check(nbytes == 512 && bad == 0, "sector 90: 512 bytes, all correct");
    end

    $display("== 4. remove card, reset, reinsert");
    card.remove;
    rst <= 1'b1; repeat (20) @(posedge clk); rst <= 1'b0;
    #5_000_000;
    check(!sd_init_done, "no card: sd_init_done stays 0");
    card.insert;
    wait_init(200_000_000, ok);
    check(ok, "card inserted: re-init within 200ms");
    if (ok) begin
        read_sector(32'd95, 0, nbytes, bad);
        check(nbytes == 512 && bad == 0, "sector 95: 512 bytes, all correct");
    end

    $display("== 5. pull card out in the middle of a sector read (no host reset)");
    begin : unplug
        integer t;
        @(posedge clk);
        sd_sec_read_addr <= 32'd100;
        sd_sec_read      <= 1'b1;
        nbytes = 0;
        while (nbytes < 50) begin @(posedge clk); if (sd_sec_read_data_valid) nbytes = nbytes + 1; end
        card.remove;
        t = 0;
        while (sd_init_done && t < 20_000_000) begin #1000; t = t + 1000; end
        sd_sec_read <= 1'b0;
        $display("        sd_init_done dropped %0d us after card removal", t / 1000);
    end
    check(!sd_init_done, "watchdog notices the stalled read and drops sd_init_done");
    check(wd_fired, "wd_fired latched (health bit3)");
    #3_000_000;
    card.insert;
    wait_init(200_000_000, ok);
    check(ok, "card reinserted: re-init within 200ms");
    if (ok) begin
        read_sector(32'd101, 0, nbytes, bad);
        check(nbytes == 512 && bad == 0, "sector 101: 512 bytes, all correct");
    end

    $display("");
    if (errors == 0) $display("== ALL PASSED");
    else             $display("== %0d FAILED", errors);
    $finish;
end

endmodule

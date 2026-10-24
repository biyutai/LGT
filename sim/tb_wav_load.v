// sd_card_bmp + bmp_read：扫描时找 WAV、首图之后把 WAV 载入音频区、加载超时后按键仍可用
// 卡模型里放 16×8 的小 BMP 和小 WAV，帧缓存写通道用一个简单的应答模型代替
// 运行：sim/run.sh tb_wav_load
`timescale 1ns / 1ps

module tb_wav_load #(
    parameter RESIDENT_TEST = 0,
    parameter PREVIEW_TEST = 0,
    parameter SWITCH_TEST = 0,
    parameter WARM_RESET_TEST = 0,
    parameter EARLY_MANUAL_TEST = 0,
    parameter FIRST_LAP_TEST = 0,
    parameter BEAT_RACE_TEST = 0
);

localparam integer BMP_W = 16, BMP_H = 8;
localparam integer BMP_WORDS = BMP_W * BMP_H;          // 128
localparam integer BMP_BYTES = 54 + BMP_WORDS * 3;     // 438，一个扇区放得下
localparam [20:0]  WAV_MAX   = 21'd1024;               // 仿真里把音频区缩小到 1024 字，测试截断
localparam integer GAP       = 64;

reg clk = 1'b0;
reg rst = 1'b1;
always #10 clk = ~clk;                                  // 50MHz：与板上 SD 域一致（sys_pll C0）

reg  key_next = 1'b1;
reg  manual_next_toggle = 1'b0;
reg  key_auto = 1'b1;
reg  auto_switch = 1'b0;
reg  manual_prev_busy = 1'b0;
reg  demo_force_auto = 1'b0;
reg  auto_init = 1'b0;                                  // 第 1~11 节按原来的"上电轮播关"测，第 12 节测上电自启动
reg  beat_toggle = 1'b0;                                // 模拟 av_sync 的节拍
reg  remote_select_toggle = 1'b0;
reg  [1:0] remote_select_index = 2'd0;
reg  button_select_toggle = 1'b0;
reg  [1:0] button_select_index = 2'd0;
reg  remote_prev_toggle = 1'b0, remote_period_toggle = 1'b0;
reg  [3:0] remote_period_seconds = 4'd1;
wire [2:0] img_count;
wire [1:0] active_image;
wire auto_enabled;
wire [1:0] display_scale_mode;
wire [7:0] image_scale_modes;
wire recovery_failed;
reg preview_requested = PREVIEW_TEST;
wire [3:0] preview_valid_mask;
wire write_is_preview;
wire        display_valid;
reg         write_finish_toggle = 1'b0;
wire [1:0]  write_buf_idx, disp_buf_idx;
wire        write_is_wav, wav_ready, next_image_ready;
wire        resident_mode;
wire [20:0] wav_words;
wire        write_req, write_en;
reg         write_req_ack = 1'b0;
wire [31:0] write_data;
wire        sd_ncs, sd_dclk, sd_mosi, sd_miso;

sd_card_bmp #(
    .FRAME_WIDTH        (BMP_W),
    .FRAME_HEIGHT       (BMP_H),
    .CLK_FREQ_HZ         (50_000),         // 只影响按键消抖（20ms → 1000 拍）和轮播 1s 计时
    .LOAD_TIMEOUT_CYCLES (3_000_000),      // 30ms
    .WAV_TIMEOUT_CYCLES  (20_000_000),     // 200ms
    .WAV_MAX_WORDS       (WAV_MAX),
    .SD_SPI_HIGH_SPEED_DIV(0),
    .ENABLE_RESIDENT     (RESIDENT_TEST),
    .SDRAM_WORDS         (1200),
    .ENABLE_FULL_PREVIEW(PREVIEW_TEST),
    .USE_AUTO_SWITCH    (SWITCH_TEST),
    .PREVIEW_WORDS       (PREVIEW_TEST ? BMP_WORDS*2 : 0),
    .SCAN_WAV_GAP        (GAP)
) dut (
    .clk                 (clk),
    .rst                 (rst),
    .key_next            (key_next),
    .manual_next_toggle  (manual_next_toggle),
    .remote_select_toggle(remote_select_toggle),
    .remote_select_index (remote_select_index),
    .button_select_toggle(button_select_toggle),
    .button_select_index (button_select_index),
    .remote_prev_toggle (remote_prev_toggle),
    .remote_period_toggle(remote_period_toggle),
    .remote_period_seconds(remote_period_seconds),
    .key_auto            (key_auto),
    .auto_play_switch    (auto_switch),
    .manual_prev_busy    (manual_prev_busy),
    .demo_force_auto     (demo_force_auto),
    .auto_play_init      (auto_init),
    .preview_requested   (preview_requested),
    .sd_wd_fired         (),
    .recovery_failed     (recovery_failed),
    .bmp_width           (BMP_W[15:0]),
    .bmp_height          (BMP_H[15:0]),
    .display_valid       (display_valid),
    .write_finish_toggle (write_finish_toggle),
    .write_buf_idx       (write_buf_idx),
    .preview_valid_mask  (preview_valid_mask),
    .write_is_preview    (write_is_preview),
    .disp_buf_idx        (disp_buf_idx),
    .write_is_wav        (write_is_wav),
    .wav_words           (wav_words),
    .wav_ready           (wav_ready),
    .next_image_ready    (next_image_ready),
    .resident_mode       (resident_mode),
    .beat_toggle         (beat_toggle),
    .img_count           (img_count),
    .active_image        (active_image),
    .auto_enabled        (auto_enabled),
    .display_scale_mode  (display_scale_mode),
    .image_scale_modes   (image_scale_modes),
    .write_req           (write_req),
    .write_req_ack       (write_req_ack),
    .write_en            (write_en),
    .write_data          (write_data),
    .sub_rd_clk          (clk),
    .SD_nCS              (sd_ncs),
    .SD_DCLK             (sd_dclk),
    .SD_MOSI             (sd_mosi),
    .SD_MISO             (sd_miso)
);
// 初始化阶段 SPI 加快到 5MHz 以缩短仿真（板上 200kHz）
defparam dut.sd_card_top_m0.SPI_LOW_SPEED_DIV = 8;

sd_card_model #(.DISK_SECTORS(128)) card (
    .cs_n (sd_ncs), .sclk (sd_dclk), .mosi (sd_mosi), .miso (sd_miso)
);

// ---------------- 检查 ----------------
integer errors = 0;
task check(input cond, input [8*72-1:0] msg);
    begin
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s  (t=%0t)", msg, $time); errors = errors + 1; end
    end
endtask

// ---------------- 卡内容 ----------------
integer i;

task disk_clear;
    begin for (i = 0; i < 128 * 512; i = i + 1) card.disk[i] = 8'h00; end
endtask

task put32(input integer a, input [31:0] v);
    begin
        card.disk[a] = v[7:0]; card.disk[a+1] = v[15:8]; card.disk[a+2] = v[23:16]; card.disk[a+3] = v[31:24];
    end
endtask

task fat_dir_entry(input integer offset, input [87:0] name,
                   input [31:0] cluster, input [31:0] size);
    integer j, a;
    begin
        a = 2*512+offset;
        for(j=0;j<11;j=j+1)card.disk[a+j]=name[(10-j)*8 +: 8];
        card.disk[a+11]=8'h20;
        put32(a+20,cluster[31:16]);
        put32(a+26,cluster[15:0]);
        put32(a+28,size);
    end
endtask
task copy_sector(input integer src, input integer dst);
    integer j;
    begin for(j=0;j<512;j=j+1)card.disk[dst*512+j]=card.disk[src*512+j];end
endtask
task fat_volume_header;
    begin
        card.disk[0]=8'heb;
        card.disk[11]=8'd0;card.disk[12]=8'd2; // 512 bytes per sector
        card.disk[13]=8'd1; // One sector per cluster
        card.disk[14]=8'd1;card.disk[15]=8'd0; // Reserved sector count
        card.disk[16]=8'd1; // One FAT
        put32(32,128);put32(36,1);put32(44,2);
        card.disk[510]=8'h55;card.disk[511]=8'haa;
        put32(512+2*4,32'h0fffffff); // Root directory cluster
    end
endtask

task put_tag(input integer a, input [31:0] s);     // "RIFF" 这样的字符串，按书写顺序存
    begin card.disk[a] = s[31:24]; card.disk[a+1] = s[23:16]; card.disk[a+2] = s[15:8]; card.disk[a+3] = s[7:0]; end
endtask

function [7:0] pix_byte(input integer img, input integer k);
    pix_byte = img * 40 + k * 7 + 3;
endfunction

task put_bmp(input integer sec, input integer img);
    integer a;
    begin
        a = sec * 512;
        card.disk[a] = "B"; card.disk[a+1] = "M";
        put32(a + 2, BMP_BYTES);
        put32(a + 10, 54);
        put32(a + 14, 40);
        put32(a + 18, BMP_W);
        put32(a + 22, BMP_H);
        card.disk[a+26] = 8'd1; card.disk[a+27] = 8'd0;
        card.disk[a+28] = 8'd24; card.disk[a+29] = 8'd0;
        put32(a + 30, 0);
        for (i = 0; i < BMP_WORDS * 3; i = i + 1) card.disk[a + 54 + i] = pix_byte(img, i);
    end
endtask

task put_bmp_half(input integer sec, input integer img);
    integer a, k;
    begin
        a = sec * 512;
        card.disk[a] = "B"; card.disk[a+1] = "M";
        put32(a + 2, 54 + (BMP_W/2)*(BMP_H/2)*3);
        put32(a + 10, 54);
        put32(a + 14, 40);
        put32(a + 18, BMP_W/2);
        put32(a + 22, BMP_H/2);
        card.disk[a+26] = 8'd1; card.disk[a+27] = 8'd0;
        card.disk[a+28] = 8'd24; card.disk[a+29] = 8'd0;
        put32(a + 30, 0);
        for (k=0; k<(BMP_W/2)*(BMP_H/2)*3; k=k+1)
            card.disk[a+54+k] = pix_byte(img,k);
    end
endtask

task put_bmp_double(input integer sec, input integer img);
    integer a, k;
    begin
        a = sec * 512;
        card.disk[a] = "B"; card.disk[a+1] = "M";
        put32(a + 2, 54 + (BMP_W*2)*(BMP_H*2)*3);
        put32(a + 10, 54);
        put32(a + 14, 40);
        put32(a + 18, BMP_W*2);
        put32(a + 22, BMP_H*2);
        card.disk[a+26] = 8'd1; card.disk[a+27] = 8'd0;
        card.disk[a+28] = 8'd24; card.disk[a+29] = 8'd0;
        put32(a + 30, 0);
        for (k=0; k<(BMP_W*2)*(BMP_H*2)*3; k=k+1)
            card.disk[a+54+k] = pix_byte(img,k);
    end
endtask

task put_bmp_wide(input integer sec, input integer img);
    integer a, k;
    begin
        a = sec * 512;
        card.disk[a] = "B"; card.disk[a+1] = "M";
        put32(a + 2, 54 + (BMP_W/2)*((BMP_H*3)/8)*3);
        put32(a + 10, 54);
        put32(a + 14, 40);
        put32(a + 18, BMP_W/2);
        put32(a + 22, (BMP_H*3)/8);
        card.disk[a+26] = 8'd1; card.disk[a+27] = 8'd0;
        card.disk[a+28] = 8'd24; card.disk[a+29] = 8'd0;
        put32(a + 30, 0);
        for (k=0; k<(BMP_W/2)*((BMP_H*3)/8)*3; k=k+1)
            card.disk[a+54+k] = pix_byte(img,k);
    end
endtask

function [31:0] wav_sample(input integer k);       // {左, 右}
    wav_sample = {16'd1000 + k[15:0] * 16'd3, 16'hF000 - k[15:0]};
endfunction

task put_wav(input integer sec, input integer nwords, input integer rate);
    integer a;
    reg [31:0] w;
    begin
        a = sec * 512;
        put_tag(a, "RIFF");      put32(a + 4, 36 + nwords * 4);
        put_tag(a + 8, "WAVE");  put_tag(a + 12, "fmt ");
        put32(a + 16, 16);
        card.disk[a+20] = 8'd1; card.disk[a+21] = 8'd0;   // PCM
        card.disk[a+22] = 8'd2; card.disk[a+23] = 8'd0;   // 立体声
        put32(a + 24, rate);
        put32(a + 28, rate * 4);
        card.disk[a+32] = 8'd4; card.disk[a+33] = 8'd0;
        card.disk[a+34] = 8'd16; card.disk[a+35] = 8'd0;
        put_tag(a + 36, "data"); put32(a + 40, nwords * 4);
        for (i = 0; i < nwords; i = i + 1) begin
            w = wav_sample(i);
            card.disk[a + 44 + 4*i]     = w[23:16];       // 左低
            card.disk[a + 44 + 4*i + 1] = w[31:24];       // 左高
            card.disk[a + 44 + 4*i + 2] = w[7:0];         // 右低
            card.disk[a + 44 + 4*i + 3] = w[15:8];        // 右高
        end
    end
endtask

// ---------------- 帧缓存写通道应答模型 ----------------
// write_req 上升 4 拍后应答（frame_fifo_write 打拍 + 跨域同步的效果），收满 len 个字后翻转 write_finish_toggle
reg  [3:0]  req_sr = 4'd0;
reg         collecting = 1'b0;
integer     want = 0, got = 0;
reg  [1:0]  cur_idx = 2'd0;
reg         cur_wav = 1'b0;
reg         cur_preview = 1'b0;
reg         drop_next_finish = 1'b0;                   // 测超时：这一次写不发完成信号
reg  [31:0] buf0 [0:BMP_WORDS-1];
reg  [31:0] buf1 [0:BMP_WORDS-1];
reg  [31:0] buf2 [0:BMP_WORDS-1];
reg  [31:0] buf3 [0:BMP_WORDS-1];
reg  [31:0] abuf [0:2047];
integer     loads = 0, wav_loads = 0;
integer     preview_loads = 0;
integer     wav_mismatch = 0;

always @(posedge clk) begin
    req_sr        <= {req_sr[2:0], write_req};
    write_req_ack <= req_sr[3];
    if (req_sr[3] && !write_req_ack) begin              // 一次新的写事务
        collecting = 1'b1;
        got        = 0;
        cur_idx    = write_buf_idx;
        cur_wav    = write_is_wav;
        cur_preview = write_is_preview;
        want       = write_is_wav ? wav_words : write_is_preview ? BMP_WORDS/8 : BMP_WORDS;
        loads      = loads + 1;
        if (write_is_wav) wav_loads = wav_loads + 1;
        if (write_is_preview) preview_loads = preview_loads + 1;
    end
    if (collecting && write_en) begin
        if (cur_wav) abuf[got] = write_data;
        else if (cur_preview) begin end
        else if (cur_idx == 2'd0) buf0[got % BMP_WORDS] = write_data;
        else if (cur_idx == 2'd1) buf1[got % BMP_WORDS] = write_data;
        else if (cur_idx == 2'd2) buf2[got % BMP_WORDS] = write_data;
        else buf3[got % BMP_WORDS] = write_data;
        got = got + 1;
        if (got == want) begin
            collecting = 1'b0;
            if (drop_next_finish) drop_next_finish = 1'b0;
            else write_finish_toggle <= ~write_finish_toggle;
        end
    end
end

// WAV 加载期间显示缓冲保持不变。
reg     disp_moved_during_wav = 1'b0;
always @(posedge clk) begin
    if (write_is_wav && disp_buf_idx != 2'd0) disp_moved_during_wav <= 1'b1;
end

// ---------------- 工具 ----------------
task restart;
    begin
        manual_next_toggle = 1'b0;
        remote_select_toggle = 1'b0;
        remote_select_index = 2'd0;
        button_select_toggle = 1'b0;
        button_select_index = 2'd0;
        remote_prev_toggle = 1'b0;
        remote_period_toggle = 1'b0;
        remote_period_seconds = 4'd1;
        demo_force_auto = 1'b0;
        rst <= 1'b1;
        card.remove;
        repeat (20) @(posedge clk);
        card.insert;
        disp_moved_during_wav = 1'b0;
        loads = 0; wav_loads = 0; collecting = 1'b0;
        rst <= 1'b0;
    end
endtask

task wait_scan_and_first(output reg ok);
    integer t;
    begin
        t = 0;
        while (!(dut.scan_done && display_valid) && t < 200_000) begin #1000; t = t + 1; end
        ok = dut.scan_done && display_valid;
    end
endtask

task wait_wav_ready(output reg ok);
    integer t;
    begin
        t = 0;
        while (!wav_ready && t < 200_000) begin #1000; t = t + 1; end
        ok = wav_ready;
    end
endtask

function bmp_buf_ok(input integer which, input integer img);
    integer k, bad;
    reg [31:0] e, g;
    begin
        bad = 0;
        for (k = 0; k < BMP_WORDS; k = k + 1) begin
            e = {pix_byte(img, 3*k+2), pix_byte(img, 3*k+1), pix_byte(img, 3*k), 8'h00};
            case (which)
                0: g = buf0[k];
                1: g = buf1[k];
                2: g = buf2[k];
                default: g = buf3[k];
            endcase
            if (g !== e) bad = bad + 1;
        end
        bmp_buf_ok = (bad == 0);
    end
endfunction

function bmp_half_ok(input integer which, input integer img);
    integer k, source_k, bad;
    reg [31:0] e, g;
    begin
        bad = 0;
        for (k=0; k<BMP_WORDS; k=k+1) begin
            source_k = (k/(BMP_W*2))*(BMP_W/2) + ((k%BMP_W)/2);
            e = {pix_byte(img,3*source_k+2),pix_byte(img,3*source_k+1),
                 pix_byte(img,3*source_k),8'h00};
            g = which ? buf1[k] : buf0[k];
            if (g !== e) bad = bad + 1;
        end
        bmp_half_ok = (bad == 0);
    end
endfunction

function bmp_double_ok(input integer which, input integer img);
    integer k, source_k, bad;
    reg [31:0] expected, actual;
    begin
        bad = 0;
        for (k=0; k<BMP_WORDS; k=k+1) begin
            source_k = ((k/BMP_W)*2)*(BMP_W*2) + ((k%BMP_W)*2);
            expected = {pix_byte(img,3*source_k+2),pix_byte(img,3*source_k+1),
                        pix_byte(img,3*source_k),8'h00};
            actual = which ? buf1[k] : buf0[k];
            if (actual !== expected) bad = bad + 1;
        end
        bmp_double_ok = (bad == 0);
    end
endfunction

function bmp_wide_ok(input integer which, input integer img);
    integer k, source_y, source_k, bad;
    reg [31:0] expected, actual;
    begin
        bad = 0;
        for (k=0; k<BMP_WORDS; k=k+1) begin
            source_y = (((k/BMP_W)+1)*3-1)/8;
            source_k = source_y*(BMP_W/2) + ((k%BMP_W)/2);
            expected = {pix_byte(img,3*source_k+2),pix_byte(img,3*source_k+1),
                        pix_byte(img,3*source_k),8'h00};
            actual = which ? buf1[k] : buf0[k];
            if (actual !== expected) bad = bad + 1;
        end
        bmp_wide_ok = (bad == 0);
    end
endfunction

function integer wav_buf_bad(input integer n);
    integer k, bad;
    begin
        bad = 0;
        for (k = 0; k < n; k = k + 1) if (abuf[k] !== wav_sample(k)) bad = bad + 1;
        wav_buf_bad = bad;
    end
endfunction

task press_auto;
    begin
        key_auto = 1'b0; #50_000; key_auto = 1'b1; #50_000;
    end
endtask

// 发一个节拍，返回节拍到显示缓冲切换之间的拍数（-1 = 2ms 内没切）
task beat(output integer lat);
    integer t;
    reg [1:0] d0;
    begin
        d0 = disp_buf_idx;
        @(posedge clk) beat_toggle <= ~beat_toggle;
        t = 0;
        while (disp_buf_idx == d0 && t < 200_000) begin @(posedge clk); t = t + 1; end
        lat = (disp_buf_idx == d0) ? -1 : t;
    end
endtask

task wait_preloaded(output reg ok);
    integer t;
    begin
        t = 0;
        while (!dut.preloaded && t < 100_000) begin #1000; t = t + 1; end
        ok = dut.preloaded;
    end
endtask

task press_next;
    begin
        key_next = 1'b0; #50_000; key_next = 1'b1; #50_000;
    end
endtask

task select_image(input [1:0] idx);
    begin
        @(negedge clk);
        remote_select_index=idx;
        remote_select_toggle=~remote_select_toggle;
    end
endtask

reg ok;

initial begin
    if (FIRST_LAP_TEST || BEAT_RACE_TEST) begin
        disk_clear;
        put_bmp(10,0); put_bmp(11,1); put_bmp(12,2); put_bmp(13,3);
        put_wav(14,700,48000);
        auto_init=1'b1;
        restart;
        wait_scan_and_first(ok);
        wait_wav_ready(ok);
        if (FIRST_LAP_TEST) begin : cached_first_lap
            integer lat, i, before_loads;
            check(dut.sd_card_top_m0.spi_clk_div==16'd0,
                  "data phase uses the 12.5 MHz SPI speed setting");
            check(ok && active_image==0 && wav_loads==1 &&
                  dut.resident_mode && dut.resident_mask==4'b0001 &&
                  bmp_buf_ok(0,0),
                  "WAV is ready after the first photo, before background cache fill");
            wait(dut.resident_mask==4'b0011 && dut.load_busy &&
                 dut.cache_fill_mode && dut.load_idx==2);
            @(negedge clk);
            manual_next_toggle=~manual_next_toggle;
            repeat(16) @(posedge clk);
            #1;
            check(active_image==1 && dut.load_busy,
                  "KEY2 selects a cached photo during background card reading");
            @(negedge clk);
            remote_prev_toggle=~remote_prev_toggle;
            repeat(16) @(posedge clk);
            #1;
            check(active_image==0 && dut.load_busy,
                  "KEY4 returns to a cached photo during background card reading");
            begin : wait_cache_fill
                integer t;
                t=0;
                while (dut.resident_mask!=4'b1111 && t<2_000_000) begin
                    @(posedge clk); t=t+1;
                end
                check(t<2_000_000 && bmp_buf_ok(1,1) &&
                      bmp_buf_ok(2,2) && bmp_buf_ok(3,3),
                      "remaining photos fill resident banks after WAV starts");
            end
            before_loads=loads;
            for (i=1;i<=4;i=i+1) begin
                wait_preloaded(ok);
                beat(lat);
                check(ok && lat>=0 && lat<=6 && active_image==(i%4),
                      "first-lap photo follows its music beat immediately");
            end
            check(loads==before_loads, "first lap makes no TF card image reads");
            @(negedge clk);
            button_select_index=2'd3;
            button_select_toggle=~button_select_toggle;
            repeat(20) @(posedge clk);
            check(active_image==3, "matrix PIC 4 selects cached photo 4");
            auto_init=1'b0;
            restart;
            wait_scan_and_first(ok);
            wait_wav_ready(ok);
            begin : wait_manual_cache
                integer t;
                t=0;
                while (dut.resident_mask!=4'b1111 && t<2_000_000) begin
                    @(posedge clk); t=t+1;
                end
                check(ok && t<2_000_000 && !auto_enabled,
                      "manual mode also fills four photo banks after WAV starts");
            end
        end else begin : beat_race
            integer lat;
            wait_preloaded(ok);
            beat(lat);
            check(lat>=0 && active_image==1, "first beat selects photo 2");
            wait_preloaded(ok);
            drop_next_finish=1'b1;
            beat(lat);
            check(lat>=0 && active_image==2, "second beat selects photo 3");
            wait(dut.load_busy && dut.preload_mode && dut.load_idx==3 &&
                 dut.source_done_seen && !collecting && !drop_next_finish);
            @(negedge clk);
            write_finish_toggle=~write_finish_toggle;
            @(negedge clk);
            beat_toggle=~beat_toggle;
            wait(!dut.load_busy);
            #1;
            check(active_image==3 && !dut.beat_pending,
                  "photo 4 commits when its first beat coincides with preload completion");
            repeat(20) @(posedge clk);
            check(active_image==3 && !dut.beat_pending,
                  "photo 4 stays visible with no stale beat until the next beat");
            beat(lat);
            check(lat>=0 && active_image==0, "next beat selects photo 1 once");
            repeat(20) @(posedge clk);
            check(active_image==0, "no stale beat advances photo 1 again");
        end
        if (errors==0) $display("ALL PASSED: first-lap playback and beat completion race");
        else $fatal(1,"first-lap beat failures: %0d",errors);
        $finish;
    end
    if (EARLY_MANUAL_TEST) begin
        disk_clear;
        put_bmp(10,0);put_bmp(11,1);put_bmp(12,2);put_bmp(13,3);
        put_wav(14,700,48000);
        auto_init=1'b0;
        restart;
        begin : first_photo
            integer t;
            t=0;
            while (!display_valid && t<100_000) begin #1000;t=t+1;end
            check(display_valid && !dut.scan_done,
                  "first photo appears before background scan completes");
        end
        press_next;
        wait_scan_and_first(ok);
        check(ok && (dut.next_req_pending || active_image==1 ||
                     (dut.load_busy && dut.load_idx==1 && !write_is_wav)),
              "early manual request is queued, loading, or already committed");
        begin : next_photo
            integer t;
            t=0;
            while (active_image==0 && t<200_000) begin #1000;t=t+1;end
            check(active_image==1 && display_valid && wav_loads==0,
                  "manual next photo commits before optional WAV preload");
        end
        if (errors==0) $display("ALL PASSED: early manual switch has priority over WAV preload");
        else $fatal(1,"early manual switch failures: %0d",errors);
        $finish;
    end
    if (WARM_RESET_TEST) begin
        disk_clear;
        put_bmp(10,0); put_bmp(11,1); put_bmp(12,2); put_bmp(13,3);
        put_wav(14,700,48000);
        restart;
        wait_scan_and_first(ok);
        check(ok && img_count == 3'd4, "cold boot finds four photos");
        rst <= 1'b1;
        repeat (20) @(posedge clk);
        rst <= 1'b0;
        wait_scan_and_first(ok);
        check(ok && img_count == 3'd4 && display_valid,
              "warm reset with card powered returns to first complete photo");
        if (errors == 0) $display("ALL PASSED: warm reset with card continuously powered");
        else $fatal(1,"warm reset failures: %0d",errors);
        $finish;
    end
    if (SWITCH_TEST) begin
        disk_clear;
        put_bmp(10,0);put_bmp(11,1);put_bmp(12,2);put_bmp(13,3);
        put_wav(14,700,48000);
        auto_init=1'b1;
        auto_switch=1'b0;
        restart;
        wait_scan_and_first(ok);
        wait_wav_ready(ok);
        wait_preloaded(ok);
        check(ok && !auto_enabled && !dut.sync_mode,
              "SW3 down keeps manual mode despite auto-play startup setting");
        begin : manual_beat
            integer lat;
            beat(lat);
            check(lat==-1 && active_image==0,"manual mode ignores WAV beat");
        end
        auto_switch=1'b1;
        repeat(4) @(posedge clk);
        check(auto_enabled && dut.sync_mode,"SW3 up enables automatic playback");
        begin : auto_beat
            integer lat;
            beat(lat);
            check(lat>=0 && active_image==1,"SW3 auto advances on WAV beat");
        end
        manual_prev_busy=1'b1;
        repeat(4) @(posedge clk);
        begin : blocked_beat
            integer lat;
            beat(lat);
            check(lat==-1 && active_image==1,
                  "automatic beat cannot preempt KEY4 previous transition");
        end
        manual_prev_busy=1'b0;
        press_auto;
        check(auto_enabled,"KEY4 no longer toggles automatic playback");
        auto_switch=1'b0;
        repeat(4) @(posedge clk);
        check(!auto_enabled && !dut.sync_mode,"SW3 down restores manual playback");
        remote_prev_toggle=~remote_prev_toggle;
        begin : wait_previous
            integer t;
            t=0;
            while(active_image!=0 && t<100_000) begin @(posedge clk);t=t+1;end
            check(t<100_000,"previous request moves image 2 back to image 1");
        end
        remote_prev_toggle=~remote_prev_toggle;
        begin : wait_wrap
            integer t;
            t=0;
            while(active_image!=3 && t<100_000) begin @(posedge clk);t=t+1;end
            check(t<100_000,"previous request wraps image 1 to image 4");
        end
        demo_force_auto=1'b1;
        repeat(4) @(posedge clk);
        check(auto_enabled,"demo temporarily enables playback with SW3 down");
        demo_force_auto=1'b0;
        repeat(4) @(posedge clk);
        check(!auto_enabled,"leaving demo follows SW3 again");
        if(errors==0)$display("ALL PASSED: SW3 auto and KEY4 previous");
        else $fatal(1,"SW3 auto / previous failures: %0d",errors);
        $finish;
    end
    if (PREVIEW_TEST) begin
        disk_clear;
        put_bmp(10,0);put_bmp_half(11,1);put_bmp(12,2);put_bmp(13,3);
        auto_init=1'b0;
        restart;
        wait_scan_and_first(ok);
        check(ok && display_valid && active_image==0,"first image stays displayed");
        preview_requested=1'b1;
        begin : wait_preview
            integer t;
            t=0;
            while(preview_valid_mask!=4'b1111 && t<2_000_000) begin @(posedge clk);t=t+1;end
            check(t<2_000_000 && preview_loads==4,"four previews completed");
        end
        check(active_image==0 && disp_buf_idx==0 && write_buf_idx==0,
              "preview loads never switch or repurpose the displayed frame");
        check(image_scale_modes[3:2]==2'd1,
              "focused second preview keeps its 320x240 source-size metadata");
        disk_clear;
        put_bmp(10,0);put_bmp(11,1);put_bmp(12,2);put_bmp(13,3);
        put_wav(14,700,48000);
        preview_loads=0;
        restart;
        wait_scan_and_first(ok);
        wait_wav_ready(ok);
        check(ok && wav_ready && wav_loads==1,"WAV finishes before preview background loads");
        begin : wait_preview_with_wav
            integer t;
            t=0;
            while(preview_valid_mask!=4'b1111 && t<2_000_000) begin @(posedge clk);t=t+1;end
            check(t<2_000_000 && preview_loads==4,"four previews complete with WAV available");
        end
        $display("ALL PASSED: SD preview loading");$finish;
    end
    if (RESIDENT_TEST) begin
        $display("== resident four-frame cache, short WAV");
        disk_clear;
        put_bmp(10,0);put_bmp(11,1);put_bmp(12,2);put_bmp(13,3);
        put_wav(14,700,48000);
        restart;
        wait_scan_and_first(ok);
        wait_wav_ready(ok);
        check(ok && resident_mode && wav_words==512,
              "short WAV selects four-frame residency");
        wait_preloaded(ok);
        check(ok && dut.load_idx==1 && bmp_buf_ok(1,1),
              "photo 2 is resident in bank 1");
        press_next;
        wait_preloaded(ok);
        check(ok && dut.load_idx==2 && bmp_buf_ok(2,2),
              "photo 3 is resident in bank 2");
        press_next;
        wait_preloaded(ok);
        check(ok && dut.load_idx==3 && bmp_buf_ok(3,3),
              "photo 4 is resident in bank 3");
        press_next;
        wait_preloaded(ok);
        check(ok && dut.load_idx==0 && bmp_buf_ok(0,0),
              "photo 1 remains resident after photo 4");
        begin : no_reload
            integer before_loads;
            before_loads=loads;
            press_next;
            repeat(200) @(posedge clk);
            check(dut.img_idx==0 && loads==before_loads,
                  "photo 4 to photo 1 switches without another card read");
        end
        wait_preloaded(ok);
        press_auto;
        begin : cached_beat
            integer before_loads, lat;
            before_loads=loads;
            beat(lat);
            check(lat>=0 && lat<=6 && dut.img_idx==1 && loads==before_loads,
                  "music beat switches cached photo without a card read");
        end
        press_auto;
        begin : direct_cache
            integer before_loads, t;
            before_loads=loads;
            select_image(2'd3);
            t=0;
            while(dut.img_idx!=3 && t<100_000) begin #1000; t=t+1; end
            check(t<100_000 && bmp_buf_ok(disp_buf_idx,3) &&
                  loads==before_loads,
                  "PIC 4 selects resident photo without a card read");
        end
        press_auto;
        wait_preloaded(ok);
        begin : direct_resume
            integer lat;
            beat(lat);
            check(ok && lat>=0 && lat<=6 && dut.img_idx==0,
                  "automatic beat resumes from directly selected photo");
        end
        begin : direct_low_index
            integer t;
            select_image(2'd1);
            t=0;
            while(dut.img_idx!=1 && t<100_000) begin #1000; t=t+1; end
            check(t<100_000 && bmp_buf_ok(disp_buf_idx,1),
                  "PIC 2 selects resident photo by index 1");
        end

        $display("== long WAV retains original double-buffer path");
        disk_clear;
        put_bmp(10,0);put_bmp(11,1);put_bmp(12,2);put_bmp(13,3);
        put_wav(14,1500,48000);
        restart;
        wait_scan_and_first(ok);
        wait_wav_ready(ok);
        check(ok && !resident_mode && wav_words==1024,
              "long WAV keeps full audio capacity and two-frame mode");
        wait_preloaded(ok);
        press_next;
        wait_preloaded(ok);
        check(ok && dut.load_idx==2 && write_buf_idx==0,
              "long WAV still reuses the two image buffers");
        begin : direct_long
            integer before_loads, t;
            before_loads=loads;
            select_image(2'd3);
            t=0;
            while(dut.img_idx!=3 && t<100_000) begin #1000; t=t+1; end
            check(t<100_000 && loads>before_loads &&
                  bmp_buf_ok(disp_buf_idx,3),
                  "PIC 4 loads selected photo in double-buffer mode");
        end

        $display("== no WAV uses resident banks with timed autoplay");
        disk_clear;
        put_bmp(10,0);put_bmp(11,1);put_bmp(12,2);put_bmp(13,3);
        auto_init=1'b1;
        restart;
        wait_scan_and_first(ok);
        check(ok && resident_mode && !wav_ready,
              "no WAV enables four-frame residency");
        begin : timed_resident
            integer t, n, before_loads;
            for(n=1;n<=4;n=n+1) begin
                t=0;
                while(dut.img_idx!=(n%4) && t<3000) begin #1000; t=t+1; end
                check(t<3000 && disp_buf_idx==(n%4),
                      "timed autoplay reaches its resident bank");
            end
            before_loads=loads;
            t=0;
            while(dut.img_idx!=1 && t<3000) begin #1000; t=t+1; end
            check(t<3000 && loads==before_loads,
                  "second timed lap reuses cached photo without reading card");
        end

        $display("== invalid direct selection leaves a smaller slideshow intact");
        disk_clear;
        put_bmp(10,0);put_bmp(11,1);put_wav(12,700,48000);
        auto_init=1'b0;
        restart;
        wait_scan_and_first(ok);
        wait_wav_ready(ok);
        begin : invalid_target
            integer before_loads;
            before_loads=loads;
            select_image(2'd3);
            repeat(200) @(posedge clk);
            check(ok && dut.img_idx==0 && loads==before_loads,
                  "PIC 4 is ignored when only two pictures exist");
        end
        if(errors==0)$display("== ALL PASSED");
        else $display("== %0d FAILED",errors);
        $finish;
    end
    // ===================================================================
    $display("== 1. 4 BMP then WAV (700 words -> 512)");
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    put_wav(14, 700, 48000);
    restart;
    wait_scan_and_first(ok);
    check(ok, "scan done and first image shown");
    check(dut.img_sector0 == 10 && dut.img_sector1 == 11 && dut.img_sector2 == 12 && dut.img_sector3 == 13,
          "BMP sectors 10..13");
    check(dut.wav_found && dut.wav_sector == 14, "WAV found at sector 14");
    check(wav_words == 512, "wav_words = 512 (700 rounded down to 256 multiple)");
    check(bmp_buf_ok(0, 0), "buffer 0 = image 0, 128 pixels correct");
    wait_wav_ready(ok);
    check(ok, "wav_ready");
    check(wav_loads == 1, "WAV loaded exactly once");
    check(wav_buf_bad(512) == 0, "audio area = 512 samples, all correct {L,R}");
    check(!disp_moved_during_wav && disp_buf_idx == 0 && display_valid, "display untouched during WAV load");

    $display("== 2. transition toggle after WAV: image 1 into buffer 1, audio stays ready");
    manual_next_toggle = ~manual_next_toggle;
    begin : w2 integer t; t = 0; while (disp_buf_idx != 1 && t < 100_000) begin #1000; t = t + 1; end end
    check(disp_buf_idx == 1 && bmp_buf_ok(1, 1), "buffer 1 = image 1, now displayed");
    check(display_scale_mode == 2'd0, "native image reports 640x480 source");
    check(active_image == 2'd1, "OSD reports displayed image 2");
    check(wav_ready && wav_loads == 1, "wav_ready kept, no WAV reload");

    // ===================================================================
    $display("== 3. WAV first (1500 words -> clamp 1024), BMPs after");
    disk_clear;
    put_wav(2, 1500, 48000);
    put_bmp(20, 0); put_bmp(21, 1); put_bmp(22, 2); put_bmp(23, 3);
    restart;
    wait_scan_and_first(ok);
    check(ok && dut.img_sector0 == 20 && dut.img_sector3 == 23, "BMP sectors 20..23 found after WAV");
    check(dut.wav_sector == 2 && wav_words == 1024, "WAV at 2, clamped to WAV_MAX_WORDS = 1024");
    wait_wav_ready(ok);
    check(ok && wav_buf_bad(1024) == 0, "audio area = first 1024 samples, all correct");

    // ===================================================================
    $display("== 4. no WAV: scan stops GAP sectors after the 4th BMP");
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    restart;
    wait_scan_and_first(ok);
    $display("        scan stopped at sector %0d", dut.bmp_read_m0.scan_sector);
    check(ok && !dut.wav_found, "first image shown, no WAV");
    check(dut.bmp_read_m0.scan_sector == 14 + GAP - 1, "stopped at 4th BMP + GAP");
    #20_000_000;
    check(!wav_ready && wav_loads == 0, "no WAV load attempted");

    // ===================================================================
    $display("== 5. WAV at 44.1kHz is ignored");
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    put_wav(14, 700, 44100);
    restart;
    wait_scan_and_first(ok);
    check(ok && !dut.wav_found, "44.1kHz WAV not accepted");

    // ===================================================================
    $display("== 6. image load times out (no write_finish): retry once automatically");
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    restart;
    wait_scan_and_first(ok);
    drop_next_finish = 1'b1;
    press_next;
    begin : w6wait                                      // 等超时 + 自动重试走完（不写死时间，随时钟缩放）
        integer t; t = 0;
        while (dut.load_busy && t < 300_000) begin #1000; t = t + 1; end
    end
    check(!dut.load_busy && dut.scan_done, "load recovers without rescanning the card");
    check(disp_buf_idx == 1 && dut.img_idx == 1,
          "a timed-out photo retries automatically and becomes visible");
    check(!recovery_failed, "successful retry leaves the health flag clear");
    press_next;
    begin : w6 integer t; t = 0; while (disp_buf_idx != 0 && t < 100_000) begin #1000; t = t + 1; end end
    check(disp_buf_idx == 0 && dut.img_idx == 2 && bmp_buf_ok(0, 2),
          "next press still advances after recovery");

    $display("== 6b. corrupt registered BMP retries then skips without replacing the old photo");
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    restart;
    wait_scan_and_first(ok);
    card.disk[11*512] = "X";
    press_next;
    begin : w6b integer t; t = 0; while (dut.img_idx != 2 && t < 100_000) begin #1000; t = t + 1; end end
    check(dut.img_idx == 2 && display_valid && recovery_failed,
          "bad image 1 skipped; healthy image 2 displayed");
    check(bmp_buf_ok(disp_buf_idx,2), "the displayed frame is complete after skip");

    $display("== 6c. first photo fails after scan pause: resume scan and show the next healthy photo");
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    restart;
    wait(dut.scan_paused);
    card.disk[10*512] = "X";
    begin : w6c integer t; t = 0;
        while ((!display_valid || dut.img_idx != 1) && t < 200_000) begin #1000; t = t + 1; end
    end
    check(display_valid && dut.img_idx == 1 && dut.bad_image_mask[0],
          "bad first photo skipped and second photo displayed");
    check(bmp_buf_ok(disp_buf_idx,1), "second photo is complete after first-photo failure");

    $display("== 6d. truncated BMP header is rejected before a partial frame write");
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    restart;
    wait_scan_and_first(ok);
    put32(11*512 + 2, 100); // File claims only 100 bytes; dimensions still require a full frame.
    press_next;
    begin : w6d integer t; t = 0;
        while (dut.img_idx != 2 && t < 100_000) begin #1000; t = t + 1; end
        check(t < 20_000, "truncated file skipped without two 30ms load timeouts");
    end
    check(dut.img_idx == 2 && bmp_buf_ok(disp_buf_idx,2),
          "truncated image never replaces the complete displayed frame");

    $display("== 6f. FAT32 directory, fragmented media, and playlist boot");
    disk_clear;
    put_bmp_double(20,6);
    put_bmp(24,1);put_bmp(25,2);put_bmp(26,3);
    put_wav(28,700,48000);
    copy_sector(20,80);copy_sector(21,85);
    copy_sector(22,90);copy_sector(23,95);
    copy_sector(24,40);copy_sector(25,41);copy_sector(26,42);
    copy_sector(28,60);copy_sector(29,65);copy_sector(30,70);
    copy_sector(31,75);copy_sector(32,100);copy_sector(33,105);
    fat_volume_header;
    put32(512+80*4,85);put32(512+85*4,90);
    put32(512+90*4,95);put32(512+95*4,32'h0fffffff);
    put32(512+40*4,32'h0fffffff);put32(512+41*4,32'h0fffffff);
    put32(512+42*4,32'h0fffffff);
    put32(512+60*4,65);put32(512+65*4,70);
    put32(512+70*4,75);put32(512+75*4,100);
    put32(512+100*4,105);put32(512+105*4,32'h0fffffff);
    put32(512+45*4,32'h0fffffff);
    fat_dir_entry(0,"PIC1    BMP",80,54+BMP_W*BMP_H*12);
    fat_dir_entry(32,"PIC2    BMP",40,BMP_BYTES);
    fat_dir_entry(64,"PIC3    BMP",41,BMP_BYTES);
    fat_dir_entry(96,"PIC4    BMP",42,BMP_BYTES);
    fat_dir_entry(128,"MUSIC   WAV",60,44+700*4);
    fat_dir_entry(160,"PLAYLISTTXT",45,16);
    card.disk[2*512+192]=0;
    card.disk[45*512+0]="1"; card.disk[45*512+1]=",";
    card.disk[45*512+2]="8"; card.disk[45*512+3]=",";
    card.disk[45*512+4]="0"; card.disk[45*512+5]=",";
    card.disk[45*512+6]="X"; card.disk[45*512+7]=8'h0a;
    card.disk[45*512+8]="2"; card.disk[45*512+9]=",";
    card.disk[45*512+10]="8"; card.disk[45*512+11]=",";
    card.disk[45*512+12]="0"; card.disk[45*512+13]=",";
    card.disk[45*512+14]="Y"; card.disk[45*512+15]=8'h0a;
    restart;
    begin : playlist_boot
        integer t;
        t=0;
        while (!display_valid && t<100_000) begin #1000; t=t+1; end
        check(display_valid && dut.list_active && !dut.scan_done &&
              active_image==0 && bmp_double_ok(0,6),
              "playlist first image becomes visible before scan completes");
    end
    wait_scan_and_first(ok);
    check(ok && dut.fat_index_active && bmp_double_ok(0,6),
          "fragmented 1280x960 photo loads through FAT32 cluster chain");
    wait_wav_ready(ok);
    check(ok && wav_buf_bad(512)==0,
          "fragmented WAV loads through FAT32 and keeps PCM sample order");
    wait_preloaded(ok);
    press_auto;
    check(dut.sync_mode,
          "playlist seconds must not override audio beat synchronization");
    begin : w6f integer lat;beat(lat);
        check(lat>=0 && dut.img_idx==1 && bmp_buf_ok(1,1),
              "music beat switches to FAT32 photo 2");
    end
    begin : w6f_pending_beat
        integer t;
        reg [3:0] old_pos;
        reg [1:0] old_image;
        repeat (4) @(posedge clk);
        old_pos = dut.list_pos;
        old_image = dut.img_idx;
        t = 0;
        while (!dut.preload_mode && t < 100_000) begin @(posedge clk); t=t+1; end
        check(dut.preload_mode && !dut.preloaded,
              "next playlist photo enters background preload");
        @(posedge clk) beat_toggle <= ~beat_toggle;
        repeat (20) @(posedge clk);
        check(dut.beat_pending && dut.list_pos == old_pos && dut.img_idx == old_image,
              "pending audio beat must not advance subtitle before photo commit");
        t = 0;
        while (dut.img_idx == old_image && t < 2_000_000) begin @(posedge clk); t=t+1; end
        repeat (4) @(posedge clk);
        check(dut.img_idx != old_image && dut.list_pos != old_pos,
              "subtitle advances when pending photo actually commits");
    end

    $display("== 6e. WAV beats continue after a damaged preloaded photo is skipped");
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    put_wav(14, 700, 48000);
    restart;
    wait_scan_and_first(ok);
    wait_wav_ready(ok);
    wait_preloaded(ok);
    card.disk[12*512] = "X";
    press_auto;
    begin : w6e
        integer lat;
        beat(lat);
        check(lat >= 0 && dut.img_idx == 1, "first beat shows healthy photo 1");
        wait_preloaded(ok);
        check(ok && dut.bad_image_mask[2] && dut.load_idx == 3,
              "damaged photo 2 is retried then skipped during preload");
        beat(lat);
        check(lat >= 0 && dut.img_idx == 3 && bmp_buf_ok(disp_buf_idx,3),
              "next beat shows photo 3 without losing audio synchronization");
    end

    // ===================================================================
    $display("== 7. sync mode: preload next image, switch exactly on the beat");
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    put_wav(14, 700, 48000);
    restart;
    wait_scan_and_first(ok);
    wait_wav_ready(ok);
    check(ok && img_count == 4, "WAV ready, img_count = 4");
    begin : s7
        integer lat, i, loads0;
        reg [1:0] d;
        // 自动轮播关着：仍预加载下一张，节拍不起作用
        #5_000_000;
        wait_preloaded(ok);
        check(ok && next_image_ready && dut.load_idx==1 && bmp_buf_ok(1,1),
              "auto off: next image still preloaded for KEY2");
        beat(lat);
        check(lat == -1 && disp_buf_idx == 0, "auto off: beat ignored");
        press_auto;
        check(dut.auto_play_en && dut.sync_mode, "KEY4: sync mode on");
        check(auto_enabled, "OSD reports automatic mode");
        wait_preloaded(ok);
        check(ok && dut.img_idx == 0 && dut.load_idx == 1 && disp_buf_idx == 0, "image 1 preloaded into back buffer, still showing image 0");
        #100_000;
        check(dut.auto_cnt == 0, "WAV mode leaves the unused one-second timer idle");
        check(display_scale_mode == 2'd0, "preload keeps the displayed source-size label");
        check(bmp_buf_ok(1, 1), "back buffer content = image 1");
        #20_000_000;
        check(disp_buf_idx == 0, "no switch without a beat (1s timer not used in sync mode)");
        for (i = 1; i <= 5; i = i + 1) begin
            beat(lat);
            $display("        beat %0d: switch %0d cycles after beat, now image %0d", i, lat, dut.img_idx);
            check(lat >= 0 && lat <= 6 && dut.img_idx == (i % 4), "switch within 6 cycles of the beat, next image");
            wait_preloaded(ok);
            check(ok && dut.load_idx == ((i + 1) % 4), "next image preloaded");
        end
    end

    $display("== 8. KEY2 while preloaded: instant switch without reading the card");
    begin : s8
        integer loads0, t, lat;
        reg [1:0] d0;
        loads0 = loads;
        d0 = disp_buf_idx;
        key_next = 1'b0;
        t = 0;
        while (disp_buf_idx == d0 && t < 200_000) begin @(posedge clk); t = t + 1; end
        $display("        switched %0d cycles after key down (debounce 2000)", t);
        key_next = 1'b1; #50_000;
        check(disp_buf_idx != d0 && t < 2100, "switched right after debounce");
        check(loads == loads0 + 0 || (loads == loads0 + 1 && dut.preload_mode), "no card read for the switch itself (next preload may have started)");
        check(dut.img_idx == 2, "now image 2 (relative advance)");
        wait_preloaded(ok);
        beat(lat);
        check(lat >= 0 && lat <= 6 && dut.img_idx == 3, "next beat continues from there: image 3");
    end

    $display("== 9. beat arrives while the next image is still loading: switch as soon as it is loaded");
    begin : s9
        integer t, lat;
        reg [1:0] d0;
        @(posedge clk);
        while (!dut.preload_mode) @(posedge clk);           // 刚切完，下一张正在读
        d0 = disp_buf_idx;
        @(posedge clk) beat_toggle <= ~beat_toggle;
        repeat (20) @(posedge clk);
        check(dut.beat_pending && disp_buf_idx == d0, "beat remembered, no switch yet");
        t = 0;
        while (disp_buf_idx == d0 && t < 2_000_000) begin @(posedge clk); t = t + 1; end
        check(disp_buf_idx != d0 && dut.img_idx == 0 && !dut.beat_pending, "switched to image 0 when load finished");
    end

    $display("== 10. KEY4 off: beats ignored again, KEY2 still uses the preloaded image");
    begin : s10
        integer lat;
        wait_preloaded(ok);
        press_auto;
        check(!dut.sync_mode, "sync mode off");
        check(!auto_enabled, "OSD reports manual mode");
        beat(lat);
        check(lat == -1, "beat ignored");
        press_next;
        #100_000;
        check(dut.img_idx == 1 && !dut.preloaded, "KEY2 switched to the preloaded image 1");
    end

    $display("== 10b. demo temporarily enables automatic beats and restores prior mode");
    begin : s10b
        integer lat;
        wait_preloaded(ok);
        check(ok && !auto_enabled, "manual mode remains off before demo");
        demo_force_auto = 1'b1;
        #1000;
        check(auto_enabled && dut.sync_mode && !dut.auto_play_en,
              "demo forces automatic beats without changing saved manual mode");
        beat(lat);
        check(lat >= 0 && dut.img_idx == 2, "demo advances a photo on the music beat");
        demo_force_auto = 1'b0;
        #1000;
        wait_preloaded(ok);
        beat(lat);
        check(lat == -1 && !auto_enabled,
              "leaving demo returns to manual mode and ignores beats");
        press_auto;
        check(auto_enabled && dut.auto_play_en, "KEY4 resumes normal automatic mode");
        demo_force_auto = 1'b1;
        #1000;
        demo_force_auto = 1'b0;
        #1000;
        check(auto_enabled && dut.auto_play_en,
              "leaving demo preserves a previously automatic mode");
    end

    $display("== 11. no WAV: original 1s auto play still works");
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    restart;
    wait_scan_and_first(ok);
    press_auto;
    begin : s11
        integer t;
        t = 0;
        while (disp_buf_idx == 0 && t < 3_000) begin #1000; t = t + 1; end   // 1s 计时 = 100000 拍 = 1ms
        check(disp_buf_idx == 1 && !wav_ready && !dut.preloaded, "auto switched by 1s timer without WAV");
        press_auto;
        check(!auto_enabled, "KEY4 returns to manual without WAV");
        demo_force_auto = 1'b1;
        t = 0;
        while (disp_buf_idx == 1 && t < 3_000) begin #1000; t = t + 1; end
        check(disp_buf_idx == 0 && auto_enabled,
              "demo uses timed switching without WAV even from manual mode");
        demo_force_auto = 1'b0;
        #1000;
        check(!auto_enabled, "leaving no-WAV demo restores manual mode");
    end

    $display("== 12. power-on auto play (top ties auto_play_init = 1): no key needed");
    auto_init = 1'b1;
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    put_wav(14, 700, 48000);
    restart;
    wait_scan_and_first(ok);
    check(ok && dut.auto_play_en, "auto play on right after the first image");
    wait_wav_ready(ok);
    check(ok && dut.img_idx == 0 && !disp_moved_during_wav, "image 0 kept until the WAV is loaded (no 1s switch before music)");
    begin : s12
        integer lat;
        wait_preloaded(ok);
        check(ok && dut.sync_mode && disp_buf_idx == 0, "sync mode on by itself, image 1 preloaded");
        beat(lat);
        check(lat >= 0 && lat <= 6 && dut.img_idx == 1, "first beat switches to image 1 without pressing KEY4");
        press_auto;
        check(!dut.auto_play_en && !dut.sync_mode, "KEY4 still turns it off");
    end
    disk_clear;
    put_bmp(10, 0); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    restart;
    wait_scan_and_first(ok);
    begin : s12b
        integer t;
        t = 0;
        while (disp_buf_idx == 0 && t < 3_000) begin #1000; t = t + 1; end
        check(disp_buf_idx == 1 && !wav_ready, "no WAV: 1s auto play starts by itself");
    end
    auto_init = 1'b0;

    $display("== 13. mixed 2x BMP and native BMP");
    disk_clear;
    put_bmp_half(10, 7); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    restart;
    wait_scan_and_first(ok);
    check(ok && img_count == 4 && bmp_half_ok(0,7),
          "half-size BMP is expanded to a full 16x8 frame");
    check(display_scale_mode == 2'd1, "half-size image reports 320x240 source");
    check(image_scale_modes[1:0] == 2'd1,
          "thumbnail metadata keeps the half-size source mode");
    press_next;
    begin : s13 integer t; t=0;
        while (disp_buf_idx != 1 && t < 100_000) begin #1000; t=t+1; end
    end
    check(disp_buf_idx == 1 && bmp_buf_ok(1,1),
          "next native-size BMP still loads without scaling");
    check(display_scale_mode == 2'd0, "native image restores 640x480 source label");
    check(image_scale_modes[1:0] == 2'd1 && image_scale_modes[3:2] == 2'd0,
          "thumbnail metadata keeps both image source modes after switching");

    $display("== 14. larger BMP downsamples to display frame");
    disk_clear;
    put_bmp_double(10, 6); put_bmp(14, 1); put_bmp(15, 2); put_bmp(16, 3);
    restart;
    wait_scan_and_first(ok);
    check(ok && img_count == 4 && bmp_double_ok(0, 6),
          "double-size BMP is reduced to a full 16x8 frame");
    check(display_scale_mode == 2'd2, "large image reports 1280x960 source");
    check(image_scale_modes[1:0] == 2'd2,
          "thumbnail metadata keeps the large source mode");
    press_next;
    begin : s14 integer t; t=0;
        while (disp_buf_idx != 1 && t < 100_000) begin #1000; t=t+1; end
    end
    check(disp_buf_idx == 1 && bmp_buf_ok(1,1),
          "native BMP still loads after a downscaled image");
    check(display_scale_mode == 2'd0, "native image clears the large-source label");

    $display("== 15. 16:9 BMP stretches to 4:3 display frame");
    disk_clear;
    put_bmp_wide(10, 5); put_bmp(11, 1); put_bmp(12, 2); put_bmp(13, 3);
    restart;
    wait_scan_and_first(ok);
    check(ok && img_count == 4 && bmp_wide_ok(0, 5),
          "wide BMP stretches into a full 16x8 frame");
    check(display_scale_mode == 2'd3, "wide image reports 320x180 source");
    check(image_scale_modes[1:0] == 2'd3,
          "thumbnail metadata keeps the wide source mode");
    press_next;
    begin : s15 integer t; t=0;
        while (disp_buf_idx != 1 && t < 100_000) begin #1000; t=t+1; end
    end
    check(disp_buf_idx == 1 && bmp_buf_ok(1,1),
          "native BMP still loads after a stretched image");

    $display("== 16. first BMP appears before remaining files are scanned");
    disk_clear;
    put_bmp(10, 0);
    put_bmp(40, 1); put_bmp(41, 2); put_bmp(42, 3);
    put_wav(43, 700, 48000);
    auto_init = 1'b1;
    restart;
    begin : s16
        integer t;
        t = 0;
        while (!display_valid && t < 200_000) begin #1000; t = t + 1; end
        check(display_valid && !dut.scan_done && bmp_buf_ok(0,0),
              "first image is visible while the remaining scan is pending");
    end
    wait_scan_and_first(ok);
    check(ok && img_count == 4 && dut.wav_found,
          "later BMPs and WAV are still discovered");
    wait_wav_ready(ok);
    check(ok && dut.sync_mode && dut.img_idx == 0,
          "music sync starts after complete scan without skipping image zero");
    auto_init = 1'b0;

    $display("== 17. fewer than four BMPs still start playback after WAV");
    disk_clear;
    put_bmp(10, 0);
    put_wav(11, 700, 48000);
    restart;
    wait_scan_and_first(ok);
    check(ok && img_count == 1 && dut.bmp_read_m0.scan_sector < 128,
          "one BMP followed by WAV finishes scanning without walking 64MB");
    wait_wav_ready(ok);
    check(ok && wav_loads == 1 && bmp_buf_ok(0,0),
          "single-image music playback keeps the first photo");

    $display("== 18. second and fourth half-size BMPs use buffer 1 on music beats");
    auto_init = 1'b1;
    disk_clear;
    put_bmp(10,0); put_bmp_half(11,1); put_bmp(12,2); put_bmp_half(13,3);
    put_wav(14,700,48000);
    restart;
    wait_scan_and_first(ok);
    wait_wav_ready(ok);
    check(ok && img_count==4 && bmp_buf_ok(0,0),
          "first native BMP displays from buffer 0");
    begin : s18
        integer lat;
        wait_preloaded(ok);
        check(ok && dut.load_idx==1 && bmp_half_ok(1,1),
              "second 320x240 BMP is fully expanded into buffer 1");
        beat(lat);
        check(lat>=0 && lat<=6 && disp_buf_idx==1 &&
              active_image==1 && display_scale_mode==1,
              "second image switches to buffer 1 on the beat");
        wait_preloaded(ok);
        check(ok && dut.load_idx==2 && bmp_buf_ok(0,2),
              "third native BMP uses buffer 0");
        beat(lat);
        check(lat>=0 && lat<=6 && disp_buf_idx==0 && active_image==2,
              "third image switches back to buffer 0 on the beat");
        wait_preloaded(ok);
        check(ok && dut.load_idx==3 && bmp_half_ok(1,3),
              "fourth 320x240 BMP is fully expanded into buffer 1");
        beat(lat);
        check(lat>=0 && lat<=6 && disp_buf_idx==1 &&
              active_image==3 && display_scale_mode==1,
              "fourth image switches to buffer 1 on the beat");
    end
    auto_init = 1'b0;

    $display("== 19. playlist KEY4 returns to the previous playlist image");
    auto_init = 1'b1;
    disk_clear;
    put_bmp_double(20,6);
    put_bmp(24,1); put_bmp(25,2); put_bmp(26,3);
    put_wav(28,700,48000);
    copy_sector(20,80);copy_sector(21,85);
    copy_sector(22,90);copy_sector(23,95);
    copy_sector(24,40);copy_sector(25,41);copy_sector(26,42);
    copy_sector(28,60);copy_sector(29,65);
    copy_sector(30,70);copy_sector(31,75);
    copy_sector(32,100);copy_sector(33,105);
    fat_volume_header;
    put32(512+80*4,85);put32(512+85*4,90);
    put32(512+90*4,95);put32(512+95*4,32'h0fffffff);
    put32(512+40*4,32'h0fffffff);put32(512+41*4,32'h0fffffff);
    put32(512+42*4,32'h0fffffff);
    put32(512+60*4,65);put32(512+65*4,70);
    put32(512+70*4,75);put32(512+75*4,100);
    put32(512+100*4,105);put32(512+105*4,32'h0fffffff);
    put32(512+45*4,32'h0fffffff);
    fat_dir_entry(0,"PIC1    BMP",80,54+BMP_W*BMP_H*12);
    fat_dir_entry(32,"PIC2    BMP",40,BMP_BYTES);
    fat_dir_entry(64,"PIC3    BMP",41,BMP_BYTES);
    fat_dir_entry(96,"PIC4    BMP",42,BMP_BYTES);
    fat_dir_entry(128,"MUSIC   WAV",60,44+700*4);
    fat_dir_entry(160,"PLAYLISTTXT",45,16);
    card.disk[2*512+192]=0;
    // 节目单只排图 1 和图 3；图 2/图 4 仍然被扫描到但不进节目单
    card.disk[45*512+0]="1"; card.disk[45*512+1]=",";
    card.disk[45*512+2]="8"; card.disk[45*512+3]=",";
    card.disk[45*512+4]="0"; card.disk[45*512+5]=",";
    card.disk[45*512+6]="X"; card.disk[45*512+7]=8'h0a;
    card.disk[45*512+8]="3"; card.disk[45*512+9]=",";
    card.disk[45*512+10]="8"; card.disk[45*512+11]=",";
    card.disk[45*512+12]="0"; card.disk[45*512+13]=",";
    card.disk[45*512+14]="Y"; card.disk[45*512+15]=8'h0a;
    restart;
    wait_scan_and_first(ok);
    check(ok, "playlist prev test: scan and first image");
    wait_wav_ready(ok);
    check(ok, "playlist prev test: WAV ready");
    wait_preloaded(ok);
    check(ok, "playlist prev test: next playlist image preloaded");
    begin : s19
        integer lat, t;
        beat(lat);
        check(lat >= 0 && dut.img_idx == 2,
              "playlist KEY2/beat advances to playlist image 3");
        remote_prev_toggle = ~remote_prev_toggle;
        t = 0;
        while (dut.img_idx != 0 && t < 2_000_000) begin @(posedge clk); t = t + 1; end
        check(t < 2_000_000 && dut.img_idx == 0,
              "playlist KEY4 returns to previous playlist image 1, not hidden image 2");
        check(dut.img_idx != 1, "playlist KEY4 does not fall back to hidden image 2");
    end
    auto_init = 1'b0;

    $display("");
    if (errors == 0) $display("== ALL PASSED");
    else             $fatal(1,"== %0d FAILED", errors);
    $finish;
end

endmodule

module tb_sw3_auto;
    tb_wav_load #(.SWITCH_TEST(1)) test();
endmodule

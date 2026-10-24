// sd_card_bmp：卡上放两首 WAV，验证 KEY1 长按（audio_next_toggle）按目录顺序切歌、并绕回第一首
//
// 卡模型：真 FAT32 卷 + 4 张 BMP + 2 首 WAV，两首长度故意不同
//         （第 1 首 700 字 → 256 对齐成 512；第 2 首 1024 字，本来就是 256 的倍数）。
// 帧缓存写通道用应答模型代替，长度取和顶层一样的 wav_words 端口
// （顶层 write_len = write_is_wav ? wav_words : FRAME_PIXELS，wav_player 的循环长度也用它），
// 所以这个仿真同时验证"切歌后写入长度/循环长度跟着换"。
// 运行：sim/run.sh tb_wav_select
`timescale 1ns / 1ps

module tb_wav_select;
localparam integer BMP_W = 16, BMP_H = 8;
localparam integer BMP_WORDS = BMP_W * BMP_H;          // 128
localparam integer BMP_BYTES = 54 + BMP_WORDS * 3;     // 438，一个扇区放得下
localparam [20:0]  WAV_MAX = 21'd1024;                 // 仿真里把音频区上限压到 1024 字
localparam integer GAP     = 64;
localparam integer W1_WORDS = 700;                     // 载入时按 256 对齐 → 512
localparam integer W2_WORDS = 1024;                    // 已经是 256 的倍数 → 1024
localparam integer W3_WORDS = 512;                     // 第三首（应急语音）→ 512

reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;                                  // 100MHz

reg  key_next = 1'b1;
reg  manual_next_toggle = 1'b0;
reg  key_auto = 1'b1;
reg  auto_switch = 1'b0;
reg  manual_prev_busy = 1'b0;
reg  demo_force_auto = 1'b0;
reg  auto_init = 1'b0;
reg  beat_toggle = 1'b0;
reg  remote_select_toggle = 1'b0;
reg  [1:0] remote_select_index = 2'd0;
reg  remote_prev_toggle = 1'b0, remote_period_toggle = 1'b0;
reg  [3:0] remote_period_seconds = 4'd1;
reg  audio_next_toggle = 1'b0;                         // 顶层 key1_long_toggle 经 sync_2ff 后进 DUT
wire [2:0] img_count;
wire [1:0] active_image;
wire auto_enabled;
wire [1:0] display_scale_mode;
wire [7:0] image_scale_modes;
wire recovery_failed;
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
    .CLK_FREQ_HZ         (100_000),        // 只影响消抖（20ms → 2000 拍）和轮播 1s 计时
    .LOAD_TIMEOUT_CYCLES (3_000_000),
    .WAV_TIMEOUT_CYCLES  (20_000_000),
    .WAV_MAX_WORDS       (WAV_MAX),
    .ENABLE_RESIDENT     (0),
    .SDRAM_WORDS         (1200),
    .ENABLE_FULL_PREVIEW (0),
    .USE_AUTO_SWITCH     (1),
    .PREVIEW_WORDS       (0),
    .SCAN_WAV_GAP        (GAP)
) dut (
    .clk                 (clk),
    .rst                 (rst),
    .key_next            (key_next),
    .manual_next_toggle  (manual_next_toggle),
    .remote_select_toggle(remote_select_toggle),
    .remote_select_index (remote_select_index),
    .remote_prev_toggle  (remote_prev_toggle),
    .remote_period_toggle(remote_period_toggle),
    .remote_period_seconds(remote_period_seconds),
    .key_auto            (key_auto),
    .auto_play_switch    (auto_switch),
    .manual_prev_busy    (manual_prev_busy),
    .demo_force_auto     (demo_force_auto),
    .auto_play_init      (auto_init),
    .preview_requested   (1'b0),
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
    .audio_select_toggle (1'b0),
    .audio_select_index  (2'd0),
    .audio_next_toggle   (audio_next_toggle),
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

task put_tag(input integer a, input [31:0] s);
    begin card.disk[a] = s[31:24]; card.disk[a+1] = s[23:16]; card.disk[a+2] = s[15:8]; card.disk[a+3] = s[7:0]; end
endtask

task fat_dir_entry(input integer offset, input [87:0] name,
                   input [31:0] cluster, input [31:0] size);
    integer j, a;
    begin
        a = 2*512+offset;
        for (j=0;j<11;j=j+1) card.disk[a+j] = name[(10-j)*8 +: 8];
        card.disk[a+11] = 8'h20;
        put32(a+20, cluster[31:16]);
        put32(a+26, cluster[15:0]);
        put32(a+28, size);
    end
endtask

task fat_volume_header;
    begin
        card.disk[0] = 8'heb;
        card.disk[11] = 8'd0; card.disk[12] = 8'd2;   // 512 字节/扇区
        card.disk[13] = 8'd1;                          // 1 扇区/簇
        card.disk[14] = 8'd1; card.disk[15] = 8'd0;    // 保留扇区 1
        card.disk[16] = 8'd1;                          // 1 个 FAT
        put32(32,128); put32(36,1); put32(44,2);
        card.disk[510] = 8'h55; card.disk[511] = 8'haa;
        put32(512+2*4, 32'h0fffffff);                  // 根目录簇
    end
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

// 两首歌的样本图案必须能区分开
function [31:0] wav_word_a(input integer k);
    wav_word_a = {16'd1000 + k[15:0] * 16'd3, 16'hF000 - k[15:0]};
endfunction

function [31:0] wav_word_b(input integer k);
    wav_word_b = {16'h2000 + k[15:0] * 16'd5, 16'd5000 - k[15:0] * 16'd2};
endfunction

function [31:0] wav_word_c(input integer k);
    wav_word_c = {16'h3000 + k[15:0] * 16'd7, 16'd6000 + k[15:0] * 16'd3};
endfunction

function [31:0] wav_word(input [1:0] track, input integer k);
    case (track)
        2'd0: wav_word = wav_word_a(k);
        2'd1: wav_word = wav_word_b(k);
        default: wav_word = wav_word_c(k);
    endcase
endfunction

task put_wav_track(input integer sec, input integer nwords, input [1:0] track);
    integer a;
    reg [31:0] w;
    begin
        a = sec * 512;
        put_tag(a, "RIFF");      put32(a + 4, 36 + nwords * 4);
        put_tag(a + 8, "WAVE");  put_tag(a + 12, "fmt ");
        put32(a + 16, 16);
        card.disk[a+20] = 8'd1; card.disk[a+21] = 8'd0;   // PCM
        card.disk[a+22] = 8'd2; card.disk[a+23] = 8'd0;   // 立体声
        put32(a + 24, 48000);
        put32(a + 28, 48000 * 4);
        card.disk[a+32] = 8'd4; card.disk[a+33] = 8'd0;
        card.disk[a+34] = 8'd16; card.disk[a+35] = 8'd0;
        put_tag(a + 36, "data"); put32(a + 40, nwords * 4);
        for (i = 0; i < nwords; i = i + 1) begin
            w = wav_word(track, i);
            card.disk[a + 44 + 4*i]     = w[23:16];       // 左低
            card.disk[a + 44 + 4*i + 1] = w[31:24];       // 左高
            card.disk[a + 44 + 4*i + 2] = w[7:0];         // 右低
            card.disk[a + 44 + 4*i + 3] = w[15:8];        // 右高
        end
    end
endtask

// ---------------- 帧缓存写通道应答模型（和顶层一致的写入长度）----------------
// 新的一次写事务用 write_is_wav ? wav_words : ... 当长度，收满就翻 write_finish_toggle。
reg  [3:0]  req_sr = 4'd0;
reg         collecting = 1'b0;
integer     want = 0, got = 0;
reg  [1:0]  cur_idx = 2'd0;
reg         cur_wav = 1'b0;
reg  [31:0] abuf [0:2047];
integer     wav_loads = 0;                      // 完成的 WAV 写事务数
integer     done_words = 0;                     // 最近一次 WAV 事务的写入字数
reg  [1:0]  done_track = 2'd0;                  // 最近一次 WAV 事务对应的音轨号
integer     short_bad = 0;                      // 长度不足/超时类失败
reg         saw_ready_drop = 1'b0;              // 切歌期间音乐确实停了
integer     disp_moved = 0;                     // 切歌期间显示缓冲不应变化

always @(posedge clk) begin
    req_sr        <= {req_sr[2:0], write_req};
    write_req_ack <= req_sr[3];
    if (!wav_ready) saw_ready_drop <= 1'b1;
    if (write_is_wav && disp_buf_idx != 2'd0) disp_moved <= 1;
    if (req_sr[3] && !write_req_ack) begin          // 一次新的写事务
        collecting = 1'b1;
        got        = 0;
        cur_idx    = write_buf_idx;
        cur_wav    = write_is_wav;
        want       = write_is_wav ? wav_words : BMP_WORDS;
        if (write_is_wav) wav_loads = wav_loads + 1;
    end
    if (collecting && write_en) begin
        if (cur_wav) abuf[got] = write_data;
        got = got + 1;
        if (got == want) begin
            collecting = 1'b0;
            write_finish_toggle <= ~write_finish_toggle;
            if (cur_wav) begin
                done_words = got;
                done_track = dut.audio_track;
            end
        end
    end
end

// 调试：音频切换请求脉冲出现时，状态机处在什么状态
reg prev_size_pending = 1'b0;
always @(posedge clk) begin
    if (dut.audio_next_pulse)
        $display("     pulse: bmp_ready=%0b load_busy=%0b scan_paused=%0b count=%0d track=%0d wav_ready=%0b",
                 dut.bmp_ready, dut.load_busy, dut.scan_paused, dut.audio_count_fat,
                 dut.audio_track, dut.wav_ready);
    if (dut.audio_size_pending && !prev_size_pending)
        $display("     request latched at t=%0t (index=%0d)", $time, dut.audio_pending_index);
    prev_size_pending <= dut.audio_size_pending;
end

function integer wav_bad(input [1:0] track, input integer n);
    integer k, bad;
    begin
        bad = 0;
        for (k = 0; k < n; k = k + 1) if (abuf[k] !== wav_word(track, k)) bad = bad + 1;
        wav_bad = bad;
    end
endfunction

// ---------------- 工具 ----------------
task restart;
    begin
        manual_next_toggle = 1'b0;
        remote_select_toggle = 1'b0;
        remote_prev_toggle = 1'b0;
        audio_next_toggle = 1'b0;
        rst <= 1'b1;
        card.remove;
        repeat (20) @(posedge clk);
        card.insert;
        collecting = 1'b0;
        wav_loads = 0;
        saw_ready_drop = 1'b0;
        disp_moved = 0;
        rst <= 1'b0;
    end
endtask

task wait_scan_and_first(output reg ok);
    integer t;
    begin
        t = 0;
        while (!(dut.scan_done && display_valid) && t < 300_000) begin #1000; t = t + 1; end
        ok = dut.scan_done && display_valid;
    end
endtask

task wait_wav_ready(output reg ok);
    integer t;
    begin
        t = 0;
        while (!wav_ready && t < 300_000) begin #1000; t = t + 1; end
        ok = wav_ready;
    end
endtask

// 等第 n 次 WAV 写事务完成
task wait_wav_load(input integer n, output reg ok);
    integer t;
    begin
        t = 0;
        while (wav_loads < n && t < 300_000) begin #1000; t = t + 1; end
        ok = (wav_loads >= n);
    end
endtask

// 等显示切到指定图片（0 基索引）
task wait_img(input [1:0] idx, output reg ok);
    integer t;
    begin
        t = 0;
        while (dut.img_idx != idx && t < 300_000) begin #1000; t = t + 1; end
        ok = (dut.img_idx == idx);
    end
endtask

// 长按 KEY1：audio_next_toggle 翻转一次（顶层是翻转电平 + 3 级打拍 + 边沿检测）。
// 只按一次，之后等待——请求必须被 DUT 记住并在写通道空下来时执行（这就是锁存那条修改要保证的）。
task long_press_next;
    begin
        @(negedge clk);
        audio_next_toggle = ~audio_next_toggle;
    end
endtask

reg ok;

initial begin
    $display("== 4 BMP + 3 WAV files, KEY1 long press switches tracks and linked images");
    disk_clear;
    put_bmp(30,0); put_bmp(31,1); put_bmp(32,2); put_bmp(33,3);
    put_wav_track(40, W1_WORDS, 2'd0);          // 6 个簇：40~45
    put_wav_track(50, W2_WORDS, 2'd1);          // 9 个簇：50~58
    put_wav_track(60, W3_WORDS, 2'd2);          // 5 个簇：60~64
    fat_volume_header;
    // FAT 链
    put32(512+30*4,32'h0fffffff); put32(512+31*4,32'h0fffffff);
    put32(512+32*4,32'h0fffffff); put32(512+33*4,32'h0fffffff);
    put32(512+40*4,41); put32(512+41*4,42); put32(512+42*4,43);
    put32(512+43*4,44); put32(512+44*4,45); put32(512+45*4,32'h0fffffff);
    put32(512+50*4,51); put32(512+51*4,52); put32(512+52*4,53);
    put32(512+53*4,54); put32(512+54*4,55); put32(512+55*4,56);
    put32(512+56*4,57); put32(512+57*4,58); put32(512+58*4,32'h0fffffff);
    put32(512+60*4,61); put32(512+61*4,62); put32(512+62*4,63);
    put32(512+63*4,64); put32(512+64*4,32'h0fffffff);
    // 根目录（目录顺序 = 播放顺序）
    fat_dir_entry(0,   "PIC1    BMP", 30, BMP_BYTES);
    fat_dir_entry(32,  "PIC2    BMP", 31, BMP_BYTES);
    fat_dir_entry(64,  "PIC3    BMP", 32, BMP_BYTES);
    fat_dir_entry(96,  "PIC4    BMP", 33, BMP_BYTES);
    fat_dir_entry(128, "MUSIC1  WAV", 40, 44 + W1_WORDS*4);
    fat_dir_entry(160, "MUSIC2  WAV", 50, 44 + W2_WORDS*4);
    fat_dir_entry(192, "MUSIC3  WAV", 60, 44 + W3_WORDS*4);
    card.disk[2*512+224] = 8'h00;               // 目录项结束

    restart;
    wait_scan_and_first(ok);
    check(ok, "scan done and first image committed");
    check(dut.fat_index_active, "FAT32 directory table is used");
    check(dut.audio_count_fat == 3, "three WAV files are registered (audio_count_fat = 3)");
    $display("     debug: img_sector0=%0d wav_found=%0b wav_sector=%0d wav_words=%0d loads=%0d",
             dut.img_sector0, dut.wav_found, dut.wav_sector, wav_words, wav_loads);

    wait_wav_ready(ok);
    if (!ok) $display("     debug: wav_ready timeout: load_busy=%0b wav_loads=%0d collecting=%0b got=%0d want=%0d wav_tried=%0b",
                      dut.load_busy, wav_loads, collecting, got, want, dut.wav_tried);
    check(ok && wav_loads >= 1, "boot loads the first WAV track");
    check(dut.audio_track == 2'd0, "boot plays the first WAV of the directory");
    check(dut.img_idx == 2'd0, "boot shows image 1");
    check(wav_words == 21'd512 && done_words == 512, "track 1 loads 512 words (700 rounded to 256)");
    check(wav_bad(2'd0, 512) == 0, "track 1 samples are correct");

    // ---- 长按 KEY1：切到第二首 -> 图 4 ----
    $display("== KEY1 long press -> second track, image 3");
    saw_ready_drop = 1'b0;
    long_press_next;
    wait_wav_load(2, ok);
    check(ok, "one KEY1 long press starts the second audio load (request is latched while busy)");
    check(saw_ready_drop, "music stops while the new track loads (wav_ready drops)");
    wait_wav_ready(ok);
    check(ok, "the second audio load completes");
    check(dut.audio_track == 2'd1, "track index moves to the second WAV");
    check(done_words == 1024, "track 2 is written with its own length (1024 words)");
    check(wav_bad(2'd1, 1024) == 0, "track 2 samples are correct");
    check(!disp_moved, "the displayed image is untouched during the WAV write");
    wait_img(2'd2, ok);
    check(ok, "second WAV selects image 3");
    check(!dut.emergency_mode, "second WAV is not emergency mode");
    disp_moved = 1'b0;

    // ---- 再长按：切到第三首 -> 图 2，进入紧急模式 ----
    $display("== KEY1 long press again -> third track, image 2, emergency hold");
    long_press_next;
    wait_wav_load(3, ok);
    check(ok, "another single long press starts the third audio load");
    wait_wav_ready(ok);
    check(ok, "the third audio load completes");
    check(dut.audio_track == 2'd2, "track index moves to the third WAV");
    check(done_words == 512 && wav_bad(2'd2, 512) == 0,
          "third track loads 512 words with correct samples");
    wait_img(2'd1, ok);
    check(ok, "third WAV selects image 2");
    check(dut.emergency_mode, "third WAV enters emergency mode");
    demo_force_auto = 1'b1;
    #100;
    check(!auto_enabled, "emergency mode holds automatic rotation");
    demo_force_auto = 1'b0;

    // ---- 再长按：绕回第一首 -> 图 1，退出紧急模式 ----
    $display("== KEY1 long press again -> wrap back to the first track, image 1");
    long_press_next;
    wait_wav_load(4, ok);
    check(ok, "another single long press starts the fourth audio load (wrap around)");
    wait_wav_ready(ok);
    check(ok, "the fourth audio load completes");
    check(dut.audio_track == 2'd0, "track index wraps back to the first WAV");
    check(done_words == 512 && wav_bad(2'd0, 512) == 0,
          "first track reloads 512 words with correct samples");
    wait_img(2'd0, ok);
    check(ok, "first WAV selects image 1");
    check(!dut.emergency_mode, "leaving the third WAV exits emergency mode");
    demo_force_auto = 1'b1;
    #100;
    check(auto_enabled, "automatic rotation is available after emergency");
    demo_force_auto = 1'b0;
    check(wav_loads == 4, "exactly four audio loads, no extra reload");

    if (errors == 0) $display("ALL PASSED: KEY1 switches WAV tracks and linked images");
    else $fatal(1, "WAV track/image switch failures: %0d", errors);
    $finish;
end
endmodule

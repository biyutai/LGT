// 回归：带 PLAYLIST.TXT 的卡在"播放中拔卡 -> 插回"后必须能恢复首图，
// 并确认节目单解析器从空表重新开始、节目单指针不跨掉卡残留。
// 运行：sim/run.sh tb_playlist_reinsert
`timescale 1ns / 1ps

module tb_playlist_reinsert #(
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
defparam dut.sd_card_top_m0.INIT_TIMEOUT = 2_000_000;   // 40ms @ 50MHz
defparam dut.sd_card_top_m0.READ_TIMEOUT = 500_000;     // 10ms @ 50MHz
defparam dut.MEDIA_RETRY_CYCLES = 10_000_000;            // 200ms: longer than SD init + scan

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


// =====================================================================
// 回归：带 PLAYLIST.TXT 的卡在"播放中拔出 -> 插回"后必须能重新出首图
//
// 曾经的故障：!sd_init_done 复位不清 playlist 指针 nxt_img_q（只在 rst 或
// !list_active 时清 1），而 playlist_parse 的 present 只在 rst 清 0，热插卡期间
// list_active 一直为 1 -> nxt_img_q 保留上一轮的图号。重扫描只找到第 1 张图时
// available_mask 只有 bit0，nxt_target_ok=0 -> can_load_next=0 -> 首图永不加载，
// 且没有读操作让看门狗动作，只能断电恢复。
// 修复：playlist_parse 在 start 时从空表重来；sd_card_bmp 在 !sd_init_done 时
// 一并复位节目单指针。
// =====================================================================
integer t;
reg ok2;
reg reinit_seen = 1'b0;
always @(posedge clk) if (dut.card_reinit) reinit_seen <= 1'b1;
// 监视解析器是否真的重新开始：done 在重挂后应先回 0 再变 1
reg pl_done_fell = 1'b0;
always @(posedge clk) if (!dut.u_playlist_parse.done) pl_done_fell <= 1'b1;

initial begin
    $display("== playlist reinsert repro: mount, play, unplug mid-load, reinsert");

    disk_clear;
    put_bmp(20,0); put_bmp(21,1); put_bmp(22,2); put_bmp(23,3);
    copy_sector(20,40); copy_sector(21,41); copy_sector(22,42); copy_sector(23,43);
    fat_volume_header;
    put32(512+40*4,32'h0fffffff);
    put32(512+41*4,32'h0fffffff);
    put32(512+42*4,32'h0fffffff);
    put32(512+43*4,32'h0fffffff);
    put32(512+45*4,32'h0fffffff);
    fat_dir_entry(0,  "PIC1    BMP",40,BMP_BYTES);
    fat_dir_entry(32, "PIC2    BMP",41,BMP_BYTES);
    fat_dir_entry(64, "PIC3    BMP",42,BMP_BYTES);
    fat_dir_entry(96, "PIC4    BMP",43,BMP_BYTES);
    fat_dir_entry(128,"PLAYLISTTXT",45,32);
    card.disk[2*512+160] = 8'h00;
    // "1,8,0,X\n2,8,0,Y\n3,8,0,Z\n4,8,0,W\n" = 32 字节
    begin : pl
        integer k;
        reg [7:0] s [0:31];
        s[0]="1"; s[1]=","; s[2]="8"; s[3]=","; s[4]="0"; s[5]=","; s[6]="X"; s[7]=8'h0a;
        s[8]="2"; s[9]=","; s[10]="8"; s[11]=","; s[12]="0"; s[13]=","; s[14]="Y"; s[15]=8'h0a;
        s[16]="3"; s[17]=","; s[18]="8"; s[19]=","; s[20]="0"; s[21]=","; s[22]="Z"; s[23]=8'h0a;
        s[24]="4"; s[25]=","; s[26]="8"; s[27]=","; s[28]="0"; s[29]=","; s[30]="W"; s[31]=8'h0a;
        for (k=0;k<32;k=k+1) card.disk[45*512+k] = s[k];
    end

    rst <= 1'b1; repeat (20) @(posedge clk); card.insert; rst <= 1'b0;
    t = 0;
    while (!(dut.scan_done && display_valid) && t < 300_000) begin #1000; t = t + 1; end
    check(dut.scan_done && display_valid, "first mount: scan done and image visible");
    check(dut.list_active, "playlist active");
    $display("        after scan: nxt_img_q=%0d list_pos=%0d list_nxt=%0d entries=%0d",
             dut.nxt_img_q, dut.list_pos, dut.list_nxt, dut.playlist_entries);
    check(dut.nxt_img_q != 3'd1, "playlist pointer has advanced past image 1 (leftover state)");

    // 触发一次从卡加载下一张，在读到一半时拔卡
    @(negedge clk) manual_next_toggle <= 1'b1;
    t = 0;
    while (!dut.sd_sec_read && t < 200_000) begin #1000; t = t + 1; end
    check(dut.sd_sec_read, "next-image load started a card read");
    @(posedge clk);
    card.remove;
    $display("        card removed while sd_sec_read=1");
    t = 0;
    while (dut.sd_mounted && t < 100_000) begin #1000; t = t + 1; end
    check(!dut.sd_mounted, "watchdog drops sd_init_done after card removal");
    check(!display_valid, "display back to cover (display_valid=0)");

    // 插回卡：重挂载、重扫描；清掉"done 曾经为低"的历史，重解析必须让它再掉一次
    pl_done_fell = 1'b0;
    card.insert;
    t = 0;
    while (!dut.sd_mounted && t < 300_000) begin #1000; t = t + 1; end
    check(dut.sd_mounted, "reinsert: sd_init_done back to 1");
    t = 0;
    while (!display_valid && t < 300_000) begin #1000; t = t + 1; end
    $display("        after reinsert: display_valid=%b scan_paused=%b scan_done=%b img_found=%0d entries=%0d nxt_img_q=%0d nxt_target_valid=%b can_load_next=%b list_active=%b",
             display_valid, dut.scan_paused, dut.scan_done, dut.img_found_count, dut.playlist_entries,
             dut.nxt_img_q, dut.next_target_valid_q, dut.can_load_next, dut.list_active);
    $display("        cfg_state=%0d cfg_started=%b cfg_ready=%b pl_state=%0d pl_done=%b",
             dut.cfg_state, dut.cfg_started, dut.cfg_ready,
             dut.u_playlist_parse.state, dut.u_playlist_parse.done);
    check(display_valid, "reinsert with playlist: first image loads and is visible");
    check(dut.next_target_valid_q == 1'b1,
          "reinsert: playlist next pointer is valid in the new scan");
    check(pl_done_fell,
          "reinsert: playlist parser restarted (done dropped during re-parse)");
    check(dut.playlist_entries == 4'd4 && dut.u_playlist_parse.done == 1'b1,
          "reinsert: playlist re-parsed from scratch (4 entries, done)");
    // 首图提交后后台扫描应能继续并结束
    t = 0;
    while (!dut.scan_done && t < 300_000) begin #1000; t = t + 1; end
    check(dut.scan_done, "reinsert: background scan finishes after the first image");

    // ---- 对照：同一流程，卡上没有 PLAYLIST.TXT（list_active=0）应当能恢复 ----
    $display("== control: same remove/reinsert flow without PLAYLIST.TXT");
    disk_clear;
    put_bmp(20,0); put_bmp(21,1); put_bmp(22,2); put_bmp(23,3);
    copy_sector(20,40); copy_sector(21,41); copy_sector(22,42); copy_sector(23,43);
    fat_volume_header;
    put32(512+40*4,32'h0fffffff); put32(512+41*4,32'h0fffffff);
    put32(512+42*4,32'h0fffffff); put32(512+43*4,32'h0fffffff);
    fat_dir_entry(0,  "PIC1    BMP",40,BMP_BYTES);
    fat_dir_entry(32, "PIC2    BMP",41,BMP_BYTES);
    fat_dir_entry(64, "PIC3    BMP",42,BMP_BYTES);
    fat_dir_entry(96, "PIC4    BMP",43,BMP_BYTES);
    card.disk[2*512+128] = 8'h00;
    reinit_seen = 1'b0;
    rst <= 1'b1; repeat (20) @(posedge clk); card.remove; card.insert; rst <= 1'b0;
    t = 0;
    while (!(dut.scan_done && display_valid) && t < 300_000) begin #1000; t = t + 1; end
    check(dut.scan_done && display_valid && !dut.list_active,
          "control: first mount without playlist");
    manual_next_toggle <= ~manual_next_toggle;
    t = 0;
    while (!dut.sd_sec_read && t < 200_000) begin #1000; t = t + 1; end
    @(posedge clk);
    card.remove;
    t = 0;
    while (dut.sd_mounted && t < 100_000) begin #1000; t = t + 1; end
    check(!dut.sd_mounted && !display_valid, "control: card removal detected, cover shown");
    card.insert;
    t = 0;
    while (!dut.sd_mounted && t < 300_000) begin #1000; t = t + 1; end
    t = 0;
    while (!display_valid && t < 300_000) begin #1000; t = t + 1; end
    check(display_valid, "control: without playlist the first image comes back after reinsert");

    if (errors == 0) $display("== ALL PASSED");
    else             $display("== %0d FAILED", errors);
    $finish;
end

endmodule

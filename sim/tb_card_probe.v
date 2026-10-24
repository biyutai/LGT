// 常驻模式拔卡检测：四帧缓存完成后 SD 总线空闲，sd_card_bmp 每 2s 探活读一个扇区；
// 拔卡后读超时，SD 看门狗复位 -> display_valid=0（回 LOGO）；插回后恢复播放。
// 运行：sim/run.sh tb_card_probe
`timescale 1ns / 1ps

module tb_card_probe;
localparam integer BMP_W = 16, BMP_H = 8;
localparam integer BMP_WORDS = BMP_W * BMP_H;
localparam integer BMP_BYTES = 54 + BMP_WORDS * 3;
localparam integer WAV_WORDS = 256;
localparam [20:0]  WAV_MAX = 21'd1024;

reg clk = 1'b0;
reg rst = 1'b1;
always #10 clk = ~clk;                      // 50MHz

reg key_next = 1'b1;
reg key_auto = 1'b1;
reg manual_next_toggle = 1'b0;
reg remote_select_toggle = 1'b0;
reg [1:0] remote_select_index = 2'd0;
reg remote_prev_toggle = 1'b0;
reg remote_period_toggle = 1'b0;
reg [3:0] remote_period_seconds = 4'd1;
reg audio_next_toggle = 1'b0;
reg auto_switch = 1'b0;
reg manual_prev_busy = 1'b0;
reg demo_force_auto = 1'b0;
reg auto_init = 1'b0;
wire [2:0] img_count;
wire [1:0] active_image;
wire auto_enabled;
wire [1:0] display_scale_mode;
wire [7:0] image_scale_modes;
wire recovery_failed;
wire [3:0] preview_valid_mask;
wire write_is_preview;
wire display_valid;
wire sd_mounted;
wire resident_mode;
wire wav_ready, next_image_ready, write_is_wav;
wire [20:0] wav_words;
wire [1:0] write_buf_idx, disp_buf_idx;
wire write_req, write_en;
wire [31:0] write_data;
reg write_finish_toggle = 1'b0;
reg write_req_ack = 1'b0;
wire sd_ncs, sd_dclk, sd_mosi, sd_miso;

sd_card_bmp #(
    .FRAME_WIDTH        (BMP_W),
    .FRAME_HEIGHT       (BMP_H),
    .CLK_FREQ_HZ        (50_000),
    .LOAD_TIMEOUT_CYCLES(3_000_000),
    .WAV_TIMEOUT_CYCLES (20_000_000),
    .WAV_MAX_WORDS      (WAV_MAX),
    .ENABLE_RESIDENT    (1),
    .SDRAM_WORDS        (1200),
    .ENABLE_FULL_PREVIEW(0),
    .USE_AUTO_SWITCH    (1),
    .PREVIEW_WORDS      (0),
    .SCAN_WAV_GAP       (64)
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
    .beat_toggle         (1'b0),
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
    .sd_mounted          (sd_mounted),
    .sub_rd_clk          (clk),
    .SD_nCS              (sd_ncs),
    .SD_DCLK             (sd_dclk),
    .SD_MOSI             (sd_mosi),
    .SD_MISO             (sd_miso)
);
defparam dut.sd_card_top_m0.SPI_LOW_SPEED_DIV = 8;
defparam dut.sd_card_top_m0.INIT_TIMEOUT = 2_000_000;   // 40ms @50MHz
defparam dut.sd_card_top_m0.READ_TIMEOUT = 500_000;     // 10ms @50MHz
defparam dut.MEDIA_RETRY_CYCLES = 2_000_000;            // 40ms

sd_card_model #(.DISK_SECTORS(128)) card (
    .cs_n (sd_ncs), .sclk (sd_dclk), .mosi (sd_mosi), .miso (sd_miso)
);

// ---------------- 卡内容 ----------------
integer i;
task disk_clear;
    begin for (i = 0; i < 128 * 512; i = i + 1) card.disk[i] = 8'h00; end
endtask
task put32(input integer a, input [31:0] v);
    begin
        card.disk[a] = v[7:0]; card.disk[a+1] = v[15:8];
        card.disk[a+2] = v[23:16]; card.disk[a+3] = v[31:24];
    end
endtask
task put_tag(input integer a, input [31:0] s);
    begin
        card.disk[a]=s[31:24]; card.disk[a+1]=s[23:16];
        card.disk[a+2]=s[15:8]; card.disk[a+3]=s[7:0];
    end
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
        card.disk[11] = 8'd0; card.disk[12] = 8'd2;
        card.disk[13] = 8'd1;
        card.disk[14] = 8'd1; card.disk[15] = 8'd0;
        card.disk[16] = 8'd1;
        put32(32,128); put32(36,1); put32(44,2);
        card.disk[510] = 8'h55; card.disk[511] = 8'haa;
        put32(512+2*4, 32'h0fffffff);
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
        put32(a+2, BMP_BYTES); put32(a+10, 54);
        put32(a+14, 40); put32(a+18, BMP_W); put32(a+22, BMP_H);
        card.disk[a+26] = 8'd1; card.disk[a+27] = 8'd0;
        card.disk[a+28] = 8'd24; card.disk[a+29] = 8'd0;
        put32(a+30, 0);
        for (i = 0; i < BMP_WORDS * 3; i = i + 1)
            card.disk[a + 54 + i] = pix_byte(img, i);
    end
endtask
task put_wav(input integer sec, input integer nwords);
    integer a;
    reg [31:0] w;
    begin
        a = sec * 512;
        put_tag(a, "RIFF");      put32(a+4, 36 + nwords*4);
        put_tag(a+8, "WAVE");    put_tag(a+12, "fmt ");
        put32(a+16, 16);
        card.disk[a+20] = 8'd1; card.disk[a+21] = 8'd0;
        card.disk[a+22] = 8'd2; card.disk[a+23] = 8'd0;
        put32(a+24, 48000); put32(a+28, 48000*4);
        card.disk[a+32] = 8'd4; card.disk[a+33] = 8'd0;
        card.disk[a+34] = 8'd16; card.disk[a+35] = 8'd0;
        put_tag(a+36, "data"); put32(a+40, nwords*4);
        for (i = 0; i < nwords; i = i + 1) begin
            w = {16'd1000 + i[15:0]*16'd3, 16'hF000 - i[15:0]};
            card.disk[a+44+4*i]   = w[23:16];
            card.disk[a+44+4*i+1] = w[31:24];
            card.disk[a+44+4*i+2] = w[7:0];
            card.disk[a+44+4*i+3] = w[15:8];
        end
    end
endtask

// ---------------- 帧写应答模型 ----------------
reg [3:0] req_sr = 4'd0;
reg collecting = 1'b0;
integer want = 0, got = 0;
reg cur_wav = 1'b0;
always @(posedge clk) begin
    req_sr <= {req_sr[2:0], write_req};
    write_req_ack <= req_sr[3];
    if (req_sr[3] && !write_req_ack) begin
        collecting = 1'b1;
        got = 0;
        cur_wav = write_is_wav;
        want = write_is_wav ? wav_words : BMP_WORDS;
    end
    if (collecting && write_en) begin
        got = got + 1;
        if (got == want) begin
            collecting = 1'b0;
            write_finish_toggle <= ~write_finish_toggle;
        end
    end
end

// ---------------- 检查 ----------------
integer errors = 0;
task check(input cond, input [8*72-1:0] msg);
    begin
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s (t=%0t)", msg, $time); errors = errors + 1; end
    end
endtask

integer t;
initial begin
    disk_clear;
    put_bmp(30, 0);
    put_wav(40, WAV_WORDS);
    fat_volume_header;
    put32(512+30*4, 32'h0fffffff);
    put32(512+40*4, 41); put32(512+41*4, 42); put32(512+42*4, 32'h0fffffff);
    fat_dir_entry(0,  "PIC1    BMP", 30, BMP_BYTES);
    fat_dir_entry(32, "MUSIC   WAV", 40, 44 + WAV_WORDS*4);
    card.disk[2*512+64] = 8'h00;

    rst <= 1'b1; repeat (20) @(posedge clk); card.insert; rst <= 1'b0;
    t = 0;
    while (!(dut.scan_done && display_valid) && t < 300_000) begin #1000; t = t + 1; end
    check(dut.scan_done && display_valid, "boot: scan done and first image visible");
    t = 0;
    while (!wav_ready && t < 300_000) begin #1000; t = t + 1; end
    check(wav_ready, "boot: WAV ready");
    check(resident_mode, "resident mode is active (four-frame cache)");

    // 卡在时多等几个探活周期，播放不能被探活干扰
    #10_000_000;
    check(display_valid && wav_ready && resident_mode,
          "card present: periodic probe does not disturb playback");

    // 拔卡：探活读超时 -> 看门狗 -> LOGO
    card.remove;
    t = 0;
    while ((sd_mounted || display_valid) && t < 100_000) begin #1000; t = t + 1; end
    $display("        after unplug: sd_mounted=%b display_valid=%b (%0d us)",
             sd_mounted, display_valid, t);
    check(!display_valid, "card removed: display_valid drops -> LOGO");

    // 插回：走已有热插卡恢复
    card.insert;
    t = 0;
    while (!(sd_mounted && display_valid) && t < 300_000) begin #1000; t = t + 1; end
    check(sd_mounted && display_valid, "card reinserted: playback recovers");

    if (errors == 0) $display("== ALL PASSED");
    else             $display("== %0d FAILED", errors);
    $finish;
end

endmodule

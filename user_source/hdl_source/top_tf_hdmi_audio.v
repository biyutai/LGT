
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 上一张 / 调节减档

    input                       key3,
    input                       sw1,             // 拨上 = 产品信息页（评委模式）
    input                       sw2,
    input                       sw3,
    input                       sw4,            // 演示模式：上拨演示，下拨正常
    inout [3:0]                 matrix_row,
    input [3:0]                 matrix_col_n,
    output [7:0]                led_green8,
    output [7:0]                led_red8,
    output [3:0]                led_green4,
    output                      uart_tx,

    // User-parameter W25Q64 (separate from the FPGA configuration Flash)
    output                      flash_cs_n,
    output                      flash_sclk,
    output                      flash_mosi,
    input                       flash_miso,
    output                      flash_wp_n,
    output                      flash_hold_n,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;
localparam [20:0] BUF2_ADDR = 2 * FRAME_PIXELS;
localparam [20:0] BUF3_ADDR = 3 * FRAME_PIXELS;
localparam [20:0] RESIDENT_AUDIO_ADDR = 4 * FRAME_PIXELS;
localparam [20:0] PREVIEW_WORDS = FRAME_PIXELS / 2;
localparam [20:0] PREVIEW_BASE = 22'd2097152 - {1'b0, PREVIEW_WORDS};
parameter AUDIO_ADDR    = 24'd614400;   // 音频区：两块帧缓存之后，到 2M 字结束
localparam [20:0] AUDIO_WORDS_MAX = PREVIEW_BASE - AUDIO_ADDR[20:0];

// 视频时序：640×480@60（VESA DMT），时序发生器和 HDMI 发射 IP 共用这一组参数
localparam integer H_ACTIVE = 640;
localparam integer H_FP     = 16;
localparam integer H_SYNC   = 96;
localparam integer H_BP     = 48;
localparam integer V_ACTIVE = 480;
localparam integer V_FP     = 10;
localparam integer V_SYNC   = 2;
localparam integer V_BP     = 33;
localparam integer H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 800
localparam integer V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 525

// 像素时钟，必须和 video_pll 的 C0 一致（第 6b 步：25.000 → 25.200MHz）
//   25.2MHz / (800 × 525) = 60.000Hz 整；VESA 标称 25.175MHz，容差 ±0.5%，25.2 偏 +0.1%
//   25.2MHz / 48kHz = 525 整，音频节拍是整数分频；ACR 的 CTS 由 audio_arc_calculate 数出来，自动为 25200
localparam integer PIX_HZ   = 25_200_000;

// 音画同步（第 5c 步）的提前量：切图节拍提前多少个音频样本发出，让画面相对声音的误差落在 ±半帧
//   读请求（场同步开始）→ 新帧第一个像素进 HDMI IP：1 + (场同步 + 场后沿) 行 + 行同步 + 行后沿 + 21 拍对齐 + 2 拍
//   = 28168 个像素时钟；再加半帧 210000，共 238168 拍 = 9.45ms = 453 个样本（25.2MHz、48kHz）
localparam integer SOF_DELAY    = 1 + (V_SYNC + V_BP) * H_TOTAL + H_SYNC + H_BP + 21 + 2;
localparam integer LEAD_SAMPLES = ((SOF_DELAY + H_TOTAL * V_TOTAL / 2) * 48) / (PIX_HZ / 1000);

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data_q;
wire [23:0] cover_mixed_rgb;         // 启动封面/照片（含淡变）叠加层之前的结果
wire        cover_active;            // 首图未就绪：封面阶段
wire        info_page_video;         // SW1 同步到视频域：产品信息页
wire hs_q, vs_q, de_q;
wire [23:0] osd_rgb;
wire [23:0] visual_rgb;
wire [23:0] adjusted_rgb;
wire [23:0] transition_rgb;
wire        display_valid;              // sd_card_clk 域
wire        display_valid_video;

wire        video_read_req;
wire        video_read_req_ack_mem;     // ext_mem_clk 域
wire        video_read_req_ack;         // 同步到 video_clk 域
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack_mem;  // ext_mem_clk 域
wire        sd_card_write_req_ack;      // 同步到 sd_card_clk 域
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  thumbnail_bank_sd;
wire [1:0]  disp_buf_idx;

wire App_rd_en;                         // 送 SDRAM：frame_read_write 读口和音频读口合并
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire fr_rd_en;                          // frame_read_write 的读口
wire [ADDR_BITS-1:0] fr_rd_addr;
wire fr_burst;                          // frame_read_write 读或写通道正在突发
wire au_owner;                          // 音频读口占用 SDRAM（frame_read_write 不再开始新突发）
wire au_mine;                           // SDRAM 返回的数据属于音频读口
wire au_rd_en;
wire [ADDR_BITS-1:0] au_rd_addr;

// WAV（第 5 步）
wire        write_is_wav;               // sd_card_clk 域
wire        write_is_wav_mem;
wire        write_is_preview, write_is_preview_mem;
wire [3:0]  preview_valid_sd;
reg [3:0]   preview_valid_meta, preview_valid_video;
reg         thumb_mode_frame, wall_mode_frame, thumb_read_req_prev;
// 数字标牌节目单（PLAYLIST.TXT）：SD 域解析出来的状态与字幕地址
wire        playlist_active_sd, playlist_active_video;
wire [1:0]  playlist_transition_sd, playlist_transition_video;
wire [3:0]  playlist_pos_sd, playlist_pos_video;
wire [4:0]  playlist_entries_sd;
wire [3:0]  playlist_errors_sd;
wire [3:0]  load_stage;
wire [3:0]  load_stage_video;
wire        playlist_ready_sd, playlist_ready_video, sd_mounted_video;
wire        sd_mounted_sd;
wire        footer_active_sd, footer_active_video;
wire [4:0]  playlist_entries_video;
wire [3:0]  playlist_errors_video;
wire [3:0]  pl_sub_entry;
wire        pl_sub_lang;
wire [5:0]  pl_sub_char;
wire [15:0] pl_sub_code;
wire        video_read_en_base;
wire [23:0] video_read_rgb;
wire        resident_mode_sd, resident_mode_mem;
wire [20:0] audio_base_mem = resident_mode_mem ? RESIDENT_AUDIO_ADDR : AUDIO_ADDR[20:0];
wire [20:0] wav_words;                  // sd_card_clk 域，扫描后不变
wire        wav_ready;                  // sd_card_clk 域
wire        next_image_ready_sd, next_image_ready_video;
wire        wav_ready_mem;
wire        wav_ready_video;

// 音画同步（第 5c 步）
wire        beat_toggle;                // video_clk 域 → sd_card_bmp
wire [2:0]  img_count;                  // sd_card_clk 域，扫描后不变
wire [2:0]  img_count_video;            // 同步到 video_clk 域后的图片数量
wire [1:0]  read_index_mem;             // 本帧显示的缓冲编号，ext_mem_clk 域
wire [1:0]  read_index_video;
wire        wav_played;
wire [7:0]  sync_beat_cnt;
wire [20:0] segment_samples;

// 健康指示（第 6a 步）
wire        video_read_empty;           // video_clk 域
wire [7:0]  wav_underrun_cnt;           // video_clk 域
wire [3:0]  au_err_cnt;                 // ext_mem_clk 域
wire        sd_wd_fired;                // sd_card_clk 域
wire        media_recovery_failed;
wire [3:0]  health;                     // 各域的粘滞标志，见下方"健康指示"
wire [3:0]  health_uart;
wire [7:0] diag_hits_sd, diag_seconds_sd;
wire [3:0] diag_error_sd;
wire diag_busy_sd;
reg [7:0] diag_hits_meta, diag_hits_video;
reg [7:0] diag_seconds_meta, diag_seconds_video;
reg [3:0] diag_error_meta, diag_error_video;
reg diag_busy_meta, diag_busy_video;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;
wire [11:0] pixel_x;     // 与 de_0 对齐，后续图层叠加使用
wire [11:0] pixel_y;
wire [11:0] osd_x, osd_y;
wire [1:0] osd_image_sd, osd_image_video;
wire [1:0] scale_mode_sd, scale_mode_video;
wire [7:0] image_scale_modes_sd, image_scale_modes_video;
wire display_large_1024_sd, display_large_1024_video;
wire [3:0] image_large_1024_sd, image_large_1024_video;
wire osd_auto_sd, osd_auto_video;
wire osd_subtitle_enable, osd_status_enable;
wire thumb_mode_clk, thumb_select_toggle;
wire thumb_confirm_toggle, key3_mode_toggle;
wire thumb_exit_toggle;
wire [1:0] thumb_focus_clk, thumb_select_index;
wire thumb_mode_video;
wire thumb_select_video, key3_mode_video;
reg thumb_select_video_prev, key3_mode_video_prev;
wire thumb_select_pulse_video = thumb_select_video ^ thumb_select_video_prev;
wire key3_mode_pulse_video = key3_mode_video ^ key3_mode_video_prev;
wire [1:0] thumb_focus_video;
wire audio_next_toggle_sd;
wire [1:0] osd_alpha;
wire [2:0] osd_edit_mode;
wire [1:0] transition_kind;
wire [2:0] osd_brightness_level, osd_contrast_level;
wire [3:0] efx_level;                   // 画面特效档位（KEY3 编辑链第 4 档，0~8）
wire [2:0] audio_effect_level;          // 音频音效档位（KEY3 编辑链第 5 档，0~5）
wire [23:0] effect_rgb;                 // 特效之后的图片层
reg [2:0] audio_volume_level;
wire [2:0] persist_volume, persist_brightness, persist_contrast;
wire [1:0] persist_transition;
wire persist_ready, persist_apply, flash_config_valid;
wire demo_mode, demo_mode_sd, demo_frame_step;
reg [1:0] demo_buf_prev;
wire [7:0] led_red_video, led_green_video;
reg [7:0] led_red_meta, led_red_sync, led_green_meta, led_green_sync;
wire sd_key_next, sw3_auto_sd, prev_in_progress_video, prev_in_progress_sd;
wire manual_next_press, manual_prev_press;
wire manual_next_toggle, manual_prev_toggle, transition_busy;
wire rst_sys, rst_sd, rst_mem, rst_video;
wire [3:0] matrix_row_drive_low;
wire [15:0] matrix_keys_down;
wire [15:0] matrix_press_pulse;
genvar matrix_row_bit;
generate
    for (matrix_row_bit = 0; matrix_row_bit < 4; matrix_row_bit = matrix_row_bit + 1) begin: g_matrix_rows
        assign matrix_row[matrix_row_bit] = matrix_row_drive_low[matrix_row_bit] ? 1'b0 : 1'bz;
    end
endgenerate
genvar stage_bit;
generate for (stage_bit=0; stage_bit<4; stage_bit=stage_bit+1) begin: sync_load_stage
    sync_2ff u_stage (.clk(video_clk), .rst(rst_video),
        .d(load_stage[stage_bit]), .q(load_stage_video[stage_bit]));
end endgenerate
matrix_keypad #(.CLK_HZ(PIX_HZ)) u_matrix_keypad (
    .clk(video_clk), .rst(rst_video), .col_n(matrix_col_n),
    .row_drive_low(matrix_row_drive_low), .keys_down(matrix_keys_down),
    .press_pulse(matrix_press_pulse), .release_pulse()
);
reg vs_0_prev;
wire osd_frame_start = vs_0_prev && !vs_0;

thumbnail_button_control u_thumbnail_buttons (
    .clk(clk), .rst(rst_sys), .key1(rst_n), .key2(key1), .key3(key3),
    .confirm_toggle(thumb_confirm_toggle),
    .confirm_long_toggle(thumb_exit_toggle),
    .thumb_mode(thumb_mode_clk), .focus_index(thumb_focus_clk),
    .select_toggle(thumb_select_toggle), .select_index(thumb_select_index),
    .mode_short_toggle(key3_mode_toggle)
);

sync_2ff u_thumb_mode_video (.clk(video_clk), .rst(rst_video), .d(thumb_mode_clk), .q(thumb_mode_video));
sync_2ff u_thumb_select_video (.clk(video_clk), .rst(rst_video), .d(thumb_select_toggle), .q(thumb_select_video));
sync_2ff u_key3_mode_video (.clk(video_clk), .rst(rst_video), .d(key3_mode_toggle), .q(key3_mode_video));
sync_2ff u_thumb_focus0_video (.clk(video_clk), .rst(rst_video), .d(thumb_focus_clk[0]), .q(thumb_focus_video[0]));
sync_2ff u_thumb_focus1_video (.clk(video_clk), .rst(rst_video), .d(thumb_focus_clk[1]), .q(thumb_focus_video[1]));

// HDMI 1.4b 音频发射相关（全部在 video_clk 域）
wire        audio_tick;
wire        audio_valid;
wire        audio_valid_eq;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire [9:0]  av_err_01ms;              // 0.1ms 单位，OSD 第 4 行使用（先声明后赋值）
wire signed [23:0] audio_left_gain, audio_right_gain;   // 音量增益之后、音效之前
wire [23:0] audio_left_raw, audio_right_raw;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// ===================== 时钟与复位 =====================
wire sys_pll_lock;
wire video_pll_lock;

sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// 上电 / 独立复位键：两个 PLL 都锁定并稳定 20ms 后才释放
// Runtime reset is power-on/PLL based.  KEY1 is reserved for controls even
// on board revisions where its physical switch is wired to the reset pad.
// 正常播放时 KEY1 短按切换"四宫格拼贴墙/单图"显示（转场改由矩阵键 S9~S12 直选），
// 长按仍是下一首；缩略图浏览时短按选图进入、长按退出浏览。
wire key1_reset_n = 1'b1;
wire key1_long_toggle;
wire key1_short_toggle;

key1_short_long u_key1_short_long (
    .clk(clk), .key_n(rst_n), .system_rst(rst_sys),
    .browse_mode(thumb_mode_clk), .reset_n(),
    .short_toggle(key1_short_toggle), .browse_short_toggle(thumb_confirm_toggle),
    .long_toggle(key1_long_toggle),
    .browse_long_toggle(thumb_exit_toggle)
);

sys_reset u_sys_reset(
    .clk        (clk),
    .rst_n      (key1_reset_n),
    .pll_locked (sys_pll_lock & video_pll_lock),
    .rst        (rst_sys)
);

// 每个时钟域各自同步撤销复位
rst_sync u_rst_sync_sd    (.clk(sd_card_clk), .arst(rst_sys), .srst(rst_sd));
rst_sync u_rst_sync_mem   (.clk(ext_mem_clk), .arst(rst_sys), .srst(rst_mem));
rst_sync u_rst_sync_video (.clk(video_clk),   .arst(rst_sys), .srst(rst_video));

// KEY1 短按脉冲：声明必须早于首次使用，否则 TD 会把这段同步链当无效逻辑剪掉
reg key1_short_meta, key1_short_sync, key1_short_prev;

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        thumb_select_video_prev <= 1'b0;
        key3_mode_video_prev <= 1'b0;
        key1_short_meta <= 1'b0;
        key1_short_sync <= 1'b0;
        key1_short_prev <= 1'b0;
    end else begin
        thumb_select_video_prev <= thumb_select_video;
        key3_mode_video_prev <= key3_mode_video;
        key1_short_meta <= key1_short_toggle;
        key1_short_sync <= key1_short_meta;
        key1_short_prev <= key1_short_sync;
    end
end

// ===================== 四宫格拼贴墙（正常播放时可切换的显示模式） =====================
// KEY1 短按在"单图/四宫格"之间切换；四宫格直接用扫描时缓存的四张预览图（SDRAM 预览区），
// 每帧只读 153,600 字（单图要读 307,200 字），带宽减半。浏览模式下四宫格本来就显示，
// 且带焦点框，这里不重复画框。
reg wall_mode_video;
wire key1_wall_press = key1_short_sync ^ key1_short_prev;

// 播放证明 LOG / 引导页：KEY2（上一页）/ KEY4（下一页）在自检页窗口内翻页
wire key2_press, key2_sel_press;
key_press_debounce #(.CLK_FREQ_HZ(PIX_HZ)) u_key2_log_page (
    .clk(video_clk), .rst(rst_video), .button_in(key2), .press_pulse(key2_press)
);
key_press_debounce #(.CLK_FREQ_HZ(PIX_HZ)) u_key2_sel_page (
    .clk(video_clk), .rst(rst_video), .button_in(key1), .press_pulse(key2_sel_press)
);

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video)
        wall_mode_video <= 1'b0;
    else if (key1_wall_press)
        wall_mode_video <= ~wall_mode_video;
end

// 帧缓存握手应答从 ext_mem_clk 域同步回请求方的时钟域
// （请求方向已在 frame_fifo_write / frame_fifo_read 内打 3 拍）
sync_2ff u_sync_write_ack (
    .clk (sd_card_clk),
    .rst (rst_sd),
    .d   (sd_card_write_req_ack_mem),
    .q   (sd_card_write_req_ack)
);

sync_2ff u_sync_read_ack (
    .clk (video_clk),
    .rst (rst_video),
    .d   (video_read_req_ack_mem),
    .q   (video_read_req_ack)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== 矩阵键 S13~S16：按编号直接选图 =====================
// S13/S14/S15/S16 → 第 1/2/3/4 张图片（0 基索引 0~3），复用 sd_card_bmp 的
// remote_select 通路（原来给 USB1 串口用过）。请求序号超过实际扫描到的图片数、
// 或那张图损坏时，由 sd_card_bmp 内部忽略，不会切到空画面。缩略图浏览模式下
// 这几颗键不生效（栅格里有自己的选图方式：短按 KEY1）。
reg        img_select_toggle;
reg  [1:0] img_select_index;

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        img_select_toggle <= 1'b0;
        img_select_index <= 2'd0;
    end else if (!thumb_mode_video) begin
        if (matrix_press_pulse[12]) begin
            img_select_index <= 2'd0;
            img_select_toggle <= ~img_select_toggle;
        end else if (matrix_press_pulse[13]) begin
            img_select_index <= 2'd1;
            img_select_toggle <= ~img_select_toggle;
        end else if (matrix_press_pulse[14]) begin
            img_select_index <= 2'd2;
            img_select_toggle <= ~img_select_toggle;
        end else if (matrix_press_pulse[15]) begin
            img_select_index <= 2'd3;
            img_select_toggle <= ~img_select_toggle;
        end
    end
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .FRAME_WIDTH      (H_ACTIVE),
    .FRAME_HEIGHT     (V_ACTIVE),
    // sys_pll 的 C0 是 SD 域时钟：PLL 按 50MHz 输入 / C0 ÷20 = 50MHz 配置
    // （VCO 仍 1000MHz，C1/C2 仍 125MHz）。这个参数只用于 1 秒计数、消抖换算与
    // SPI 分频换算，必须填真实频率。
    .CLK_FREQ_HZ       (50_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4),
    .SD_SPI_HIGH_SPEED_DIV(0),
    .WAV_MAX_WORDS     (AUDIO_WORDS_MAX),
    .PREVIEW_WORDS     (PREVIEW_WORDS),
    .ENABLE_FULL_PREVIEW(1),
    .FAT32_ONLY        (1),
    .ENABLE_TEXT       (0),
    .USE_AUTO_SWITCH   (1)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .key_next          (1'b1),
    .manual_next_toggle(manual_next_toggle),
    .remote_select_toggle(img_select_toggle),
    .remote_select_index (img_select_index),
    .button_select_toggle(thumb_select_toggle),
    .button_select_index (thumb_select_index),
    .key_auto          (1'b1),
    .auto_play_switch  (sw3_auto_sd),
    .manual_prev_busy  (prev_in_progress_sd),
    .demo_force_auto   (demo_mode_sd),
    .auto_play_init    (1'b0),
    .preview_requested (1'b1),
    .sd_wd_fired       (sd_wd_fired),
    .recovery_failed   (media_recovery_failed),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .thumbnail_bank    (thumbnail_bank_sd),
    .preview_valid_mask(preview_valid_sd),
    .write_is_preview  (write_is_preview),
    .disp_buf_idx      (disp_buf_idx),
    .write_is_wav      (write_is_wav),
    .wav_words         (wav_words),
    .wav_ready         (wav_ready),
    .remote_prev_toggle(manual_prev_toggle),
    .remote_period_toggle(1'b0),
    .remote_period_seconds(4'd1),
    .audio_select_toggle(1'b0),
    .audio_select_index(2'd0),
    .audio_next_toggle(audio_next_toggle_sd),
    .resident_mode     (resident_mode_sd),
    .diag_cache_hits   (diag_hits_sd),
    .diag_load_seconds (diag_seconds_sd),
    .diag_error_code   (diag_error_sd),
    .diag_load_busy    (diag_busy_sd),
    .next_image_ready  (next_image_ready_sd),
    .beat_toggle       (beat_toggle),
    .img_count         (img_count),
    .active_image      (osd_image_sd),
    .display_scale_mode(scale_mode_sd),
    .display_large_1024(display_large_1024_sd),
    .image_large_1024(image_large_1024_sd),
    .image_scale_modes (image_scale_modes_sd),
    .auto_enabled      (osd_auto_sd),
    .playlist_active     (playlist_active_sd),
    .playlist_ready      (playlist_ready_sd),
    .text_mode           (),
    .footer_active       (footer_active_sd),
    .sd_mounted          (sd_mounted_sd),
    .load_stage          (load_stage),
    .playlist_entries    (playlist_entries_sd),
    .playlist_errors     (playlist_errors_sd),
    .playlist_pos        (playlist_pos_sd),
    .playlist_transition (playlist_transition_sd),
    .sub_rd_entry        (pl_sub_entry),
    .sub_rd_lang         (pl_sub_lang),
    .sub_rd_char         (pl_sub_char),
    .sub_rd_clk          (video_clk),
    .sub_rd_code         (pl_sub_code),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

// ===================== 视频时序与帧缓存 =====================
video_timing_gen #(
    .H_ACTIVE          (H_ACTIVE),
    .H_FP              (H_FP),
    .H_SYNC            (H_SYNC),
    .H_BP              (H_BP),
    .V_ACTIVE          (V_ACTIVE),
    .V_FP              (V_FP),
    .V_SYNC            (V_SYNC),
    .V_BP              (V_BP),
    .HS_POL            (1'b0),
    .VS_POL            (1'b0)
) u_video_timing_gen (
    .clk               (video_clk),
    .rst               (rst_video),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .x                 (pixel_x),
    .y                 (pixel_y),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_en           (video_read_en_base),
    .read_data         (video_read_rgb),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前输出片内启动画面；提交后在帧边界切换到显示缓冲区
// display_valid 来自 sd_card_clk 域，官方原来直接用；第 6b 步视频时钟与其他时钟设为异步组，补上同步
sync_2ff u_sync_display_valid (
    .clk (video_clk),
    .rst (rst_video),
    .d   (display_valid),
    .q   (display_valid_video)
);
// SW1（板上 C8，手册第 18 页）拨上 = 整屏产品信息页；两级同步进视频域
sync_2ff u_sync_sw1_info (
    .clk (video_clk),
    .rst (rst_video),
    .d   (sw1),
    .q   (info_page_video)
);
video_coord_delay u_video_coord_delay (
    .clk       (video_clk),
    .rst       (rst_video),
    .x         (pixel_x),
    .y         (pixel_y),
    .x_delayed (osd_x),
    .y_delayed (osd_y)
);
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        thumb_mode_frame <= 1'b0;
        wall_mode_frame <= 1'b0;
        thumb_read_req_prev <= 1'b0;
        preview_valid_meta <= 4'd0;
        preview_valid_video <= 4'd0;
    end else begin
        thumb_read_req_prev <= video_read_req;
        if (video_read_req && !thumb_read_req_prev) begin
            thumb_mode_frame <= thumb_mode_video;
            wall_mode_frame <= wall_mode_video;
        end
        preview_valid_meta <= preview_valid_sd;
        preview_valid_video <= preview_valid_meta;
    end
end
// 单图/拼贴墙/缩略图浏览三种状态下，前两种都读预览区、画四宫格
wire preview_view_frame = thumb_mode_frame | wall_mode_frame;
thumbnail_stream_unpack u_thumbnail_stream_unpack (
    .clk(video_clk), .rst(rst_video), .preview_mode(preview_view_frame),
    .base_read_en(video_read_en_base), .x_parity(pixel_x[0]),
    .read_word(video_read_data), .read_en(video_read_en), .rgb(video_read_rgb)
);

wire [23:0] thumb_rgb;
wire thumb_active;
thumbnail_cache u_thumbnail_cache (
    .thumb_mode(preview_view_frame), .focus_enable(thumb_mode_frame),
    .focus_index(thumb_focus_video),
    .full_rgb(vout_data_raw),
    .full_valid_mask(preview_valid_video & {4{preview_view_frame}}),
    .x(osd_x), .y(osd_y), .rgb(thumb_rgb), .active(thumb_active)
);

wire [23:0] video_picture_rgb = thumb_active ? thumb_rgb : vout_data_raw;

always @(posedge clk or posedge rst_sys) begin
    if (rst_sys) begin
        led_red_meta <= 8'd0;
        led_red_sync <= 8'd0;
        led_green_meta <= 8'd0;
        led_green_sync <= 8'd0;
    end else begin
        led_red_meta <= led_red_video;
        led_red_sync <= led_red_meta;
        led_green_meta <= led_green_video;
        led_green_sync <= led_green_meta;
    end
end
assign led_green8 = {led_green_sync[1:0], led_green_sync[7:2]};
assign led_red8 = led_red_sync;

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video)
        vs_0_prev <= 1'b1;
    else
        vs_0_prev <= vs_0;
end

osd_controls #(.CLK_FREQ_HZ(PIX_HZ)) u_osd_controls (
    .clk(video_clk), .rst(rst_video),
    .key_mode(1'b1), .key_mode_pulse(key3_mode_pulse_video),
    .key_next(key1), .key_prev(key2),
    .browse_mode(thumb_mode_video),
    .info_page(info_page_video),
    .prev_available(img_count_video > 3'd1),
    // 矩阵键 S9~S12 直接选四种转场
    .effect_select(matrix_press_pulse[11:8]),
    .demo_frame_step(demo_frame_step), .demo_mode(demo_mode),
    .persist_ready(persist_ready), .persist_apply(persist_apply),
    .persist_brightness(persist_brightness),
    .persist_contrast(persist_contrast),
    .persist_transition(persist_transition),
    .sd_key_next(sd_key_next),
    .manual_next_press(manual_next_press), .manual_prev_press(manual_prev_press),
    .transition_kind(transition_kind),
    .edit_mode(osd_edit_mode), .brightness_level(osd_brightness_level),
    .contrast_level(osd_contrast_level),
    .effect_level(efx_level),
    .audio_effect_level(audio_effect_level),
    .sw2(sw2), .sw4(sw4), .subtitle_select(matrix_press_pulse[7:4]),
    .subtitle_enable(osd_subtitle_enable),
    .status_enable(osd_status_enable), .alpha(osd_alpha)
);

sync_2ff u_sync_demo_mode_sd (
    .clk(sd_card_clk), .rst(rst_sd), .d(demo_mode), .q(demo_mode_sd)
);

sync_2ff u_sync_sw3_auto_sd (
    .clk(sd_card_clk), .rst(rst_sd), .d(sw3), .q(sw3_auto_sd)
);
sync_2ff u_sync_prev_busy_sd (
    .clk(sd_card_clk), .rst(rst_sd),
    .d(prev_in_progress_video), .q(prev_in_progress_sd)
);

// ===================== 参数与播放证明共用 W25Q64 =====================
localparam integer EVENT_LOG_SLOTS = 16;

wire        ev_busy;
wire        ev_scan_done, ev_append_done, ev_log_error;
wire        ev_newest_valid;
wire [15:0] ev_newest_seq;
wire [3:0]  ev_newest_slot;
wire        ev_log_refresh;
wire        log_rd_start;
wire [3:0]  log_rd_slot;
wire        log_rd_done, log_rd_valid;
wire [95:0] log_rd_data;
wire [251:0] log_view;
wire        log_any_valid;

reg  [31:0] uptime_sec;
reg  [24:0] uptime_sec_div;
reg  [31:0] event_gap;
reg         ev_boot_sent;
reg  [23:0] ev_boot_delay;
reg  [1:0]  ev_img_prev;
reg  [3:0]  ev_err_prev;
reg         ev_mount_prev;
reg         ev_pulse;
reg  [2:0]  ev_kind;
reg  [3:0]  ev_item;
reg  [7:0]  ev_detail;

product_flash #(.LOG_SLOTS(EVENT_LOG_SLOTS)) u_product_flash (
    .clk(video_clk), .rst(rst_video),
    .current_brightness(osd_brightness_level),
    .current_contrast(osd_contrast_level),
    .current_transition(transition_kind),
    .current_volume(audio_volume_level),
    .save_enable(!demo_mode),
    .ready(persist_ready), .apply_pulse(persist_apply),
    .loaded_brightness(persist_brightness),
    .loaded_contrast(persist_contrast),
    .loaded_transition(persist_transition),
    .loaded_volume(persist_volume),
    .config_valid(flash_config_valid), .flash_error(),
    .event_pulse(ev_pulse), .event_kind(ev_kind), .event_item(ev_item),
    .event_detail(ev_detail), .uptime_s(uptime_sec),
    .log_busy(ev_busy), .scan_done(ev_scan_done),
    .append_done(ev_append_done), .log_error(ev_log_error),
    .newest_valid(ev_newest_valid), .newest_seq(ev_newest_seq),
    .newest_slot(ev_newest_slot),
    .rd_start(log_rd_start), .rd_slot(log_rd_slot),
    .rd_done(log_rd_done), .rd_valid(log_rd_valid), .rd_data(log_rd_data),
    .spi_cs_n(flash_cs_n), .spi_sclk(flash_sclk),
    .spi_mosi(flash_mosi), .spi_miso(flash_miso),
    .spi_wp_n(flash_wp_n), .spi_hold_n(flash_hold_n)
);
assign ev_log_refresh = ev_scan_done | ev_append_done;

// ---- 事件源：上电 / 换条 / 加载失败 / 掉卡（最小间隔 1s，避免把 Flash 擦穿）----
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        uptime_sec    <= 32'd0;
        uptime_sec_div<= 25'd0;
        event_gap     <= 32'd0;
        ev_boot_sent  <= 1'b0;
        ev_boot_delay <= 24'd0;
        ev_img_prev   <= 2'd0;
        ev_err_prev   <= 4'd0;
        ev_mount_prev <= 1'b0;
        ev_pulse      <= 1'b0;
        ev_kind       <= 3'd0;
        ev_item       <= 4'd0;
        ev_detail     <= 8'd0;
    end else begin
        ev_pulse <= 1'b0;
        if (uptime_sec_div == PIX_HZ - 1) begin
            uptime_sec_div <= 25'd0;
            uptime_sec     <= uptime_sec + 32'd1;
        end else begin
            uptime_sec_div <= uptime_sec_div + 25'd1;
        end
        if (event_gap != 32'd0)
            event_gap <= event_gap - 32'd1;
        ev_img_prev   <= osd_image_video;
        ev_err_prev   <= diag_error_video;
        ev_mount_prev <= sd_mounted_video;


        if (!ev_boot_sent) begin
            if (ev_boot_delay == 24'hffffff) begin
                ev_boot_sent <= 1'b1;
                ev_pulse     <= 1'b1;
                ev_kind      <= 3'd0;
                ev_item      <= {2'b00,osd_image_video};
                ev_detail    <= {7'd0,sd_mounted_video};
                event_gap    <= PIX_HZ;
            end else begin
                ev_boot_delay <= ev_boot_delay + 24'd1;
            end
        end else if (event_gap == 32'd0) begin
            if (osd_image_video != ev_img_prev) begin
                ev_pulse  <= 1'b1;
                ev_kind   <= 3'd1;
                ev_item   <= {2'b00,osd_image_video};
                ev_detail <= 8'd0;
                event_gap <= PIX_HZ;
            end else if ((diag_error_video != 4'd0) && (ev_err_prev == 4'd0)) begin
                ev_pulse  <= 1'b1;
                ev_kind   <= 3'd2;
                ev_item   <= {2'b00,osd_image_video};
                ev_detail <= {4'd0,diag_error_video};
                event_gap <= PIX_HZ;
            end else if (!sd_mounted_video && ev_mount_prev) begin
                ev_pulse  <= 1'b1;
                ev_kind   <= 3'd3;
                ev_item   <= {2'b00,osd_image_video};
                ev_detail <= 8'd1;
                event_gap <= PIX_HZ;
            end
        end
    end
end

sync_2ff u_osd_index_0 (.clk(video_clk), .rst(rst_video), .d(osd_image_sd[0]), .q(osd_image_video[0]));
sync_2ff u_osd_index_1 (.clk(video_clk), .rst(rst_video), .d(osd_image_sd[1]), .q(osd_image_video[1]));
sync_2ff u_osd_auto (.clk(video_clk), .rst(rst_video), .d(osd_auto_sd), .q(osd_auto_video));
sync_2ff u_scale_mode_0 (.clk(video_clk), .rst(rst_video), .d(scale_mode_sd[0]), .q(scale_mode_video[0]));
sync_2ff u_scale_mode_1 (.clk(video_clk), .rst(rst_video), .d(scale_mode_sd[1]), .q(scale_mode_video[1]));
sync_2ff u_display_large_1024 (.clk(video_clk), .rst(rst_video),
    .d(display_large_1024_sd), .q(display_large_1024_video));
genvar scale_bit;
generate for (scale_bit=0; scale_bit<8; scale_bit=scale_bit+1) begin: sync_image_scale
    sync_2ff u_scale (.clk(video_clk), .rst(rst_video),
                      .d(image_scale_modes_sd[scale_bit]),
                      .q(image_scale_modes_video[scale_bit]));
end endgenerate
genvar large_bit;
generate for (large_bit=0; large_bit<4; large_bit=large_bit+1) begin: sync_image_large
    sync_2ff u_large (.clk(video_clk), .rst(rst_video),
        .d(image_large_1024_sd[large_bit]), .q(image_large_1024_video[large_bit]));
end endgenerate
sync_2ff u_next_image_ready (.clk(video_clk), .rst(rst_video),
                             .d(next_image_ready_sd), .q(next_image_ready_video));

// 节目单状态同步进视频域：轮播顺序与时长由 SD 域的解析结果决定，视频域只用它选转场与显示
sync_2ff u_playlist_active (.clk(video_clk), .rst(rst_video),
                            .d(playlist_active_sd), .q(playlist_active_video));
sync_2ff u_playlist_tr_0 (.clk(video_clk), .rst(rst_video),
                          .d(playlist_transition_sd[0]), .q(playlist_transition_video[0]));
sync_2ff u_playlist_tr_1 (.clk(video_clk), .rst(rst_video),
                          .d(playlist_transition_sd[1]), .q(playlist_transition_video[1]));
sync_2ff u_playlist_pos_0 (.clk(video_clk), .rst(rst_video),
                           .d(playlist_pos_sd[0]), .q(playlist_pos_video[0]));
sync_2ff u_playlist_pos_1 (.clk(video_clk), .rst(rst_video),
                           .d(playlist_pos_sd[1]), .q(playlist_pos_video[1]));
sync_2ff u_playlist_pos_2 (.clk(video_clk), .rst(rst_video),
                           .d(playlist_pos_sd[2]), .q(playlist_pos_video[2]));
sync_2ff u_playlist_pos_3 (.clk(video_clk), .rst(rst_video),
                           .d(playlist_pos_sd[3]), .q(playlist_pos_video[3]));
sync_2ff u_playlist_ready (.clk(video_clk), .rst(rst_video),
                           .d(playlist_ready_sd), .q(playlist_ready_video));
sync_2ff u_footer_active (.clk(video_clk), .rst(rst_video),
                          .d(footer_active_sd), .q(footer_active_video));
sync_2ff u_sd_mounted (.clk(video_clk), .rst(rst_video),
                       .d(sd_mounted_sd), .q(sd_mounted_video));
genvar pl_i;
generate
    for (pl_i = 0; pl_i < 5; pl_i = pl_i + 1) begin: g_playlist_entries_sync
        sync_2ff u_entries (.clk(video_clk), .rst(rst_video),
                            .d(playlist_entries_sd[pl_i]), .q(playlist_entries_video[pl_i]));
    end
    for (pl_i = 0; pl_i < 4; pl_i = pl_i + 1) begin: g_playlist_errors_sync
        sync_2ff u_errors (.clk(video_clk), .rst(rst_video),
                           .d(playlist_errors_sd[pl_i]), .q(playlist_errors_video[pl_i]));
    end
endgenerate
// A manual transition selection remains active for all subsequent image switches.
wire [1:0] transition_kind_eff;
playlist_transition_preview u_playlist_transition_preview (
    .clk(video_clk), .rst(rst_video), .playlist_active(playlist_active_video),
    .playlist_kind(playlist_transition_video), .manual_kind(transition_kind),
    .manual_select(((|matrix_press_pulse[11:8]) ||
                    (|matrix_press_pulse[3:0]) ||
                    manual_next_press || manual_prev_press) && !demo_mode),
    .restore_select(persist_apply && flash_config_valid),
    .transition_busy(transition_busy), .effective_kind(transition_kind_eff)
);
// 字幕读口：条目号跟着节目单指针走，字符地址由 OSD 的坐标流水给出
assign pl_sub_entry = playlist_pos_video;

// 扫描到的图片数量在 sd_card_clk 域产生，视频域统一用同步后的值
sync_2ff u_img_count_0 (.clk(video_clk), .rst(rst_video), .d(img_count[0]), .q(img_count_video[0]));
sync_2ff u_img_count_1 (.clk(video_clk), .rst(rst_video), .d(img_count[1]), .q(img_count_video[1]));
sync_2ff u_img_count_2 (.clk(video_clk), .rst(rst_video), .d(img_count[2]), .q(img_count_video[2]));

video_transition u_video_transition (
    .clk(video_clk), .rst(rst_video), .frame_start(osd_frame_start), .de(de),
    .browse_mode(preview_view_frame), .browse_select_pulse(thumb_select_pulse_video),
    .active(display_valid_video), .manual_press(manual_next_press),
    .manual_prev_press(manual_prev_press),
    .prefetch_enabled(wav_ready_video && (img_count_video > 3'd1)),
    .next_ready(next_image_ready_video),
    .buffer_index(read_index_video), .effect_kind(transition_kind_eff),
    .x(osd_x), .y(osd_y), .rgb_in(video_picture_rgb), .rgb_out(transition_rgb),
    .switch_toggle(manual_next_toggle), .prev_toggle(manual_prev_toggle),
    .prev_in_progress(prev_in_progress_video),
    .busy(transition_busy)
);

// 画面特效：纯逐像素运算，放在转场之后、调色之前，只作用于图片层
video_effects u_video_effects (
    .clk(video_clk), .rst(rst_video), .frame_start(osd_frame_start), .de(de),
    .x(osd_x), .y(osd_y), .effect_in(efx_level),
    .rgb_in(transition_rgb), .rgb_out(effect_rgb)
);

video_color_adjust u_video_color_adjust (
    .clk(video_clk), .rst(rst_video), .frame_start(osd_frame_start),
    .brightness_level(osd_brightness_level),
    .contrast_level(osd_contrast_level),
    .rgb_in(effect_rgb), .rgb_out(adjusted_rgb)
);

// ===================== 运行时间戳：状态栏第 4 行的动态文字 =====================
// 板卡没有 RTC，这里显示"上电以来的运行时长"（99 小时循环），字形来自状态栏字库的
// 数字和 ":"，以及新加的"运行"两个汉字。每帧边界更新，帧内不跳字。
localparam integer UPTIME_CYCLES = PIX_HZ;          // 25.2M 拍 = 1 秒
reg [24:0] uptime_div;
reg [3:0]  uptime_ss_lo, uptime_ss_hi;
reg [3:0]  uptime_mm_lo, uptime_mm_hi;
reg [3:0]  uptime_hh_lo, uptime_hh_hi;

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        uptime_div   <= 25'd0;
        uptime_ss_lo <= 4'd0; uptime_ss_hi <= 4'd0;
        uptime_mm_lo <= 4'd0; uptime_mm_hi <= 4'd0;
        uptime_hh_lo <= 4'd0; uptime_hh_hi <= 4'd0;
    end else if (uptime_div == UPTIME_CYCLES - 1) begin
        uptime_div <= 25'd0;
        if (uptime_ss_lo != 4'd9)
            uptime_ss_lo <= uptime_ss_lo + 4'd1;
        else begin
            uptime_ss_lo <= 4'd0;
            if (uptime_ss_hi != 4'd5)
                uptime_ss_hi <= uptime_ss_hi + 4'd1;
            else begin
                uptime_ss_hi <= 4'd0;
                if (uptime_mm_lo != 4'd9)
                    uptime_mm_lo <= uptime_mm_lo + 4'd1;
                else begin
                    uptime_mm_lo <= 4'd0;
                    if (uptime_mm_hi != 4'd5)
                        uptime_mm_hi <= uptime_mm_hi + 4'd1;
                    else begin
                        uptime_mm_hi <= 4'd0;
                        if (uptime_hh_lo != 4'd9)
                            uptime_hh_lo <= uptime_hh_lo + 4'd1;
                        else begin
                            uptime_hh_lo <= 4'd0;
                            if (uptime_hh_hi != 4'd9)
                                uptime_hh_hi <= uptime_hh_hi + 4'd1;
                            else
                                uptime_hh_hi <= 4'd0;
                        end
                    end
                end
            end
        end
    end else begin
        uptime_div <= uptime_div + 25'd1;
    end
end

wire [23:0] uptime_bcd = {uptime_hh_hi, uptime_hh_lo,
                          uptime_mm_hi, uptime_mm_lo,
                          uptime_ss_hi, uptime_ss_lo};

// ===================== 自检行：每秒帧数 + 与时间戳交替 =====================
// uptime_tick 是上面分频出来的秒脉冲；自检行每 4 秒出现一次。（状态栏第 4 行）
wire uptime_tick = (uptime_div == UPTIME_CYCLES - 1);
reg [7:0] fps_count;
reg [7:0] fps_hold;
reg [2:0] diag_phase;

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        fps_count <= 8'd0;
        fps_hold <= 8'd0;
        diag_phase <= 3'd0;
    end else begin
        if (osd_frame_start && fps_count != 8'hff)
            fps_count <= fps_count + 8'd1;
        if (uptime_tick) begin
            fps_hold <= fps_count;
            fps_count <= 8'd0;
            diag_phase <= diag_phase + 3'd1;
        end
    end
end

wire diag_view = diag_phase[2];

// ===================== 开机自检页：首图显示后约 3 秒的健康看板 =====================
// 7 项按顺序：TF 卡挂载 / 图片扫描 / SDRAM 读写环回 / 音频通路 / HDMI 显示锁定 / 参数存档 / 节目单解析。
// 失败只是红点，不阻塞播放（画面照常进片）；SW1 的产品信息页优先级更高。
wire [6:0] selfcheck_ok = {
    playlist_ready_video && (playlist_errors_video == 4'd0),   // 6 节目单解析
    flash_config_valid,                                        // 5 参数存档
    video_pll_lock,                                            // 4 HDMI 显示锁定
    ~(health_uart[1] | health_uart[2]),                        // 3 音频通路（欠载/出错）
    ~health_uart[0],                                           // 2 SDRAM 读写环回（显示缓冲欠载）
    (img_count_video != 3'd0),                                 // 1 图片扫描
    sd_mounted_video                                           // 0 TF 卡挂载
};
reg [1:0] boot_sec_q;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video)
        boot_sec_q <= 2'd0;
    else if (uptime_tick && boot_sec_q != 2'd3)
        boot_sec_q <= boot_sec_q + 2'd1;
end
// 上电自启动越快越好：自检页只占"首图还没出来"的那段时间——第 0 秒留给品牌封面，
// 之后显示自检页，首图一旦就绪（display_valid）立刻让位，绝不压住首图。
wire selfcheck_page = !display_valid_video && sd_mounted_video &&
                      (boot_sec_q >= 2'd1) && !info_page_video;

// 自检页 / LOG 页 / 无内容引导页：KEY2 上一页、KEY4 下一页。
// 只在首图出来之前的页面窗口生效，不抢正常播放时 KEY2/KEY4 的切图/调档功能。
reg [1:0] osd_page;
reg       guide_auto_done;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        osd_page <= 2'd0;
        guide_auto_done <= 1'b0;
    end else begin
        if (selfcheck_page) begin
            if (key2_sel_press)
                osd_page <= (osd_page == 2'd0) ? 2'd2 : osd_page - 2'd1;
            else if (key2_press)
                osd_page <= (osd_page == 2'd2) ? 2'd0 : osd_page + 2'd1;
        end
        // 没有图片时 2 秒后自动落到引导页，仍可用 KEY2/KEY4 翻回自检/日志
        if (!guide_auto_done && boot_sec_q >= 2'd2 && sd_mounted_video &&
            img_count_video == 3'd0 &&
            !info_page_video) begin
            osd_page <= 2'd2;
            guide_auto_done <= 1'b1;
        end
    end
end
// SW1 信息页里再按 KEY4 看 LOG，KEY2 返回信息页；不影响正常播放按键。
reg info_log_page;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video)
        info_log_page <= 1'b0;
    else if (info_page_video) begin
        if (key2_press)
            info_log_page <= 1'b1;
        else if (key2_sel_press)
            info_log_page <= 1'b0;
    end
end
wire log_page   = (selfcheck_page && (osd_page == 2'd1)) ||
                  (info_page_video && info_log_page);
wire guide_page = selfcheck_page && (osd_page == 2'd2);

// Manual mode alone counts idle time; returning from auto starts a fresh minute.
wire any_user_key = key2_sel_press | key2_press | key1_wall_press |
                    key3_mode_pulse_video | (matrix_press_pulse != 16'd0);
wire screensaver;
video_standby #(.IDLE_SECONDS(60)) u_video_standby (
    .clk(video_clk), .rst(rst_video), .tick_1s(uptime_tick),
    .activity(any_user_key), .card_change(sd_mounted_video != ev_mount_prev),
    .manual_mode(~osd_auto_video),
    .standby(screensaver)
);

video_osd_overlay u_video_osd_overlay (
    .clk(video_clk), .rst(rst_video), .frame_start(osd_frame_start),
    .de(de), .x(osd_x), .y(osd_y), .rgb_in(cover_mixed_rgb),
    .subtitle_enable(osd_subtitle_enable),
    .status_enable(osd_status_enable),
    .info_page(info_page_video && ~info_log_page),
    .cover_active(cover_active),
    .standby_mode(screensaver),
    .alpha(osd_alpha),
    .image_index(osd_image_video),
    .browse_mode(thumb_mode_frame), .browse_index(thumb_focus_video),
    .browse_scale_mode(image_scale_modes_video[thumb_focus_video*2 +: 2]),
    .auto_enabled(osd_auto_video),
    .playlist_subtitle(footer_active_video),
    .playlist_sub_code(pl_sub_code),
    .playlist_sub_char(pl_sub_char),
    .playlist_sub_lang(pl_sub_lang),
    .selfcheck_page(selfcheck_page),
    .selfcheck_ok(selfcheck_ok),
    .img_found(img_count_video),
    .playlist_entries(playlist_entries_video),
    .playlist_errors(playlist_errors_video),
    .log_page(log_page), .log_view(log_view), .log_any_valid(log_any_valid),
    .guide_page(guide_page), .av_err_01ms(av_err_01ms),
    .brightness_level(osd_brightness_level),
    .contrast_level(osd_contrast_level), .volume_level(audio_volume_level),
    .edit_mode(osd_edit_mode),
    .demo_mode(demo_mode),
    .transition_kind(transition_kind_eff),
    .scale_mode(scale_mode_video),
    .source_large_1024(thumb_mode_frame ? image_large_1024_video[thumb_focus_video] :
                       display_large_1024_video),
    .timestamp(uptime_bcd),
    .effect_level(efx_level),
    .audio_effect_level(audio_effect_level),
    .health(health_uart),
    .fps(fps_hold),
    .load_seconds(diag_seconds_video),
    .cache_hits(diag_hits_video),
    .underrun_count(wav_underrun_cnt),
    .diag_view(diag_view),
    .rgb_out(osd_rgb)
);

audio_visualizer u_audio_visualizer (
    .clk(video_clk), .rst(rst_video), .frame_start(osd_frame_start),
    .de(de), .x(osd_x), .y(osd_y), .rgb_in(osd_rgb),
    .pcm_valid(audio_valid_eq), .pcm(audio_left_data[23:8]),
    .led_enable(1'b1), .video_enable(~(info_page_video | selfcheck_page |
                                     guide_page | log_page | cover_active)),
    .rgb_out(visual_rgb), .led_red(led_red_video), .led_green(led_green_video)
);
video_startup_screen u_video_startup_screen (
    .clk(video_clk), .rst(rst_video), .frame_start(osd_frame_start),
    .photo_valid(display_valid_video & ~screensaver), .x(osd_x), .y(osd_y),
    .photo_rgb(adjusted_rgb), .rgb_out(cover_mixed_rgb), .cover_active(cover_active)
);
video_output_stage u_video_output_stage (
    .clk(video_clk), .rst(rst_video), .hs(hs), .vs(vs), .de(de), .rgb(visual_rgb),
    .hs_out(hs_q), .vs_out(vs_q), .de_out(de_q), .rgb_out(vout_data_q)
);

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .ext_rd_busy       (au_owner),
    .fr_burst          (fr_burst),
    .read_index_cur    (read_index_mem),
    .read_empty        (video_read_empty),

    .App_rd_en         (fr_rd_en),
    .App_rd_addr       (fr_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en & ~au_mine),     // 音频读口正在读时返回的数据都是音频的
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack_mem),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_index   (disp_buf_idx),
    .read_is_preview   (preview_view_frame),
    .read_preview_addr (PREVIEW_BASE),
    .read_len          (preview_view_frame ? PREVIEW_WORDS : FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack_mem),
    .write_finish      (frame_write_finish),
    .write_addr_0      (write_is_preview_mem ? PREVIEW_BASE : BUF0_ADDR),
    .write_addr_1      (write_is_preview_mem ? PREVIEW_BASE + 21'd160 : BUF1_ADDR),
    .write_addr_2      (write_is_preview_mem ? PREVIEW_BASE + 21'd76800 :
                        write_is_wav_mem ? audio_base_mem : BUF2_ADDR),
    .write_addr_3      (write_is_preview_mem ? PREVIEW_BASE + 21'd76960 : BUF3_ADDR),
    .write_addr_index  (write_is_preview ? thumbnail_bank_sd : write_buf_idx),
    .write_is_wav      (write_is_wav),
    .write_is_preview  (write_is_preview),
    .write_len         (write_is_wav ? {3'd0, wav_words} :
                        write_is_preview ? 21'd38400 : FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

assign App_rd_en   = fr_rd_en | au_rd_en;
assign App_rd_addr = au_mine ? au_rd_addr : fr_rd_addr;     // 不能用 au_owner：等待阶段视频还在发最后一次突发

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== 音频：48kHz 正弦测试音，PCM 直送 HDMI IP =====================
// 在像素时钟下分频出 48kHz（25.2MHz 时正好每 525 拍一个），不需要单独的音频 PLL，也不经过 I2S
audio_sample_tick #(
    .CLK_HZ (PIX_HZ),
    .FS     (48_000)
) u_audio_sample_tick (
    .clk  (video_clk),
    .rst  (rst_video),
    .tick (audio_tick)
);

// Capacity release: the tone generator is kept in the repository but not
// instantiated; the card always supplies MUSIC.WAV.  Without WAV the output
// is silent, which frees enough mslice for the FAT32 fallback.
wire        tone_valid  = 1'b0;
wire [23:0] tone_left   = 24'sd0;
wire [23:0] tone_right  = 24'sd0;

// ===================== 音频：TF 卡 WAV，开机载入 SDRAM 音频区后循环播放 =====================
sync_2ff u_sync_wav_ready_mem (
    .clk (ext_mem_clk),
    .rst (rst_mem),
    .d   (wav_ready),
    .q   (wav_ready_mem)
);

sync_2ff u_sync_wav_ready_video (
    .clk (video_clk),
    .rst (rst_video),
    .d   (wav_ready),
    .q   (wav_ready_video)
);

wire        wav_pop;
wire [31:0] wav_data;
wire        wav_empty;
wire        wav_valid;
wire [23:0] wav_left;
wire [23:0] wav_right;

audio_sdram_stream u_audio_sdram_stream (
    .mem_clk     (ext_mem_clk),
    .mem_rst     (rst_mem),
    .enable      (wav_ready_mem),
    .words       (wav_words),                  // wav_ready 拉高前就已稳定
    .base_addr   (audio_base_mem),
    .fr_burst    (fr_burst),
    .sdr_busy    (Sdr_busy),
    .owner       (au_owner),
    .mine        (au_mine),
    .other_rd_en (fr_rd_en),
    .rd_en       (au_rd_en),
    .rd_addr     (au_rd_addr),
    .sdr_rd_en   (Sdr_rd_en),
    .sdr_rd_dout (Sdr_rd_dout),
    .video_clk   (video_clk),
    .pop         (wav_pop),
    .data        (wav_data),
    .empty       (wav_empty),
    .err_cnt     (au_err_cnt)
);

wav_player u_wav_player (
    .clk          (video_clk),
    .rst          (rst_video),
    .sample_tick  (audio_tick),
    .active       (wav_ready_video),
    .played       (wav_played),
    .pop          (wav_pop),
    .data         (wav_data),
    .empty        (wav_empty),
    .audio_valid  (wav_valid),
    .audio_left   (wav_left),
    .audio_right  (wav_right),
    .underrun_cnt (wav_underrun_cnt)
);

// ===================== 音画同步：切图跟着 WAV 播放位置走，并测量误差 =====================
sync_2ff u_sync_read_index_0 (.clk(video_clk), .rst(rst_video), .d(read_index_mem[0]), .q(read_index_video[0]));
sync_2ff u_sync_read_index_1 (.clk(video_clk), .rst(rst_video), .d(read_index_mem[1]), .q(read_index_video[1]));

// 演示模式只在显示缓冲实际切换后推进一次，预加载不会重复触发。
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video)
        demo_buf_prev <= 2'd0;
    else
        demo_buf_prev <= read_index_video;
end
assign demo_frame_step = demo_mode && (read_index_video != demo_buf_prev);

wire [23:0] av_err_max_abs;
av_sync #(
    .LEAD_SAMPLES (LEAD_SAMPLES),
    .MEAS_TIMEOUT (3 * H_TOTAL * V_TOTAL)
) u_av_sync (
    .clk          (video_clk),
    .rst          (rst_video),
    .active       (wav_ready_video),
    .words        (wav_words),                 // 扫描后不变，wav_ready 之前已稳定
    .img_count    (img_count_video),
    .played       (wav_played),
    .beat_toggle  (beat_toggle),
    .beat_cnt     (sync_beat_cnt),
    .segment_samples(segment_samples),
    .sof          (axis_s_user),
    .frame_buf    (read_index_video),
    .err_last     (),
    .err_max_abs  (av_err_max_abs),
    .meas_cnt     ()
);

// av_sync 的误差单位是 25.2MHz 像素时钟；换到 0.1ms：
// 0.1ms = 2520 拍，x/2520 ≈ (x*1664)>>22（误差 < 0.1%）。
wire [39:0] av_ms_prod = ({16'd0,av_err_max_abs} << 10) +
                         ({16'd0,av_err_max_abs} << 9) +
                         ({16'd0,av_err_max_abs} << 7);
wire [9:0]  av_ms_raw  = av_ms_prod[31:22];
assign av_err_01ms = (av_ms_raw > 10'd999) ? 10'd999 : av_ms_raw;

sync_2ff u_sync_resident_mode_mem (
    .clk (ext_mem_clk), .rst (rst_mem),
    .d (resident_mode_sd), .q (resident_mode_mem)
);

sync_2ff u_sync_write_is_wav_mem (
    .clk (ext_mem_clk), .rst (rst_mem),
    .d (write_is_wav), .q (write_is_wav_mem)
);
sync_2ff u_sync_write_is_preview_mem (
    .clk (ext_mem_clk), .rst (rst_mem),
    .d (write_is_preview), .q (write_is_preview_mem)
);

// Breathing-LED chain is kept in the repository but not instantiated in the
// capacity release (~158 LUT).  The four green LEDs stay useful: they mirror
// the lower four audio-band LEDs, so no indicator goes dark.
assign led_green4 = led_green_video[3:0];

// ===================== 健康指示：长时间运行时有没有出过错 =====================
// 4 个粘滞标志通过串口状态报告输出，只有复位（上电 / KEY1）清零。
//   bit0 画面读空：要像素时帧缓存读 FIFO 是空的（SDRAM 带宽 / 仲裁问题，画面会花）
//   bit1 声音读空：WAV 播放中音频 FIFO 是空的（会听到断续）
//   bit2 SDRAM 音频读口突发异常（读回数据个数不对或等待超时）
//   bit3 SD 卡看门狗动作过（读卡超时、拔插卡、初始化失败；拔插卡测试后为 1 属正常）
// 计数器在各自时钟域先变成单比特标志再跨域，避免多比特计数跨域时采到中间值
reg video_fifo_armed;                   // 第一帧开始读之后才检查读空
reg health_video_underflow;
reg health_wav_underrun;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        video_fifo_armed       <= 1'b0;
        health_video_underflow <= 1'b0;
        health_wav_underrun    <= 1'b0;
    end else begin
        if (video_read_req_ack)
            video_fifo_armed <= 1'b1;
        if (video_fifo_armed && video_read_en && video_read_empty)
            health_video_underflow <= 1'b1;
        if (wav_underrun_cnt != 8'd0)
            health_wav_underrun <= 1'b1;
    end
end

reg health_au_err;
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        health_au_err <= 1'b0;
    else if (au_err_cnt != 4'd0)
        health_au_err <= 1'b1;
end

assign health = {sd_wd_fired | media_recovery_failed,
                 health_au_err, health_wav_underrun, health_video_underflow};

genvar uart_health_bit;
generate
    for (uart_health_bit=0; uart_health_bit<4; uart_health_bit=uart_health_bit+1) begin: g_uart_health_sync
        sync_2ff u_sync_health (
            .clk(video_clk), .rst(rst_video),
            .d(health[uart_health_bit]), .q(health_uart[uart_health_bit])
        );
    end
endgenerate

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        diag_hits_meta <= 0; diag_hits_video <= 0;
        diag_seconds_meta <= 0; diag_seconds_video <= 0;
        diag_error_meta <= 0; diag_error_video <= 0;
        diag_busy_meta <= 0; diag_busy_video <= 0;
    end else begin
        diag_hits_meta <= diag_hits_sd; diag_hits_video <= diag_hits_meta;
        diag_seconds_meta <= diag_seconds_sd; diag_seconds_video <= diag_seconds_meta;
        diag_error_meta <= diag_error_sd; diag_error_video <= diag_error_meta;
        diag_busy_meta <= diag_busy_sd; diag_busy_video <= diag_busy_meta;
    end
end

// One readable status snapshot per second; the event log is only shown on the OSD LOG page.
uart_slim_reporter #(.CLK_HZ(PIX_HZ), .BAUD(115_200), .FRAMES_PER_REPORT(60)) u_uart_slim (
    .clk(video_clk), .rst(rst_video), .frame_start(osd_frame_start),
    .brightness(osd_brightness_level), .contrast(osd_contrast_level),
    .transition(transition_kind), .volume(audio_volume_level),
    .image_index(osd_image_video), .image_count(img_count_video),
    .uptime_bcd(uptime_bcd), .auto_mode(osd_auto_video),
    .tf_mounted(sd_mounted_video), .wav_ready(wav_ready_video),
    .health(health_uart), .load_stage(load_stage_video),
    .playlist_errors(playlist_errors_video),
    .log_refresh(ev_log_refresh), .log_newest_slot(ev_newest_slot),
    .log_rd_start(log_rd_start), .log_rd_slot(log_rd_slot),
    .log_rd_done(log_rd_done), .log_rd_valid(log_rd_valid),
    .log_rd_data(log_rd_data), .log_view(log_view),
    .log_any_valid(log_any_valid),
    .uart_tx(uart_tx)
);

always @(posedge video_clk or posedge rst_video) begin
    if (rst_video)
        audio_volume_level <= 3'd4;
    else if (persist_apply)
        audio_volume_level <= persist_volume;
    else if (matrix_press_pulse[0])
        audio_volume_level <= 3'd0;
    else if (matrix_press_pulse[1])
        audio_volume_level <= 3'd1;
    else if (matrix_press_pulse[2])
        audio_volume_level <= 3'd2;
    else if (matrix_press_pulse[3])
        audio_volume_level <= 3'd4;
end

sync_2ff u_sync_audio_next_sd (
    .clk(sd_card_clk), .rst(rst_sd), .d(key1_long_toggle), .q(audio_next_toggle_sd)
);

assign audio_valid      = wav_ready_video ? wav_valid : tone_valid;
assign audio_left_raw   = wav_ready_video ? wav_left  : tone_left;
assign audio_right_raw  = wav_ready_video ? wav_right : tone_right;

audio_sample_gain u_audio_sample_gain (
    .clk(video_clk), .rst(rst_video), .sample_valid(audio_valid),
    .left_in(audio_left_raw), .right_in(audio_right_raw),
    .volume_level(audio_volume_level),
    .left_out(audio_left_gain), .right_out(audio_right_gain)
);

// 音频音效：5 段 IIR 均衡 + 输出限幅，挂在音量之后、HDMI 之前，
// 屏幕上的频谱柱取的就是这里的输出，所以音效会一起体现在可视化上。
audio_dsp u_audio_dsp (
    .clk(video_clk), .rst(rst_video), .sample_valid(audio_valid),
    .effect(audio_effect_level),
    .left_in(audio_left_gain), .right_in(audio_right_gain),
    .left_out(audio_left_data), .right_out(audio_right_data),
    .out_valid(audio_valid_eq)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_audio_valid (audio_valid_eq),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (vs_q),
    .I_de          (de_q),
    .I_rgb         (vout_data_q),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( H_TOTAL    ),
    .HSA                    ( H_SYNC     ),
    .HFP                    ( H_FP       ),
    .HBP                    ( H_BP       ),
    .HACTIVE                ( H_ACTIVE   ),
    .VTOTAL                 ( V_TOTAL    ),
    .VSA                    ( V_SYNC     ),
    .VFP                    ( V_FP       ),
    .VBP                    ( V_BP       ),
    .VACTIVE                ( V_ACTIVE   ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid_eq),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_video),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

module uart_status_reporter #(
    parameter integer CLK_HZ = 25_200_000,
    parameter integer BAUD = 115_200,
    parameter integer FRAMES_PER_REPORT = 60
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        photo_valid,
    input  wire [1:0]  image_index,
    input  wire [2:0]  image_count,
    input  wire        auto_enabled,
    input  wire        demo_mode,
    input  wire        wav_ready,
    input  wire [2:0]  brightness,
    input  wire [2:0]  contrast,
    input  wire [1:0]  subtitle_alpha,
    input  wire [3:0]  health,
    input  wire [7:0]  beat_count,
    input  wire [2:0]  volume_level,
    input  wire [7:0]  diag_cache_hits,
    input  wire [7:0]  diag_load_seconds,
    input  wire [3:0]  diag_error_code,
    input  wire        diag_load_busy,
    input  wire [15:0] key_mask,
    // 数字标牌状态：节目单条数 / 解析错误行数 / 当前条目号（0 起）
    input  wire [4:0]  playlist_entries,
    input  wire [3:0]  playlist_errors,
    input  wire [2:0]  playlist_pos,
    output wire        uart_tx
);
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer FRAME_BITS = (FRAMES_PER_REPORT < 2) ? 1 : $clog2(FRAMES_PER_REPORT);
    localparam [2:0] S_IDLE=3'd0, S_PREP=3'd1, S_SEND=3'd2, S_DATA=3'd3, S_WAIT=3'd4;

    reg [2:0] state;
    reg [FRAME_BITS-1:0] frame_count;
    reg have_sample, pending;
    reg photo_latest, auto_latest, wav_latest, demo_latest;
    reg [1:0] image_latest, alpha_latest;
    reg [2:0] count_latest, brightness_latest, contrast_latest, volume_latest;
    reg [3:0] health_latest;
    reg [7:0] beat_latest;
    reg photo_q, auto_q, wav_q, demo_q;
    reg [1:0] image_q, alpha_q;
    reg [2:0] count_q, brightness_q, contrast_q, volume_q;
    reg [7:0] diag_hits_latest, diag_hits_q, diag_seconds_latest, diag_seconds_q;
    reg [3:0] diag_error_latest, diag_error_q;
    reg diag_busy_latest, diag_busy_q;
    reg [15:0] key_latest, key_q;
    reg [4:0]  pl_entries_latest, pl_entries_q;
    reg [3:0]  pl_errors_latest, pl_errors_q;
    reg [2:0]  pl_pos_latest, pl_pos_q;
    reg [3:0] health_q;
    reg [7:0] beat_q;
    reg [7:0] char_index;
    reg tx_start;
    reg [7:0] tx_data;
    wire tx_busy, tx_done;

    uart_tx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst), .start(tx_start), .data(tx_data),
        .tx(uart_tx), .busy(tx_busy), .done(tx_done)
    );

    // 报文 4 行 x 64 字节：每行 62 个可见字符 + CR + LF，共 256 字节。
    //   ROM 0..255   : 每行固定文字（可变列由下面的覆盖逻辑替换）
    //   ROM 256..511 : 十进制最高位字符（0..255）
    //   ROM 512..767 : 十位字符
    //   ROM 768..1023: 个位字符
    // 固定文字和十进制字符都放在 ROM 里（同步读，综合成 BRAM），
    // 可变字段每帧只选一次，覆盖逻辑只处理可变列，避免把整张字符表做成 LUT。
    reg [7:0] text_rom [0:1023];
    initial begin
        text_rom[   0] = "P";
        text_rom[   1] = "H";
        text_rom[   2] = "O";
        text_rom[   3] = "T";
        text_rom[   4] = "O";
        text_rom[   5] = " ";
        text_rom[   6] = "0";
        text_rom[   7] = "/";
        text_rom[   8] = "0";
        text_rom[   9] = " ";
        text_rom[  10] = " ";
        text_rom[  11] = " ";
        text_rom[  12] = "P";
        text_rom[  13] = "L";
        text_rom[  14] = "A";
        text_rom[  15] = "Y";
        text_rom[  16] = " ";
        text_rom[  17] = "M";
        text_rom[  18] = "A";
        text_rom[  19] = "N";
        text_rom[  20] = "U";
        text_rom[  21] = "A";
        text_rom[  22] = "L";
        text_rom[  23] = " ";
        text_rom[  24] = " ";
        text_rom[  25] = "A";
        text_rom[  26] = "U";
        text_rom[  27] = "D";
        text_rom[  28] = "I";
        text_rom[  29] = "O";
        text_rom[  30] = " ";
        text_rom[  31] = "T";
        text_rom[  32] = "O";
        text_rom[  33] = "N";
        text_rom[  34] = "E";
        text_rom[  35] = " ";
        text_rom[  36] = " ";
        text_rom[  37] = " ";
        text_rom[  38] = "V";
        text_rom[  39] = "O";
        text_rom[  40] = "L";
        text_rom[  41] = "U";
        text_rom[  42] = "M";
        text_rom[  43] = "E";
        text_rom[  44] = " ";
        text_rom[  45] = "1";
        text_rom[  46] = "0";
        text_rom[  47] = "0";
        text_rom[  48] = "%";
        // 行 0 末尾的标牌状态字段 "PL ee/ee Cee"：条数 / 解析错误行数 / 当前条目号（0 起）。
        // 静态的 "PL"、"/"、"C" 与空格固定在这里，6 个数字位先按"全 0"预置，
        // 真正的值由下面的覆盖逻辑每帧填一次（与照片序号、音量等字段同一套机制）。
        text_rom[  49] = " ";
        text_rom[  50] = "P";
        text_rom[  51] = "L";
        text_rom[  52] = " ";
        text_rom[  53] = " ";
        text_rom[  54] = "0";
        text_rom[  55] = "/";
        text_rom[  56] = " ";
        text_rom[  57] = "0";
        text_rom[  58] = " ";
        text_rom[  59] = "C";
        text_rom[  60] = " ";
        text_rom[  61] = "0";
        text_rom[  62] = 8'h0d;
        text_rom[  63] = 8'h0a;
        text_rom[  64] = "B";
        text_rom[  65] = "R";
        text_rom[  66] = "I";
        text_rom[  67] = "G";
        text_rom[  68] = "H";
        text_rom[  69] = "T";
        text_rom[  70] = " ";
        text_rom[  71] = "0";
        text_rom[  72] = "/";
        text_rom[  73] = "4";
        text_rom[  74] = " ";
        text_rom[  75] = " ";
        text_rom[  76] = "C";
        text_rom[  77] = "O";
        text_rom[  78] = "N";
        text_rom[  79] = "T";
        text_rom[  80] = "R";
        text_rom[  81] = "A";
        text_rom[  82] = "S";
        text_rom[  83] = "T";
        text_rom[  84] = " ";
        text_rom[  85] = "0";
        text_rom[  86] = "/";
        text_rom[  87] = "4";
        text_rom[  88] = " ";
        text_rom[  89] = " ";
        text_rom[  90] = "S";
        text_rom[  91] = "U";
        text_rom[  92] = "B";
        text_rom[  93] = "T";
        text_rom[  94] = "I";
        text_rom[  95] = "T";
        text_rom[  96] = "L";
        text_rom[  97] = "E";
        text_rom[  98] = " ";
        text_rom[  99] = "1";
        text_rom[ 100] = "0";
        text_rom[ 101] = "0";
        text_rom[ 102] = "%";
        text_rom[ 103] = " ";
        text_rom[ 104] = " ";
        text_rom[ 105] = "K";
        text_rom[ 106] = "E";
        text_rom[ 107] = "Y";
        text_rom[ 108] = " ";
        text_rom[ 109] = "m";
        text_rom[ 110] = "u";
        text_rom[ 111] = "l";
        text_rom[ 112] = "t";
        text_rom[ 113] = "i";
        text_rom[ 114] = " ";
        text_rom[ 115] = " ";
        text_rom[ 116] = " ";
        text_rom[ 117] = " ";
        text_rom[ 118] = " ";
        text_rom[ 119] = " ";
        text_rom[ 120] = " ";
        text_rom[ 121] = " ";
        text_rom[ 122] = " ";
        text_rom[ 123] = " ";
        text_rom[ 124] = " ";
        text_rom[ 125] = " ";
        text_rom[ 126] = 8'h0d;
        text_rom[ 127] = 8'h0a;
        text_rom[ 128] = "H";
        text_rom[ 129] = "E";
        text_rom[ 130] = "A";
        text_rom[ 131] = "L";
        text_rom[ 132] = "T";
        text_rom[ 133] = "H";
        text_rom[ 134] = " ";
        text_rom[ 135] = "V";
        text_rom[ 136] = "I";
        text_rom[ 137] = "D";
        text_rom[ 138] = "E";
        text_rom[ 139] = "O";
        text_rom[ 140] = " ";
        text_rom[ 141] = "O";
        text_rom[ 142] = "K";
        text_rom[ 143] = " ";
        text_rom[ 144] = " ";
        text_rom[ 145] = " ";
        text_rom[ 146] = "A";
        text_rom[ 147] = "U";
        text_rom[ 148] = "D";
        text_rom[ 149] = "I";
        text_rom[ 150] = "O";
        text_rom[ 151] = " ";
        text_rom[ 152] = "O";
        text_rom[ 153] = "K";
        text_rom[ 154] = " ";
        text_rom[ 155] = " ";
        text_rom[ 156] = " ";
        text_rom[ 157] = "S";
        text_rom[ 158] = "D";
        text_rom[ 159] = " ";
        text_rom[ 160] = "C";
        text_rom[ 161] = "A";
        text_rom[ 162] = "R";
        text_rom[ 163] = "D";
        text_rom[ 164] = " ";
        text_rom[ 165] = "O";
        text_rom[ 166] = "K";
        text_rom[ 167] = " ";
        text_rom[ 168] = " ";
        text_rom[ 169] = " ";
        text_rom[ 170] = "L";
        text_rom[ 171] = "O";
        text_rom[ 172] = "A";
        text_rom[ 173] = "D";
        text_rom[ 174] = " ";
        text_rom[ 175] = "i";
        text_rom[ 176] = "d";
        text_rom[ 177] = "l";
        text_rom[ 178] = "e";
        text_rom[ 179] = " ";
        text_rom[ 180] = "0";
        text_rom[ 181] = "0";
        text_rom[ 182] = "s";
        text_rom[ 183] = " ";
        text_rom[ 184] = " ";
        text_rom[ 185] = " ";
        text_rom[ 186] = " ";
        text_rom[ 187] = " ";
        text_rom[ 188] = " ";
        text_rom[ 189] = " ";
        text_rom[ 190] = 8'h0d;
        text_rom[ 191] = 8'h0a;
        text_rom[ 192] = "C";
        text_rom[ 193] = "A";
        text_rom[ 194] = "C";
        text_rom[ 195] = "H";
        text_rom[ 196] = "E";
        text_rom[ 197] = " ";
        text_rom[ 198] = "H";
        text_rom[ 199] = "I";
        text_rom[ 200] = "T";
        text_rom[ 201] = "S";
        text_rom[ 202] = " ";
        text_rom[ 203] = "0";
        text_rom[ 204] = "0";
        text_rom[ 205] = "0";
        text_rom[ 206] = " ";
        text_rom[ 207] = " ";
        text_rom[ 208] = "M";
        text_rom[ 209] = "U";
        text_rom[ 210] = "S";
        text_rom[ 211] = "I";
        text_rom[ 212] = "C";
        text_rom[ 213] = " ";
        text_rom[ 214] = "B";
        text_rom[ 215] = "E";
        text_rom[ 216] = "A";
        text_rom[ 217] = "T";
        text_rom[ 218] = "S";
        text_rom[ 219] = " ";
        text_rom[ 220] = "0";
        text_rom[ 221] = "0";
        text_rom[ 222] = "0";
        text_rom[ 223] = " ";
        text_rom[ 224] = " ";
        text_rom[ 225] = "L";
        text_rom[ 226] = "A";
        text_rom[ 227] = "S";
        text_rom[ 228] = "T";
        text_rom[ 229] = " ";
        text_rom[ 230] = "E";
        text_rom[ 231] = "R";
        text_rom[ 232] = "R";
        text_rom[ 233] = "O";
        text_rom[ 234] = "R";
        text_rom[ 235] = " ";
        text_rom[ 236] = "n";
        text_rom[ 237] = "o";
        text_rom[ 238] = "n";
        text_rom[ 239] = "e";
        text_rom[ 240] = " ";
        text_rom[ 241] = " ";
        text_rom[ 242] = " ";
        text_rom[ 243] = " ";
        text_rom[ 244] = " ";
        text_rom[ 245] = " ";
        text_rom[ 246] = " ";
        text_rom[ 247] = " ";
        text_rom[ 248] = " ";
        text_rom[ 249] = " ";
        text_rom[ 250] = " ";
        text_rom[ 251] = " ";
        text_rom[ 252] = " ";
        text_rom[ 253] = " ";
        text_rom[ 254] = 8'h0d;
        text_rom[ 255] = 8'h0a;
        text_rom[ 256] = "0";
        text_rom[ 512] = "0";
        text_rom[ 768] = "0";
        text_rom[ 257] = "0";
        text_rom[ 513] = "0";
        text_rom[ 769] = "1";
        text_rom[ 258] = "0";
        text_rom[ 514] = "0";
        text_rom[ 770] = "2";
        text_rom[ 259] = "0";
        text_rom[ 515] = "0";
        text_rom[ 771] = "3";
        text_rom[ 260] = "0";
        text_rom[ 516] = "0";
        text_rom[ 772] = "4";
        text_rom[ 261] = "0";
        text_rom[ 517] = "0";
        text_rom[ 773] = "5";
        text_rom[ 262] = "0";
        text_rom[ 518] = "0";
        text_rom[ 774] = "6";
        text_rom[ 263] = "0";
        text_rom[ 519] = "0";
        text_rom[ 775] = "7";
        text_rom[ 264] = "0";
        text_rom[ 520] = "0";
        text_rom[ 776] = "8";
        text_rom[ 265] = "0";
        text_rom[ 521] = "0";
        text_rom[ 777] = "9";
        text_rom[ 266] = "0";
        text_rom[ 522] = "1";
        text_rom[ 778] = "0";
        text_rom[ 267] = "0";
        text_rom[ 523] = "1";
        text_rom[ 779] = "1";
        text_rom[ 268] = "0";
        text_rom[ 524] = "1";
        text_rom[ 780] = "2";
        text_rom[ 269] = "0";
        text_rom[ 525] = "1";
        text_rom[ 781] = "3";
        text_rom[ 270] = "0";
        text_rom[ 526] = "1";
        text_rom[ 782] = "4";
        text_rom[ 271] = "0";
        text_rom[ 527] = "1";
        text_rom[ 783] = "5";
        text_rom[ 272] = "0";
        text_rom[ 528] = "1";
        text_rom[ 784] = "6";
        text_rom[ 273] = "0";
        text_rom[ 529] = "1";
        text_rom[ 785] = "7";
        text_rom[ 274] = "0";
        text_rom[ 530] = "1";
        text_rom[ 786] = "8";
        text_rom[ 275] = "0";
        text_rom[ 531] = "1";
        text_rom[ 787] = "9";
        text_rom[ 276] = "0";
        text_rom[ 532] = "2";
        text_rom[ 788] = "0";
        text_rom[ 277] = "0";
        text_rom[ 533] = "2";
        text_rom[ 789] = "1";
        text_rom[ 278] = "0";
        text_rom[ 534] = "2";
        text_rom[ 790] = "2";
        text_rom[ 279] = "0";
        text_rom[ 535] = "2";
        text_rom[ 791] = "3";
        text_rom[ 280] = "0";
        text_rom[ 536] = "2";
        text_rom[ 792] = "4";
        text_rom[ 281] = "0";
        text_rom[ 537] = "2";
        text_rom[ 793] = "5";
        text_rom[ 282] = "0";
        text_rom[ 538] = "2";
        text_rom[ 794] = "6";
        text_rom[ 283] = "0";
        text_rom[ 539] = "2";
        text_rom[ 795] = "7";
        text_rom[ 284] = "0";
        text_rom[ 540] = "2";
        text_rom[ 796] = "8";
        text_rom[ 285] = "0";
        text_rom[ 541] = "2";
        text_rom[ 797] = "9";
        text_rom[ 286] = "0";
        text_rom[ 542] = "3";
        text_rom[ 798] = "0";
        text_rom[ 287] = "0";
        text_rom[ 543] = "3";
        text_rom[ 799] = "1";
        text_rom[ 288] = "0";
        text_rom[ 544] = "3";
        text_rom[ 800] = "2";
        text_rom[ 289] = "0";
        text_rom[ 545] = "3";
        text_rom[ 801] = "3";
        text_rom[ 290] = "0";
        text_rom[ 546] = "3";
        text_rom[ 802] = "4";
        text_rom[ 291] = "0";
        text_rom[ 547] = "3";
        text_rom[ 803] = "5";
        text_rom[ 292] = "0";
        text_rom[ 548] = "3";
        text_rom[ 804] = "6";
        text_rom[ 293] = "0";
        text_rom[ 549] = "3";
        text_rom[ 805] = "7";
        text_rom[ 294] = "0";
        text_rom[ 550] = "3";
        text_rom[ 806] = "8";
        text_rom[ 295] = "0";
        text_rom[ 551] = "3";
        text_rom[ 807] = "9";
        text_rom[ 296] = "0";
        text_rom[ 552] = "4";
        text_rom[ 808] = "0";
        text_rom[ 297] = "0";
        text_rom[ 553] = "4";
        text_rom[ 809] = "1";
        text_rom[ 298] = "0";
        text_rom[ 554] = "4";
        text_rom[ 810] = "2";
        text_rom[ 299] = "0";
        text_rom[ 555] = "4";
        text_rom[ 811] = "3";
        text_rom[ 300] = "0";
        text_rom[ 556] = "4";
        text_rom[ 812] = "4";
        text_rom[ 301] = "0";
        text_rom[ 557] = "4";
        text_rom[ 813] = "5";
        text_rom[ 302] = "0";
        text_rom[ 558] = "4";
        text_rom[ 814] = "6";
        text_rom[ 303] = "0";
        text_rom[ 559] = "4";
        text_rom[ 815] = "7";
        text_rom[ 304] = "0";
        text_rom[ 560] = "4";
        text_rom[ 816] = "8";
        text_rom[ 305] = "0";
        text_rom[ 561] = "4";
        text_rom[ 817] = "9";
        text_rom[ 306] = "0";
        text_rom[ 562] = "5";
        text_rom[ 818] = "0";
        text_rom[ 307] = "0";
        text_rom[ 563] = "5";
        text_rom[ 819] = "1";
        text_rom[ 308] = "0";
        text_rom[ 564] = "5";
        text_rom[ 820] = "2";
        text_rom[ 309] = "0";
        text_rom[ 565] = "5";
        text_rom[ 821] = "3";
        text_rom[ 310] = "0";
        text_rom[ 566] = "5";
        text_rom[ 822] = "4";
        text_rom[ 311] = "0";
        text_rom[ 567] = "5";
        text_rom[ 823] = "5";
        text_rom[ 312] = "0";
        text_rom[ 568] = "5";
        text_rom[ 824] = "6";
        text_rom[ 313] = "0";
        text_rom[ 569] = "5";
        text_rom[ 825] = "7";
        text_rom[ 314] = "0";
        text_rom[ 570] = "5";
        text_rom[ 826] = "8";
        text_rom[ 315] = "0";
        text_rom[ 571] = "5";
        text_rom[ 827] = "9";
        text_rom[ 316] = "0";
        text_rom[ 572] = "6";
        text_rom[ 828] = "0";
        text_rom[ 317] = "0";
        text_rom[ 573] = "6";
        text_rom[ 829] = "1";
        text_rom[ 318] = "0";
        text_rom[ 574] = "6";
        text_rom[ 830] = "2";
        text_rom[ 319] = "0";
        text_rom[ 575] = "6";
        text_rom[ 831] = "3";
        text_rom[ 320] = "0";
        text_rom[ 576] = "6";
        text_rom[ 832] = "4";
        text_rom[ 321] = "0";
        text_rom[ 577] = "6";
        text_rom[ 833] = "5";
        text_rom[ 322] = "0";
        text_rom[ 578] = "6";
        text_rom[ 834] = "6";
        text_rom[ 323] = "0";
        text_rom[ 579] = "6";
        text_rom[ 835] = "7";
        text_rom[ 324] = "0";
        text_rom[ 580] = "6";
        text_rom[ 836] = "8";
        text_rom[ 325] = "0";
        text_rom[ 581] = "6";
        text_rom[ 837] = "9";
        text_rom[ 326] = "0";
        text_rom[ 582] = "7";
        text_rom[ 838] = "0";
        text_rom[ 327] = "0";
        text_rom[ 583] = "7";
        text_rom[ 839] = "1";
        text_rom[ 328] = "0";
        text_rom[ 584] = "7";
        text_rom[ 840] = "2";
        text_rom[ 329] = "0";
        text_rom[ 585] = "7";
        text_rom[ 841] = "3";
        text_rom[ 330] = "0";
        text_rom[ 586] = "7";
        text_rom[ 842] = "4";
        text_rom[ 331] = "0";
        text_rom[ 587] = "7";
        text_rom[ 843] = "5";
        text_rom[ 332] = "0";
        text_rom[ 588] = "7";
        text_rom[ 844] = "6";
        text_rom[ 333] = "0";
        text_rom[ 589] = "7";
        text_rom[ 845] = "7";
        text_rom[ 334] = "0";
        text_rom[ 590] = "7";
        text_rom[ 846] = "8";
        text_rom[ 335] = "0";
        text_rom[ 591] = "7";
        text_rom[ 847] = "9";
        text_rom[ 336] = "0";
        text_rom[ 592] = "8";
        text_rom[ 848] = "0";
        text_rom[ 337] = "0";
        text_rom[ 593] = "8";
        text_rom[ 849] = "1";
        text_rom[ 338] = "0";
        text_rom[ 594] = "8";
        text_rom[ 850] = "2";
        text_rom[ 339] = "0";
        text_rom[ 595] = "8";
        text_rom[ 851] = "3";
        text_rom[ 340] = "0";
        text_rom[ 596] = "8";
        text_rom[ 852] = "4";
        text_rom[ 341] = "0";
        text_rom[ 597] = "8";
        text_rom[ 853] = "5";
        text_rom[ 342] = "0";
        text_rom[ 598] = "8";
        text_rom[ 854] = "6";
        text_rom[ 343] = "0";
        text_rom[ 599] = "8";
        text_rom[ 855] = "7";
        text_rom[ 344] = "0";
        text_rom[ 600] = "8";
        text_rom[ 856] = "8";
        text_rom[ 345] = "0";
        text_rom[ 601] = "8";
        text_rom[ 857] = "9";
        text_rom[ 346] = "0";
        text_rom[ 602] = "9";
        text_rom[ 858] = "0";
        text_rom[ 347] = "0";
        text_rom[ 603] = "9";
        text_rom[ 859] = "1";
        text_rom[ 348] = "0";
        text_rom[ 604] = "9";
        text_rom[ 860] = "2";
        text_rom[ 349] = "0";
        text_rom[ 605] = "9";
        text_rom[ 861] = "3";
        text_rom[ 350] = "0";
        text_rom[ 606] = "9";
        text_rom[ 862] = "4";
        text_rom[ 351] = "0";
        text_rom[ 607] = "9";
        text_rom[ 863] = "5";
        text_rom[ 352] = "0";
        text_rom[ 608] = "9";
        text_rom[ 864] = "6";
        text_rom[ 353] = "0";
        text_rom[ 609] = "9";
        text_rom[ 865] = "7";
        text_rom[ 354] = "0";
        text_rom[ 610] = "9";
        text_rom[ 866] = "8";
        text_rom[ 355] = "0";
        text_rom[ 611] = "9";
        text_rom[ 867] = "9";
        text_rom[ 356] = "1";
        text_rom[ 612] = "0";
        text_rom[ 868] = "0";
        text_rom[ 357] = "1";
        text_rom[ 613] = "0";
        text_rom[ 869] = "1";
        text_rom[ 358] = "1";
        text_rom[ 614] = "0";
        text_rom[ 870] = "2";
        text_rom[ 359] = "1";
        text_rom[ 615] = "0";
        text_rom[ 871] = "3";
        text_rom[ 360] = "1";
        text_rom[ 616] = "0";
        text_rom[ 872] = "4";
        text_rom[ 361] = "1";
        text_rom[ 617] = "0";
        text_rom[ 873] = "5";
        text_rom[ 362] = "1";
        text_rom[ 618] = "0";
        text_rom[ 874] = "6";
        text_rom[ 363] = "1";
        text_rom[ 619] = "0";
        text_rom[ 875] = "7";
        text_rom[ 364] = "1";
        text_rom[ 620] = "0";
        text_rom[ 876] = "8";
        text_rom[ 365] = "1";
        text_rom[ 621] = "0";
        text_rom[ 877] = "9";
        text_rom[ 366] = "1";
        text_rom[ 622] = "1";
        text_rom[ 878] = "0";
        text_rom[ 367] = "1";
        text_rom[ 623] = "1";
        text_rom[ 879] = "1";
        text_rom[ 368] = "1";
        text_rom[ 624] = "1";
        text_rom[ 880] = "2";
        text_rom[ 369] = "1";
        text_rom[ 625] = "1";
        text_rom[ 881] = "3";
        text_rom[ 370] = "1";
        text_rom[ 626] = "1";
        text_rom[ 882] = "4";
        text_rom[ 371] = "1";
        text_rom[ 627] = "1";
        text_rom[ 883] = "5";
        text_rom[ 372] = "1";
        text_rom[ 628] = "1";
        text_rom[ 884] = "6";
        text_rom[ 373] = "1";
        text_rom[ 629] = "1";
        text_rom[ 885] = "7";
        text_rom[ 374] = "1";
        text_rom[ 630] = "1";
        text_rom[ 886] = "8";
        text_rom[ 375] = "1";
        text_rom[ 631] = "1";
        text_rom[ 887] = "9";
        text_rom[ 376] = "1";
        text_rom[ 632] = "2";
        text_rom[ 888] = "0";
        text_rom[ 377] = "1";
        text_rom[ 633] = "2";
        text_rom[ 889] = "1";
        text_rom[ 378] = "1";
        text_rom[ 634] = "2";
        text_rom[ 890] = "2";
        text_rom[ 379] = "1";
        text_rom[ 635] = "2";
        text_rom[ 891] = "3";
        text_rom[ 380] = "1";
        text_rom[ 636] = "2";
        text_rom[ 892] = "4";
        text_rom[ 381] = "1";
        text_rom[ 637] = "2";
        text_rom[ 893] = "5";
        text_rom[ 382] = "1";
        text_rom[ 638] = "2";
        text_rom[ 894] = "6";
        text_rom[ 383] = "1";
        text_rom[ 639] = "2";
        text_rom[ 895] = "7";
        text_rom[ 384] = "1";
        text_rom[ 640] = "2";
        text_rom[ 896] = "8";
        text_rom[ 385] = "1";
        text_rom[ 641] = "2";
        text_rom[ 897] = "9";
        text_rom[ 386] = "1";
        text_rom[ 642] = "3";
        text_rom[ 898] = "0";
        text_rom[ 387] = "1";
        text_rom[ 643] = "3";
        text_rom[ 899] = "1";
        text_rom[ 388] = "1";
        text_rom[ 644] = "3";
        text_rom[ 900] = "2";
        text_rom[ 389] = "1";
        text_rom[ 645] = "3";
        text_rom[ 901] = "3";
        text_rom[ 390] = "1";
        text_rom[ 646] = "3";
        text_rom[ 902] = "4";
        text_rom[ 391] = "1";
        text_rom[ 647] = "3";
        text_rom[ 903] = "5";
        text_rom[ 392] = "1";
        text_rom[ 648] = "3";
        text_rom[ 904] = "6";
        text_rom[ 393] = "1";
        text_rom[ 649] = "3";
        text_rom[ 905] = "7";
        text_rom[ 394] = "1";
        text_rom[ 650] = "3";
        text_rom[ 906] = "8";
        text_rom[ 395] = "1";
        text_rom[ 651] = "3";
        text_rom[ 907] = "9";
        text_rom[ 396] = "1";
        text_rom[ 652] = "4";
        text_rom[ 908] = "0";
        text_rom[ 397] = "1";
        text_rom[ 653] = "4";
        text_rom[ 909] = "1";
        text_rom[ 398] = "1";
        text_rom[ 654] = "4";
        text_rom[ 910] = "2";
        text_rom[ 399] = "1";
        text_rom[ 655] = "4";
        text_rom[ 911] = "3";
        text_rom[ 400] = "1";
        text_rom[ 656] = "4";
        text_rom[ 912] = "4";
        text_rom[ 401] = "1";
        text_rom[ 657] = "4";
        text_rom[ 913] = "5";
        text_rom[ 402] = "1";
        text_rom[ 658] = "4";
        text_rom[ 914] = "6";
        text_rom[ 403] = "1";
        text_rom[ 659] = "4";
        text_rom[ 915] = "7";
        text_rom[ 404] = "1";
        text_rom[ 660] = "4";
        text_rom[ 916] = "8";
        text_rom[ 405] = "1";
        text_rom[ 661] = "4";
        text_rom[ 917] = "9";
        text_rom[ 406] = "1";
        text_rom[ 662] = "5";
        text_rom[ 918] = "0";
        text_rom[ 407] = "1";
        text_rom[ 663] = "5";
        text_rom[ 919] = "1";
        text_rom[ 408] = "1";
        text_rom[ 664] = "5";
        text_rom[ 920] = "2";
        text_rom[ 409] = "1";
        text_rom[ 665] = "5";
        text_rom[ 921] = "3";
        text_rom[ 410] = "1";
        text_rom[ 666] = "5";
        text_rom[ 922] = "4";
        text_rom[ 411] = "1";
        text_rom[ 667] = "5";
        text_rom[ 923] = "5";
        text_rom[ 412] = "1";
        text_rom[ 668] = "5";
        text_rom[ 924] = "6";
        text_rom[ 413] = "1";
        text_rom[ 669] = "5";
        text_rom[ 925] = "7";
        text_rom[ 414] = "1";
        text_rom[ 670] = "5";
        text_rom[ 926] = "8";
        text_rom[ 415] = "1";
        text_rom[ 671] = "5";
        text_rom[ 927] = "9";
        text_rom[ 416] = "1";
        text_rom[ 672] = "6";
        text_rom[ 928] = "0";
        text_rom[ 417] = "1";
        text_rom[ 673] = "6";
        text_rom[ 929] = "1";
        text_rom[ 418] = "1";
        text_rom[ 674] = "6";
        text_rom[ 930] = "2";
        text_rom[ 419] = "1";
        text_rom[ 675] = "6";
        text_rom[ 931] = "3";
        text_rom[ 420] = "1";
        text_rom[ 676] = "6";
        text_rom[ 932] = "4";
        text_rom[ 421] = "1";
        text_rom[ 677] = "6";
        text_rom[ 933] = "5";
        text_rom[ 422] = "1";
        text_rom[ 678] = "6";
        text_rom[ 934] = "6";
        text_rom[ 423] = "1";
        text_rom[ 679] = "6";
        text_rom[ 935] = "7";
        text_rom[ 424] = "1";
        text_rom[ 680] = "6";
        text_rom[ 936] = "8";
        text_rom[ 425] = "1";
        text_rom[ 681] = "6";
        text_rom[ 937] = "9";
        text_rom[ 426] = "1";
        text_rom[ 682] = "7";
        text_rom[ 938] = "0";
        text_rom[ 427] = "1";
        text_rom[ 683] = "7";
        text_rom[ 939] = "1";
        text_rom[ 428] = "1";
        text_rom[ 684] = "7";
        text_rom[ 940] = "2";
        text_rom[ 429] = "1";
        text_rom[ 685] = "7";
        text_rom[ 941] = "3";
        text_rom[ 430] = "1";
        text_rom[ 686] = "7";
        text_rom[ 942] = "4";
        text_rom[ 431] = "1";
        text_rom[ 687] = "7";
        text_rom[ 943] = "5";
        text_rom[ 432] = "1";
        text_rom[ 688] = "7";
        text_rom[ 944] = "6";
        text_rom[ 433] = "1";
        text_rom[ 689] = "7";
        text_rom[ 945] = "7";
        text_rom[ 434] = "1";
        text_rom[ 690] = "7";
        text_rom[ 946] = "8";
        text_rom[ 435] = "1";
        text_rom[ 691] = "7";
        text_rom[ 947] = "9";
        text_rom[ 436] = "1";
        text_rom[ 692] = "8";
        text_rom[ 948] = "0";
        text_rom[ 437] = "1";
        text_rom[ 693] = "8";
        text_rom[ 949] = "1";
        text_rom[ 438] = "1";
        text_rom[ 694] = "8";
        text_rom[ 950] = "2";
        text_rom[ 439] = "1";
        text_rom[ 695] = "8";
        text_rom[ 951] = "3";
        text_rom[ 440] = "1";
        text_rom[ 696] = "8";
        text_rom[ 952] = "4";
        text_rom[ 441] = "1";
        text_rom[ 697] = "8";
        text_rom[ 953] = "5";
        text_rom[ 442] = "1";
        text_rom[ 698] = "8";
        text_rom[ 954] = "6";
        text_rom[ 443] = "1";
        text_rom[ 699] = "8";
        text_rom[ 955] = "7";
        text_rom[ 444] = "1";
        text_rom[ 700] = "8";
        text_rom[ 956] = "8";
        text_rom[ 445] = "1";
        text_rom[ 701] = "8";
        text_rom[ 957] = "9";
        text_rom[ 446] = "1";
        text_rom[ 702] = "9";
        text_rom[ 958] = "0";
        text_rom[ 447] = "1";
        text_rom[ 703] = "9";
        text_rom[ 959] = "1";
        text_rom[ 448] = "1";
        text_rom[ 704] = "9";
        text_rom[ 960] = "2";
        text_rom[ 449] = "1";
        text_rom[ 705] = "9";
        text_rom[ 961] = "3";
        text_rom[ 450] = "1";
        text_rom[ 706] = "9";
        text_rom[ 962] = "4";
        text_rom[ 451] = "1";
        text_rom[ 707] = "9";
        text_rom[ 963] = "5";
        text_rom[ 452] = "1";
        text_rom[ 708] = "9";
        text_rom[ 964] = "6";
        text_rom[ 453] = "1";
        text_rom[ 709] = "9";
        text_rom[ 965] = "7";
        text_rom[ 454] = "1";
        text_rom[ 710] = "9";
        text_rom[ 966] = "8";
        text_rom[ 455] = "1";
        text_rom[ 711] = "9";
        text_rom[ 967] = "9";
        text_rom[ 456] = "2";
        text_rom[ 712] = "0";
        text_rom[ 968] = "0";
        text_rom[ 457] = "2";
        text_rom[ 713] = "0";
        text_rom[ 969] = "1";
        text_rom[ 458] = "2";
        text_rom[ 714] = "0";
        text_rom[ 970] = "2";
        text_rom[ 459] = "2";
        text_rom[ 715] = "0";
        text_rom[ 971] = "3";
        text_rom[ 460] = "2";
        text_rom[ 716] = "0";
        text_rom[ 972] = "4";
        text_rom[ 461] = "2";
        text_rom[ 717] = "0";
        text_rom[ 973] = "5";
        text_rom[ 462] = "2";
        text_rom[ 718] = "0";
        text_rom[ 974] = "6";
        text_rom[ 463] = "2";
        text_rom[ 719] = "0";
        text_rom[ 975] = "7";
        text_rom[ 464] = "2";
        text_rom[ 720] = "0";
        text_rom[ 976] = "8";
        text_rom[ 465] = "2";
        text_rom[ 721] = "0";
        text_rom[ 977] = "9";
        text_rom[ 466] = "2";
        text_rom[ 722] = "1";
        text_rom[ 978] = "0";
        text_rom[ 467] = "2";
        text_rom[ 723] = "1";
        text_rom[ 979] = "1";
        text_rom[ 468] = "2";
        text_rom[ 724] = "1";
        text_rom[ 980] = "2";
        text_rom[ 469] = "2";
        text_rom[ 725] = "1";
        text_rom[ 981] = "3";
        text_rom[ 470] = "2";
        text_rom[ 726] = "1";
        text_rom[ 982] = "4";
        text_rom[ 471] = "2";
        text_rom[ 727] = "1";
        text_rom[ 983] = "5";
        text_rom[ 472] = "2";
        text_rom[ 728] = "1";
        text_rom[ 984] = "6";
        text_rom[ 473] = "2";
        text_rom[ 729] = "1";
        text_rom[ 985] = "7";
        text_rom[ 474] = "2";
        text_rom[ 730] = "1";
        text_rom[ 986] = "8";
        text_rom[ 475] = "2";
        text_rom[ 731] = "1";
        text_rom[ 987] = "9";
        text_rom[ 476] = "2";
        text_rom[ 732] = "2";
        text_rom[ 988] = "0";
        text_rom[ 477] = "2";
        text_rom[ 733] = "2";
        text_rom[ 989] = "1";
        text_rom[ 478] = "2";
        text_rom[ 734] = "2";
        text_rom[ 990] = "2";
        text_rom[ 479] = "2";
        text_rom[ 735] = "2";
        text_rom[ 991] = "3";
        text_rom[ 480] = "2";
        text_rom[ 736] = "2";
        text_rom[ 992] = "4";
        text_rom[ 481] = "2";
        text_rom[ 737] = "2";
        text_rom[ 993] = "5";
        text_rom[ 482] = "2";
        text_rom[ 738] = "2";
        text_rom[ 994] = "6";
        text_rom[ 483] = "2";
        text_rom[ 739] = "2";
        text_rom[ 995] = "7";
        text_rom[ 484] = "2";
        text_rom[ 740] = "2";
        text_rom[ 996] = "8";
        text_rom[ 485] = "2";
        text_rom[ 741] = "2";
        text_rom[ 997] = "9";
        text_rom[ 486] = "2";
        text_rom[ 742] = "3";
        text_rom[ 998] = "0";
        text_rom[ 487] = "2";
        text_rom[ 743] = "3";
        text_rom[ 999] = "1";
        text_rom[ 488] = "2";
        text_rom[ 744] = "3";
        text_rom[1000] = "2";
        text_rom[ 489] = "2";
        text_rom[ 745] = "3";
        text_rom[1001] = "3";
        text_rom[ 490] = "2";
        text_rom[ 746] = "3";
        text_rom[1002] = "4";
        text_rom[ 491] = "2";
        text_rom[ 747] = "3";
        text_rom[1003] = "5";
        text_rom[ 492] = "2";
        text_rom[ 748] = "3";
        text_rom[1004] = "6";
        text_rom[ 493] = "2";
        text_rom[ 749] = "3";
        text_rom[1005] = "7";
        text_rom[ 494] = "2";
        text_rom[ 750] = "3";
        text_rom[1006] = "8";
        text_rom[ 495] = "2";
        text_rom[ 751] = "3";
        text_rom[1007] = "9";
        text_rom[ 496] = "2";
        text_rom[ 752] = "4";
        text_rom[1008] = "0";
        text_rom[ 497] = "2";
        text_rom[ 753] = "4";
        text_rom[1009] = "1";
        text_rom[ 498] = "2";
        text_rom[ 754] = "4";
        text_rom[1010] = "2";
        text_rom[ 499] = "2";
        text_rom[ 755] = "4";
        text_rom[1011] = "3";
        text_rom[ 500] = "2";
        text_rom[ 756] = "4";
        text_rom[1012] = "4";
        text_rom[ 501] = "2";
        text_rom[ 757] = "4";
        text_rom[1013] = "5";
        text_rom[ 502] = "2";
        text_rom[ 758] = "4";
        text_rom[1014] = "6";
        text_rom[ 503] = "2";
        text_rom[ 759] = "4";
        text_rom[1015] = "7";
        text_rom[ 504] = "2";
        text_rom[ 760] = "4";
        text_rom[1016] = "8";
        text_rom[ 505] = "2";
        text_rom[ 761] = "4";
        text_rom[1017] = "9";
        text_rom[ 506] = "2";
        text_rom[ 762] = "5";
        text_rom[1018] = "0";
        text_rom[ 507] = "2";
        text_rom[ 763] = "5";
        text_rom[1019] = "1";
        text_rom[ 508] = "2";
        text_rom[ 764] = "5";
        text_rom[1020] = "2";
        text_rom[ 509] = "2";
        text_rom[ 765] = "5";
        text_rom[1021] = "3";
        text_rom[ 510] = "2";
        text_rom[ 766] = "5";
        text_rom[1022] = "4";
        text_rom[ 511] = "2";
        text_rom[ 767] = "5";
        text_rom[1023] = "5";
    end

    reg [7:0] rom_q;
    reg [5:0] col_q;
    reg [1:0] line_q;
    reg [3:0] prep_cnt;
    reg [7:0] hits_h, hits_t, hits_u;
    reg [7:0] beats_h, beats_t, beats_u;
    reg [7:0] secs_t, secs_u;
    wire [7:0] hits_value  = diag_hits_q;
    wire [7:0] beats_value = beat_q;
    wire [7:0] secs_value  = (diag_seconds_q > 8'd99) ? 8'd99 : diag_seconds_q;
    wire [9:0] prep_addr =
        (prep_cnt == 4'd0) ? (10'd256 + {2'b0, hits_value})  :
        (prep_cnt == 4'd1) ? (10'd512 + {2'b0, hits_value})  :
        (prep_cnt == 4'd2) ? (10'd768 + {2'b0, hits_value})  :
        (prep_cnt == 4'd3) ? (10'd256 + {2'b0, beats_value}) :
        (prep_cnt == 4'd4) ? (10'd512 + {2'b0, beats_value}) :
        (prep_cnt == 4'd5) ? (10'd768 + {2'b0, beats_value}) :
        (prep_cnt == 4'd6) ? (10'd512 + {2'b0, secs_value})  :
        (prep_cnt == 4'd7) ? (10'd768 + {2'b0, secs_value})  : 10'd0;
    wire [9:0] rom_addr = (state == S_PREP) ? prep_addr : {2'b0, char_index};
    always @(posedge clk) begin
        rom_q  <= text_rom[rom_addr];
        col_q  <= char_index[5:0];
        line_q <= char_index[7:6];
    end

    reg [8*6-1:0] play_text;
    reg [8*4-1:0] audio_text, volume_text, subtitle_text;
    reg [8*4-1:0] video_text, audio_health_text, sd_text;
    reg [8*5-1:0] load_text, key_text;
    reg [8*8-1:0] error_text;
    wire [4:0] key_num = key_number(key_q);

    function [4:0] key_number;                   // 0=无键, 1..16=S1..S16, 17=多键
        input [15:0] mask;
        integer bit_index;
        reg found;
        begin
            key_number = 5'd0;
            found = 1'b0;
            for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1) begin
                if (mask[bit_index]) begin
                    if (found)
                        key_number = 5'd17;
                    else begin
                        key_number = bit_index + 1;
                        found = 1'b1;
                    end
                end
            end
        end
    endfunction

    always @* begin
        play_text = demo_q ? "DEMO  " : auto_q ? "AUTO  " : "MANUAL";
        audio_text = wav_q ? "WAV " : "TONE";
        case (volume_q)
            3'd0: volume_text = "0%  ";
            3'd1: volume_text = "35% ";
            3'd2: volume_text = "70% ";
            3'd3: volume_text = "75% ";
            default: volume_text = "100%";
        endcase
        case (alpha_q)
            2'd0: subtitle_text = "0%  ";
            2'd1: subtitle_text = "35% ";
            2'd2: subtitle_text = "70% ";
            default: subtitle_text = "100%";
        endcase
        video_text = health_q[0] ? "FAIL" : "OK  ";
        audio_health_text = (health_q[1] | health_q[2]) ? "FAIL" : "OK  ";
        sd_text = health_q[3] ? "FAIL" : "OK  ";
        load_text = diag_busy_q ? "busy " : "idle ";
        case (diag_error_q)
            4'd1: error_text = "BMP DATA";
            4'd2: error_text = "FAT MAP ";
            4'd3: error_text = "TIMEOUT ";
            4'd4: error_text = "RETRY   ";
            default: error_text = "none    ";
        endcase
        if (key_num == 5'd0)
            key_text = "none ";
        else if (key_num == 5'd17)
            key_text = "multi";
        else if (key_num <= 5'd9)
            key_text = {"S", "0" + {4'd0, key_num[3:0]}, "   "};
        else
            key_text = {"S1", "0" + {4'd0, key_num - 5'd10}, "  "};
    end

    // 标牌状态字段的数字位：条数 / 解析错误行数 / 当前条目号（0 起）。
    // 两位定宽、十位为 0 时显示空格 —— 和屏幕上"节目单位置 n/总"角标的写法一致，
    // 现场演示时串口与屏幕能逐字对上。
    // 节目单容量上限 8（sd_card_bmp 里 MAX_ENTRIES = 8），条数十位只可能是空格或 1；
    // 条目号是 3 位（0..7），十位恒为空格 —— 将来容量扩到 16 条时这两处要一起放宽。
    wire [3:0] pl_ent_tens  = (pl_entries_q >= 5'd10) ? 4'd1 : 4'd0;
    wire [4:0] pl_ent_units = pl_entries_q - ((pl_entries_q >= 5'd10) ? 5'd10 : 5'd0);
    wire [3:0] pl_err_tens  = (pl_errors_q  >= 4'd10) ? 4'd1 : 4'd0;
    wire [3:0] pl_err_units = pl_errors_q  - ((pl_errors_q  >= 4'd10) ? 4'd10 : 4'd0);
    wire [7:0] pl_ent_t_ch  = pl_ent_tens ? ("0" + {4'd0, pl_ent_tens}) : " ";
    wire [7:0] pl_ent_u_ch  = "0" + {3'd0, pl_ent_units};
    wire [7:0] pl_err_t_ch  = pl_err_tens ? ("0" + {4'd0, pl_err_tens}) : " ";
    wire [7:0] pl_err_u_ch  = "0" + {4'd0, pl_err_units};
    wire [7:0] pl_pos_u_ch  = "0" + {5'd0, pl_pos_q};

    reg [7:0] line_ch;
    always @* begin
        line_ch = rom_q;
        case (line_q)
            2'd0: begin
                case (col_q)
                     6: line_ch = photo_valid ? ("1" + {6'd0, image_q}) : "0";
                     8: line_ch = "0" + {5'd0, count_q};
                    17: line_ch = play_text[8*5 +: 8];
                    18: line_ch = play_text[8*4 +: 8];
                    19: line_ch = play_text[8*3 +: 8];
                    20: line_ch = play_text[8*2 +: 8];
                    21: line_ch = play_text[8*1 +: 8];
                    22: line_ch = play_text[8*0 +: 8];
                    31: line_ch = audio_text[8*3 +: 8];
                    32: line_ch = audio_text[8*2 +: 8];
                    33: line_ch = audio_text[8*1 +: 8];
                    34: line_ch = audio_text[8*0 +: 8];
                    45: line_ch = volume_text[8*3 +: 8];
                    46: line_ch = volume_text[8*2 +: 8];
                    47: line_ch = volume_text[8*1 +: 8];
                    48: line_ch = volume_text[8*0 +: 8];
                    53: line_ch = pl_ent_t_ch;
                    54: line_ch = pl_ent_u_ch;
                    56: line_ch = pl_err_t_ch;
                    57: line_ch = pl_err_u_ch;
                    61: line_ch = pl_pos_u_ch;   // 60 = 条目号十位，恒为空格（ROM 里已填）
                    default: ;
                endcase
            end
            2'd1: begin
                case (col_q)
                     7: line_ch = "0" + {5'd0, brightness_q};
                    21: line_ch = "0" + {5'd0, contrast_q};
                    35: line_ch = subtitle_text[8*3 +: 8];
                    36: line_ch = subtitle_text[8*2 +: 8];
                    37: line_ch = subtitle_text[8*1 +: 8];
                    38: line_ch = subtitle_text[8*0 +: 8];
                    45: line_ch = key_text[8*4 +: 8];
                    46: line_ch = key_text[8*3 +: 8];
                    47: line_ch = key_text[8*2 +: 8];
                    48: line_ch = key_text[8*1 +: 8];
                    49: line_ch = key_text[8*0 +: 8];
                    default: ;
                endcase
            end
            2'd2: begin
                case (col_q)
                    13: line_ch = video_text[8*3 +: 8];
                    14: line_ch = video_text[8*2 +: 8];
                    15: line_ch = video_text[8*1 +: 8];
                    16: line_ch = video_text[8*0 +: 8];
                    24: line_ch = audio_health_text[8*3 +: 8];
                    25: line_ch = audio_health_text[8*2 +: 8];
                    26: line_ch = audio_health_text[8*1 +: 8];
                    27: line_ch = audio_health_text[8*0 +: 8];
                    37: line_ch = sd_text[8*3 +: 8];
                    38: line_ch = sd_text[8*2 +: 8];
                    39: line_ch = sd_text[8*1 +: 8];
                    40: line_ch = sd_text[8*0 +: 8];
                    47: line_ch = load_text[8*4 +: 8];
                    48: line_ch = load_text[8*3 +: 8];
                    49: line_ch = load_text[8*2 +: 8];
                    50: line_ch = load_text[8*1 +: 8];
                    51: line_ch = load_text[8*0 +: 8];
                    52: line_ch = secs_t;
                    53: line_ch = secs_u;
                    default: ;
                endcase
            end
            2'd3: begin
                case (col_q)
                    11: line_ch = hits_h;
                    12: line_ch = hits_t;
                    13: line_ch = hits_u;
                    28: line_ch = beats_h;
                    29: line_ch = beats_t;
                    30: line_ch = beats_u;
                    44: line_ch = error_text[8*7 +: 8];
                    45: line_ch = error_text[8*6 +: 8];
                    46: line_ch = error_text[8*5 +: 8];
                    47: line_ch = error_text[8*4 +: 8];
                    48: line_ch = error_text[8*3 +: 8];
                    49: line_ch = error_text[8*2 +: 8];
                    50: line_ch = error_text[8*1 +: 8];
                    51: line_ch = error_text[8*0 +: 8];
                    default: ;
                endcase
            end
            default: ;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            frame_count <= {FRAME_BITS{1'b0}};
            have_sample <= 1'b0;
            pending <= 1'b0;
            photo_latest <= 1'b0;
            image_latest <= 2'd0;
            count_latest <= 3'd0;
            auto_latest <= 1'b0;
            demo_latest <= 1'b0;
            wav_latest <= 1'b0;
            brightness_latest <= 3'd2;
            contrast_latest <= 3'd2;
            alpha_latest <= 2'd2;
            volume_latest <= 3'd4;
            diag_hits_latest <= 0; diag_seconds_latest <= 0;
            diag_error_latest <= 0; diag_busy_latest <= 0;
            key_latest <= 16'd0;
            pl_entries_latest <= 5'd0;
            pl_errors_latest <= 4'd0;
            pl_pos_latest <= 3'd0;
            health_latest <= 4'd0;
            beat_latest <= 8'd0;
            photo_q <= 1'b0;
            image_q <= 2'd0;
            count_q <= 3'd0;
            auto_q <= 1'b0;
            demo_q <= 1'b0;
            wav_q <= 1'b0;
            brightness_q <= 3'd2;
            contrast_q <= 3'd2;
            alpha_q <= 2'd2;
            volume_q <= 3'd4;
            diag_hits_q <= 0; diag_seconds_q <= 0;
            diag_error_q <= 0; diag_busy_q <= 0;
            pl_entries_q <= 5'd0;
            pl_errors_q <= 4'd0;
            pl_pos_q <= 3'd0;
            health_q <= 4'd0;
            beat_q <= 8'd0;
            char_index <= 8'd0;
            prep_cnt <= 4'd0;
            hits_h <= "0"; hits_t <= "0"; hits_u <= "0";
            beats_h <= "0"; beats_t <= "0"; beats_u <= "0";
            secs_t <= "0"; secs_u <= "0";
            tx_start <= 1'b0;
            tx_data <= 8'd0;
        end else begin
            tx_start <= 1'b0;
            if (frame_start) begin
                if (!have_sample || photo_latest != photo_valid ||
                    image_latest != image_index || count_latest != image_count ||
                    auto_latest != auto_enabled || demo_latest != demo_mode ||
                    wav_latest != wav_ready || brightness_latest != brightness ||
                    contrast_latest != contrast || alpha_latest != subtitle_alpha ||
                    health_latest != health ||
                    volume_latest != volume_level ||
                    diag_hits_latest != diag_cache_hits ||
                    diag_seconds_latest != diag_load_seconds ||
                    diag_error_latest != diag_error_code ||
                    diag_busy_latest != diag_load_busy ||
                    key_latest != key_mask ||
                    pl_entries_latest != playlist_entries ||
                    pl_errors_latest  != playlist_errors ||
                    pl_pos_latest     != playlist_pos ||
                    frame_count == FRAMES_PER_REPORT - 1)
                    pending <= 1'b1;
                frame_count <= frame_count == FRAMES_PER_REPORT - 1 ?
                               {FRAME_BITS{1'b0}} : frame_count + 1'b1;
                have_sample <= 1'b1;
                photo_latest <= photo_valid;
                image_latest <= image_index;
                count_latest <= image_count;
                auto_latest <= auto_enabled;
                demo_latest <= demo_mode;
                wav_latest <= wav_ready;
                brightness_latest <= brightness;
                contrast_latest <= contrast;
                alpha_latest <= subtitle_alpha;
                    volume_latest <= volume_level;
                diag_hits_latest <= diag_cache_hits;
                diag_seconds_latest <= diag_load_seconds;
                diag_error_latest <= diag_error_code;
                diag_busy_latest <= diag_load_busy;
                key_latest <= key_mask;
                pl_entries_latest <= playlist_entries;
                pl_errors_latest  <= playlist_errors;
                pl_pos_latest     <= playlist_pos;
                health_latest <= health;
                beat_latest <= beat_count;
            end
            case (state)
                S_IDLE: if (pending && !frame_start) begin
                    photo_q <= photo_latest;
                    image_q <= image_latest;
                    count_q <= count_latest;
                    auto_q <= auto_latest;
                    demo_q <= demo_latest;
                    wav_q <= wav_latest;
                    brightness_q <= brightness_latest;
                    contrast_q <= contrast_latest;
                    alpha_q <= alpha_latest;
                    volume_q <= volume_latest;
                    diag_hits_q <= diag_hits_latest;
                    diag_seconds_q <= diag_seconds_latest;
                    diag_error_q <= diag_error_latest;
                    diag_busy_q <= diag_busy_latest;
                    key_q <= key_latest;
                    pl_entries_q <= pl_entries_latest;
                    pl_errors_q  <= pl_errors_latest;
                    pl_pos_q     <= pl_pos_latest;
                    health_q <= health_latest;
                    beat_q <= beat_latest;
                    pending <= 1'b0;
                    prep_cnt <= 4'd0;
                    state <= S_PREP;
                end
                S_PREP: begin
                    case (prep_cnt)
                        4'd1: hits_h  <= rom_q;
                        4'd2: hits_t  <= rom_q;
                        4'd3: hits_u  <= rom_q;
                        4'd4: beats_h <= rom_q;
                        4'd5: beats_t <= rom_q;
                        4'd6: beats_u <= rom_q;
                        4'd7: secs_t  <= rom_q;
                        4'd8: secs_u  <= rom_q;
                        default: ;
                    endcase
                    if (prep_cnt == 4'd8) begin
                        char_index <= 8'd0;
                        state <= S_SEND;
                    end else
                        prep_cnt <= prep_cnt + 4'd1;
                end
                S_SEND: state <= S_DATA;          // 等一拍让 ROM 输出对齐
                S_DATA: if (!tx_busy) begin
                    tx_data <= line_ch;
                    tx_start <= 1'b1;
                    state <= S_WAIT;
                end
                S_WAIT: if (tx_done) begin
                    if (char_index == 8'd255)
                        state <= S_IDLE;
                    else begin
                        char_index <= char_index + 8'd1;
                        state <= S_SEND;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

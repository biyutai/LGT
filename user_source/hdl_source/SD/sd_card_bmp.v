
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter integer FRAME_WIDTH = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer ENABLE_RESIDENT = 1,
    parameter integer SDRAM_WORDS = 2_097_152,
    parameter integer USE_AUTO_SWITCH = 0,
    parameter integer PREVIEW_WORDS = 0,
    parameter integer ENABLE_FULL_PREVIEW = 0,
    parameter integer FAT32_ONLY = 0,
    parameter integer ENABLE_TEXT = 1,
    parameter integer SD_SPI_HIGH_SPEED_DIV = 2,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    // 默认数据速率为 6.25MHz；产品顶层显式选 12.5MHz。
    // 大 BMP 仍需留足卡响应与 SDRAM 写入余量。
    parameter integer LOAD_TIMEOUT_CYCLES = 20 * CLK_FREQ_HZ,
    parameter integer WAV_TIMEOUT_CYCLES  = 20 * CLK_FREQ_HZ, // WAV 加载超时：20s（30s 立体声约 6MB，正常 3~4s）
    parameter [20:0]  WAV_MAX_WORDS       = 21'd1329152,   // 见 bmp_read
    parameter [31:0]  SCAN_WAV_GAP        = 32'd1024       // 见 bmp_read
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       manual_next_toggle,
    input                       remote_select_toggle,
    input  [1:0]                remote_select_index,
    input                       button_select_toggle,
    input  [1:0]                button_select_index,
    input                       remote_prev_toggle,
    input                       remote_period_toggle,
    input  [3:0]                remote_period_seconds,
    input                       audio_select_toggle,
    input  [1:0]                audio_select_index,
    input                       audio_next_toggle,
    input                       key_auto,
    input                       auto_play_switch,
    input                       manual_prev_busy,
    input                       demo_force_auto,    // 演示期间临时轮播，不改 KEY4 保存的手动/自动状态
    input                       auto_play_init,     // 上电 / 重新扫描后自动轮播的初始状态（顶层接 1：上电自启动）
    input                       preview_requested,
    output                      sd_wd_fired,        // SD 看门狗动作过（粘滞），供健康指示
    output reg                  recovery_failed,    // 图片或 WAV 重试失败（粘滞）
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,      // 0 / 1 = 两块帧缓存，2 = 音频区
    output reg [1:0]            thumbnail_bank,
    output reg [3:0]            preview_valid_mask,
    output reg                  write_is_preview,
    output reg [1:0]            disp_buf_idx,
    output                      resident_mode,
    output reg [7:0]            diag_cache_hits,
    output reg [7:0]            diag_load_seconds,
    output reg [3:0]            diag_error_code,
    output reg [1:0]            audio_track,
    output                      diag_load_busy,

    // WAV（第 5 步新增）
    output reg                  write_is_wav,       // 本次写入的是 WAV：写长度取 wav_words，地址线性不翻转
    output [20:0]               wav_words,          // WAV 字数（扫描后不再变化）
    output reg                  wav_ready,          // WAV 已完整写入 SDRAM 音频区，可以播放
    output                      next_image_ready,   // 后台下一张完整写入，可供手动切图

    // 音画同步（第 5c 步）
    input                       beat_toggle,        // video_clk 域 av_sync：每到一个对齐点翻转一次
    output [2:0]                img_count,          // 扫描到的图片张数（扫描后不再变化）

    output [1:0]                active_image,
    output reg [1:0]            display_scale_mode,
    output reg                  display_large_1024,
    output [3:0]                image_large_1024,
    output [7:0]                image_scale_modes,
    output                      auto_enabled,
    // 数字标牌节目单（PLAYLIST.TXT）：状态给自检页/信息页，转场与字幕给视频域
    output                      playlist_active,
    output                      playlist_ready,    // 配置文件读取/解析已结束（无该文件时也立刻为 1）
    output                      text_mode,        // 解析的是 TEXT.TXT（纯词条行）：轮播保持原行为，只换底部词条
    output                      footer_active,    // 底部字幕有内容可显示（节目单条目或 TEXT.TXT 词条）
    output                      sd_mounted,       // TF 卡初始化完成（自检页第 1 项）
    output [3:0]                load_stage,       // 串口 LOAD_PHASE：0..14 阶段码
    output [4:0]                playlist_entries,
    output [3:0]                playlist_errors,
    output [3:0]                playlist_pos,
    output [1:0]                playlist_transition,
    input  [3:0]                sub_rd_entry,
    input                       sub_rd_lang,
    input  [5:0]                sub_rd_char,
    input                       sub_rd_clk,
    output [15:0]               sub_rd_code,
    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;
reg [2:0] manual_next_sync;
wire manual_next_pulse = manual_next_sync[2] ^ manual_next_sync[1];
reg [2:0] remote_select_sync;
reg [1:0] remote_index_meta, remote_index_sync;
wire remote_select_pulse = remote_select_sync[2] ^ remote_select_sync[1];
reg [2:0] button_select_sync;
reg [1:0] button_index_meta, button_index_sync;
wire button_select_pulse = button_select_sync[2] ^ button_select_sync[1];
reg [2:0] remote_prev_sync, remote_period_sync;
reg [3:0] remote_period_meta, remote_period_sync_value;
wire remote_prev_pulse = remote_prev_sync[2] ^ remote_prev_sync[1];
wire remote_period_pulse = remote_period_sync[2] ^ remote_period_sync[1];
reg [2:0] audio_select_sync;
reg [1:0] audio_index_meta, audio_index_sync;
wire audio_select_pulse = audio_select_sync[2] ^ audio_select_sync[1];
reg [2:0] audio_next_sync;
wire audio_next_pulse = audio_next_sync[2] ^ audio_next_sync[1];
    reg  audio_next_latch;                  // 长按请求锁存到被接受为止
    wire audio_next_req = audio_next_pulse || audio_next_latch;
wire [2:0] audio_count_fat;
    wire [1:0] audio_request_idx = audio_next_req ?
    ((audio_track + 2'd1 >= audio_count_fat) ? 2'd0 : audio_track + 2'd1) : audio_index_sync;
wire key_auto_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             physical_sec_read;
wire [31:0]      physical_sec_addr;
wire [7:0]       physical_sec_data;
wire             physical_sec_valid, physical_sec_end;
wire             fat_index_ready, fat_index_active;
wire [31:0]      fat_raw_start;
wire [31:0]      fat_virtual_last;
wire             fat_mapping_fault;
wire [31:0]      audio_base_fat, audio_size_fat;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire [15:0]      source_width, source_height;
wire             scaled_valid, scale_done;
wire [23:0]      scaled_data;
wire             preview_word_valid;
wire [31:0]      preview_word_data;
wire [31:0]      wav_word;
wire             wav_found;
wire [31:0]      wav_sector;
reg [20:0]       selected_audio_words;
reg [31:0]       audio_size_latched;
reg [1:0]        audio_pending_index;
reg              audio_request_pending, audio_size_pending;
function [20:0] wav_words_from_size;
    input [31:0] size_bytes;
    input [20:0] max_words;
    reg [31:0] data_words;
    begin
        if (size_bytes <= 32'd44)
            wav_words_from_size = 21'd0;
        else begin
            data_words = (size_bytes - 32'd44) >> 2;
            if (data_words > max_words)
                data_words = max_words;
            wav_words_from_size = {data_words[20:8], 8'd0};
        end
    end
endfunction
reg              wav_tried;            // 每次扫描后只尝试加载一次（失败不反复重试）
wire             sd_init_done;
wire             bmp_ready;
wire             bmp_load_error;
wire             scan_done;
wire             scan_paused;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              scan_resume_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
wire             auto_play_effective = (USE_AUTO_SWITCH ? auto_play_switch : auto_play_en) || demo_force_auto;
localparam integer AUTO_COUNT_BITS = (CLK_FREQ_HZ < 2) ? 1 : $clog2(CLK_FREQ_HZ);
reg [AUTO_COUNT_BITS-1:0] auto_cnt;
reg [26:0] diag_second_counter;
reg              auto_count_enable_q;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        load_scale_mode;
reg              load_large_1024;
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              next_req_pending;
reg              remote_target_pending;
reg [1:0]        remote_target;
reg [3:0]        period_seconds_q;
reg [7:0]        elapsed_seconds;
reg              load_busy;
// 音频切换请求"被状态机接受"的当拍条件。KEY1 长按常常正好落在后台预加载 / 写图期间，
// 那一拍 bmp_ready = 0，只靠单拍脉冲会被丢掉（tb_wav_select 复现过：连按三下才进去）。
// 所以脉冲进 audio_next_latch 记住，写通道一空下来就当拍接受。这几个信号都先声明后使用——
// TD 会把"声明写在首次使用之后"的逻辑整块剪掉。
wire             audio_request_taken = (audio_select_pulse || audio_next_req) && bmp_ready && !load_busy &&
                                       audio_count_fat != 0 &&
                                       (audio_next_req || audio_index_sync < audio_count_fat);
reg              retry_pending;
reg              retry_count;
reg              retry_wav;
reg              retry_preview;
reg [1:0]        preview_load_idx;
reg              scan_resume_pending;
reg [3:0]        bad_image_mask;
reg [3:0]        preview_failed_mask;
reg [3:0]        resident_mask;
reg              resident_eligible;
reg              resident_mode_q;
reg              scan_done_q;
reg [1:0]        resident_scale_mode [0:3];
reg [3:0]        resident_large_1024;
assign image_large_1024 = resident_large_1024;
integer          resident_i;
assign image_scale_modes = {resident_scale_mode[3], resident_scale_mode[2],
                            resident_scale_mode[1], resident_scale_mode[0]};

// 音画同步（第 5c 步）：WAV 在播、自动轮播打开、图片不止一张时，切图跟着 av_sync 的节拍走
//   每次切换后立刻把下一张预加载进后台缓冲（preload_mode），读完不切（preloaded），等节拍到了再切；
//   节拍来时如果还没读完就先记下（beat_pending），读完立刻切。
//   KEY2：后台已有下一张就立即切换，不用再读卡；接下来的自动切换从下一个节拍继续。
reg [2:0]        beat_sync;
wire             beat_pulse;
wire [2:0]      sd_init_phase;
wire             sync_mode;
reg              preload_mode;
reg              preloaded;
reg              beat_pending;
reg              cache_fill_mode;
reg [31:0]       load_timeout_cnt;
reg              load_abort;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
reg [1:0] next_from_current;
reg [1:0] next_current_q;
reg next_available_q;
reg next_target_valid_q;
wire next_index_ready = next_current_q == img_idx && next_target_valid_q;

wire load_scale_done = scale_done;
assign write_en   = write_is_wav ? bmp_data_wr_en :
                    write_is_preview ? preview_word_valid :
                    scaled_valid;
assign write_data = write_is_wav ? wav_word :
                    write_is_preview ? preview_word_data :
                    {scaled_data, 8'b0};
wire [3:0] available_mask = ((4'b0001 << img_found_count) - 4'b0001) & ~bad_image_mask;
wire [3:0] uncached_mask = available_mask & ~resident_mask;
wire [1:0] uncached_index = uncached_mask[0] ? 2'd0 :
                            uncached_mask[1] ? 2'd1 :
                            uncached_mask[2] ? 2'd2 : 2'd3;
wire [3:0] missing_preview_mask = available_mask &
                                  ~(preview_valid_mask | preview_failed_mask);
wire [1:0] next_preview_index = missing_preview_mask[0] ? 2'd0 :
                                missing_preview_mask[1] ? 2'd1 :
                                missing_preview_mask[2] ? 2'd2 : 2'd3;
reg [1:0] next_preview_index_q;
reg       preview_available_q;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        next_preview_index_q <= 2'd0;
        preview_available_q <= 1'b0;
    end else begin
        next_preview_index_q <= next_preview_index;
        preview_available_q <= missing_preview_mask != 4'd0;
    end
end
localparam integer RESIDENT_AUDIO_WORDS = SDRAM_WORDS - 4*FRAME_WIDTH*FRAME_HEIGHT - PREVIEW_WORDS;
localparam [20:0] RESIDENT_AUDIO_WORDS_ALIGNED = (RESIDENT_AUDIO_WORDS / 256) * 256;
wire resident_cache_possible = ENABLE_RESIDENT && resident_eligible &&
                               RESIDENT_AUDIO_WORDS > 0 &&
                               (!wav_found || wav_words <= RESIDENT_AUDIO_WORDS);
assign resident_mode = resident_mode_q;
assign diag_load_busy = load_busy;
wire can_load_next = next_index_ready && next_available_q &&
                     (!display_valid || next_from_current != img_idx);

// ===================== 数字标牌节目单（PLAYLIST.TXT）在 SD 域的状态 =====================
// 启动时把 PLAYLIST.TXT 读进来解析一次（cfg_* 状态机在本文件末尾），之后只做三件事：
//   ① 轮播推进按"节目单条目的图片序号"走，而不是目录顺序；
//   ② 每条时长按条目秒数（0 = 该条仍跟随音频节拍）；
//   ③ 当前条目的转场与字幕交给顶层（字幕是一张只写一次的静态表，视频域可直接寻址）。
wire        list_present;                // 解析器：文件存在且至少一条
wire        list_done;                   // 解析器：解析完成
wire [4:0]  list_entries;                // 节目条数（0..16）
wire [3:0]  list_errors;                 // 解析错误行数（进自检页）
reg         cfg_text_mode;                  // 解析的是 TEXT.TXT（先声明，list_active 要用）
wire        list_active = list_present && !cfg_text_mode;  // 节目单模式：轮播/转场也按它走（TEXT.TXT 模式不接管轮播）
wire [3:0]  list_rd_addr;                // 节目表读口地址（后台在探测的条目）
wire [2:0]  list_rd_img;
wire [7:0]  list_rd_sec;
wire [1:0]  list_rd_tr;
reg  [3:0]  list_pos;                    // 当前显示中的条目
reg  [3:0]  list_nxt;                    // 下一条（图片确实存在的条目）
reg  [3:0]  list_probe;                  // 后台逐拍找下一条时的探测位置
reg  [4:0]  list_probe_cnt;
reg  [1:0]  prev_list_img;               // 上一张播放过的节目单图片（KEY4 回退目标）
reg         prev_list_valid;
reg         direct_select_pending;       // 当前换图来自 S13~S16/缩略图直选
reg         list_nxt_stale;              // 需要重新找下一条
reg  [2:0]  nxt_img_q;                   // 已确认的下一条图片序号（1..7）
reg  [7:0]  nxt_sec_q;
reg  [1:0]  nxt_tr_q;
reg  [7:0]  cur_sec_q;                   // 当前条目秒数（0 = 跟节拍）
reg  [1:0]  cur_tr_q;                    // 当前条目转场
reg  [1:0]  img_idx_prev;
wire        list_timed = list_active && (cur_sec_q != 8'd0);
wire [1:0]  list_rd_index = list_rd_img[1:0] - 2'd1;
wire [1:0]  nxt_index = nxt_img_q[1:0] - 2'd1;
wire [7:0]  period_eff = list_timed ? cur_sec_q : {4'd0, period_seconds_q};
wire        tick_mode  = !wav_ready;
wire        list_tick_boundary = (auto_tick && tick_mode && auto_play_effective) ||
                                 (beat_pulse && sync_mode);
wire        list_rd_usable = (list_probe < list_entries) &&
                             (list_rd_img >= 3'd1) && (list_rd_img <= 3'd4) &&
                             available_mask[list_rd_index] &&
                             !bad_image_mask[list_rd_index];
wire        direct_select_start = (remote_select_pulse && scan_done && display_valid &&
                                   remote_index_sync < img_found_count &&
                                   !bad_image_mask[remote_index_sync]) ||
                                  (button_select_pulse && display_valid);
wire        nxt_target_ok = (nxt_img_q >= 3'd1) && (nxt_img_q <= 3'd4) &&
                             available_mask[nxt_index] &&
                             !bad_image_mask[nxt_index];

// 启动时读 PLAYLIST.TXT 的状态机（逻辑在本文件末尾靠近 bmp_read 处；这里先声明，避免前向引用）
wire [31:0] cfg_list_base, cfg_list_bytes, cfg_text_base, cfg_text_bytes;
localparam integer CFG_MAX_BYTES = 2048;                  // 最多读 2KB：8 条节目绰绰有余
wire [31:0] cfg_total = (cfg_list_bytes > CFG_MAX_BYTES) ? CFG_MAX_BYTES : cfg_list_bytes;
wire        cfg_use_text = ENABLE_TEXT && (cfg_list_bytes == 32'd0) && (cfg_text_bytes != 32'd0);
wire [31:0] cfg_total_eff = cfg_use_text ?
                            ((cfg_text_bytes > CFG_MAX_BYTES) ? CFG_MAX_BYTES : cfg_text_bytes) :
                            cfg_total;
wire [31:0] bmp_sec_read_addr;
wire        bmp_sec_read;
localparam [2:0] CFG_IDLE=3'd0, CFG_REQ=3'd1, CFG_DATA=3'd2, CFG_GAP=3'd3,
                 CFG_EOF=3'd4, CFG_WAIT=3'd5, CFG_DONE=3'd6;
reg  [2:0]  cfg_state;
reg  [31:0] cfg_left, cfg_addr_q;
reg  [1:0]  cfg_gap_cnt;
reg         cfg_read_q, cfg_started, cfg_ready;
reg  [27:0] cfg_timeout_cnt;
reg         cfg_byte_valid, cfg_start_pulse, cfg_eof_pulse;
reg  [7:0]  cfg_byte_data;

assign sd_sec_read      = cfg_read_q ? 1'b1 : bmp_sec_read;
assign sd_sec_read_addr = cfg_read_q ? cfg_addr_q : bmp_sec_read_addr;
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign beat_pulse = beat_sync[2] ^ beat_sync[1];
assign sync_mode  = wav_ready && auto_play_effective && (img_found_count > 3'd1);
assign next_image_ready = preloaded;
assign img_count  = img_found_count;
assign active_image = img_idx;
assign auto_enabled = auto_play_effective;
assign playlist_active     = list_active;
assign text_mode           = cfg_text_mode;
assign footer_active       = list_present;
assign playlist_ready      = cfg_ready;
assign sd_mounted          = sd_init_done;
// 串口状态行的 LOAD_PHASE 阶段码（OSD 的节目单错误行数单独显示）。
assign load_stage =
    !sd_init_done        ? (sd_init_phase == 3'd0 ? 4'd0 :
                            {1'b1,sd_init_phase} + 4'd1) :
    !fat_index_ready     ? 4'd1 :
    !bmp_ready           ? 4'd2 :
    !cfg_ready           ? 4'd3 :
    !scan_done           ? 4'd4 :
    (img_found_count==0) ? 4'd5 :
    !display_valid       ? 4'd6 :
    !wav_ready           ? 4'd7 :
    !fat_index_active    ? 4'd8 : 4'd9;
assign playlist_entries    = list_entries;
assign playlist_errors     = list_errors;
assign playlist_pos        = list_pos;
assign playlist_transition = cur_tr_q;

always @(posedge clk or posedge rst) begin
    if (rst)
        auto_count_enable_q <= 1'b0;
    else
        auto_count_enable_q <= scan_done && auto_play_effective && display_valid &&
                               !(USE_AUTO_SWITCH && manual_prev_busy) &&
                               !load_busy && first_image_committed && tick_mode &&
                               (!wav_found || wav_tried) &&
                               (img_found_count > 3'd1);
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        resident_mode_q <= 1'b0;
        scan_done_q <= 1'b0;
    end else begin
        resident_mode_q <= scan_done && resident_cache_possible;
        scan_done_q <= scan_done;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst)
        manual_next_sync <= 3'd0;
    else
        manual_next_sync <= {manual_next_sync[1:0], manual_next_toggle};
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        remote_select_sync <= 3'd0;
        remote_index_meta <= 2'd0;
        remote_index_sync <= 2'd0;
        button_select_sync <= 3'd0;
        button_index_meta <= 2'd0;
        button_index_sync <= 2'd0;
        remote_prev_sync <= 3'd0;
        remote_period_sync <= 3'd0;
        remote_period_meta <= 4'd1;
        remote_period_sync_value <= 4'd1;
        audio_select_sync <= 3'd0;
        audio_index_meta <= 2'd0;
        audio_index_sync <= 2'd0;
        audio_next_sync <= 3'd0;
        audio_next_latch <= 1'b0;
    end else begin
        remote_select_sync <= {remote_select_sync[1:0], remote_select_toggle};
        remote_index_meta <= remote_select_index;
        remote_index_sync <= remote_index_meta;
        button_select_sync <= {button_select_sync[1:0], button_select_toggle};
        button_index_meta <= button_select_index;
        button_index_sync <= button_index_meta;
        remote_prev_sync <= {remote_prev_sync[1:0], remote_prev_toggle};
        remote_period_sync <= {remote_period_sync[1:0], remote_period_toggle};
        remote_period_meta <= remote_period_seconds;
        remote_period_sync_value <= remote_period_meta;
        audio_select_sync <= {audio_select_sync[1:0], audio_select_toggle};
        audio_index_meta <= audio_select_index;
        audio_index_sync <= audio_index_meta;
        audio_next_sync <= {audio_next_sync[1:0], audio_next_toggle};
        if (audio_request_taken)
            audio_next_latch <= 1'b0;      // 已被状态机接受（写通道 / 读卡空闲），清掉
        else if (audio_next_pulse)
            audio_next_latch <= 1'b1;      // 忙的时候也要记住，别丢按键
    end
end

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    input [3:0] bad;
    integer step;
    reg [1:0] candidate;
    reg found;
    begin
        next_index_limited = cur;
        found = 1'b0;
        for (step=1; step<=4; step=step+1) begin
            candidate = cur + step[1:0];
            if (!found && candidate < count && !bad[candidate]) begin
                next_index_limited = candidate;
                found = 1'b1;
            end
        end
    end
endfunction

function [1:0] prev_index_limited;
    input [1:0] cur;
    input [2:0] count;
    input [3:0] bad;
    integer step;
    reg [1:0] candidate;
    reg found;
    begin
        prev_index_limited = cur;
        found = 1'b0;
        for (step=1; step<=4; step=step+1) begin
            candidate = cur - step[1:0];
            if (!found && candidate < count && !bad[candidate]) begin
                prev_index_limited = candidate;
                found = 1'b1;
            end
        end
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        next_from_current <= 2'd0;
        next_current_q <= 2'd0;
        next_available_q <= 1'b0;
        next_target_valid_q <= 1'b0;
    end else begin
        next_from_current <= list_active ? nxt_index :
                             next_index_limited(img_idx, img_found_count, bad_image_mask);
        next_current_q <= img_idx;
        next_available_q <= |available_mask;
        next_target_valid_q <= list_active ? nxt_target_ok :
                              !bad_image_mask[next_index_limited(img_idx,
                                                                 img_found_count,
                                                                 bad_image_mask)];
    end
end

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

function integer lowest_one;
    input [31:0] v;
    integer i;
    begin
        lowest_one = 0;
        for (i = 31; i >= 0; i = i - 1)
            if (v[i]) lowest_one = i;
    end
endfunction

// 1s 计时到点：比较提前一拍寄存（原来 32 位比较和后面的加载判断一拍做完，100MHz 下余量为负）。
// 上一拍 auto_cnt == AUTO_LAST - 1 时，这一拍 auto_cnt 只可能是 AUTO_LAST（继续计数）或 0（被某个分支清零），
// 取 AUTO_LAST 里任意一个为 1 的位就能区分，结果与原来的 auto_cnt == AUTO_LAST 完全等价
localparam [31:0] AUTO_LAST = CLK_FREQ_HZ - 1;
localparam integer AUTO_BIT = lowest_one(AUTO_LAST);
reg auto_tick_q;
reg period_boundary_q;
wire second_tick = auto_tick_q & auto_cnt[AUTO_BIT];

always @(posedge clk or posedge rst) begin
    if (rst) begin
        auto_tick_q <= 1'b0;
        period_boundary_q <= 1'b0;
    end else if (tick_mode) begin
        auto_tick_q <= (auto_cnt == AUTO_LAST - 32'd1);
        period_boundary_q <= (elapsed_seconds + 8'd1 >= period_eff);
    end else begin
        auto_tick_q <= 1'b0;
        period_boundary_q <= 1'b0;
    end
end

assign auto_tick = second_tick && period_boundary_q;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        scan_resume_pulse     <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;             // 异步复位值必须是常数；上电扫描开始那一拍会同步设成 auto_play_init
        auto_cnt              <= 32'd0;
        diag_second_counter   <= 32'd0;
        diag_cache_hits       <= 8'd0;
        diag_load_seconds     <= 8'd0;
        diag_error_code       <= 4'd0;
        period_seconds_q      <= 4'd1;
        elapsed_seconds       <= 8'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        display_scale_mode    <= 2'd0;
        display_large_1024    <= 1'b0;
        load_scale_mode       <= 2'd0;
        load_large_1024       <= 1'b0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        thumbnail_bank        <= 2'd0;
        preview_valid_mask    <= 4'd0;
        preview_failed_mask   <= 4'd0;
        write_is_preview      <= 1'b0;
        retry_preview         <= 1'b0;
        preview_load_idx      <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        next_req_pending      <= 1'b0;
        remote_target_pending <= 1'b0;
        remote_target         <= 2'd0;
        load_busy             <= 1'b0;
        retry_pending         <= 1'b0;
        retry_count           <= 1'b0;
        retry_wav             <= 1'b0;
        scan_resume_pending   <= 1'b0;
        bad_image_mask        <= 4'd0;
        resident_mask         <= 4'd0;
        resident_eligible     <= 1'b1;
        for (resident_i=0;resident_i<4;resident_i=resident_i+1)
            resident_scale_mode[resident_i] <= 2'd0;
        resident_large_1024   <= 4'd0;
        recovery_failed       <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
        write_is_wav          <= 1'b0;
        wav_tried             <= 1'b0;
        wav_ready             <= 1'b0;
        audio_track           <= 2'd0;
        selected_audio_words  <= 21'd0;
        audio_size_latched    <= 32'd0;
        audio_pending_index   <= 2'd0;
        audio_request_pending <= 1'b0;
        audio_size_pending    <= 1'b0;
        beat_sync             <= 3'b000;
        preload_mode          <= 1'b0;
        preloaded             <= 1'b0;
        beat_pending          <= 1'b0;
        cache_fill_mode       <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        beat_sync        <= {beat_sync[1:0], beat_toggle};
        scan_start_pulse <= 1'b0;
        scan_resume_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;
        if (!load_busy)
            diag_second_counter <= 32'd0;
        else if (diag_second_counter == CLK_FREQ_HZ - 1) begin
            diag_second_counter <= 32'd0;
            if (diag_load_seconds != 8'hFF)
                diag_load_seconds <= diag_load_seconds + 1'b1;
        end else
            diag_second_counter <= diag_second_counter + 1'b1;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            scan_resume_pulse     <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= auto_play_init;
            auto_cnt              <= 32'd0;
            diag_second_counter   <= 32'd0;
            diag_cache_hits       <= 8'd0;
            diag_load_seconds     <= 8'd0;
            diag_error_code       <= 4'd0;
            period_seconds_q      <= 4'd1;
            elapsed_seconds       <= 8'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            display_scale_mode    <= 2'd0;
            display_large_1024    <= 1'b0;
            load_scale_mode       <= 2'd0;
            load_large_1024       <= 1'b0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            thumbnail_bank        <= 2'd0;
            preview_valid_mask    <= 4'd0;
            preview_failed_mask   <= 4'd0;
            write_is_preview      <= 1'b0;
            retry_preview         <= 1'b0;
            preview_load_idx      <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            next_req_pending      <= 1'b0;
            remote_target_pending <= 1'b0;
            load_busy             <= 1'b0;
            retry_pending         <= 1'b0;
            retry_count           <= 1'b0;
            retry_wav             <= 1'b0;
            scan_resume_pending   <= 1'b0;
            bad_image_mask        <= 4'd0;
            resident_mask         <= 4'd0;
            resident_large_1024   <= 4'd0;
            resident_eligible     <= 1'b1;
            recovery_failed       <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            display_valid         <= 1'b0;
            write_is_wav          <= 1'b0;
            wav_tried             <= 1'b0;
            wav_ready             <= 1'b0;
            audio_track           <= 2'd0;
            selected_audio_words  <= 21'd0;
            audio_size_latched    <= 32'd0;
            audio_pending_index   <= 2'd0;
            audio_request_pending <= 1'b0;
            audio_size_pending    <= 1'b0;
            preload_mode          <= 1'b0;
            preloaded             <= 1'b0;
            beat_pending          <= 1'b0;
            cache_fill_mode       <= 1'b0;
        end else begin
            if (write_req && write_req_ack && !write_is_wav) begin
                load_large_1024 <= (source_width == 16'd1024 && source_height == 16'd768);
                if (source_width == FRAME_WIDTH/2 && source_height == FRAME_HEIGHT/2)
                    load_scale_mode <= 2'd1;
                else if (source_width == FRAME_WIDTH/2 &&
                         source_height == (FRAME_HEIGHT*3)/8)
                    load_scale_mode <= 2'd3;
                else if (source_width == FRAME_WIDTH*2 && source_height == FRAME_HEIGHT*2)
                    load_scale_mode <= 2'd2;
                else if (source_width == 16'd1024 && source_height == 16'd768)
                    load_scale_mode <= 2'd2;      // 1024x768：同样按"缩小"上报（实际抽取在 bmp_read 里做）
                else
                    load_scale_mode <= 2'd0;
            end
            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && bmp_ready && (write_is_wav || load_scale_done))
                source_done_seen <= 1'b1;

            // 记住写帧完成脉冲，避免"先写完后源结束"导致脉冲丢失而卡死（移植自 lab_ex4）
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            // 只有"源图送完 + 整帧写完"都满足，才提交新图并切换显示缓冲区
            if (load_busy && source_done_seen && write_done_seen) begin
                load_busy             <= 1'b0;
                retry_count           <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                if (!write_is_wav && !write_is_preview) begin
                    resident_mask[load_idx] <= 1'b1;
                    resident_scale_mode[load_idx] <= load_scale_mode;
                    resident_large_1024[load_idx] <= load_large_1024;
                end
                if (write_is_wav) begin
                    // WAV 写完：开始播放，显示不动
                    write_is_wav      <= 1'b0;
                    wav_ready         <= 1'b1;
                end else if (write_is_preview) begin
                    preview_valid_mask[preview_load_idx] <= 1'b1;
                    resident_scale_mode[preview_load_idx] <= load_scale_mode;
                    resident_large_1024[preview_load_idx] <= load_large_1024;
                    write_is_preview <= 1'b0;
                end else if (cache_fill_mode) begin
                    cache_fill_mode <= 1'b0;
                    preloaded <= 1'b0;
                end else if (remote_target_pending && load_idx == remote_target) begin
                    disp_buf_idx          <= pending_buf_idx;
                    img_idx               <= load_idx;
                    display_scale_mode    <= load_scale_mode;
                    display_large_1024    <= load_large_1024;
                    display_valid         <= 1'b1;
                    first_image_committed <= 1'b1;
                    preload_mode          <= 1'b0;
                    preloaded             <= 1'b0;
                    remote_target_pending <= 1'b0;
                    next_req_pending      <= 1'b0;
                    beat_pending          <= 1'b0;
                end else if (remote_target_pending && load_idx != remote_target) begin
                    preload_mode <= 1'b0;
                    preloaded <= 1'b0;
                end else if (preload_mode && !beat_pending && !next_req_pending &&
                             !(beat_pulse && sync_mode)) begin
                    // 预加载完成：图已在后台缓冲，等节拍（或按键）再切
                    preload_mode      <= 1'b0;
                    preloaded         <= 1'b1;
                end else begin
                    disp_buf_idx          <= pending_buf_idx;
                    img_idx               <= load_idx;
                    display_scale_mode    <= load_scale_mode;
                    display_large_1024    <= load_large_1024;
                    display_valid         <= 1'b1;
                    first_image_committed <= 1'b1;
                    preload_mode          <= 1'b0;
                    // 这次切换顶掉了期间到来的节拍；预加载期间按的 KEY2 也算用掉了
                    beat_pending          <= 1'b0;
                    if (preload_mode)
                        next_req_pending  <= 1'b0;
                end
            end else if (load_busy) begin
                // 加载超时（坏图、截断的文件、SDRAM 写不完）：放弃这次加载，恢复按键响应（移植自 lab_ex4）
                // 正常加载约 0.5s；lab_ex4 用 1s，这里放宽到 3s，给读得慢的卡留余量
                if (bmp_load_error || fat_mapping_fault ||
                    load_timeout_cnt == (write_is_wav ? WAV_TIMEOUT_CYCLES : LOAD_TIMEOUT_CYCLES) - 1) begin
                    if (bmp_load_error) diag_error_code <= 4'd1;
                    else if (fat_mapping_fault) diag_error_code <= 4'd2;
                    else diag_error_code <= 4'd3;
                    load_busy             <= 1'b0;
                    load_timeout_cnt      <= 32'd0;
                    source_done_seen      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    write_is_wav          <= 1'b0;
                    write_is_preview      <= 1'b0;
                    preload_mode          <= 1'b0;
                    load_abort            <= 1'b1;
                    if (!retry_count) begin
                        retry_count <= 1'b1;
                        retry_pending <= 1'b1;
                        retry_wav <= write_is_wav;
                        retry_preview <= write_is_preview;
                    end else begin
                        retry_count <= 1'b0;
                        recovery_failed <= 1'b1;
                        diag_error_code <= 4'd4;
                        if (write_is_preview)
                            preview_failed_mask[preview_load_idx] <= 1'b1;
                        else if (!write_is_wav) begin
                            bad_image_mask[load_idx] <= 1'b1;
                            cache_fill_mode <= 1'b0;
                            if (remote_target_pending && load_idx == remote_target)
                                remote_target_pending <= 1'b0;
                            if (!first_image_committed && scan_paused)
                                scan_resume_pending <= 1'b1;
                            else if (display_valid && !preload_mode && !cache_fill_mode)
                                next_req_pending <= 1'b1;
                        end
                    end
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready && fat_index_ready && cfg_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= auto_play_init;
                auto_cnt              <= 32'd0;
                elapsed_seconds       <= 8'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                display_scale_mode    <= 2'd0;
                display_large_1024    <= 1'b0;
                load_scale_mode       <= 2'd0;
                load_large_1024       <= 1'b0;
                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                remote_target_pending <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                write_is_wav          <= 1'b0;
                write_is_preview      <= 1'b0;
                preview_valid_mask    <= 4'd0;
                preview_failed_mask   <= 4'd0;
                wav_tried             <= 1'b0;
                wav_ready             <= 1'b0;
                preload_mode          <= 1'b0;
                preloaded             <= 1'b0;
                beat_pending          <= 1'b0;
                cache_fill_mode       <= 1'b0;
                retry_pending         <= 1'b0;
                retry_count           <= 1'b0;
                scan_resume_pending   <= 1'b0;
                bad_image_mask        <= 4'd0;
                resident_mask         <= 4'd0;
                resident_large_1024   <= 4'd0;
                resident_eligible     <= 1'b1;
                for (resident_i=0;resident_i<4;resident_i=resident_i+1)
                    resident_scale_mode[resident_i] <= 2'd0;
                recovery_failed       <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if ((key_next_press || manual_next_pulse) && display_valid)
                    next_req_pending <= 1'b1;
                if (remote_select_pulse && scan_done && display_valid &&
                    remote_index_sync < img_found_count &&
                    !bad_image_mask[remote_index_sync]) begin
                    remote_target <= remote_index_sync;
                    remote_target_pending <= 1'b1;
                end
                if (button_select_pulse && display_valid) begin
                    remote_target <= button_index_sync;
                    remote_target_pending <= 1'b1;
                end
                if (remote_period_pulse && remote_period_sync_value >= 4'd1 &&
                    remote_period_sync_value <= 4'd9) begin
                    period_seconds_q <= remote_period_sync_value;
                    auto_cnt <= 32'd0;
                    elapsed_seconds <= 8'd0;
                end
                if (remote_prev_pulse && scan_done && display_valid &&
                    img_found_count != 0) begin
                    if (list_active) begin
                        // KEY4 只回上一张播放过的节目单图片，不跨到未排入
                        // 节目单的隐藏图片（例如应急图 2/4）。
                        if (prev_list_valid) begin
                            remote_target <= prev_list_img;
                            remote_target_pending <= 1'b1;
                        end
                    end else begin
                        // 没有节目单时保留原来的全图集回退。
                        remote_target <= prev_index_limited(img_idx, img_found_count,
                                                            bad_image_mask);
                        remote_target_pending <= 1'b1;
                    end
                    beat_pending <= 1'b0;
                end

                // 自动播放开/关
                if (!USE_AUTO_SWITCH && key_auto_press && scan_done && (img_found_count > 3'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt <= 32'd0;
                    beat_pending <= 1'b0;
                end

                // 节拍到了：后台已有下一张就切，没有就记下来等它读完
                if (beat_pulse && sync_mode && !remote_target_pending &&
                    !(USE_AUTO_SWITCH && manual_prev_busy) &&
                    !remote_prev_pulse &&
                    !remote_select_pulse) begin
                    if (preloaded) begin
                        disp_buf_idx <= pending_buf_idx;
                        img_idx      <= load_idx;
                        display_scale_mode <= load_scale_mode;
                        display_large_1024 <= load_large_1024;
                        preloaded    <= 1'b0;
                        beat_pending <= 1'b0;
                    end else if (!(load_busy && source_done_seen && write_done_seen &&
                                   preload_mode && !remote_target_pending)) begin
                        beat_pending <= 1'b1;
                    end
                end
                // KEY2 且后台已有下一张：立即切换（不和节拍同一拍，避免连切两张）
                else if (next_req_pending && preloaded && !remote_target_pending) begin
                    disp_buf_idx     <= pending_buf_idx;
                    img_idx          <= load_idx;
                    display_scale_mode <= load_scale_mode;
                    display_large_1024 <= load_large_1024;
                    preloaded        <= 1'b0;
                    next_req_pending <= 1'b0;
                end
                else if (auto_tick && tick_mode && auto_play_effective &&
                         !(USE_AUTO_SWITCH && manual_prev_busy) &&
                         !remote_prev_pulse &&
                         preloaded && !remote_target_pending) begin
                    disp_buf_idx <= pending_buf_idx;
                    img_idx <= load_idx;
                    display_scale_mode <= load_scale_mode;
                    display_large_1024 <= load_large_1024;
                    preloaded <= 1'b0;
                end

                // 自动播放 1s 计数：只有当前没有写图任务时才计时
                if (auto_count_enable_q) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 1'b1;
                end else
                    auto_cnt <= 32'd0;
                if (remote_prev_pulse)
                    auto_cnt <= 32'd0;
                if (USE_AUTO_SWITCH && (!auto_play_effective || manual_prev_busy))
                    beat_pending <= 1'b0;
                if (second_tick) begin
                    if (elapsed_seconds + 8'd1 >= period_eff)
                        elapsed_seconds <= 8'd0;
                    else
                        elapsed_seconds <= elapsed_seconds + 8'd1;
                end

                // 首图自动加载到 buffer0
                if (retry_pending && bmp_ready && !load_abort) begin
                    retry_pending    <= 1'b0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    write_is_wav     <= retry_wav;
                    write_is_preview <= retry_preview;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    load_timeout_cnt <= 32'd0;
                end
                else if (scan_resume_pending && bmp_ready && !load_abort) begin
                    scan_resume_pending <= 1'b0;
                    scan_resume_pulse <= 1'b1;
                end
                else if ((scan_done || (scan_paused && !bad_image_mask[0])) &&
                    !first_image_committed && bmp_ready && !load_busy && can_load_next) begin
                    if (next_from_current != 2'd0)
                        resident_eligible <= 1'b0;
                    load_idx         <= next_from_current;
                    thumbnail_bank   <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt <= 32'd0;
                end
                else if (scan_paused && first_image_committed && bmp_ready && !load_busy) begin
                    scan_resume_pulse <= 1'b1;
                end
                else if (audio_size_pending && bmp_ready && !load_busy) begin
                    audio_size_latched <= audio_size_fat;
                    load_sector <= audio_base_fat;
                    audio_size_pending <= 1'b0;
                    audio_request_pending <= 1'b1;
                end
                else if (audio_request_pending && bmp_ready && !load_busy) begin
                    selected_audio_words <= wav_words_from_size(audio_size_latched,
                        resident_mode ? RESIDENT_AUDIO_WORDS_ALIGNED : WAV_MAX_WORDS);
                    audio_track       <= audio_pending_index;
                    write_buf_idx     <= 2'd2;
                    write_is_wav      <= 1'b1;
                    wav_ready         <= 1'b0;
                    wav_tried         <= 1'b1;
                    load_start_pulse  <= 1'b1;
                    load_busy         <= 1'b1;
                    source_done_seen  <= 1'b0;
                    write_done_seen   <= 1'b0;
                    auto_cnt          <= 32'd0;
                    audio_request_pending <= 1'b0;
                end
                else if (audio_request_taken) begin
                    audio_pending_index <= audio_request_idx;
                    audio_size_pending <= 1'b1;
                end
                // 首图显示出来之后，把 WAV 整段载入 SDRAM 音频区（buffer 2），只做一次
                // 期间按键请求照样记下，载完再切图
                else if (scan_done && first_image_committed && bmp_ready && !load_busy &&
                         scan_done_q &&
                         wav_found && !wav_tried && !next_req_pending &&
                         !remote_target_pending) begin
                    load_sector      <= wav_sector;
                    write_buf_idx    <= 2'd2;
                    write_is_wav     <= 1'b1;
                    wav_tried        <= 1'b1;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    auto_cnt <= 32'd0;
                end
                else if (remote_target_pending && scan_done && bmp_ready && !load_busy) begin
                    if (remote_target >= img_found_count ||
                        bad_image_mask[remote_target] || remote_target == img_idx) begin
                        remote_target_pending <= 1'b0;
                    end else if (preloaded && load_idx != remote_target) begin
                        preloaded <= 1'b0;
                    end else if (preloaded || (resident_mode && resident_mask[remote_target])) begin
                        if (resident_mode && resident_mask[remote_target] &&
                            diag_cache_hits != 8'hFF)
                            diag_cache_hits <= diag_cache_hits + 1'b1;
                        disp_buf_idx <= resident_mode ? remote_target : pending_buf_idx;
                        img_idx <= remote_target;
                        display_scale_mode <= resident_mode ?
                                              resident_scale_mode[remote_target] : load_scale_mode;
                        display_large_1024 <= resident_mode ?
                                              resident_large_1024[remote_target] : load_large_1024;
                        preloaded <= 1'b0;
                        remote_target_pending <= 1'b0;
                        next_req_pending <= 1'b0;
                        beat_pending <= 1'b0;
                    end else begin
                    load_idx <= remote_target;
                    thumbnail_bank <= remote_target;
                        load_sector <= sector_lut(remote_target);
                        pending_buf_idx <= resident_mode ? remote_target :
                                           next_buf_lut(disp_buf_idx, display_valid);
                        write_buf_idx <= resident_mode ? remote_target :
                                         next_buf_lut(disp_buf_idx, display_valid);
                        load_start_pulse <= 1'b1;
                        load_busy <= 1'b1;
                        source_done_seen <= 1'b0;
                        write_done_seen <= 1'b0;
                        preload_mode <= 1'b0;
                        auto_cnt <= 32'd0;
                    end
                end
                else if (scan_done && bmp_ready && display_valid && !load_busy &&
                         resident_mode && resident_mask[next_from_current] &&
                         !preloaded && can_load_next) begin
                    load_idx <= next_from_current;
                    thumbnail_bank <= next_from_current;
                    pending_buf_idx <= next_from_current;
                    load_scale_mode <= resident_scale_mode[next_from_current];
                    load_large_1024 <= resident_large_1024[next_from_current];
                    if (beat_pending || (beat_pulse && sync_mode) || next_req_pending ||
                        (auto_tick && tick_mode && auto_play_effective)) begin
                        disp_buf_idx <= next_from_current;
                        img_idx <= next_from_current;
                        display_scale_mode <= resident_scale_mode[next_from_current];
                        display_large_1024 <= resident_large_1024[next_from_current];
                        beat_pending <= 1'b0;
                        next_req_pending <= 1'b0;
                    end else
                        preloaded <= 1'b1;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && next_req_pending && !preloaded && can_load_next) begin
                    load_idx         <= next_from_current;
                    thumbnail_bank   <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= resident_mode ? next_from_current : next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= resident_mode ? next_from_current : next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt <= 32'd0;
                end
                else if (scan_done && scan_done_q && bmp_ready && display_valid && !load_busy &&
                         wav_ready && resident_mode && |uncached_mask &&
                         !next_req_pending && !remote_target_pending) begin
                    load_idx         <= uncached_index;
                    thumbnail_bank   <= uncached_index;
                    load_sector      <= sector_lut(uncached_index);
                    pending_buf_idx  <= uncached_index;
                    write_buf_idx    <= uncached_index;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    cache_fill_mode  <= 1'b1;
                    preloaded        <= 1'b0;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 音画同步：把下一张预加载进后台缓冲，读完不切，等节拍
                else if (scan_done && bmp_ready && display_valid && !load_busy &&
                         wav_ready && (img_found_count > 3'd1) && !preloaded && can_load_next) begin
                    load_idx         <= next_from_current;
                    thumbnail_bank   <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= resident_mode ? next_from_current : next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= resident_mode ? next_from_current : next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    preload_mode     <= 1'b1;
                    auto_cnt <= 32'd0;
                end
                // 自动播放下一张（没有 WAV 时每 1s 一张）：同样写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && !preloaded &&
                         tick_mode && auto_play_effective && auto_tick &&
                         (img_found_count > 3'd1) && can_load_next) begin
                    load_idx         <= next_from_current;
                    thumbnail_bank   <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= resident_mode ? next_from_current : next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= resident_mode ? next_from_current : next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    auto_cnt <= 32'd0;
                end
                else if (ENABLE_FULL_PREVIEW && preview_requested && scan_done &&
                         bmp_ready && !load_busy && preview_available_q &&
                         !preview_valid_mask[next_preview_index_q] &&
                         !preview_failed_mask[next_preview_index_q] &&
                         !next_req_pending && !remote_target_pending && !beat_pending) begin
                    preview_load_idx <= next_preview_index_q;
                    thumbnail_bank   <= next_preview_index_q;
                    load_sector      <= sector_lut(next_preview_index_q);
                    write_is_preview <= 1'b1;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    load_timeout_cnt <= 32'd0;
                end
                if (load_busy && cache_fill_mode && resident_mode) begin
                    if (remote_target_pending && resident_mask[remote_target] &&
                        remote_target != write_buf_idx) begin
                        disp_buf_idx <= remote_target;
                        img_idx <= remote_target;
                        display_scale_mode <= resident_scale_mode[remote_target];
                        display_large_1024 <= resident_large_1024[remote_target];
                        remote_target_pending <= 1'b0;
                        next_req_pending <= 1'b0;
                        beat_pending <= 1'b0;
                        if (diag_cache_hits != 8'hFF)
                            diag_cache_hits <= diag_cache_hits + 1'b1;
                    end else if (next_req_pending && next_index_ready &&
                                 resident_mask[next_from_current] &&
                                 next_from_current != write_buf_idx) begin
                        disp_buf_idx <= next_from_current;
                        img_idx <= next_from_current;
                        display_scale_mode <= resident_scale_mode[next_from_current];
                        display_large_1024 <= resident_large_1024[next_from_current];
                        next_req_pending <= 1'b0;
                        beat_pending <= 1'b0;
                        if (diag_cache_hits != 8'hFF)
                            diag_cache_hits <= diag_cache_hits + 1'b1;
                    end
                end
            end
        end
    end
end

// ===================== 数字标牌节目单：启动时把 PLAYLIST.TXT 读进来解析一次 =====================
// 读法复用虚拟盘的同一个逻辑读口：cfg 状态机独占它（扫描还没开始，bmp_read 停在 ST_IDLE），
// 逐扇区把文件字节喂给 playlist_parse，喂完拉 eof，等 done 再放扫描开始（scan_kicked 加了 cfg_ready）。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        cfg_state       <= CFG_IDLE;
        cfg_read_q      <= 1'b0;
        cfg_started     <= 1'b0;
        cfg_ready       <= 1'b0;
        cfg_left        <= 32'd0;
        cfg_addr_q      <= 32'd0;
        cfg_gap_cnt     <= 2'd0;
        cfg_byte_valid  <= 1'b0;
        cfg_start_pulse <= 1'b0;
        cfg_eof_pulse   <= 1'b0;
        cfg_byte_data   <= 8'd0;
        cfg_text_mode   <= 1'b0;
        cfg_timeout_cnt <= 28'd0;
    end else begin
        cfg_byte_valid  <= 1'b0;
        cfg_start_pulse <= 1'b0;
        cfg_eof_pulse   <= 1'b0;
        case (cfg_state)
            CFG_IDLE: if (fat_index_ready && !cfg_started) begin
                cfg_started <= 1'b1;
                if (!fat_index_active || cfg_total_eff == 32'd0) begin
                    cfg_ready <= 1'b1;                    // 没有节目单：完全保持原来的轮播行为
                end else begin
                    cfg_text_mode   <= cfg_use_text;
                    cfg_left        <= cfg_total_eff;
                    cfg_addr_q      <= cfg_use_text ? cfg_text_base : cfg_list_base;
                    cfg_start_pulse <= 1'b1;
                    cfg_state       <= CFG_REQ;
                end
            end
            CFG_REQ: begin
                cfg_read_q <= 1'b1;
                cfg_state  <= CFG_DATA;
            end
            CFG_DATA: begin
                if (sd_sec_read_data_valid && cfg_left != 32'd0) begin
                    cfg_byte_valid <= 1'b1;
                    cfg_byte_data  <= sd_sec_read_data;
                    cfg_left       <= cfg_left - 32'd1;
                end
                if (sd_sec_read_end) begin
                    cfg_read_q <= 1'b0;
                    if (cfg_left == 32'd0 ||
                        (sd_sec_read_data_valid && cfg_left == 32'd1))
                        cfg_state <= CFG_EOF;
                    else begin
                        cfg_addr_q  <= cfg_addr_q + 32'd1;
                        cfg_gap_cnt <= 2'd0;
                        cfg_state   <= CFG_GAP;
                    end
                end
            end
            CFG_GAP: begin
                cfg_read_q <= 1'b0;
                if (cfg_gap_cnt == 2'd1)
                    cfg_state <= CFG_REQ;
                else
                    cfg_gap_cnt <= cfg_gap_cnt + 2'd1;
            end
            CFG_EOF: begin
                cfg_eof_pulse <= 1'b1;                     // 这一拍 byte_valid 已回 0
                cfg_state     <= CFG_WAIT;
            end
            CFG_WAIT: if (list_done) begin
                cfg_ready <= 1'b1;
                cfg_state <= CFG_DONE;
            end
            default: cfg_state <= CFG_DONE;
        endcase
        // A broken/oversized PLAYLIST.TXT must not block image scanning forever.
        // 50M cycles at 50MHz = 1s; a 990-byte playlist needs only a few ms.
        if (cfg_started && !cfg_ready) begin
            if (cfg_timeout_cnt == 28'd49_999_999) begin
                cfg_ready      <= 1'b1;
                cfg_state      <= CFG_DONE;
                cfg_read_q     <= 1'b0;
                cfg_byte_valid <= 1'b0;
                cfg_eof_pulse  <= 1'b0;
            end else begin
                cfg_timeout_cnt <= cfg_timeout_cnt + 28'd1;
            end
        end else begin
            cfg_timeout_cnt <= 28'd0;
        end
    end
end

playlist_parse #(
    .MAX_ENTRIES    (16),
    .SUBTITLE_WORDS (39)
) u_playlist_parse (
    .clk(clk), .rst(rst),
    .start(cfg_start_pulse), .byte_valid(cfg_byte_valid), .byte_data(cfg_byte_data),
    .eof(cfg_eof_pulse),
    .entry_count(list_entries), .error_count(list_errors),
    .present(list_present), .done(list_done),
    .rd_entry(list_rd_addr), .rd_img_index(list_rd_img), .rd_seconds(list_rd_sec),
    .rd_transition(list_rd_tr),
    .rd_sub_entry(sub_rd_entry), .rd_sub_lang(sub_rd_lang),
    .rd_sub_char(sub_rd_char), .rd_sub_clk(sub_rd_clk),
    .rd_sub_code(sub_rd_code)
);

assign list_rd_addr = list_nxt_stale ? list_probe : list_nxt;

// 节目单指针：pos 是当前条目；nxt 是下一条"图片确实存在"的条目。
// 图片换了一张（正常轮播）就把 pos 推到 nxt；手动跳图时 pos 不动（下一条仍按节目单继续）。
// 两条相邻节目用同一张图时，图片不会换（没有缓冲切换），此时按节拍/秒数把 pos 推进一步，
// 让字幕与时长立即生效。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        list_pos       <= 4'd0;
        list_nxt       <= 4'd0;
        list_probe     <= 4'd1;
        list_probe_cnt <= 5'd0;
        prev_list_img  <= 2'd0;
        prev_list_valid <= 1'b0;
        direct_select_pending <= 1'b0;
        list_nxt_stale <= 1'b0;
        nxt_img_q      <= 3'd1;
        nxt_sec_q      <= 8'd0;
        nxt_tr_q       <= 2'd0;
        cur_sec_q      <= 8'd0;
        cur_tr_q       <= 2'd0;
        img_idx_prev   <= 2'd0;
    end else begin
        img_idx_prev <= img_idx;
        if (!list_active) begin
            list_pos       <= 4'd0;
            list_nxt       <= 4'd0;
            list_probe     <= 4'd1;
            list_probe_cnt <= 5'd0;
            prev_list_img  <= 2'd0;
            prev_list_valid <= 1'b0;
            direct_select_pending <= 1'b0;
            list_nxt_stale <= 1'b0;
            nxt_img_q      <= 3'd1;
            nxt_sec_q      <= 8'd0;
            nxt_tr_q       <= 2'd0;
            cur_sec_q      <= 8'd0;
            cur_tr_q       <= 2'd0;
        end else if (scan_found_valid && img_found_count != 3'd0) begin
            list_nxt_stale <= 1'b1;
            list_probe     <= list_pos + 4'd1;
            list_probe_cnt <= 5'd0;
            prev_list_valid <= 1'b0;
            direct_select_pending <= 1'b0;
        end else if (list_tick_boundary &&
                     (preloaded || (resident_mode && resident_mask[next_from_current])) &&
                     !list_nxt_stale &&
                     (nxt_img_q == ({1'b0, img_idx} + 3'd1))) begin
            list_pos       <= list_nxt;
            cur_sec_q      <= nxt_sec_q;
            cur_tr_q       <= nxt_tr_q;
            list_nxt_stale <= 1'b1;
            list_probe     <= list_nxt + 4'd1;
            list_probe_cnt <= 5'd0;
        end else if (img_idx != img_idx_prev) begin
            if (!direct_select_pending && list_active) begin
                prev_list_img   <= img_idx_prev;
                prev_list_valid <= 1'b1;
            end
            if (nxt_img_q == ({1'b0, img_idx} + 3'd1)) begin
                list_pos  <= list_nxt;
                cur_sec_q <= nxt_sec_q;
                cur_tr_q  <= nxt_tr_q;
            end
            list_nxt_stale <= 1'b1;
            list_probe     <= list_nxt + 4'd1;
            list_probe_cnt <= 5'd0;
        end else if (list_nxt_stale) begin
            if (list_probe == list_pos) begin
                list_nxt_stale <= 1'b0;                    // 一圈只剩自己
            end else if (list_rd_usable) begin
                list_nxt       <= list_probe;
                nxt_img_q      <= list_rd_img;
                nxt_sec_q      <= list_rd_sec;
                nxt_tr_q       <= list_rd_tr;
                list_nxt_stale <= 1'b0;
            end else if (list_probe_cnt == 5'd15) begin
                list_nxt_stale <= 1'b0;                    // 整圈都没有可用图片：保持原值
            end else begin
                list_probe     <= list_probe + 4'd1;       // 4 位自动回绕
                list_probe_cnt <= list_probe_cnt + 5'd1;
            end
        end
        if (direct_select_start)
            direct_select_pending <= 1'b1;
        else if (img_idx != img_idx_prev)
            direct_select_pending <= 1'b0;
    end
end

wire [11:0] bmp_pix_pos;
bmp_read #(
    .FRAME_WIDTH            (FRAME_WIDTH),
    .FRAME_HEIGHT           (FRAME_HEIGHT),
    .WAV_MAX_WORDS          (WAV_MAX_WORDS),
    .SCAN_WAV_GAP           (SCAN_WAV_GAP)
) bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_resume            (scan_resume_pulse),
    .scan_start_sector      (fat_index_active ? 32'd0 : fat_raw_start),
    .scan_max_sector        (fat_index_active ? fat_virtual_last : SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_paused            (scan_paused),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),
    .wav_found              (wav_found),
    .wav_sector             (wav_sector),
    .wav_words              (wav_words),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),
    .load_wav               (write_is_wav),
    .wav_load_words         (selected_audio_words),
    .load_error             (bmp_load_error),

    .sd_init_done           (sd_init_done && fat_index_ready),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .source_width           (source_width),
    .source_height          (source_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (bmp_sec_read),
    .sd_sec_read_addr       (bmp_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .bmp_pix_pos            (bmp_pix_pos),
    .wav_word               (wav_word)
);

// ===================== 1280x960 → 640x480 的 2x2 均值（画质） =====================
// bmp_read 对该尺寸不再抽样、把完整像素流送出来，这里做 2x2 均值再交给缩放器（透传）。
// 像素坐标直接用 bmp_read 的 bmp_pix_pos（不数脉冲——扇区边界有空拍，数脉冲会整行漂移）。
// 其余尺寸把 in_valid 关掉、旁路原始数据，模块完全不影响它们。
wire use_avg2x = (source_width == FRAME_WIDTH*2) && (source_height == FRAME_HEIGHT*2);
wire avg_in_valid = bmp_data_wr_en && !write_is_wav && use_avg2x;
wire avg_out_valid;
wire [23:0] avg_out_data;
wire scale_in_valid = avg_out_valid || (bmp_data_wr_en && !write_is_wav && !use_avg2x);
wire [23:0] scale_in_data = use_avg2x ? avg_out_data : bmp_data;

bmp_avg2x u_bmp_avg2x (
    .clk(clk), .rst(rst),
    .in_valid(avg_in_valid), .in_data(bmp_data), .in_pix_pos(bmp_pix_pos),
    .out_valid(avg_out_valid), .out_data(avg_out_data)
);

bmp_scale_2x #(
    .FRAME_WIDTH  (FRAME_WIDTH),
    .FRAME_HEIGHT (FRAME_HEIGHT)
) u_bmp_scale_2x (
    .clk(clk), .rst(rst), .start(load_start_pulse),
    .mode_load(write_req && write_req_ack && !write_is_wav),
    .src_width(source_width), .src_height(source_height),
    .in_valid(bmp_data_wr_en && !write_is_wav), .in_data(bmp_data),
    .out_valid(scaled_valid), .out_data(scaled_data), .done(scale_done)
);

thumbnail_downsample #(.WIDTH(FRAME_WIDTH), .HEIGHT(FRAME_HEIGHT)) u_thumbnail_downsample (
    .clk(clk), .rst(rst), .start(load_start_pulse),
    .in_valid(scaled_valid && write_is_preview), .in_rgb(scaled_data),
    .word_valid(preview_word_valid), .word_data(preview_word_data)
);

// 50 MHz / ((2+2)*2) = 6.25 MHz for data; initialization stays at 100 kHz.
sd_card_top #(.SPI_HIGH_SPEED_DIV(SD_SPI_HIGH_SPEED_DIV)) sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .init_phase             (sd_init_phase),
    .sd_sec_read            (physical_sec_read),
    .sd_sec_read_addr       (physical_sec_addr),
    .sd_sec_read_data       (physical_sec_data),
    .sd_sec_read_data_valid (physical_sec_valid),
    .sd_sec_read_end        (physical_sec_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       (),
    .wd_fired               (sd_wd_fired)
);

fat32_virtual_disk #(.FAT32_ONLY(FAT32_ONLY), .ENABLE_TEXT(ENABLE_TEXT)) u_fat32_virtual_disk (
    .clk(clk), .rst(rst), .sd_ready(sd_init_done),
    .logical_read(sd_sec_read), .logical_addr(sd_sec_read_addr),
    .logical_valid(sd_sec_read_data_valid), .logical_data(sd_sec_read_data),
    .logical_end(sd_sec_read_end), .ready(fat_index_ready),
    .fat_mode(fat_index_active), .virtual_last(fat_virtual_last),
    .raw_start_sector(fat_raw_start),
    .wav_count(audio_count_fat),
    .wav_index(audio_pending_index), .wav_base(audio_base_fat),
    .wav_bytes(audio_size_fat),
    .list_base(cfg_list_base), .list_bytes(cfg_list_bytes),
    .text_base(cfg_text_base), .text_bytes(cfg_text_bytes),
    .mapping_fault(fat_mapping_fault),
    .physical_read(physical_sec_read), .physical_addr(physical_sec_addr),
    .physical_valid(physical_sec_valid), .physical_data(physical_sec_data),
    .physical_end(physical_sec_end)
);

endmodule
module bmp_scale_2x #(
    parameter integer FRAME_WIDTH = 640,
    parameter integer FRAME_HEIGHT = 480
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        mode_load,
    // in_valid must be at least 8 clocks apart. The 25MHz SD SPI byte stream
    // supplies one 24-bit pixel no faster than every 96 clocks at 100MHz.
    input  wire [15:0] src_width,
    input  wire [15:0] src_height,
    input  wire        in_valid,
    input  wire [23:0] in_data,
    output wire        out_valid,
    output wire [23:0] out_data,
    output wire        done
);

    localparam integer HALF_WIDTH = FRAME_WIDTH / 2;
    localparam integer HALF_HEIGHT = FRAME_HEIGHT / 2;
    localparam integer WIDE_HEIGHT = (FRAME_HEIGHT * 3) / 8;
    localparam integer IN_X_BITS = $clog2(HALF_WIDTH);
    localparam integer OUT_X_BITS = $clog2(FRAME_WIDTH);
    localparam integer ROW_BITS = $clog2(HALF_HEIGHT);
    reg half_size;
    reg wide_stretch;

    reg [23:0] row_mem [0:FRAME_WIDTH-1];
    reg [IN_X_BITS-1:0] write_x;
    reg [OUT_X_BITS-1:0] read_x;
    reg [ROW_BITS-1:0] read_row;
    reg write_bank, read_bank, read_active;
    reg [1:0] repeat_count, vertical_phase;
    reg ready0, ready1, done_q, valid_q;
    reg [23:0] data_q;
    wire [IN_X_BITS:0] write_addr = write_bank ? HALF_WIDTH + write_x : write_x;
    wire [IN_X_BITS:0] read_addr = read_bank ? HALF_WIDTH + read_x[OUT_X_BITS-1:1] :
                                             read_x[OUT_X_BITS-1:1];

    assign out_valid = half_size ? valid_q : in_valid;
    assign out_data = half_size ? data_q : in_data;
    assign done = half_size ? done_q : 1'b1;

    always @(posedge clk) begin
        if (!rst && !start && half_size && in_valid)
            row_mem[write_addr] <= in_data;
    end

    always @(posedge clk) begin
        if (half_size && read_active && !done_q)
            data_q <= row_mem[read_addr];
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            write_x <= {IN_X_BITS{1'b0}};
            read_x <= {OUT_X_BITS{1'b0}};
            read_row <= {ROW_BITS{1'b0}};
            write_bank <= 1'b0;
            read_bank <= 1'b0;
            read_active <= 1'b0;
            repeat_count <= 2'd0;
            vertical_phase <= 2'd0;
            ready0 <= 1'b0;
            ready1 <= 1'b0;
            done_q <= 1'b0;
            half_size <= 1'b0;
            wide_stretch <= 1'b0;
            valid_q <= 1'b0;
        end else if (start) begin
            write_x <= {IN_X_BITS{1'b0}};
            read_x <= {OUT_X_BITS{1'b0}};
            read_row <= {ROW_BITS{1'b0}};
            write_bank <= 1'b0;
            read_bank <= 1'b0;
            read_active <= 1'b0;
            repeat_count <= 2'd0;
            vertical_phase <= 2'd0;
            ready0 <= 1'b0;
            ready1 <= 1'b0;
            done_q <= 1'b0;
            half_size <= 1'b0;
            wide_stretch <= 1'b0;
            valid_q <= 1'b0;
        end else begin
            valid_q <= 1'b0;
            if (mode_load) begin
                half_size <= (src_width == HALF_WIDTH) &&
                             ((src_height == HALF_HEIGHT) || (src_height == WIDE_HEIGHT));
                wide_stretch <= (src_width == HALF_WIDTH) && (src_height == WIDE_HEIGHT);
            end
            if (half_size && in_valid) begin
                if (write_x == HALF_WIDTH-1) begin
                    write_x <= {IN_X_BITS{1'b0}};
                    write_bank <= ~write_bank;
                    if (write_bank) ready1 <= 1'b1;
                    else ready0 <= 1'b1;
                end else
                    write_x <= write_x + 1'b1;
            end
            if (half_size && !done_q) begin
                if (!read_active) begin
                    if ((read_bank && ready1) || (!read_bank && ready0)) begin
                        read_active <= 1'b1;
                        read_x <= {OUT_X_BITS{1'b0}};
                        repeat_count <= 2'd0;
                    end
                end else begin
                    valid_q <= 1'b1;
                    if (read_x == FRAME_WIDTH-1) begin
                        read_x <= {OUT_X_BITS{1'b0}};
                        if (repeat_count == ((wide_stretch && vertical_phase != 2'd0) ? 2'd2 : 2'd1)) begin
                            repeat_count <= 2'd0;
                            read_active <= 1'b0;
                            read_bank <= ~read_bank;
                            vertical_phase <= (vertical_phase == 2'd2) ? 2'd0 : vertical_phase + 2'd1;
                            if (read_bank) ready1 <= 1'b0;
                            else ready0 <= 1'b0;
                            if (read_row == (wide_stretch ? WIDE_HEIGHT-1 : HALF_HEIGHT-1))
                                done_q <= 1'b1;
                            else
                                read_row <= read_row + 1'b1;
                        end else
                            repeat_count <= repeat_count + 2'd1;
                    end else
                        read_x <= read_x + 1'b1;
                end
            end
        end
    end
endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule

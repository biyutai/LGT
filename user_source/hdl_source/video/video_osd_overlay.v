`timescale 1ns/1ps

module video_osd_overlay (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [23:0] rgb_in,
    input  wire        subtitle_enable,
    input  wire        status_enable,
    input  wire        info_page,          // SW1 拨上：整屏产品信息页（评委模式）
    input  wire        cover_active,       // 首图未就绪：画品牌封面的文字层
    input  wire        standby_mode,
    input  wire [1:0]  alpha,
    input  wire [1:0]  image_index,
    input  wire        browse_mode,
    input  wire [1:0]  browse_index,
    input  wire [1:0]  browse_scale_mode,
    input  wire        auto_enabled,
    input  wire        demo_mode,
    input  wire [2:0]  brightness_level,
    input  wire [2:0]  contrast_level,
    input  wire [3:0]  effect_level,
    input  wire [2:0]  audio_effect_level,
    input  wire [2:0]  volume_level,
    input  wire [2:0]  edit_mode,
    input  wire [1:0]  transition_kind,
    input  wire [1:0]  scale_mode,
    input  wire        source_large_1024,
    input  wire [23:0] timestamp,
    input  wire [3:0]  health,
    input  wire [7:0]  fps,
    input  wire [7:0]  load_seconds,
    input  wire [7:0]  cache_hits,
    input  wire [7:0]  underrun_count,
    input  wire        diag_view,
    // 数字标牌节目单字幕：有 PLAYLIST.TXT 时，底部字幕改用 16x16 中文字模画当前条目
    input  wire        playlist_subtitle,
    input  wire [15:0] playlist_sub_code,   // 当前字符槽对应的字幕码（节目单表组合读口）
    output wire [5:0]  playlist_sub_char,   // 字幕字符地址：交给节目单表
    output wire        playlist_sub_lang,   // 0 = 中文行，1 = 英文行（双语字幕）
    // 开机自检页：首图显示后 3 秒内的健康看板（TF/BMP/SDRAM/音频/HDMI/存档/节目单）
    input  wire        selfcheck_page,
    input  wire [6:0]  selfcheck_ok,        // 7 项：1 = 通过
    input  wire [2:0]  img_found,           // 扫描到的图片张数（0..4）
    input  wire [4:0]  playlist_entries,    // 节目单条数（最多 16）
    input  wire [3:0]  playlist_errors,     // 节目单错误行数
    // 播放证明 LOG 页：uart_slim_reporter 抓到的最近 7 条事件快照
    input  wire        log_page,
    input  wire [251:0] log_view,           // 7 × 36 bit（seq/秒 BCD/kind/item/valid）
    input  wire        log_any_valid,
    // 免维护值守：无内容引导页 / 运营者可读的错误提示 / 音画误差（0.1ms）
    input  wire        guide_page,
    input  wire [9:0]  av_err_01ms,
    output reg  [23:0] rgb_out
);
    reg subtitle_q, status_q, auto_q, demo_q;
    reg [1:0] alpha_q, image_q;
    reg [2:0] brightness_q, contrast_q, volume_q;
    reg [2:0] edit_q;
    reg [1:0] transition_q;
    reg [1:0] scale_q;
    reg       source_large_q;
    reg [23:0] time_q;
    reg [3:0] effect_q;
    reg [2:0] audio_q;
    reg [3:0] health_q;
    reg [7:0] fps_q, load_q, hits_q, underrun_q;
    reg       diag_q;
    reg [9:0] av_ms_q;

    // LOG 页快照展开成 7 个并行行（OSD 每行 16 像素，行内容只需在像素链里选一次）
    wire [15:0] lv_seq  [0:6];
    wire [11:0] lv_bcd  [0:6];
    wire [2:0]  lv_kind [0:6];
    wire [3:0]  lv_item [0:6];
    wire        lv_valid[0:6];
    genvar gl;
    generate
        for (gl = 0; gl < 7; gl = gl + 1) begin: g_log_unpack
            assign lv_seq[gl]   = log_view[gl*36    +: 16];
            assign lv_bcd[gl]   = log_view[gl*36+16 +: 12];
            assign lv_kind[gl]  = log_view[gl*36+28 +: 3];
            assign lv_item[gl]  = log_view[gl*36+31 +: 4];
            assign lv_valid[gl] = log_view[gl*36+35];
        end
    endgenerate

    function [15:0] log_kind_char;
        input [2:0] kind;
        input [1:0] pos;
        begin
            case (kind)
                3'd0: case (pos)
                    2'd0: log_kind_char=16'h8bbe; 2'd1: log_kind_char=16'h5907;
                    2'd2: log_kind_char=16'h542f; default: log_kind_char=16'h52a8;
                endcase
                3'd1: case (pos)
                    2'd0: log_kind_char=16'h56fe; 2'd1: log_kind_char=16'h7247;
                    2'd2: log_kind_char=16'h5207; default: log_kind_char=16'h6362;
                endcase
                3'd2: case (pos)
                    2'd0: log_kind_char=16'h8bfb; 2'd1: log_kind_char=16'h53d6;
                    2'd2: log_kind_char=16'h5931; default: log_kind_char=16'h8d25;
                endcase
                3'd3: case (pos)
                    2'd0: log_kind_char=16'h5361; 2'd1: log_kind_char=16'h7247;
                    2'd2: log_kind_char=16'h79fb; default: log_kind_char=16'h9664;
                endcase
                3'd4: case (pos)
                    2'd0: log_kind_char=16'h8282; 2'd1: log_kind_char=16'h76ee;
                    2'd2: log_kind_char=16'h9519; default: log_kind_char=16'h8bef;
                endcase
                default: case (pos)
                    2'd0: log_kind_char=16'h672a; 2'd1: log_kind_char=16'h77e5;
                    2'd2: log_kind_char=16'h4e8b; default: log_kind_char=16'h4ef6;
                endcase
            endcase
        end
    endfunction

    // Each row reads as "123秒  图片切换  图2"; item numbers are shown only where useful.
    function [15:0] log_cell_char;
        input [2:0] row;
        input [4:0] col;
        begin
            log_cell_char = 16'h0020;
            if (lv_valid[row]) begin
                case (col)
                    5'd0: log_cell_char = 16'h0030 + {12'd0,lv_bcd[row][11:8]};
                    5'd1: log_cell_char = 16'h0030 + {12'd0,lv_bcd[row][7:4]};
                    5'd2: log_cell_char = 16'h0030 + {12'd0,lv_bcd[row][3:0]};
                    5'd3: log_cell_char = 16'h79d2;
                    5'd5,5'd6,5'd7,5'd8: log_cell_char = log_kind_char(lv_kind[row], col - 5'd5);
                    5'd11: if ((lv_kind[row] == 3'd1 || lv_kind[row] == 3'd2) &&
                               lv_item[row] < 4'd4) log_cell_char = 16'h56fe;
                    5'd12: if ((lv_kind[row] == 3'd1 || lv_kind[row] == 3'd2) &&
                               lv_item[row] < 4'd4)
                               log_cell_char = 16'h0031 + {12'd0,lv_item[row]};
                    default: log_cell_char = 16'h0020;
                endcase
            end
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            subtitle_q <= 1'b0;
            status_q <= 1'b0;
            auto_q <= 1'b0;
            demo_q <= 1'b0;
            alpha_q <= 2'd0;
            image_q <= 2'd0;
            brightness_q <= 3'd2;
            contrast_q <= 3'd2;
            volume_q <= 3'd4;
            edit_q <= 2'd0;
            transition_q <= 2'd0;
            scale_q <= 2'd0;
            source_large_q <= 1'b0;
            time_q <= 24'd0;
            effect_q <= 4'd0;
            audio_q <= 3'd0;
            health_q <= 4'd0;
            fps_q <= 8'd0;
            load_q <= 8'd0;
            hits_q <= 8'd0;
            underrun_q <= 8'd0;
            diag_q <= 1'b0;
            av_ms_q <= 10'd0;
        end else if (frame_start) begin
            subtitle_q <= subtitle_enable;
            status_q <= status_enable;
            alpha_q <= alpha;
            volume_q <= volume_level;
            image_q <= browse_mode ? browse_index : image_index;
            scale_q <= browse_mode ? browse_scale_mode : scale_mode;
            source_large_q <= source_large_1024;
            time_q <= timestamp;
            effect_q <= effect_level;
            audio_q <= audio_effect_level;
            health_q <= health;
            fps_q <= fps;
            load_q <= load_seconds;
            hits_q <= cache_hits;
            underrun_q <= underrun_count;
            av_ms_q <= av_err_01ms;
            diag_q <= diag_view;
            if (!browse_mode) begin
                auto_q <= auto_enabled;
                demo_q <= demo_mode;
                brightness_q <= brightness_level;
                contrast_q <= contrast_level;
                edit_q <= edit_mode;
                transition_q <= transition_kind;
            end
        end
    end

    // ---------------- 产品化：操作提示条（toast）的状态与计时 ----------------
    // Each constant is seven 5-bit rows, top row first. The synthesizer maps
    // this small read-only character table to ROM logic.
    function [4:0] glyph_row;
        input [7:0] ch;
        input [2:0] row;
        reg [34:0] glyph;
        begin
            case (ch)
                "0": glyph = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1": glyph = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2": glyph = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "3": glyph = {5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                "4": glyph = {5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                "5": glyph = {5'b11111,5'b10000,5'b11110,5'b00001,5'b00001,5'b10001,5'b01110};
                "6": glyph = {5'b00110,5'b01000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                "7": glyph = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                "8": glyph = {5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                "9": glyph = {5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00010,5'b11100};
                "A": glyph = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "B": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                "C": glyph = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                "D": glyph = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "E": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "F": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                "G": glyph = {5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110};
                "H": glyph = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "I": glyph = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
                "J": glyph = {5'b00111,5'b00010,5'b00010,5'b00010,5'b10010,5'b10010,5'b01100};
                "K": glyph = {5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
                "L": glyph = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "M": glyph = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "N": glyph = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
                "O": glyph = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "P": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "Q": glyph = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101};
                "R": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "S": glyph = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "T": glyph = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "U": glyph = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "V": glyph = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                "W": glyph = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                "X": glyph = {5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
                "Y": glyph = {5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
                "Z": glyph = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111};
                ".": glyph = {5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b01100,5'b01100};
                ",": glyph = {5'b00000,5'b00000,5'b00000,5'b00000,5'b01100,5'b01100,5'b00100};
                "-": glyph = {5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
                ":": glyph = {5'b00000,5'b01100,5'b01100,5'b00000,5'b01100,5'b01100,5'b00000};
                "/": glyph = {5'b00001,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b10000};
                "!": glyph = {5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00000,5'b00100};
                "?": glyph = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b00000,5'b00100};
                ">": glyph = {5'b10000,5'b01000,5'b00100,5'b00010,5'b00100,5'b01000,5'b10000};
                default: glyph = 35'd0;
            endcase
            glyph_row = glyph[34 - row*5 -: 5];
        end
    endfunction

    function [15:0] status_main_code;
        input [4:0] slot;
        input [1:0] idx, strength;
        input [2:0] brightness, contrast;
        input mode_auto;
        begin
            case (slot)
                0: status_main_code=16'h56fe; 1: status_main_code=16'h7247; // 图片
                2: status_main_code=16'h0031 + {14'd0,idx};
                4: status_main_code=16'h64ad; 5: status_main_code=16'h653e; // 播放
                6: status_main_code=demo_q ? 16'h6f14 : mode_auto ? 16'h81ea : 16'h624b; // 演/自/手
                7: status_main_code=demo_q ? 16'h793a : 16'h52a8; // 示/动
                9: status_main_code=16'h4eae; 10: status_main_code=16'h5ea6;
                11: status_main_code=16'h7b49; 12: status_main_code=16'h7ea7; // 亮度等级
                13: status_main_code=16'h0030 + {13'd0,brightness};
                15: status_main_code=16'h5bf9; 16: status_main_code=16'h6bd4;
                17: status_main_code=16'h5ea6; 18: status_main_code=16'h7b49;
                19: status_main_code=16'h7ea7; // 对比度等级
                20: status_main_code=16'h0030 + {13'd0,contrast};
                22: status_main_code=16'h5b57; 23: status_main_code=16'h5e55; // 字幕
                24: status_main_code=strength==0 ? "0" : strength==1 ? "5" :
                                     strength==2 ? "7" : "1";
                25: status_main_code=strength==0 ? "%" : strength==1 ? "0" :
                                     strength==2 ? "5" : "0";
                26: status_main_code=strength==0 ? " " : strength==3 ? "0" : "%";
                27: status_main_code=strength==3 ? "%" : " ";
                default: status_main_code=" ";
            endcase
        end
    endfunction

    function [15:0] status_detail_code;
        input [4:0] slot;
        input [1:0] scale, transition;
        input [2:0] selected;
        begin
            status_detail_code=" ";
            case (slot)
                0: status_detail_code=16'h5206; 1: status_detail_code=16'h8fa8;
                2: status_detail_code=16'h7387; // 分辨率
                3,4,5,6,7,8,9,10: status_detail_code=source_char(slot[3:0]+4'd1,scale);
                12: status_detail_code=16'h663e; 13: status_detail_code=16'h793a; // 显示
                14: case (scale)
                    0: status_detail_code=16'h539f; // 原
                    1: status_detail_code=16'h653e; // 放
                    2: status_detail_code=16'h7f29; // 缩
                    3: status_detail_code=16'h62c9; // 拉
                endcase
                15: case (scale)
                    0: status_detail_code=16'h6837; // 样
                    1: status_detail_code=16'h5927; // 大
                    2: status_detail_code=16'h5c0f; // 小
                    3: status_detail_code=16'h4f38; // 伸
                endcase
                17: status_detail_code=16'h64cd; 18: status_detail_code=16'h4f5c; // 操作
                19: case (selected)
                    1: status_detail_code=16'h4eae; // 亮
                    2: status_detail_code=16'h5bf9; // 对
                    3: status_detail_code=16'h7279; // 特
                    4: status_detail_code=16'h97f3; // 音
                    default: status_detail_code=16'h6b63; // 正
                endcase
                20: case (selected)
                    1: status_detail_code=16'h5ea6; // 度
                    2: status_detail_code=16'h6bd4; // 比
                    3: status_detail_code=16'h6548; // 效
                    4: status_detail_code=16'h6548; // 效
                    default: status_detail_code=16'h5e38; // 常
                endcase
                21: status_detail_code=(selected==3 || selected==4) ? 16'h7b49 : // 特效/音效：等
                                       selected==2 ? 16'h5ea6 :      // 对比度：度
                                       selected==1 ? 16'h7b49 : " "; // 亮度：等
                22: if (selected==3 || selected==1 || selected==4)
                        status_detail_code=16'h7ea7;             // 级
                    else if (selected==2) status_detail_code=16'h7b49;           // 等
                23: if (selected==3) status_detail_code=16'h0030 + {13'd0, effect_q};
                    else if (selected==4) status_detail_code=16'h0030 + {13'd0, audio_q};
                    else if (selected==2) status_detail_code=16'h7ea7;           // 级
                25: status_detail_code=16'h8f6c; 26: status_detail_code=16'h573a; // 转场
                27: status_detail_code=transition==0 ? 16'h6de1 :
                                       transition==1 ? 16'h5de6 :
                                       transition==2 ? 16'h53f3 : 16'h83f1; // 淡/左/右/菱
                28: status_detail_code=transition==0 ? 16'h5165 :
                                       transition==3 ? 16'h5f62 : 16'h63ed; // 入/形/揭
                29: if (transition!=0) status_detail_code=transition==3 ? 16'h6eb6 : 16'h793a; // 溶/示
                30: if (transition==3) status_detail_code=16'h89e3; // 解
                default: ;
            endcase
        end
    endfunction

    function [15:0] status_volume_code;
        input [4:0] slot;
        input [2:0] level;
        begin
            status_volume_code=" ";
            case (slot)
                0: status_volume_code=16'h97f3; // 音
                1: status_volume_code=16'h91cf; // 量
                3: status_volume_code=level==0 ? "0" : level==1 ? "3" :
                                      level==2 || level==3 ? "7" : "1";
                4: status_volume_code=level==0 ? "%" : level==1 || level==3 ? "5" : "0";
                5: status_volume_code=level==0 ? " " : level==4 ? "0" : "%";
                6: if (level==4) status_volume_code="%";
                default: ;
            endcase
        end
    endfunction

    // 0..99 的两位十进制字符（超过 99 按 99 显示；value*205>>11 得到十位）
    function [15:0] dec2_code;
        input [7:0] value;
        input       which;          // 0 = 十位，1 = 个位
        reg [7:0]   clamped;
        reg [15:0]  product;
        reg [4:0]   tens;
        begin
            clamped = (value > 8'd99) ? 8'd99 : value;
            product = clamped * 16'd205;
            tens = product[15:11];
            if (which == 1'b0)
                dec2_code = 16'h0030 + {12'd0, tens[3:0]};
            else
                dec2_code = 16'h0030 + {12'd0, (clamped - ({4'd0, tens[3:0]} * 4'd10))};
        end
    endfunction

    // 状态栏第 4 行：0 = 运行时间戳（动态文字），1 = 系统自检，两者交替显示
    //   自检行 = 「自检 V A S 帧 PP 读图 PP 秒 缓存 PP 欠载 PP」
    //   V/A/S 分别是视频/音频/存储的 1=正常 0=异常（取健康标志的反）；
    //   帧 = 每秒帧数，读图 = 最近一次图片加载秒数，缓存 = 常驻缓存命中次数，
    //   欠载 = 音频 FIFO 取空（underrun）次数，8 位饱和。
    function [15:0] status_line4_code;
        input [4:0] slot;
        input       sel;                   // 0 = 运行时间戳，1 = 系统自检
        reg [9:0] av_int;
        reg [3:0] av_tens;
        reg [3:0] av_units;
        reg [3:0] av_tenth;
        begin
            status_line4_code = " ";
            av_int   = ({10'd0,av_ms_q} * 20'd205) >> 11;  // 0.1ms -> 整数 ms（0..99）
            av_tens  = ({10'd0,av_int} * 20'd205) >> 11;   // 整数 ms 的十位
            av_units = av_int - ({6'd0,av_tens} * 4'd10);
            av_tenth = av_ms_q - ({6'd0,av_int} * 4'd10);
            if (!sel) begin
                case (slot)
                    0: status_line4_code=16'h8fd0; // 运
                    1: status_line4_code=16'h884c; // 行
                    3: status_line4_code=16'h0030 + {14'd0,time_q[23:20]};
                    4: status_line4_code=16'h0030 + {14'd0,time_q[19:16]};
                    5: status_line4_code=":";
                    6: status_line4_code=16'h0030 + {14'd0,time_q[15:12]};
                    7: status_line4_code=16'h0030 + {14'd0,time_q[11:8]};
                    8: status_line4_code=":";
                    9: status_line4_code=16'h0030 + {14'd0,time_q[7:4]};
                    10: status_line4_code=16'h0030 + {14'd0,time_q[3:0]};
                    // 槽位 11~31 空着：显示音画同步最大误差 xx.x MS（不是 ms）
                    12: status_line4_code="A";
                    13: status_line4_code="V";
                    15: status_line4_code=16'h0030 + {12'd0,av_tens};
                    16: status_line4_code=16'h0030 + {12'd0,av_units};
                    17: status_line4_code=".";
                    18: status_line4_code=16'h0030 + {12'd0,av_tenth};
                    20: status_line4_code="M";
                    21: status_line4_code="S";
                    default: ;
                endcase
            end else begin
                case (slot)
                    0: status_line4_code=16'h81ea; // 自
                    1: status_line4_code=16'h68c0; // 检
                    3: status_line4_code=health_q[0] ? "0" : "1";
                    4: status_line4_code=(health_q[1] | health_q[2]) ? "0" : "1";
                    5: status_line4_code=health_q[3] ? "0" : "1";
                    7: status_line4_code=16'h5e27; // 帧
                    8: status_line4_code=dec2_code(fps_q, 1'b0);
                    9: status_line4_code=dec2_code(fps_q, 1'b1);
                    11: status_line4_code=16'h8bfb; // 读
                    12: status_line4_code=16'h56fe; // 图
                    13: status_line4_code=dec2_code(load_q, 1'b0);
                    14: status_line4_code=dec2_code(load_q, 1'b1);
                    15: status_line4_code=16'h79d2; // 秒
                    17: status_line4_code=16'h7f13; // 缓
                    18: status_line4_code=16'h5b58; // 存
                    19: status_line4_code=dec2_code(hits_q, 1'b0);
                    20: status_line4_code=dec2_code(hits_q, 1'b1);
                    22: status_line4_code=16'h6b20; // 欠
                    23: status_line4_code=16'h8f7d; // 载
                    24: status_line4_code=dec2_code(underrun_q, 1'b0);
                    25: status_line4_code=dec2_code(underrun_q, 1'b1);
                    default: ;
                endcase
            end
        end
    endfunction

    // Generated by scripts/gen_osd_chinese_font.py from Noto Sans SC (SIL OFL).
    // BEGIN GENERATED STATUS FONT
    // 汉字码 -> 字形索引（0 = 空格/未知）
    // GLYPH_MAP_GENERATED: 4 x 256 banks + collision overrides.
    reg [7:0] glyph_map0 [0:255];
    reg [7:0] glyph_map1 [0:255];
    reg [7:0] glyph_map2 [0:255];
    reg [7:0] glyph_map3 [0:255];
    reg [15:0] glyph_code_q;
    reg [3:0]  glyph_row_sel_q;
    reg [7:0]  glyph_index_q, glyph_index_d;
    integer gm_i;
    initial begin
        for (gm_i = 0; gm_i < 256; gm_i = gm_i + 1) glyph_map0[gm_i] = 8'd0;
        glyph_map0[8'd0] = 8'd89;
        glyph_map0[8'd7] = 8'd96;
        glyph_map0[8'd12] = 8'd70;
        glyph_map0[8'd15] = 8'd25;
        glyph_map0[8'd26] = 8'd123;
        glyph_map0[8'd33] = 8'd216;
        glyph_map0[8'd37] = 8'd54;
        glyph_map0[8'd45] = 8'd183;
        glyph_map0[8'd46] = 8'd182;
        glyph_map0[8'd47] = 8'd184;
        glyph_map0[8'd48] = 8'd43;
        glyph_map0[8'd49] = 8'd44;
        glyph_map0[8'd50] = 8'd45;
        glyph_map0[8'd51] = 8'd46;
        glyph_map0[8'd52] = 8'd47;
        glyph_map0[8'd53] = 8'd48;
        glyph_map0[8'd54] = 8'd49;
        glyph_map0[8'd55] = 8'd22;
        glyph_map0[8'd56] = 8'd51;
        glyph_map0[8'd57] = 8'd52;
        glyph_map0[8'd58] = 8'd18;
        glyph_map0[8'd60] = 8'd106;
        glyph_map0[8'd64] = 8'd136;
        glyph_map0[8'd65] = 8'd157;
        glyph_map0[8'd66] = 8'd158;
        glyph_map0[8'd67] = 8'd159;
        glyph_map0[8'd68] = 8'd160;
        glyph_map0[8'd69] = 8'd161;
        glyph_map0[8'd70] = 8'd162;
        glyph_map0[8'd71] = 8'd163;
        glyph_map0[8'd72] = 8'd164;
        glyph_map0[8'd73] = 8'd165;
        glyph_map0[8'd74] = 8'd166;
        glyph_map0[8'd75] = 8'd167;
        glyph_map0[8'd76] = 8'd58;
        glyph_map0[8'd77] = 8'd169;
        glyph_map0[8'd78] = 8'd170;
        glyph_map0[8'd79] = 8'd171;
        glyph_map0[8'd80] = 8'd172;
        glyph_map0[8'd81] = 8'd173;
        glyph_map0[8'd82] = 8'd174;
        glyph_map0[8'd83] = 8'd175;
        glyph_map0[8'd84] = 8'd176;
        glyph_map0[8'd85] = 8'd177;
        glyph_map0[8'd86] = 8'd178;
        glyph_map0[8'd87] = 8'd179;
        glyph_map0[8'd88] = 8'd53;
        glyph_map0[8'd89] = 8'd180;
        glyph_map0[8'd90] = 8'd181;
        glyph_map0[8'd97] = 8'd219;
        glyph_map0[8'd98] = 8'd213;
        glyph_map0[8'd99] = 8'd128;
        glyph_map0[8'd101] = 8'd84;
        glyph_map0[8'd111] = 8'd137;
        glyph_map0[8'd125] = 8'd87;
        glyph_map0[8'd145] = 8'd71;
        glyph_map0[8'd168] = 8'd108;
        glyph_map0[8'd173] = 8'd3;
        glyph_map0[8'd192] = 8'd60;
        glyph_map0[8'd205] = 8'd28;
        glyph_map0[8'd251] = 8'd92;
        glyph_map0[8'd253] = 8'd146;
    end
    initial begin
        for (gm_i = 0; gm_i < 256; gm_i = gm_i + 1) glyph_map1[gm_i] = 8'd0;
        glyph_map1[8'd1] = 8'd114;
        glyph_map1[8'd7] = 8'd134;
        glyph_map1[8'd13] = 8'd208;
        glyph_map1[8'd25] = 8'd197;
        glyph_map1[8'd26] = 8'd72;
        glyph_map1[8'd37] = 8'd194;
        glyph_map1[8'd39] = 8'd23;
        glyph_map1[8'd40] = 8'd217;
        glyph_map1[8'd49] = 8'd193;
        glyph_map1[8'd58] = 8'd9;
        glyph_map1[8'd59] = 8'd144;
        glyph_map1[8'd62] = 8'd4;
        glyph_map1[8'd72] = 8'd62;
        glyph_map1[8'd101] = 8'd35;
        glyph_map1[8'd108] = 8'd202;
        glyph_map1[8'd112] = 8'd119;
        glyph_map1[8'd153] = 8'd125;
        glyph_map1[8'd176] = 8'd140;
        glyph_map1[8'd194] = 8'd148;
        glyph_map1[8'd198] = 8'd97;
        glyph_map1[8'd205] = 8'd152;
        glyph_map1[8'd207] = 8'd56;
        glyph_map1[8'd210] = 8'd65;
        glyph_map1[8'd224] = 8'd141;
        glyph_map1[8'd225] = 8'd34;
        glyph_map1[8'd227] = 8'd42;
        glyph_map1[8'd229] = 8'd214;
        glyph_map1[8'd230] = 8'd36;
        glyph_map1[8'd234] = 8'd5;
        glyph_map1[8'd239] = 8'd150;
        glyph_map1[8'd244] = 8'd190;
        glyph_map1[8'd246] = 8'd189;
        glyph_map1[8'd250] = 8'd90;
        glyph_map1[8'd251] = 8'd195;
    end
    initial begin
        for (gm_i = 0; gm_i < 256; gm_i = gm_i + 1) glyph_map2[gm_i] = 8'd0;
        glyph_map2[8'd3] = 8'd135;
        glyph_map2[8'd6] = 8'd185;
        glyph_map2[8'd7] = 8'd132;
        glyph_map2[8'd11] = 8'd95;
        glyph_map2[8'd39] = 8'd63;
        glyph_map2[8'd45] = 8'd88;
        glyph_map2[8'd56] = 8'd31;
        glyph_map2[8'd62] = 8'd20;
        glyph_map2[8'd71] = 8'd2;
        glyph_map2[8'd72] = 8'd77;
        glyph_map2[8'd75] = 8'd7;
        glyph_map2[8'd76] = 8'd98;
        glyph_map2[8'd85] = 8'd17;
        glyph_map2[8'd100] = 8'd196;
        glyph_map2[8'd107] = 8'd116;
        glyph_map2[8'd113] = 8'd155;
        glyph_map2[8'd121] = 8'd61;
        glyph_map2[8'd122] = 8'd142;
        glyph_map2[8'd123] = 8'd156;
        glyph_map2[8'd130] = 8'd147;
        glyph_map2[8'd139] = 8'd191;
        glyph_map2[8'd144] = 8'd83;
        glyph_map2[8'd146] = 8'd73;
        glyph_map2[8'd148] = 8'd211;
        glyph_map2[8'd164] = 8'd129;
        glyph_map2[8'd166] = 8'd11;
        glyph_map2[8'd167] = 8'd13;
        glyph_map2[8'd168] = 8'd6;
        glyph_map2[8'd174] = 8'd10;
        glyph_map2[8'd182] = 8'd41;
        glyph_map2[8'd183] = 8'd85;
        glyph_map2[8'd186] = 8'd105;
        glyph_map2[8'd200] = 8'd75;
        glyph_map2[8'd201] = 8'd26;
        glyph_map2[8'd205] = 8'd138;
        glyph_map2[8'd219] = 8'd133;
        glyph_map2[8'd222] = 8'd113;
        glyph_map2[8'd223] = 8'd93;
        glyph_map2[8'd232] = 8'd94;
        glyph_map2[8'd234] = 8'd121;
        glyph_map2[8'd237] = 8'd206;
        glyph_map2[8'd238] = 8'd126;
        glyph_map2[8'd239] = 8'd76;
        glyph_map2[8'd244] = 8'd218;
        glyph_map2[8'd246] = 8'd102;
        glyph_map2[8'd250] = 8'd101;
        glyph_map2[8'd254] = 8'd1;
    end
    initial begin
        for (gm_i = 0; gm_i < 256; gm_i = gm_i + 1) glyph_map3[gm_i] = 8'd0;
        glyph_map3[8'd0] = 8'd109;
        glyph_map3[8'd2] = 8'd111;
        glyph_map3[8'd11] = 8'd145;
        glyph_map3[8'd19] = 8'd66;
        glyph_map3[8'd20] = 8'd8;
        glyph_map3[8'd32] = 8'd68;
        glyph_map3[8'd34] = 8'd143;
        glyph_map3[8'd40] = 8'd79;
        glyph_map3[8'd41] = 8'd24;
        glyph_map3[8'd42] = 8'd199;
        glyph_map3[8'd44] = 8'd78;
        glyph_map3[8'd56] = 8'd27;
        glyph_map3[8'd58] = 8'd33;
        glyph_map3[8'd71] = 8'd207;
        glyph_map3[8'd73] = 8'd12;
        glyph_map3[8'd83] = 8'd74;
        glyph_map3[8'd85] = 8'd127;
        glyph_map3[8'd87] = 8'd16;
        glyph_map3[8'd88] = 8'd67;
        glyph_map3[8'd92] = 8'd29;
        glyph_map3[8'd97] = 8'd81;
        glyph_map3[8'd98] = 8'd40;
        glyph_map3[8'd99] = 8'd30;
        glyph_map3[8'd101] = 8'd82;
        glyph_map3[8'd108] = 8'd32;
        glyph_map3[8'd115] = 8'd104;
        glyph_map3[8'd125] = 8'd69;
        glyph_map3[8'd135] = 8'd86;
        glyph_map3[8'd136] = 8'd107;
        glyph_map3[8'd139] = 8'd99;
        glyph_map3[8'd144] = 8'd124;
        glyph_map3[8'd154] = 8'd115;
        glyph_map3[8'd156] = 8'd215;
        glyph_map3[8'd159] = 8'd21;
        glyph_map3[8'd168] = 8'd186;
        glyph_map3[8'd175] = 8'd112;
        glyph_map3[8'd176] = 8'd187;
        glyph_map3[8'd190] = 8'd149;
        glyph_map3[8'd194] = 8'd118;
        glyph_map3[8'd206] = 8'd151;
        glyph_map3[8'd207] = 8'd117;
        glyph_map3[8'd208] = 8'd57;
        glyph_map3[8'd209] = 8'd204;
        glyph_map3[8'd210] = 8'd103;
        glyph_map3[8'd212] = 8'd15;
        glyph_map3[8'd214] = 8'd80;
        glyph_map3[8'd225] = 8'd131;
        glyph_map3[8'd229] = 8'd122;
        glyph_map3[8'd237] = 8'd38;
        glyph_map3[8'd239] = 8'd198;
        glyph_map3[8'd241] = 8'd39;
        glyph_map3[8'd243] = 8'd37;
        glyph_map3[8'd247] = 8'd100;
        glyph_map3[8'd248] = 8'd19;
        glyph_map3[8'd249] = 8'd14;
        glyph_map3[8'd251] = 8'd64;
    end

    always @* begin
        glyph_index_d = glyph_index_q;
        case (glyph_code_q)
            16'h0025: glyph_index_d = 8'd54;
            16'h6025: glyph_index_d = 8'd212;
            16'h002f: glyph_index_d = 8'd184;
            16'h542f: glyph_index_d = 8'd192;
            16'h0031: glyph_index_d = 8'd44;
            16'h5c31: glyph_index_d = 8'd120;
            16'h6837: glyph_index_d = 8'd22;
            16'h0037: glyph_index_d = 8'd50;
            16'h5c3a: glyph_index_d = 8'd18;
            16'h003a: glyph_index_d = 8'd59;
            16'h004a: glyph_index_d = 8'd166;
            16'h544a: glyph_index_d = 8'd205;
            16'h884c: glyph_index_d = 8'd58;
            16'h004c: glyph_index_d = 8'd168;
            16'h0055: glyph_index_d = 8'd177;
            16'h5c55: glyph_index_d = 8'd209;
            16'h6de1: glyph_index_d = 8'd34;
            16'h5de1: glyph_index_d = 8'd210;
            16'h7248: glyph_index_d = 8'd77;
            16'h9648: glyph_index_d = 8'd220;
            16'h8282: glyph_index_d = 8'd147;
            16'h6682: glyph_index_d = 8'd201;
            16'h5a92: glyph_index_d = 8'd73;
            16'h4e92: glyph_index_d = 8'd130;
            16'h5f00: glyph_index_d = 8'd109;
            16'h9700: glyph_index_d = 8'd153;
            16'h6b20: glyph_index_d = 8'd68;
            16'h5f20: glyph_index_d = 8'd91;
            16'h573a: glyph_index_d = 8'd33;
            16'h673a: glyph_index_d = 8'd110;
            16'h533a: glyph_index_d = 8'd203;
            16'h5355: glyph_index_d = 8'd127;
            16'h5f55: glyph_index_d = 8'd188;
            16'h5f62: glyph_index_d = 8'd40;
            16'h6362: glyph_index_d = 8'd139;
            16'h9762: glyph_index_d = 8'd154;
            16'h67e5: glyph_index_d = 8'd122;
            16'h77e5: glyph_index_d = 8'd200;
            16'h53f3: glyph_index_d = 8'd37;
            16'h97f3: glyph_index_d = 8'd55;
            default: ;
        endcase
    end

    // Simulation-only reference for testbenches; RTL uses the registered path.
    function [7:0] status_glyph_index;
        input [15:0] code;
        begin
            case (code[9:8])
                2'd0: status_glyph_index = glyph_map0[code[7:0]];
                2'd1: status_glyph_index = glyph_map1[code[7:0]];
                2'd2: status_glyph_index = glyph_map2[code[7:0]];
                2'd3: status_glyph_index = glyph_map3[code[7:0]];
                default: status_glyph_index = 8'd0;
            endcase
            case (code)
                16'h0025: status_glyph_index = 8'd54;
                16'h6025: status_glyph_index = 8'd212;
                16'h002f: status_glyph_index = 8'd184;
                16'h542f: status_glyph_index = 8'd192;
                16'h0031: status_glyph_index = 8'd44;
                16'h5c31: status_glyph_index = 8'd120;
                16'h6837: status_glyph_index = 8'd22;
                16'h0037: status_glyph_index = 8'd50;
                16'h5c3a: status_glyph_index = 8'd18;
                16'h003a: status_glyph_index = 8'd59;
                16'h004a: status_glyph_index = 8'd166;
                16'h544a: status_glyph_index = 8'd205;
                16'h884c: status_glyph_index = 8'd58;
                16'h004c: status_glyph_index = 8'd168;
                16'h0055: status_glyph_index = 8'd177;
                16'h5c55: status_glyph_index = 8'd209;
                16'h6de1: status_glyph_index = 8'd34;
                16'h5de1: status_glyph_index = 8'd210;
                16'h7248: status_glyph_index = 8'd77;
                16'h9648: status_glyph_index = 8'd220;
                16'h8282: status_glyph_index = 8'd147;
                16'h6682: status_glyph_index = 8'd201;
                16'h5a92: status_glyph_index = 8'd73;
                16'h4e92: status_glyph_index = 8'd130;
                16'h5f00: status_glyph_index = 8'd109;
                16'h9700: status_glyph_index = 8'd153;
                16'h6b20: status_glyph_index = 8'd68;
                16'h5f20: status_glyph_index = 8'd91;
                16'h573a: status_glyph_index = 8'd33;
                16'h673a: status_glyph_index = 8'd110;
                16'h533a: status_glyph_index = 8'd203;
                16'h5355: status_glyph_index = 8'd127;
                16'h5f55: status_glyph_index = 8'd188;
                16'h5f62: status_glyph_index = 8'd40;
                16'h6362: status_glyph_index = 8'd139;
                16'h9762: status_glyph_index = 8'd154;
                16'h67e5: status_glyph_index = 8'd122;
                16'h77e5: status_glyph_index = 8'd200;
                16'h53f3: status_glyph_index = 8'd37;
                16'h97f3: status_glyph_index = 8'd55;
                default: ;
            endcase
        end
    endfunction

    // 16x16 点阵 ROM：地址 = {索引[7:0], 行[3:0]}，4096 x 16bit
    reg [15:0] status_font_rom [0:4095]; // synthesis ram_style = bram
    integer font_init_i;
    initial begin
        for (font_init_i = 0; font_init_i < 4096; font_init_i = font_init_i + 1)
            status_font_rom[font_init_i] = 16'd0;
        status_font_rom[12'd16] = 16'h0000; // 图 row0
        status_font_rom[12'd17] = 16'h0000; // 图 row1
        status_font_rom[12'd18] = 16'h7ffe; // 图 row2
        status_font_rom[12'd19] = 16'h6006; // 图 row3
        status_font_rom[12'd20] = 16'h6206; // 图 row4
        status_font_rom[12'd21] = 16'h67f6; // 图 row5
        status_font_rom[12'd22] = 16'h6e26; // 图 row6
        status_font_rom[12'd23] = 16'h63c6; // 图 row7
        status_font_rom[12'd24] = 16'h63c6; // 图 row8
        status_font_rom[12'd25] = 16'h7e3e; // 图 row9
        status_font_rom[12'd26] = 16'h6306; // 图 row10
        status_font_rom[12'd27] = 16'h60c6; // 图 row11
        status_font_rom[12'd28] = 16'h6706; // 图 row12
        status_font_rom[12'd29] = 16'h60e6; // 图 row13
        status_font_rom[12'd30] = 16'h6006; // 图 row14
        status_font_rom[12'd31] = 16'h7ffe; // 图 row15
        status_font_rom[12'd32] = 16'h0000; // 片 row0
        status_font_rom[12'd33] = 16'h0040; // 片 row1
        status_font_rom[12'd34] = 16'h1040; // 片 row2
        status_font_rom[12'd35] = 16'h1040; // 片 row3
        status_font_rom[12'd36] = 16'h1040; // 片 row4
        status_font_rom[12'd37] = 16'h1040; // 片 row5
        status_font_rom[12'd38] = 16'h1ffc; // 片 row6
        status_font_rom[12'd39] = 16'h1000; // 片 row7
        status_font_rom[12'd40] = 16'h1000; // 片 row8
        status_font_rom[12'd41] = 16'h1000; // 片 row9
        status_font_rom[12'd42] = 16'h1ff0; // 片 row10
        status_font_rom[12'd43] = 16'h1010; // 片 row11
        status_font_rom[12'd44] = 16'h3010; // 片 row12
        status_font_rom[12'd45] = 16'h2010; // 片 row13
        status_font_rom[12'd46] = 16'h2010; // 片 row14
        status_font_rom[12'd47] = 16'h6010; // 片 row15
        status_font_rom[12'd48] = 16'h0000; // 播 row0
        status_font_rom[12'd49] = 16'h100c; // 播 row1
        status_font_rom[12'd50] = 16'h13f0; // 播 row2
        status_font_rom[12'd51] = 16'h1024; // 播 row3
        status_font_rom[12'd52] = 16'h112c; // 播 row4
        status_font_rom[12'd53] = 16'h7da8; // 播 row5
        status_font_rom[12'd54] = 16'h13fe; // 播 row6
        status_font_rom[12'd55] = 16'h10f0; // 播 row7
        status_font_rom[12'd56] = 16'h112c; // 播 row8
        status_font_rom[12'd57] = 16'h3e26; // 播 row9
        status_font_rom[12'd58] = 16'h73fc; // 播 row10
        status_font_rom[12'd59] = 16'h1324; // 播 row11
        status_font_rom[12'd60] = 16'h1324; // 播 row12
        status_font_rom[12'd61] = 16'h13fc; // 播 row13
        status_font_rom[12'd62] = 16'h1324; // 播 row14
        status_font_rom[12'd63] = 16'h13fc; // 播 row15
        status_font_rom[12'd64] = 16'h0000; // 放 row0
        status_font_rom[12'd65] = 16'h0020; // 放 row1
        status_font_rom[12'd66] = 16'h0860; // 放 row2
        status_font_rom[12'd67] = 16'h0840; // 放 row3
        status_font_rom[12'd68] = 16'h7f7e; // 放 row4
        status_font_rom[12'd69] = 16'h1044; // 放 row5
        status_font_rom[12'd70] = 16'h10c4; // 放 row6
        status_font_rom[12'd71] = 16'h1ec4; // 放 row7
        status_font_rom[12'd72] = 16'h13a8; // 放 row8
        status_font_rom[12'd73] = 16'h1228; // 放 row9
        status_font_rom[12'd74] = 16'h1238; // 放 row10
        status_font_rom[12'd75] = 16'h3230; // 放 row11
        status_font_rom[12'd76] = 16'h2210; // 放 row12
        status_font_rom[12'd77] = 16'h2238; // 放 row13
        status_font_rom[12'd78] = 16'h226c; // 放 row14
        status_font_rom[12'd79] = 16'h46c6; // 放 row15
        status_font_rom[12'd80] = 16'h0000; // 自 row0
        status_font_rom[12'd81] = 16'h0100; // 自 row1
        status_font_rom[12'd82] = 16'h0100; // 自 row2
        status_font_rom[12'd83] = 16'h0100; // 自 row3
        status_font_rom[12'd84] = 16'h1ffc; // 自 row4
        status_font_rom[12'd85] = 16'h100c; // 自 row5
        status_font_rom[12'd86] = 16'h100c; // 自 row6
        status_font_rom[12'd87] = 16'h1ffc; // 自 row7
        status_font_rom[12'd88] = 16'h100c; // 自 row8
        status_font_rom[12'd89] = 16'h100c; // 自 row9
        status_font_rom[12'd90] = 16'h100c; // 自 row10
        status_font_rom[12'd91] = 16'h1ffc; // 自 row11
        status_font_rom[12'd92] = 16'h100c; // 自 row12
        status_font_rom[12'd93] = 16'h100c; // 自 row13
        status_font_rom[12'd94] = 16'h100c; // 自 row14
        status_font_rom[12'd95] = 16'h1ffc; // 自 row15
        status_font_rom[12'd96] = 16'h0000; // 动 row0
        status_font_rom[12'd97] = 16'h0000; // 动 row1
        status_font_rom[12'd98] = 16'h0030; // 动 row2
        status_font_rom[12'd99] = 16'h7f30; // 动 row3
        status_font_rom[12'd100] = 16'h0030; // 动 row4
        status_font_rom[12'd101] = 16'h00fe; // 动 row5
        status_font_rom[12'd102] = 16'h0032; // 动 row6
        status_font_rom[12'd103] = 16'h7f22; // 动 row7
        status_font_rom[12'd104] = 16'h1022; // 动 row8
        status_font_rom[12'd105] = 16'h1022; // 动 row9
        status_font_rom[12'd106] = 16'h3222; // 动 row10
        status_font_rom[12'd107] = 16'h2222; // 动 row11
        status_font_rom[12'd108] = 16'h2f62; // 动 row12
        status_font_rom[12'd109] = 16'h7946; // 动 row13
        status_font_rom[12'd110] = 16'h00c4; // 动 row14
        status_font_rom[12'd111] = 16'h009c; // 动 row15
        status_font_rom[12'd112] = 16'h0000; // 手 row0
        status_font_rom[12'd113] = 16'h0008; // 手 row1
        status_font_rom[12'd114] = 16'h01f8; // 手 row2
        status_font_rom[12'd115] = 16'h3f80; // 手 row3
        status_font_rom[12'd116] = 16'h0180; // 手 row4
        status_font_rom[12'd117] = 16'h0180; // 手 row5
        status_font_rom[12'd118] = 16'h3ffc; // 手 row6
        status_font_rom[12'd119] = 16'h0180; // 手 row7
        status_font_rom[12'd120] = 16'h0180; // 手 row8
        status_font_rom[12'd121] = 16'h0180; // 手 row9
        status_font_rom[12'd122] = 16'h7ffe; // 手 row10
        status_font_rom[12'd123] = 16'h0180; // 手 row11
        status_font_rom[12'd124] = 16'h0180; // 手 row12
        status_font_rom[12'd125] = 16'h0180; // 手 row13
        status_font_rom[12'd126] = 16'h0180; // 手 row14
        status_font_rom[12'd127] = 16'h0180; // 手 row15
        status_font_rom[12'd128] = 16'h0000; // 演 row0
        status_font_rom[12'd129] = 16'h0040; // 演 row1
        status_font_rom[12'd130] = 16'h3040; // 演 row2
        status_font_rom[12'd131] = 16'h07fe; // 演 row3
        status_font_rom[12'd132] = 16'h0402; // 演 row4
        status_font_rom[12'd133] = 16'h0402; // 演 row5
        status_font_rom[12'd134] = 16'h6040; // 演 row6
        status_font_rom[12'd135] = 16'h3040; // 演 row7
        status_font_rom[12'd136] = 16'h03fc; // 演 row8
        status_font_rom[12'd137] = 16'h0244; // 演 row9
        status_font_rom[12'd138] = 16'h03fc; // 演 row10
        status_font_rom[12'd139] = 16'h1244; // 演 row11
        status_font_rom[12'd140] = 16'h1244; // 演 row12
        status_font_rom[12'd141] = 16'h23fc; // 演 row13
        status_font_rom[12'd142] = 16'h2118; // 演 row14
        status_font_rom[12'd143] = 16'h660c; // 演 row15
        status_font_rom[12'd144] = 16'h0000; // 示 row0
        status_font_rom[12'd145] = 16'h0000; // 示 row1
        status_font_rom[12'd146] = 16'h0000; // 示 row2
        status_font_rom[12'd147] = 16'h3ffc; // 示 row3
        status_font_rom[12'd148] = 16'h0000; // 示 row4
        status_font_rom[12'd149] = 16'h0000; // 示 row5
        status_font_rom[12'd150] = 16'h0000; // 示 row6
        status_font_rom[12'd151] = 16'h7ffe; // 示 row7
        status_font_rom[12'd152] = 16'h0180; // 示 row8
        status_font_rom[12'd153] = 16'h0180; // 示 row9
        status_font_rom[12'd154] = 16'h1990; // 示 row10
        status_font_rom[12'd155] = 16'h1188; // 示 row11
        status_font_rom[12'd156] = 16'h318c; // 示 row12
        status_font_rom[12'd157] = 16'h2184; // 示 row13
        status_font_rom[12'd158] = 16'h4186; // 示 row14
        status_font_rom[12'd159] = 16'h0180; // 示 row15
        status_font_rom[12'd160] = 16'h0000; // 亮 row0
        status_font_rom[12'd161] = 16'h0100; // 亮 row1
        status_font_rom[12'd162] = 16'h0180; // 亮 row2
        status_font_rom[12'd163] = 16'h7ffe; // 亮 row3
        status_font_rom[12'd164] = 16'h0000; // 亮 row4
        status_font_rom[12'd165] = 16'h1ff8; // 亮 row5
        status_font_rom[12'd166] = 16'h1008; // 亮 row6
        status_font_rom[12'd167] = 16'h1ff8; // 亮 row7
        status_font_rom[12'd168] = 16'h0000; // 亮 row8
        status_font_rom[12'd169] = 16'h7ffe; // 亮 row9
        status_font_rom[12'd170] = 16'h4002; // 亮 row10
        status_font_rom[12'd171] = 16'h47e2; // 亮 row11
        status_font_rom[12'd172] = 16'h0420; // 亮 row12
        status_font_rom[12'd173] = 16'h0c20; // 亮 row13
        status_font_rom[12'd174] = 16'h1822; // 亮 row14
        status_font_rom[12'd175] = 16'h703c; // 亮 row15
        status_font_rom[12'd176] = 16'h0000; // 度 row0
        status_font_rom[12'd177] = 16'h0080; // 度 row1
        status_font_rom[12'd178] = 16'h0080; // 度 row2
        status_font_rom[12'd179] = 16'h3ffe; // 度 row3
        status_font_rom[12'd180] = 16'h2000; // 度 row4
        status_font_rom[12'd181] = 16'h2210; // 度 row5
        status_font_rom[12'd182] = 16'h3ffe; // 度 row6
        status_font_rom[12'd183] = 16'h2210; // 度 row7
        status_font_rom[12'd184] = 16'h2210; // 度 row8
        status_font_rom[12'd185] = 16'h23f0; // 度 row9
        status_font_rom[12'd186] = 16'h2000; // 度 row10
        status_font_rom[12'd187] = 16'h2ffc; // 度 row11
        status_font_rom[12'd188] = 16'h2208; // 度 row12
        status_font_rom[12'd189] = 16'h2130; // 度 row13
        status_font_rom[12'd190] = 16'h41e0; // 度 row14
        status_font_rom[12'd191] = 16'h4fbc; // 度 row15
        status_font_rom[12'd192] = 16'h0000; // 等 row0
        status_font_rom[12'd193] = 16'h1040; // 等 row1
        status_font_rom[12'd194] = 16'h3040; // 等 row2
        status_font_rom[12'd195] = 16'h3ffe; // 等 row3
        status_font_rom[12'd196] = 16'h6990; // 等 row4
        status_font_rom[12'd197] = 16'h0180; // 等 row5
        status_font_rom[12'd198] = 16'h3ffc; // 等 row6
        status_font_rom[12'd199] = 16'h0180; // 等 row7
        status_font_rom[12'd200] = 16'h0180; // 等 row8
        status_font_rom[12'd201] = 16'h7ffe; // 等 row9
        status_font_rom[12'd202] = 16'h0010; // 等 row10
        status_font_rom[12'd203] = 16'h0010; // 等 row11
        status_font_rom[12'd204] = 16'h7ffe; // 等 row12
        status_font_rom[12'd205] = 16'h0810; // 等 row13
        status_font_rom[12'd206] = 16'h0410; // 等 row14
        status_font_rom[12'd207] = 16'h0210; // 等 row15
        status_font_rom[12'd208] = 16'h0000; // 级 row0
        status_font_rom[12'd209] = 16'h0000; // 级 row1
        status_font_rom[12'd210] = 16'h13f8; // 级 row2
        status_font_rom[12'd211] = 16'h1088; // 级 row3
        status_font_rom[12'd212] = 16'h2088; // 级 row4
        status_font_rom[12'd213] = 16'h2498; // 级 row5
        status_font_rom[12'd214] = 16'h4c90; // 级 row6
        status_font_rom[12'd215] = 16'h789e; // 级 row7
        status_font_rom[12'd216] = 16'h10c4; // 级 row8
        status_font_rom[12'd217] = 16'h30c4; // 级 row9
        status_font_rom[12'd218] = 16'h3ce4; // 级 row10
        status_font_rom[12'd219] = 16'h6128; // 级 row11
        status_font_rom[12'd220] = 16'h0138; // 级 row12
        status_font_rom[12'd221] = 16'h1f18; // 级 row13
        status_font_rom[12'd222] = 16'h722c; // 级 row14
        status_font_rom[12'd223] = 16'h42c6; // 级 row15
        status_font_rom[12'd224] = 16'h0000; // 对 row0
        status_font_rom[12'd225] = 16'h0008; // 对 row1
        status_font_rom[12'd226] = 16'h0008; // 对 row2
        status_font_rom[12'd227] = 16'h0008; // 对 row3
        status_font_rom[12'd228] = 16'h7e08; // 对 row4
        status_font_rom[12'd229] = 16'h0208; // 对 row5
        status_font_rom[12'd230] = 16'h02fe; // 对 row6
        status_font_rom[12'd231] = 16'h0208; // 对 row7
        status_font_rom[12'd232] = 16'h2608; // 对 row8
        status_font_rom[12'd233] = 16'h1488; // 对 row9
        status_font_rom[12'd234] = 16'h0c48; // 对 row10
        status_font_rom[12'd235] = 16'h0c48; // 对 row11
        status_font_rom[12'd236] = 16'h0e08; // 对 row12
        status_font_rom[12'd237] = 16'h1b08; // 对 row13
        status_font_rom[12'd238] = 16'h3008; // 对 row14
        status_font_rom[12'd239] = 16'h6008; // 对 row15
        status_font_rom[12'd240] = 16'h0000; // 比 row0
        status_font_rom[12'd241] = 16'h0000; // 比 row1
        status_font_rom[12'd242] = 16'h2040; // 比 row2
        status_font_rom[12'd243] = 16'h2040; // 比 row3
        status_font_rom[12'd244] = 16'h2040; // 比 row4
        status_font_rom[12'd245] = 16'h2044; // 比 row5
        status_font_rom[12'd246] = 16'h204c; // 比 row6
        status_font_rom[12'd247] = 16'h3e78; // 比 row7
        status_font_rom[12'd248] = 16'h2060; // 比 row8
        status_font_rom[12'd249] = 16'h2040; // 比 row9
        status_font_rom[12'd250] = 16'h2040; // 比 row10
        status_font_rom[12'd251] = 16'h2040; // 比 row11
        status_font_rom[12'd252] = 16'h2042; // 比 row12
        status_font_rom[12'd253] = 16'h2042; // 比 row13
        status_font_rom[12'd254] = 16'h3e46; // 比 row14
        status_font_rom[12'd255] = 16'h307c; // 比 row15
        status_font_rom[12'd256] = 16'h0000; // 字 row0
        status_font_rom[12'd257] = 16'h0100; // 字 row1
        status_font_rom[12'd258] = 16'h0180; // 字 row2
        status_font_rom[12'd259] = 16'h7ffe; // 字 row3
        status_font_rom[12'd260] = 16'h6006; // 字 row4
        status_font_rom[12'd261] = 16'h4006; // 字 row5
        status_font_rom[12'd262] = 16'h0ff0; // 字 row6
        status_font_rom[12'd263] = 16'h0020; // 字 row7
        status_font_rom[12'd264] = 16'h00c0; // 字 row8
        status_font_rom[12'd265] = 16'h0180; // 字 row9
        status_font_rom[12'd266] = 16'h7ffe; // 字 row10
        status_font_rom[12'd267] = 16'h0180; // 字 row11
        status_font_rom[12'd268] = 16'h0180; // 字 row12
        status_font_rom[12'd269] = 16'h0180; // 字 row13
        status_font_rom[12'd270] = 16'h0180; // 字 row14
        status_font_rom[12'd271] = 16'h0180; // 字 row15
        status_font_rom[12'd272] = 16'h0000; // 幕 row0
        status_font_rom[12'd273] = 16'h0420; // 幕 row1
        status_font_rom[12'd274] = 16'h7ffe; // 幕 row2
        status_font_rom[12'd275] = 16'h0420; // 幕 row3
        status_font_rom[12'd276] = 16'h1ff8; // 幕 row4
        status_font_rom[12'd277] = 16'h1008; // 幕 row5
        status_font_rom[12'd278] = 16'h1ff8; // 幕 row6
        status_font_rom[12'd279] = 16'h1008; // 幕 row7
        status_font_rom[12'd280] = 16'h1ff8; // 幕 row8
        status_font_rom[12'd281] = 16'h0600; // 幕 row9
        status_font_rom[12'd282] = 16'h7ffe; // 幕 row10
        status_font_rom[12'd283] = 16'h1918; // 幕 row11
        status_font_rom[12'd284] = 16'h3ffe; // 幕 row12
        status_font_rom[12'd285] = 16'h590a; // 幕 row13
        status_font_rom[12'd286] = 16'h1908; // 幕 row14
        status_font_rom[12'd287] = 16'h1938; // 幕 row15
        status_font_rom[12'd288] = 16'h0000; // 尺 row0
        status_font_rom[12'd289] = 16'h0000; // 尺 row1
        status_font_rom[12'd290] = 16'h1ffc; // 尺 row2
        status_font_rom[12'd291] = 16'h100c; // 尺 row3
        status_font_rom[12'd292] = 16'h1004; // 尺 row4
        status_font_rom[12'd293] = 16'h1004; // 尺 row5
        status_font_rom[12'd294] = 16'h1004; // 尺 row6
        status_font_rom[12'd295] = 16'h100c; // 尺 row7
        status_font_rom[12'd296] = 16'h1ffc; // 尺 row8
        status_font_rom[12'd297] = 16'h10c0; // 尺 row9
        status_font_rom[12'd298] = 16'h1040; // 尺 row10
        status_font_rom[12'd299] = 16'h1040; // 尺 row11
        status_font_rom[12'd300] = 16'h3020; // 尺 row12
        status_font_rom[12'd301] = 16'h2030; // 尺 row13
        status_font_rom[12'd302] = 16'h6018; // 尺 row14
        status_font_rom[12'd303] = 16'h400e; // 尺 row15
        status_font_rom[12'd304] = 16'h0000; // 寸 row0
        status_font_rom[12'd305] = 16'h0020; // 寸 row1
        status_font_rom[12'd306] = 16'h0020; // 寸 row2
        status_font_rom[12'd307] = 16'h0020; // 寸 row3
        status_font_rom[12'd308] = 16'h0020; // 寸 row4
        status_font_rom[12'd309] = 16'h7ffe; // 寸 row5
        status_font_rom[12'd310] = 16'h0020; // 寸 row6
        status_font_rom[12'd311] = 16'h0020; // 寸 row7
        status_font_rom[12'd312] = 16'h1020; // 寸 row8
        status_font_rom[12'd313] = 16'h0820; // 寸 row9
        status_font_rom[12'd314] = 16'h0c20; // 寸 row10
        status_font_rom[12'd315] = 16'h0420; // 寸 row11
        status_font_rom[12'd316] = 16'h0420; // 寸 row12
        status_font_rom[12'd317] = 16'h0020; // 寸 row13
        status_font_rom[12'd318] = 16'h0020; // 寸 row14
        status_font_rom[12'd319] = 16'h0020; // 寸 row15
        status_font_rom[12'd320] = 16'h0000; // 显 row0
        status_font_rom[12'd321] = 16'h0000; // 显 row1
        status_font_rom[12'd322] = 16'h1ff8; // 显 row2
        status_font_rom[12'd323] = 16'h1008; // 显 row3
        status_font_rom[12'd324] = 16'h1008; // 显 row4
        status_font_rom[12'd325] = 16'h1ff8; // 显 row5
        status_font_rom[12'd326] = 16'h1008; // 显 row6
        status_font_rom[12'd327] = 16'h1008; // 显 row7
        status_font_rom[12'd328] = 16'h1ff8; // 显 row8
        status_font_rom[12'd329] = 16'h0000; // 显 row9
        status_font_rom[12'd330] = 16'h0244; // 显 row10
        status_font_rom[12'd331] = 16'h324c; // 显 row11
        status_font_rom[12'd332] = 16'h1248; // 显 row12
        status_font_rom[12'd333] = 16'h0250; // 显 row13
        status_font_rom[12'd334] = 16'h0240; // 显 row14
        status_font_rom[12'd335] = 16'h7ffe; // 显 row15
        status_font_rom[12'd336] = 16'h0000; // 原 row0
        status_font_rom[12'd337] = 16'h0000; // 原 row1
        status_font_rom[12'd338] = 16'h3ffe; // 原 row2
        status_font_rom[12'd339] = 16'h2080; // 原 row3
        status_font_rom[12'd340] = 16'h2080; // 原 row4
        status_font_rom[12'd341] = 16'h27fc; // 原 row5
        status_font_rom[12'd342] = 16'h2404; // 原 row6
        status_font_rom[12'd343] = 16'h2404; // 原 row7
        status_font_rom[12'd344] = 16'h27fc; // 原 row8
        status_font_rom[12'd345] = 16'h2404; // 原 row9
        status_font_rom[12'd346] = 16'h27fc; // 原 row10
        status_font_rom[12'd347] = 16'h2040; // 原 row11
        status_font_rom[12'd348] = 16'h2250; // 原 row12
        status_font_rom[12'd349] = 16'h6448; // 原 row13
        status_font_rom[12'd350] = 16'h4c44; // 原 row14
        status_font_rom[12'd351] = 16'h5846; // 原 row15
        status_font_rom[12'd352] = 16'h0000; // 样 row0
        status_font_rom[12'd353] = 16'h1004; // 样 row1
        status_font_rom[12'd354] = 16'h1184; // 样 row2
        status_font_rom[12'd355] = 16'h108c; // 样 row3
        status_font_rom[12'd356] = 16'h1088; // 样 row4
        status_font_rom[12'd357] = 16'h7ffe; // 样 row5
        status_font_rom[12'd358] = 16'h1020; // 样 row6
        status_font_rom[12'd359] = 16'h1820; // 样 row7
        status_font_rom[12'd360] = 16'h39fc; // 样 row8
        status_font_rom[12'd361] = 16'h3420; // 样 row9
        status_font_rom[12'd362] = 16'h3020; // 样 row10
        status_font_rom[12'd363] = 16'h5020; // 样 row11
        status_font_rom[12'd364] = 16'h53fe; // 样 row12
        status_font_rom[12'd365] = 16'h1020; // 样 row13
        status_font_rom[12'd366] = 16'h1020; // 样 row14
        status_font_rom[12'd367] = 16'h1020; // 样 row15
        status_font_rom[12'd368] = 16'h0000; // 大 row0
        status_font_rom[12'd369] = 16'h0000; // 大 row1
        status_font_rom[12'd370] = 16'h0180; // 大 row2
        status_font_rom[12'd371] = 16'h0180; // 大 row3
        status_font_rom[12'd372] = 16'h0180; // 大 row4
        status_font_rom[12'd373] = 16'h0100; // 大 row5
        status_font_rom[12'd374] = 16'h7ffe; // 大 row6
        status_font_rom[12'd375] = 16'h0180; // 大 row7
        status_font_rom[12'd376] = 16'h0180; // 大 row8
        status_font_rom[12'd377] = 16'h0340; // 大 row9
        status_font_rom[12'd378] = 16'h0240; // 大 row10
        status_font_rom[12'd379] = 16'h0660; // 大 row11
        status_font_rom[12'd380] = 16'h0430; // 大 row12
        status_font_rom[12'd381] = 16'h0c18; // 大 row13
        status_font_rom[12'd382] = 16'h180c; // 大 row14
        status_font_rom[12'd383] = 16'h6006; // 大 row15
        status_font_rom[12'd384] = 16'h0000; // 缩 row0
        status_font_rom[12'd385] = 16'h0000; // 缩 row1
        status_font_rom[12'd386] = 16'h1020; // 缩 row2
        status_font_rom[12'd387] = 16'h13fe; // 缩 row3
        status_font_rom[12'd388] = 16'h3202; // 缩 row4
        status_font_rom[12'd389] = 16'h2200; // 缩 row5
        status_font_rom[12'd390] = 16'h697e; // 缩 row6
        status_font_rom[12'd391] = 16'h7910; // 缩 row7
        status_font_rom[12'd392] = 16'h1310; // 缩 row8
        status_font_rom[12'd393] = 16'h137e; // 缩 row9
        status_font_rom[12'd394] = 16'h2742; // 缩 row10
        status_font_rom[12'd395] = 16'h7942; // 缩 row11
        status_font_rom[12'd396] = 16'h017e; // 缩 row12
        status_font_rom[12'd397] = 16'h0d42; // 缩 row13
        status_font_rom[12'd398] = 16'h7142; // 缩 row14
        status_font_rom[12'd399] = 16'h417e; // 缩 row15
        status_font_rom[12'd400] = 16'h0000; // 小 row0
        status_font_rom[12'd401] = 16'h0000; // 小 row1
        status_font_rom[12'd402] = 16'h0180; // 小 row2
        status_font_rom[12'd403] = 16'h0180; // 小 row3
        status_font_rom[12'd404] = 16'h0180; // 小 row4
        status_font_rom[12'd405] = 16'h0180; // 小 row5
        status_font_rom[12'd406] = 16'h1188; // 小 row6
        status_font_rom[12'd407] = 16'h1188; // 小 row7
        status_font_rom[12'd408] = 16'h118c; // 小 row8
        status_font_rom[12'd409] = 16'h3184; // 小 row9
        status_font_rom[12'd410] = 16'h2186; // 小 row10
        status_font_rom[12'd411] = 16'h6182; // 小 row11
        status_font_rom[12'd412] = 16'h4182; // 小 row12
        status_font_rom[12'd413] = 16'h0180; // 小 row13
        status_font_rom[12'd414] = 16'h0180; // 小 row14
        status_font_rom[12'd415] = 16'h0180; // 小 row15
        status_font_rom[12'd416] = 16'h0000; // 拉 row0
        status_font_rom[12'd417] = 16'h1020; // 拉 row1
        status_font_rom[12'd418] = 16'h1020; // 拉 row2
        status_font_rom[12'd419] = 16'h1020; // 拉 row3
        status_font_rom[12'd420] = 16'h13fe; // 拉 row4
        status_font_rom[12'd421] = 16'h7c00; // 拉 row5
        status_font_rom[12'd422] = 16'h1004; // 拉 row6
        status_font_rom[12'd423] = 16'h108c; // 拉 row7
        status_font_rom[12'd424] = 16'h1088; // 拉 row8
        status_font_rom[12'd425] = 16'h1c88; // 拉 row9
        status_font_rom[12'd426] = 16'h7888; // 拉 row10
        status_font_rom[12'd427] = 16'h5088; // 拉 row11
        status_font_rom[12'd428] = 16'h10c8; // 拉 row12
        status_font_rom[12'd429] = 16'h1050; // 拉 row13
        status_font_rom[12'd430] = 16'h1010; // 拉 row14
        status_font_rom[12'd431] = 16'h13fe; // 拉 row15
        status_font_rom[12'd432] = 16'h0000; // 伸 row0
        status_font_rom[12'd433] = 16'h0800; // 伸 row1
        status_font_rom[12'd434] = 16'h0860; // 伸 row2
        status_font_rom[12'd435] = 16'h1860; // 伸 row3
        status_font_rom[12'd436] = 16'h17fe; // 伸 row4
        status_font_rom[12'd437] = 16'h3462; // 伸 row5
        status_font_rom[12'd438] = 16'h7462; // 伸 row6
        status_font_rom[12'd439] = 16'h77fe; // 伸 row7
        status_font_rom[12'd440] = 16'h1462; // 伸 row8
        status_font_rom[12'd441] = 16'h1462; // 伸 row9
        status_font_rom[12'd442] = 16'h1462; // 伸 row10
        status_font_rom[12'd443] = 16'h17fe; // 伸 row11
        status_font_rom[12'd444] = 16'h1462; // 伸 row12
        status_font_rom[12'd445] = 16'h1060; // 伸 row13
        status_font_rom[12'd446] = 16'h1060; // 伸 row14
        status_font_rom[12'd447] = 16'h1060; // 伸 row15
        status_font_rom[12'd448] = 16'h0000; // 操 row0
        status_font_rom[12'd449] = 16'h0000; // 操 row1
        status_font_rom[12'd450] = 16'h11f8; // 操 row2
        status_font_rom[12'd451] = 16'h1108; // 操 row3
        status_font_rom[12'd452] = 16'h11f8; // 操 row4
        status_font_rom[12'd453] = 16'h7800; // 操 row5
        status_font_rom[12'd454] = 16'h13de; // 操 row6
        status_font_rom[12'd455] = 16'h1252; // 操 row7
        status_font_rom[12'd456] = 16'h1252; // 操 row8
        status_font_rom[12'd457] = 16'h3bde; // 操 row9
        status_font_rom[12'd458] = 16'h7020; // 操 row10
        status_font_rom[12'd459] = 16'h17fe; // 操 row11
        status_font_rom[12'd460] = 16'h10f0; // 操 row12
        status_font_rom[12'd461] = 16'h11a8; // 操 row13
        status_font_rom[12'd462] = 16'h132c; // 操 row14
        status_font_rom[12'd463] = 16'h1622; // 操 row15
        status_font_rom[12'd464] = 16'h0000; // 作 row0
        status_font_rom[12'd465] = 16'h0000; // 作 row1
        status_font_rom[12'd466] = 16'h0880; // 作 row2
        status_font_rom[12'd467] = 16'h0880; // 作 row3
        status_font_rom[12'd468] = 16'h11fe; // 作 row4
        status_font_rom[12'd469] = 16'h1140; // 作 row5
        status_font_rom[12'd470] = 16'h3240; // 作 row6
        status_font_rom[12'd471] = 16'h7640; // 作 row7
        status_font_rom[12'd472] = 16'h547e; // 作 row8
        status_font_rom[12'd473] = 16'h1040; // 作 row9
        status_font_rom[12'd474] = 16'h1040; // 作 row10
        status_font_rom[12'd475] = 16'h1040; // 作 row11
        status_font_rom[12'd476] = 16'h107e; // 作 row12
        status_font_rom[12'd477] = 16'h1040; // 作 row13
        status_font_rom[12'd478] = 16'h1040; // 作 row14
        status_font_rom[12'd479] = 16'h1040; // 作 row15
        status_font_rom[12'd480] = 16'h0000; // 正 row0
        status_font_rom[12'd481] = 16'h0000; // 正 row1
        status_font_rom[12'd482] = 16'h0000; // 正 row2
        status_font_rom[12'd483] = 16'h3ffe; // 正 row3
        status_font_rom[12'd484] = 16'h0080; // 正 row4
        status_font_rom[12'd485] = 16'h0080; // 正 row5
        status_font_rom[12'd486] = 16'h0080; // 正 row6
        status_font_rom[12'd487] = 16'h1080; // 正 row7
        status_font_rom[12'd488] = 16'h10fc; // 正 row8
        status_font_rom[12'd489] = 16'h1080; // 正 row9
        status_font_rom[12'd490] = 16'h1080; // 正 row10
        status_font_rom[12'd491] = 16'h1080; // 正 row11
        status_font_rom[12'd492] = 16'h1080; // 正 row12
        status_font_rom[12'd493] = 16'h1080; // 正 row13
        status_font_rom[12'd494] = 16'h1080; // 正 row14
        status_font_rom[12'd495] = 16'h7ffe; // 正 row15
        status_font_rom[12'd496] = 16'h0000; // 常 row0
        status_font_rom[12'd497] = 16'h0000; // 常 row1
        status_font_rom[12'd498] = 16'h1898; // 常 row2
        status_font_rom[12'd499] = 16'h0990; // 常 row3
        status_font_rom[12'd500] = 16'h7ffe; // 常 row4
        status_font_rom[12'd501] = 16'h6002; // 常 row5
        status_font_rom[12'd502] = 16'h6ff2; // 常 row6
        status_font_rom[12'd503] = 16'h0810; // 常 row7
        status_font_rom[12'd504] = 16'h0810; // 常 row8
        status_font_rom[12'd505] = 16'h0ff0; // 常 row9
        status_font_rom[12'd506] = 16'h0080; // 常 row10
        status_font_rom[12'd507] = 16'h3ffc; // 常 row11
        status_font_rom[12'd508] = 16'h308c; // 常 row12
        status_font_rom[12'd509] = 16'h3084; // 常 row13
        status_font_rom[12'd510] = 16'h308c; // 常 row14
        status_font_rom[12'd511] = 16'h30b8; // 常 row15
        status_font_rom[12'd512] = 16'h0000; // 转 row0
        status_font_rom[12'd513] = 16'h1010; // 转 row1
        status_font_rom[12'd514] = 16'h1030; // 转 row2
        status_font_rom[12'd515] = 16'h7ffe; // 转 row3
        status_font_rom[12'd516] = 16'h1020; // 转 row4
        status_font_rom[12'd517] = 16'h2820; // 转 row5
        status_font_rom[12'd518] = 16'h29fe; // 转 row6
        status_font_rom[12'd519] = 16'h2840; // 转 row7
        status_font_rom[12'd520] = 16'h6840; // 转 row8
        status_font_rom[12'd521] = 16'h7e40; // 转 row9
        status_font_rom[12'd522] = 16'h08fc; // 转 row10
        status_font_rom[12'd523] = 16'h080c; // 转 row11
        status_font_rom[12'd524] = 16'h1e08; // 转 row12
        status_font_rom[12'd525] = 16'h7870; // 转 row13
        status_font_rom[12'd526] = 16'h0830; // 转 row14
        status_font_rom[12'd527] = 16'h0818; // 转 row15
        status_font_rom[12'd528] = 16'h0000; // 场 row0
        status_font_rom[12'd529] = 16'h1000; // 场 row1
        status_font_rom[12'd530] = 16'h13f8; // 场 row2
        status_font_rom[12'd531] = 16'h1018; // 场 row3
        status_font_rom[12'd532] = 16'h1020; // 场 row4
        status_font_rom[12'd533] = 16'h7cc0; // 场 row5
        status_font_rom[12'd534] = 16'h1180; // 场 row6
        status_font_rom[12'd535] = 16'h13fe; // 场 row7
        status_font_rom[12'd536] = 16'h105a; // 场 row8
        status_font_rom[12'd537] = 16'h10d2; // 场 row9
        status_font_rom[12'd538] = 16'h1092; // 场 row10
        status_font_rom[12'd539] = 16'h1126; // 场 row11
        status_font_rom[12'd540] = 16'h1e26; // 场 row12
        status_font_rom[12'd541] = 16'h7044; // 场 row13
        status_font_rom[12'd542] = 16'h40c4; // 场 row14
        status_font_rom[12'd543] = 16'h0184; // 场 row15
        status_font_rom[12'd544] = 16'h0000; // 淡 row0
        status_font_rom[12'd545] = 16'h0000; // 淡 row1
        status_font_rom[12'd546] = 16'h2060; // 淡 row2
        status_font_rom[12'd547] = 16'h3164; // 淡 row3
        status_font_rom[12'd548] = 16'h0a4c; // 淡 row4
        status_font_rom[12'd549] = 16'h0248; // 淡 row5
        status_font_rom[12'd550] = 16'h0070; // 淡 row6
        status_font_rom[12'd551] = 16'h609c; // 淡 row7
        status_font_rom[12'd552] = 16'h1306; // 淡 row8
        status_font_rom[12'd553] = 16'h0060; // 淡 row9
        status_font_rom[12'd554] = 16'h0244; // 淡 row10
        status_font_rom[12'd555] = 16'h1264; // 淡 row11
        status_font_rom[12'd556] = 16'h1668; // 淡 row12
        status_font_rom[12'd557] = 16'h30f0; // 淡 row13
        status_font_rom[12'd558] = 16'h2198; // 淡 row14
        status_font_rom[12'd559] = 16'h670e; // 淡 row15
        status_font_rom[12'd560] = 16'h0000; // 入 row0
        status_font_rom[12'd561] = 16'h0000; // 入 row1
        status_font_rom[12'd562] = 16'h0400; // 入 row2
        status_font_rom[12'd563] = 16'h0600; // 入 row3
        status_font_rom[12'd564] = 16'h0300; // 入 row4
        status_font_rom[12'd565] = 16'h0180; // 入 row5
        status_font_rom[12'd566] = 16'h0180; // 入 row6
        status_font_rom[12'd567] = 16'h01c0; // 入 row7
        status_font_rom[12'd568] = 16'h0340; // 入 row8
        status_font_rom[12'd569] = 16'h0260; // 入 row9
        status_font_rom[12'd570] = 16'h0620; // 入 row10
        status_font_rom[12'd571] = 16'h0430; // 入 row11
        status_font_rom[12'd572] = 16'h0c18; // 入 row12
        status_font_rom[12'd573] = 16'h180c; // 入 row13
        status_font_rom[12'd574] = 16'h3006; // 入 row14
        status_font_rom[12'd575] = 16'h6002; // 入 row15
        status_font_rom[12'd576] = 16'h0000; // 左 row0
        status_font_rom[12'd577] = 16'h0200; // 左 row1
        status_font_rom[12'd578] = 16'h0200; // 左 row2
        status_font_rom[12'd579] = 16'h0200; // 左 row3
        status_font_rom[12'd580] = 16'h7ffe; // 左 row4
        status_font_rom[12'd581] = 16'h0400; // 左 row5
        status_font_rom[12'd582] = 16'h0400; // 左 row6
        status_font_rom[12'd583] = 16'h0400; // 左 row7
        status_font_rom[12'd584] = 16'h0c00; // 左 row8
        status_font_rom[12'd585] = 16'h0ffc; // 左 row9
        status_font_rom[12'd586] = 16'h1840; // 左 row10
        status_font_rom[12'd587] = 16'h1040; // 左 row11
        status_font_rom[12'd588] = 16'h3040; // 左 row12
        status_font_rom[12'd589] = 16'h2040; // 左 row13
        status_font_rom[12'd590] = 16'h4040; // 左 row14
        status_font_rom[12'd591] = 16'h0ffe; // 左 row15
        status_font_rom[12'd592] = 16'h0000; // 右 row0
        status_font_rom[12'd593] = 16'h0000; // 右 row1
        status_font_rom[12'd594] = 16'h0300; // 右 row2
        status_font_rom[12'd595] = 16'h0200; // 右 row3
        status_font_rom[12'd596] = 16'h0200; // 右 row4
        status_font_rom[12'd597] = 16'h7ffe; // 右 row5
        status_font_rom[12'd598] = 16'h0400; // 右 row6
        status_font_rom[12'd599] = 16'h0400; // 右 row7
        status_font_rom[12'd600] = 16'h0800; // 右 row8
        status_font_rom[12'd601] = 16'h1ffc; // 右 row9
        status_font_rom[12'd602] = 16'h1c0c; // 右 row10
        status_font_rom[12'd603] = 16'h2804; // 右 row11
        status_font_rom[12'd604] = 16'h4804; // 右 row12
        status_font_rom[12'd605] = 16'h0804; // 右 row13
        status_font_rom[12'd606] = 16'h0c04; // 右 row14
        status_font_rom[12'd607] = 16'h0ffc; // 右 row15
        status_font_rom[12'd608] = 16'h0000; // 揭 row0
        status_font_rom[12'd609] = 16'h1000; // 揭 row1
        status_font_rom[12'd610] = 16'h11fc; // 揭 row2
        status_font_rom[12'd611] = 16'h1104; // 揭 row3
        status_font_rom[12'd612] = 16'h11fc; // 揭 row4
        status_font_rom[12'd613] = 16'h7d04; // 揭 row5
        status_font_rom[12'd614] = 16'h1104; // 揭 row6
        status_font_rom[12'd615] = 16'h11fc; // 揭 row7
        status_font_rom[12'd616] = 16'h1100; // 揭 row8
        status_font_rom[12'd617] = 16'h1dfe; // 揭 row9
        status_font_rom[12'd618] = 16'h7222; // 揭 row10
        status_font_rom[12'd619] = 16'h1222; // 揭 row11
        status_font_rom[12'd620] = 16'h1152; // 揭 row12
        status_font_rom[12'd621] = 16'h1102; // 揭 row13
        status_font_rom[12'd622] = 16'h11fa; // 揭 row14
        status_font_rom[12'd623] = 16'h1006; // 揭 row15
        status_font_rom[12'd624] = 16'h0000; // 菱 row0
        status_font_rom[12'd625] = 16'h0000; // 菱 row1
        status_font_rom[12'd626] = 16'h0420; // 菱 row2
        status_font_rom[12'd627] = 16'h7ffe; // 菱 row3
        status_font_rom[12'd628] = 16'h0420; // 菱 row4
        status_font_rom[12'd629] = 16'h1ff8; // 菱 row5
        status_font_rom[12'd630] = 16'h0180; // 菱 row6
        status_font_rom[12'd631] = 16'h7ffe; // 菱 row7
        status_font_rom[12'd632] = 16'h0420; // 菱 row8
        status_font_rom[12'd633] = 16'h1c38; // 菱 row9
        status_font_rom[12'd634] = 16'h3206; // 菱 row10
        status_font_rom[12'd635] = 16'h07f0; // 菱 row11
        status_font_rom[12'd636] = 16'h1c30; // 菱 row12
        status_font_rom[12'd637] = 16'h3660; // 菱 row13
        status_font_rom[12'd638] = 16'h03c0; // 菱 row14
        status_font_rom[12'd639] = 16'h0ff0; // 菱 row15
        status_font_rom[12'd640] = 16'h0000; // 形 row0
        status_font_rom[12'd641] = 16'h0000; // 形 row1
        status_font_rom[12'd642] = 16'h7f8c; // 形 row2
        status_font_rom[12'd643] = 16'h1318; // 形 row3
        status_font_rom[12'd644] = 16'h1330; // 形 row4
        status_font_rom[12'd645] = 16'h1320; // 形 row5
        status_font_rom[12'd646] = 16'h1302; // 形 row6
        status_font_rom[12'd647] = 16'h1304; // 形 row7
        status_font_rom[12'd648] = 16'h7f88; // 形 row8
        status_font_rom[12'd649] = 16'h1330; // 形 row9
        status_font_rom[12'd650] = 16'h1320; // 形 row10
        status_font_rom[12'd651] = 16'h3302; // 形 row11
        status_font_rom[12'd652] = 16'h3306; // 形 row12
        status_font_rom[12'd653] = 16'h230c; // 形 row13
        status_font_rom[12'd654] = 16'h2318; // 形 row14
        status_font_rom[12'd655] = 16'h4360; // 形 row15
        status_font_rom[12'd656] = 16'h0000; // 溶 row0
        status_font_rom[12'd657] = 16'h0040; // 溶 row1
        status_font_rom[12'd658] = 16'h3060; // 溶 row2
        status_font_rom[12'd659] = 16'h1ffe; // 溶 row3
        status_font_rom[12'd660] = 16'h0402; // 溶 row4
        status_font_rom[12'd661] = 16'h0492; // 溶 row5
        status_font_rom[12'd662] = 16'h6108; // 溶 row6
        status_font_rom[12'd663] = 16'h3264; // 溶 row7
        status_font_rom[12'd664] = 16'h00f0; // 溶 row8
        status_font_rom[12'd665] = 16'h0198; // 溶 row9
        status_font_rom[12'd666] = 16'h0206; // 溶 row10
        status_font_rom[12'd667] = 16'h1ffe; // 溶 row11
        status_font_rom[12'd668] = 16'h1308; // 溶 row12
        status_font_rom[12'd669] = 16'h3308; // 溶 row13
        status_font_rom[12'd670] = 16'h2308; // 溶 row14
        status_font_rom[12'd671] = 16'h63f8; // 溶 row15
        status_font_rom[12'd672] = 16'h0000; // 解 row0
        status_font_rom[12'd673] = 16'h1000; // 解 row1
        status_font_rom[12'd674] = 16'h10fe; // 解 row2
        status_font_rom[12'd675] = 16'h3e22; // 解 row3
        status_font_rom[12'd676] = 16'h2422; // 解 row4
        status_font_rom[12'd677] = 16'h2466; // 解 row5
        status_font_rom[12'd678] = 16'h7fcc; // 解 row6
        status_font_rom[12'd679] = 16'h6900; // 解 row7
        status_font_rom[12'd680] = 16'h2958; // 解 row8
        status_font_rom[12'd681] = 16'h3f7e; // 解 row9
        status_font_rom[12'd682] = 16'h2998; // 解 row10
        status_font_rom[12'd683] = 16'h2918; // 解 row11
        status_font_rom[12'd684] = 16'h3ffe; // 解 row12
        status_font_rom[12'd685] = 16'h2918; // 解 row13
        status_font_rom[12'd686] = 16'h4918; // 解 row14
        status_font_rom[12'd687] = 16'h4b18; // 解 row15
        status_font_rom[12'd688] = 16'h0000; // 0 row0
        status_font_rom[12'd689] = 16'h0000; // 0 row1
        status_font_rom[12'd690] = 16'h0000; // 0 row2
        status_font_rom[12'd691] = 16'h0380; // 0 row3
        status_font_rom[12'd692] = 16'h06c0; // 0 row4
        status_font_rom[12'd693] = 16'h0c40; // 0 row5
        status_font_rom[12'd694] = 16'h0860; // 0 row6
        status_font_rom[12'd695] = 16'h0820; // 0 row7
        status_font_rom[12'd696] = 16'h0820; // 0 row8
        status_font_rom[12'd697] = 16'h0820; // 0 row9
        status_font_rom[12'd698] = 16'h0820; // 0 row10
        status_font_rom[12'd699] = 16'h0860; // 0 row11
        status_font_rom[12'd700] = 16'h0c40; // 0 row12
        status_font_rom[12'd701] = 16'h06c0; // 0 row13
        status_font_rom[12'd702] = 16'h0380; // 0 row14
        status_font_rom[12'd703] = 16'h0000; // 0 row15
        status_font_rom[12'd704] = 16'h0000; // 1 row0
        status_font_rom[12'd705] = 16'h0000; // 1 row1
        status_font_rom[12'd706] = 16'h0000; // 1 row2
        status_font_rom[12'd707] = 16'h0300; // 1 row3
        status_font_rom[12'd708] = 16'h0700; // 1 row4
        status_font_rom[12'd709] = 16'h0100; // 1 row5
        status_font_rom[12'd710] = 16'h0100; // 1 row6
        status_font_rom[12'd711] = 16'h0100; // 1 row7
        status_font_rom[12'd712] = 16'h0100; // 1 row8
        status_font_rom[12'd713] = 16'h0100; // 1 row9
        status_font_rom[12'd714] = 16'h0100; // 1 row10
        status_font_rom[12'd715] = 16'h0100; // 1 row11
        status_font_rom[12'd716] = 16'h0100; // 1 row12
        status_font_rom[12'd717] = 16'h0180; // 1 row13
        status_font_rom[12'd718] = 16'h0fe0; // 1 row14
        status_font_rom[12'd719] = 16'h0000; // 1 row15
        status_font_rom[12'd720] = 16'h0000; // 2 row0
        status_font_rom[12'd721] = 16'h0000; // 2 row1
        status_font_rom[12'd722] = 16'h0000; // 2 row2
        status_font_rom[12'd723] = 16'h0780; // 2 row3
        status_font_rom[12'd724] = 16'h0cc0; // 2 row4
        status_font_rom[12'd725] = 16'h0040; // 2 row5
        status_font_rom[12'd726] = 16'h0040; // 2 row6
        status_font_rom[12'd727] = 16'h0040; // 2 row7
        status_font_rom[12'd728] = 16'h0040; // 2 row8
        status_font_rom[12'd729] = 16'h00c0; // 2 row9
        status_font_rom[12'd730] = 16'h0180; // 2 row10
        status_font_rom[12'd731] = 16'h0300; // 2 row11
        status_font_rom[12'd732] = 16'h0600; // 2 row12
        status_font_rom[12'd733] = 16'h0c00; // 2 row13
        status_font_rom[12'd734] = 16'h0fe0; // 2 row14
        status_font_rom[12'd735] = 16'h0000; // 2 row15
        status_font_rom[12'd736] = 16'h0000; // 3 row0
        status_font_rom[12'd737] = 16'h0000; // 3 row1
        status_font_rom[12'd738] = 16'h0000; // 3 row2
        status_font_rom[12'd739] = 16'h0780; // 3 row3
        status_font_rom[12'd740] = 16'h0cc0; // 3 row4
        status_font_rom[12'd741] = 16'h0040; // 3 row5
        status_font_rom[12'd742] = 16'h0040; // 3 row6
        status_font_rom[12'd743] = 16'h00c0; // 3 row7
        status_font_rom[12'd744] = 16'h0380; // 3 row8
        status_font_rom[12'd745] = 16'h00c0; // 3 row9
        status_font_rom[12'd746] = 16'h0060; // 3 row10
        status_font_rom[12'd747] = 16'h0060; // 3 row11
        status_font_rom[12'd748] = 16'h0060; // 3 row12
        status_font_rom[12'd749] = 16'h0cc0; // 3 row13
        status_font_rom[12'd750] = 16'h0780; // 3 row14
        status_font_rom[12'd751] = 16'h0000; // 3 row15
        status_font_rom[12'd752] = 16'h0000; // 4 row0
        status_font_rom[12'd753] = 16'h0000; // 4 row1
        status_font_rom[12'd754] = 16'h0000; // 4 row2
        status_font_rom[12'd755] = 16'h00c0; // 4 row3
        status_font_rom[12'd756] = 16'h01c0; // 4 row4
        status_font_rom[12'd757] = 16'h01c0; // 4 row5
        status_font_rom[12'd758] = 16'h02c0; // 4 row6
        status_font_rom[12'd759] = 16'h06c0; // 4 row7
        status_font_rom[12'd760] = 16'h04c0; // 4 row8
        status_font_rom[12'd761] = 16'h0cc0; // 4 row9
        status_font_rom[12'd762] = 16'h08c0; // 4 row10
        status_font_rom[12'd763] = 16'h1fe0; // 4 row11
        status_font_rom[12'd764] = 16'h00c0; // 4 row12
        status_font_rom[12'd765] = 16'h00c0; // 4 row13
        status_font_rom[12'd766] = 16'h00c0; // 4 row14
        status_font_rom[12'd767] = 16'h0000; // 4 row15
        status_font_rom[12'd768] = 16'h0000; // 5 row0
        status_font_rom[12'd769] = 16'h0000; // 5 row1
        status_font_rom[12'd770] = 16'h0000; // 5 row2
        status_font_rom[12'd771] = 16'h07c0; // 5 row3
        status_font_rom[12'd772] = 16'h0400; // 5 row4
        status_font_rom[12'd773] = 16'h0400; // 5 row5
        status_font_rom[12'd774] = 16'h0c00; // 5 row6
        status_font_rom[12'd775] = 16'h0f80; // 5 row7
        status_font_rom[12'd776] = 16'h04c0; // 5 row8
        status_font_rom[12'd777] = 16'h0060; // 5 row9
        status_font_rom[12'd778] = 16'h0060; // 5 row10
        status_font_rom[12'd779] = 16'h0060; // 5 row11
        status_font_rom[12'd780] = 16'h0060; // 5 row12
        status_font_rom[12'd781] = 16'h0cc0; // 5 row13
        status_font_rom[12'd782] = 16'h0780; // 5 row14
        status_font_rom[12'd783] = 16'h0000; // 5 row15
        status_font_rom[12'd784] = 16'h0000; // 6 row0
        status_font_rom[12'd785] = 16'h0000; // 6 row1
        status_font_rom[12'd786] = 16'h0000; // 6 row2
        status_font_rom[12'd787] = 16'h03c0; // 6 row3
        status_font_rom[12'd788] = 16'h0660; // 6 row4
        status_font_rom[12'd789] = 16'h0400; // 6 row5
        status_font_rom[12'd790] = 16'h0c00; // 6 row6
        status_font_rom[12'd791] = 16'h0800; // 6 row7
        status_font_rom[12'd792] = 16'h0bc0; // 6 row8
        status_font_rom[12'd793] = 16'h0c60; // 6 row9
        status_font_rom[12'd794] = 16'h0820; // 6 row10
        status_font_rom[12'd795] = 16'h0820; // 6 row11
        status_font_rom[12'd796] = 16'h0c20; // 6 row12
        status_font_rom[12'd797] = 16'h0640; // 6 row13
        status_font_rom[12'd798] = 16'h0380; // 6 row14
        status_font_rom[12'd799] = 16'h0000; // 6 row15
        status_font_rom[12'd800] = 16'h0000; // 7 row0
        status_font_rom[12'd801] = 16'h0000; // 7 row1
        status_font_rom[12'd802] = 16'h0000; // 7 row2
        status_font_rom[12'd803] = 16'h0fe0; // 7 row3
        status_font_rom[12'd804] = 16'h0060; // 7 row4
        status_font_rom[12'd805] = 16'h0040; // 7 row5
        status_font_rom[12'd806] = 16'h0080; // 7 row6
        status_font_rom[12'd807] = 16'h0080; // 7 row7
        status_font_rom[12'd808] = 16'h0180; // 7 row8
        status_font_rom[12'd809] = 16'h0100; // 7 row9
        status_font_rom[12'd810] = 16'h0100; // 7 row10
        status_font_rom[12'd811] = 16'h0100; // 7 row11
        status_font_rom[12'd812] = 16'h0300; // 7 row12
        status_font_rom[12'd813] = 16'h0300; // 7 row13
        status_font_rom[12'd814] = 16'h0300; // 7 row14
        status_font_rom[12'd815] = 16'h0000; // 7 row15
        status_font_rom[12'd816] = 16'h0000; // 8 row0
        status_font_rom[12'd817] = 16'h0000; // 8 row1
        status_font_rom[12'd818] = 16'h0000; // 8 row2
        status_font_rom[12'd819] = 16'h0380; // 8 row3
        status_font_rom[12'd820] = 16'h0440; // 8 row4
        status_font_rom[12'd821] = 16'h0c60; // 8 row5
        status_font_rom[12'd822] = 16'h0c60; // 8 row6
        status_font_rom[12'd823] = 16'h0440; // 8 row7
        status_font_rom[12'd824] = 16'h03c0; // 8 row8
        status_font_rom[12'd825] = 16'h05c0; // 8 row9
        status_font_rom[12'd826] = 16'h0860; // 8 row10
        status_font_rom[12'd827] = 16'h0820; // 8 row11
        status_font_rom[12'd828] = 16'h0820; // 8 row12
        status_font_rom[12'd829] = 16'h0c60; // 8 row13
        status_font_rom[12'd830] = 16'h0780; // 8 row14
        status_font_rom[12'd831] = 16'h0000; // 8 row15
        status_font_rom[12'd832] = 16'h0000; // 9 row0
        status_font_rom[12'd833] = 16'h0000; // 9 row1
        status_font_rom[12'd834] = 16'h0000; // 9 row2
        status_font_rom[12'd835] = 16'h0780; // 9 row3
        status_font_rom[12'd836] = 16'h0cc0; // 9 row4
        status_font_rom[12'd837] = 16'h0840; // 9 row5
        status_font_rom[12'd838] = 16'h0860; // 9 row6
        status_font_rom[12'd839] = 16'h0860; // 9 row7
        status_font_rom[12'd840] = 16'h0c60; // 9 row8
        status_font_rom[12'd841] = 16'h07a0; // 9 row9
        status_font_rom[12'd842] = 16'h0060; // 9 row10
        status_font_rom[12'd843] = 16'h0060; // 9 row11
        status_font_rom[12'd844] = 16'h0040; // 9 row12
        status_font_rom[12'd845] = 16'h0cc0; // 9 row13
        status_font_rom[12'd846] = 16'h0700; // 9 row14
        status_font_rom[12'd847] = 16'h0000; // 9 row15
        status_font_rom[12'd848] = 16'h0000; // X row0
        status_font_rom[12'd849] = 16'h0000; // X row1
        status_font_rom[12'd850] = 16'h0000; // X row2
        status_font_rom[12'd851] = 16'h0820; // X row3
        status_font_rom[12'd852] = 16'h0c60; // X row4
        status_font_rom[12'd853] = 16'h0440; // X row5
        status_font_rom[12'd854] = 16'h06c0; // X row6
        status_font_rom[12'd855] = 16'h0380; // X row7
        status_font_rom[12'd856] = 16'h0380; // X row8
        status_font_rom[12'd857] = 16'h0380; // X row9
        status_font_rom[12'd858] = 16'h0280; // X row10
        status_font_rom[12'd859] = 16'h06c0; // X row11
        status_font_rom[12'd860] = 16'h0440; // X row12
        status_font_rom[12'd861] = 16'h0c60; // X row13
        status_font_rom[12'd862] = 16'h0830; // X row14
        status_font_rom[12'd863] = 16'h0000; // X row15
        status_font_rom[12'd864] = 16'h0000; // % row0
        status_font_rom[12'd865] = 16'h0000; // % row1
        status_font_rom[12'd866] = 16'h0000; // % row2
        status_font_rom[12'd867] = 16'h3820; // % row3
        status_font_rom[12'd868] = 16'h4840; // % row4
        status_font_rom[12'd869] = 16'h4440; // % row5
        status_font_rom[12'd870] = 16'h4480; // % row6
        status_font_rom[12'd871] = 16'h4480; // % row7
        status_font_rom[12'd872] = 16'h4538; // % row8
        status_font_rom[12'd873] = 16'h496c; // % row9
        status_font_rom[12'd874] = 16'h3244; // % row10
        status_font_rom[12'd875] = 16'h0044; // % row11
        status_font_rom[12'd876] = 16'h0444; // % row12
        status_font_rom[12'd877] = 16'h084c; // % row13
        status_font_rom[12'd878] = 16'h0838; // % row14
        status_font_rom[12'd879] = 16'h0000; // % row15
        status_font_rom[12'd880] = 16'h0000; // 音 row0
        status_font_rom[12'd881] = 16'h0100; // 音 row1
        status_font_rom[12'd882] = 16'h0180; // 音 row2
        status_font_rom[12'd883] = 16'h3ffc; // 音 row3
        status_font_rom[12'd884] = 16'h0810; // 音 row4
        status_font_rom[12'd885] = 16'h0c30; // 音 row5
        status_font_rom[12'd886] = 16'h0420; // 音 row6
        status_font_rom[12'd887] = 16'h7ffe; // 音 row7
        status_font_rom[12'd888] = 16'h0000; // 音 row8
        status_font_rom[12'd889] = 16'h1ff8; // 音 row9
        status_font_rom[12'd890] = 16'h1008; // 音 row10
        status_font_rom[12'd891] = 16'h1008; // 音 row11
        status_font_rom[12'd892] = 16'h1ff8; // 音 row12
        status_font_rom[12'd893] = 16'h1008; // 音 row13
        status_font_rom[12'd894] = 16'h1008; // 音 row14
        status_font_rom[12'd895] = 16'h1ff8; // 音 row15
        status_font_rom[12'd896] = 16'h0000; // 量 row0
        status_font_rom[12'd897] = 16'h0000; // 量 row1
        status_font_rom[12'd898] = 16'h1ff8; // 量 row2
        status_font_rom[12'd899] = 16'h1ff8; // 量 row3
        status_font_rom[12'd900] = 16'h1008; // 量 row4
        status_font_rom[12'd901] = 16'h1ff8; // 量 row5
        status_font_rom[12'd902] = 16'h0000; // 量 row6
        status_font_rom[12'd903] = 16'h7ffe; // 量 row7
        status_font_rom[12'd904] = 16'h1ff8; // 量 row8
        status_font_rom[12'd905] = 16'h118c; // 量 row9
        status_font_rom[12'd906] = 16'h1ffc; // 量 row10
        status_font_rom[12'd907] = 16'h1ffc; // 量 row11
        status_font_rom[12'd908] = 16'h0180; // 量 row12
        status_font_rom[12'd909] = 16'h3ffc; // 量 row13
        status_font_rom[12'd910] = 16'h0180; // 量 row14
        status_font_rom[12'd911] = 16'h7ffe; // 量 row15
        status_font_rom[12'd912] = 16'h0000; // 运 row0
        status_font_rom[12'd913] = 16'h0000; // 运 row1
        status_font_rom[12'd914] = 16'h63fc; // 运 row2
        status_font_rom[12'd915] = 16'h3000; // 运 row3
        status_font_rom[12'd916] = 16'h1000; // 运 row4
        status_font_rom[12'd917] = 16'h0000; // 运 row5
        status_font_rom[12'd918] = 16'h07fe; // 运 row6
        status_font_rom[12'd919] = 16'h70c0; // 运 row7
        status_font_rom[12'd920] = 16'h1090; // 运 row8
        status_font_rom[12'd921] = 16'h1198; // 运 row9
        status_font_rom[12'd922] = 16'h1108; // 运 row10
        status_font_rom[12'd923] = 16'h130c; // 运 row11
        status_font_rom[12'd924] = 16'h13fc; // 运 row12
        status_font_rom[12'd925] = 16'h1206; // 运 row13
        status_font_rom[12'd926] = 16'h3800; // 运 row14
        status_font_rom[12'd927] = 16'h6e00; // 运 row15
        status_font_rom[12'd928] = 16'h0000; // 行 row0
        status_font_rom[12'd929] = 16'h0800; // 行 row1
        status_font_rom[12'd930] = 16'h19fe; // 行 row2
        status_font_rom[12'd931] = 16'h3000; // 行 row3
        status_font_rom[12'd932] = 16'h6000; // 行 row4
        status_font_rom[12'd933] = 16'h4c00; // 行 row5
        status_font_rom[12'd934] = 16'h0800; // 行 row6
        status_font_rom[12'd935] = 16'h1bfe; // 行 row7
        status_font_rom[12'd936] = 16'h3008; // 行 row8
        status_font_rom[12'd937] = 16'h7008; // 行 row9
        status_font_rom[12'd938] = 16'h5008; // 行 row10
        status_font_rom[12'd939] = 16'h1008; // 行 row11
        status_font_rom[12'd940] = 16'h1008; // 行 row12
        status_font_rom[12'd941] = 16'h1008; // 行 row13
        status_font_rom[12'd942] = 16'h1008; // 行 row14
        status_font_rom[12'd943] = 16'h1018; // 行 row15
        status_font_rom[12'd944] = 16'h0000; // : row0
        status_font_rom[12'd945] = 16'h0000; // : row1
        status_font_rom[12'd946] = 16'h0000; // : row2
        status_font_rom[12'd947] = 16'h0000; // : row3
        status_font_rom[12'd948] = 16'h0000; // : row4
        status_font_rom[12'd949] = 16'h0000; // : row5
        status_font_rom[12'd950] = 16'h0180; // : row6
        status_font_rom[12'd951] = 16'h0180; // : row7
        status_font_rom[12'd952] = 16'h0000; // : row8
        status_font_rom[12'd953] = 16'h0000; // : row9
        status_font_rom[12'd954] = 16'h0000; // : row10
        status_font_rom[12'd955] = 16'h0000; // : row11
        status_font_rom[12'd956] = 16'h0000; // : row12
        status_font_rom[12'd957] = 16'h0180; // : row13
        status_font_rom[12'd958] = 16'h0180; // : row14
        status_font_rom[12'd959] = 16'h0000; // : row15
        status_font_rom[12'd960] = 16'h0000; // 检 row0
        status_font_rom[12'd961] = 16'h1020; // 检 row1
        status_font_rom[12'd962] = 16'h1060; // 检 row2
        status_font_rom[12'd963] = 16'h1070; // 检 row3
        status_font_rom[12'd964] = 16'h1090; // 检 row4
        status_font_rom[12'd965] = 16'h7d88; // 检 row5
        status_font_rom[12'd966] = 16'h1306; // 检 row6
        status_font_rom[12'd967] = 16'h37fa; // 检 row7
        status_font_rom[12'd968] = 16'h3800; // 检 row8
        status_font_rom[12'd969] = 16'h3404; // 检 row9
        status_font_rom[12'd970] = 16'h5124; // 检 row10
        status_font_rom[12'd971] = 16'h5124; // 检 row11
        status_font_rom[12'd972] = 16'h5128; // 检 row12
        status_font_rom[12'd973] = 16'h1008; // 检 row13
        status_font_rom[12'd974] = 16'h1010; // 检 row14
        status_font_rom[12'd975] = 16'h13fe; // 检 row15
        status_font_rom[12'd976] = 16'h0000; // 特 row0
        status_font_rom[12'd977] = 16'h0020; // 特 row1
        status_font_rom[12'd978] = 16'h1820; // 特 row2
        status_font_rom[12'd979] = 16'h79fe; // 特 row3
        status_font_rom[12'd980] = 16'h7820; // 特 row4
        status_font_rom[12'd981] = 16'h7c20; // 特 row5
        status_font_rom[12'd982] = 16'h5bfe; // 特 row6
        status_font_rom[12'd983] = 16'h5808; // 特 row7
        status_font_rom[12'd984] = 16'h1808; // 特 row8
        status_font_rom[12'd985] = 16'h1808; // 特 row9
        status_font_rom[12'd986] = 16'h7bfe; // 特 row10
        status_font_rom[12'd987] = 16'h5888; // 特 row11
        status_font_rom[12'd988] = 16'h1888; // 特 row12
        status_font_rom[12'd989] = 16'h1848; // 特 row13
        status_font_rom[12'd990] = 16'h1848; // 特 row14
        status_font_rom[12'd991] = 16'h1808; // 特 row15
        status_font_rom[12'd992] = 16'h0000; // 效 row0
        status_font_rom[12'd993] = 16'h0020; // 效 row1
        status_font_rom[12'd994] = 16'h0820; // 效 row2
        status_font_rom[12'd995] = 16'h0820; // 效 row3
        status_font_rom[12'd996] = 16'h7f7e; // 效 row4
        status_font_rom[12'd997] = 16'h0044; // 效 row5
        status_font_rom[12'd998] = 16'h2244; // 效 row6
        status_font_rom[12'd999] = 16'h23c4; // 效 row7
        status_font_rom[12'd1000] = 16'h41ec; // 效 row8
        status_font_rom[12'd1001] = 16'h1428; // 效 row9
        status_font_rom[12'd1002] = 16'h1c38; // 效 row10
        status_font_rom[12'd1003] = 16'h0c18; // 效 row11
        status_font_rom[12'd1004] = 16'h0c10; // 效 row12
        status_font_rom[12'd1005] = 16'h1238; // 效 row13
        status_font_rom[12'd1006] = 16'h226c; // 效 row14
        status_font_rom[12'd1007] = 16'h40c6; // 效 row15
        status_font_rom[12'd1008] = 16'h0000; // 帧 row0
        status_font_rom[12'd1009] = 16'h0000; // 帧 row1
        status_font_rom[12'd1010] = 16'h1030; // 帧 row2
        status_font_rom[12'd1011] = 16'h103e; // 帧 row3
        status_font_rom[12'd1012] = 16'h1030; // 帧 row4
        status_font_rom[12'd1013] = 16'h7efc; // 帧 row5
        status_font_rom[12'd1014] = 16'h5284; // 帧 row6
        status_font_rom[12'd1015] = 16'h5284; // 帧 row7
        status_font_rom[12'd1016] = 16'h52b4; // 帧 row8
        status_font_rom[12'd1017] = 16'h52b4; // 帧 row9
        status_font_rom[12'd1018] = 16'h52b4; // 帧 row10
        status_font_rom[12'd1019] = 16'h52b4; // 帧 row11
        status_font_rom[12'd1020] = 16'h5ca4; // 帧 row12
        status_font_rom[12'd1021] = 16'h1020; // 帧 row13
        status_font_rom[12'd1022] = 16'h1048; // 帧 row14
        status_font_rom[12'd1023] = 16'h1186; // 帧 row15
        status_font_rom[12'd1024] = 16'h0000; // 读 row0
        status_font_rom[12'd1025] = 16'h0020; // 读 row1
        status_font_rom[12'd1026] = 16'h2020; // 读 row2
        status_font_rom[12'd1027] = 16'h13fc; // 读 row3
        status_font_rom[12'd1028] = 16'h0020; // 读 row4
        status_font_rom[12'd1029] = 16'h03fe; // 读 row5
        status_font_rom[12'd1030] = 16'h0006; // 读 row6
        status_font_rom[12'd1031] = 16'h7184; // 读 row7
        status_font_rom[12'd1032] = 16'h1060; // 读 row8
        status_font_rom[12'd1033] = 16'h1120; // 读 row9
        status_font_rom[12'd1034] = 16'h10a0; // 读 row10
        status_font_rom[12'd1035] = 16'h13fe; // 读 row11
        status_font_rom[12'd1036] = 16'h1060; // 读 row12
        status_font_rom[12'd1037] = 16'h1c58; // 读 row13
        status_font_rom[12'd1038] = 16'h188c; // 读 row14
        status_font_rom[12'd1039] = 16'h3306; // 读 row15
        status_font_rom[12'd1040] = 16'h0000; // 秒 row0
        status_font_rom[12'd1041] = 16'h0020; // 秒 row1
        status_font_rom[12'd1042] = 16'h1c20; // 秒 row2
        status_font_rom[12'd1043] = 16'h7820; // 秒 row3
        status_font_rom[12'd1044] = 16'h18a4; // 秒 row4
        status_font_rom[12'd1045] = 16'h18a4; // 秒 row5
        status_font_rom[12'd1046] = 16'h7fa6; // 秒 row6
        status_font_rom[12'd1047] = 16'h1922; // 秒 row7
        status_font_rom[12'd1048] = 16'h1922; // 秒 row8
        status_font_rom[12'd1049] = 16'h3c20; // 秒 row9
        status_font_rom[12'd1050] = 16'h3824; // 秒 row10
        status_font_rom[12'd1051] = 16'h582c; // 秒 row11
        status_font_rom[12'd1052] = 16'h5808; // 秒 row12
        status_font_rom[12'd1053] = 16'h1830; // 秒 row13
        status_font_rom[12'd1054] = 16'h1860; // 秒 row14
        status_font_rom[12'd1055] = 16'h1bc0; // 秒 row15
        status_font_rom[12'd1056] = 16'h0000; // 缓 row0
        status_font_rom[12'd1057] = 16'h0004; // 缓 row1
        status_font_rom[12'd1058] = 16'h13f8; // 缓 row2
        status_font_rom[12'd1059] = 16'h1124; // 缓 row3
        status_font_rom[12'd1060] = 16'h3124; // 缓 row4
        status_font_rom[12'd1061] = 16'h2528; // 缓 row5
        status_font_rom[12'd1062] = 16'h4ffe; // 缓 row6
        status_font_rom[12'd1063] = 16'h7880; // 缓 row7
        status_font_rom[12'd1064] = 16'h13fe; // 缓 row8
        status_font_rom[12'd1065] = 16'h2080; // 缓 row9
        status_font_rom[12'd1066] = 16'h7cfc; // 缓 row10
        status_font_rom[12'd1067] = 16'h6184; // 缓 row11
        status_font_rom[12'd1068] = 16'h0148; // 缓 row12
        status_font_rom[12'd1069] = 16'h1f78; // 缓 row13
        status_font_rom[12'd1070] = 16'h7230; // 缓 row14
        status_font_rom[12'd1071] = 16'h04ce; // 缓 row15
        status_font_rom[12'd1072] = 16'h0000; // 存 row0
        status_font_rom[12'd1073] = 16'h0000; // 存 row1
        status_font_rom[12'd1074] = 16'h0200; // 存 row2
        status_font_rom[12'd1075] = 16'h0200; // 存 row3
        status_font_rom[12'd1076] = 16'h7ffe; // 存 row4
        status_font_rom[12'd1077] = 16'h0400; // 存 row5
        status_font_rom[12'd1078] = 16'h0800; // 存 row6
        status_font_rom[12'd1079] = 16'h09fc; // 存 row7
        status_font_rom[12'd1080] = 16'h1018; // 存 row8
        status_font_rom[12'd1081] = 16'h3030; // 存 row9
        status_font_rom[12'd1082] = 16'h7020; // 存 row10
        status_font_rom[12'd1083] = 16'h17fe; // 存 row11
        status_font_rom[12'd1084] = 16'h1020; // 存 row12
        status_font_rom[12'd1085] = 16'h1020; // 存 row13
        status_font_rom[12'd1086] = 16'h1020; // 存 row14
        status_font_rom[12'd1087] = 16'h1020; // 存 row15
        status_font_rom[12'd1088] = 16'h0000; // 欠 row0
        status_font_rom[12'd1089] = 16'h0800; // 欠 row1
        status_font_rom[12'd1090] = 16'h0800; // 欠 row2
        status_font_rom[12'd1091] = 16'h0800; // 欠 row3
        status_font_rom[12'd1092] = 16'h1ffe; // 欠 row4
        status_font_rom[12'd1093] = 16'h1004; // 欠 row5
        status_font_rom[12'd1094] = 16'h3104; // 欠 row6
        status_font_rom[12'd1095] = 16'h218c; // 欠 row7
        status_font_rom[12'd1096] = 16'h4188; // 欠 row8
        status_font_rom[12'd1097] = 16'h0180; // 欠 row9
        status_font_rom[12'd1098] = 16'h0180; // 欠 row10
        status_font_rom[12'd1099] = 16'h0340; // 欠 row11
        status_font_rom[12'd1100] = 16'h0240; // 欠 row12
        status_font_rom[12'd1101] = 16'h0420; // 欠 row13
        status_font_rom[12'd1102] = 16'h1818; // 欠 row14
        status_font_rom[12'd1103] = 16'h700e; // 欠 row15
        status_font_rom[12'd1104] = 16'h0000; // 载 row0
        status_font_rom[12'd1105] = 16'h0420; // 载 row1
        status_font_rom[12'd1106] = 16'h0428; // 载 row2
        status_font_rom[12'd1107] = 16'h3fa4; // 载 row3
        status_font_rom[12'd1108] = 16'h0420; // 载 row4
        status_font_rom[12'd1109] = 16'h7ffe; // 载 row5
        status_font_rom[12'd1110] = 16'h0820; // 载 row6
        status_font_rom[12'd1111] = 16'h0824; // 载 row7
        status_font_rom[12'd1112] = 16'h7fa4; // 载 row8
        status_font_rom[12'd1113] = 16'h1024; // 载 row9
        status_font_rom[12'd1114] = 16'h2428; // 载 row10
        status_font_rom[12'd1115] = 16'h3fb8; // 载 row11
        status_font_rom[12'd1116] = 16'h0410; // 载 row12
        status_font_rom[12'd1117] = 16'h07b2; // 载 row13
        status_font_rom[12'd1118] = 16'h7c3a; // 载 row14
        status_font_rom[12'd1119] = 16'h044a; // 载 row15
        status_font_rom[12'd1120] = 16'h0000; // 同 row0
        status_font_rom[12'd1121] = 16'h0000; // 同 row1
        status_font_rom[12'd1122] = 16'h7ffe; // 同 row2
        status_font_rom[12'd1123] = 16'h6006; // 同 row3
        status_font_rom[12'd1124] = 16'h6006; // 同 row4
        status_font_rom[12'd1125] = 16'h6ff6; // 同 row5
        status_font_rom[12'd1126] = 16'h6006; // 同 row6
        status_font_rom[12'd1127] = 16'h6006; // 同 row7
        status_font_rom[12'd1128] = 16'h67e6; // 同 row8
        status_font_rom[12'd1129] = 16'h6426; // 同 row9
        status_font_rom[12'd1130] = 16'h6426; // 同 row10
        status_font_rom[12'd1131] = 16'h6426; // 同 row11
        status_font_rom[12'd1132] = 16'h67e6; // 同 row12
        status_font_rom[12'd1133] = 16'h6406; // 同 row13
        status_font_rom[12'd1134] = 16'h6406; // 同 row14
        status_font_rom[12'd1135] = 16'h6006; // 同 row15
        status_font_rom[12'd1136] = 16'h0000; // 频 row0
        status_font_rom[12'd1137] = 16'h0800; // 频 row1
        status_font_rom[12'd1138] = 16'h08fe; // 频 row2
        status_font_rom[12'd1139] = 16'h2f10; // 频 row3
        status_font_rom[12'd1140] = 16'h2810; // 频 row4
        status_font_rom[12'd1141] = 16'h287e; // 频 row5
        status_font_rom[12'd1142] = 16'h2842; // 频 row6
        status_font_rom[12'd1143] = 16'h7f42; // 频 row7
        status_font_rom[12'd1144] = 16'h0852; // 频 row8
        status_font_rom[12'd1145] = 16'h2952; // 频 row9
        status_font_rom[12'd1146] = 16'h2b52; // 频 row10
        status_font_rom[12'd1147] = 16'h4a52; // 频 row11
        status_font_rom[12'd1148] = 16'h4e52; // 频 row12
        status_font_rom[12'd1149] = 16'h0430; // 频 row13
        status_font_rom[12'd1150] = 16'h082c; // 频 row14
        status_font_rom[12'd1151] = 16'h30c6; // 频 row15
        status_font_rom[12'd1152] = 16'h0000; // 多 row0
        status_font_rom[12'd1153] = 16'h0100; // 多 row1
        status_font_rom[12'd1154] = 16'h0300; // 多 row2
        status_font_rom[12'd1155] = 16'h07f0; // 多 row3
        status_font_rom[12'd1156] = 16'h0c30; // 多 row4
        status_font_rom[12'd1157] = 16'h3460; // 多 row5
        status_font_rom[12'd1158] = 16'h02c0; // 多 row6
        status_font_rom[12'd1159] = 16'h03a0; // 多 row7
        status_font_rom[12'd1160] = 16'h0e60; // 多 row8
        status_font_rom[12'd1161] = 16'h38fe; // 多 row9
        status_font_rom[12'd1162] = 16'h0304; // 多 row10
        status_font_rom[12'd1163] = 16'h0e0c; // 多 row11
        status_font_rom[12'd1164] = 16'h0898; // 多 row12
        status_font_rom[12'd1165] = 16'h00e0; // 多 row13
        status_font_rom[12'd1166] = 16'h01c0; // 多 row14
        status_font_rom[12'd1167] = 16'h3e00; // 多 row15
        status_font_rom[12'd1168] = 16'h0000; // 媒 row0
        status_font_rom[12'd1169] = 16'h1080; // 媒 row1
        status_font_rom[12'd1170] = 16'h1084; // 媒 row2
        status_font_rom[12'd1171] = 16'h33fe; // 媒 row3
        status_font_rom[12'd1172] = 16'h208c; // 媒 row4
        status_font_rom[12'd1173] = 16'h7c84; // 媒 row5
        status_font_rom[12'd1174] = 16'h24fc; // 媒 row6
        status_font_rom[12'd1175] = 16'h2484; // 媒 row7
        status_font_rom[12'd1176] = 16'h28fc; // 媒 row8
        status_font_rom[12'd1177] = 16'h4820; // 媒 row9
        status_font_rom[12'd1178] = 16'h4820; // 媒 row10
        status_font_rom[12'd1179] = 16'h3bfe; // 媒 row11
        status_font_rom[12'd1180] = 16'h1870; // 媒 row12
        status_font_rom[12'd1181] = 16'h18e8; // 媒 row13
        status_font_rom[12'd1182] = 16'h25a4; // 媒 row14
        status_font_rom[12'd1183] = 16'h6322; // 媒 row15
        status_font_rom[12'd1184] = 16'h0000; // 体 row0
        status_font_rom[12'd1185] = 16'h0000; // 体 row1
        status_font_rom[12'd1186] = 16'h0840; // 体 row2
        status_font_rom[12'd1187] = 16'h1040; // 体 row3
        status_font_rom[12'd1188] = 16'h1060; // 体 row4
        status_font_rom[12'd1189] = 16'h37fe; // 体 row5
        status_font_rom[12'd1190] = 16'h30e0; // 体 row6
        status_font_rom[12'd1191] = 16'h70f0; // 体 row7
        status_font_rom[12'd1192] = 16'h51d0; // 体 row8
        status_font_rom[12'd1193] = 16'h1148; // 体 row9
        status_font_rom[12'd1194] = 16'h1148; // 体 row10
        status_font_rom[12'd1195] = 16'h124c; // 体 row11
        status_font_rom[12'd1196] = 16'h1646; // 体 row12
        status_font_rom[12'd1197] = 16'h1dfa; // 体 row13
        status_font_rom[12'd1198] = 16'h1040; // 体 row14
        status_font_rom[12'd1199] = 16'h1040; // 体 row15
        status_font_rom[12'd1200] = 16'h0000; // 终 row0
        status_font_rom[12'd1201] = 16'h0040; // 终 row1
        status_font_rom[12'd1202] = 16'h1040; // 终 row2
        status_font_rom[12'd1203] = 16'h10fc; // 终 row3
        status_font_rom[12'd1204] = 16'h218c; // 终 row4
        status_font_rom[12'd1205] = 16'h2748; // 终 row5
        status_font_rom[12'd1206] = 16'h6e70; // 终 row6
        status_font_rom[12'd1207] = 16'h7830; // 终 row7
        status_font_rom[12'd1208] = 16'h1078; // 终 row8
        status_font_rom[12'd1209] = 16'h318e; // 终 row9
        status_font_rom[12'd1210] = 16'h6c62; // 终 row10
        status_font_rom[12'd1211] = 16'h7830; // 终 row11
        status_font_rom[12'd1212] = 16'h0008; // 终 row12
        status_font_rom[12'd1213] = 16'h0080; // 终 row13
        status_font_rom[12'd1214] = 16'h7cf0; // 终 row14
        status_font_rom[12'd1215] = 16'h401c; // 终 row15
        status_font_rom[12'd1216] = 16'h0000; // 端 row0
        status_font_rom[12'd1217] = 16'h0020; // 端 row1
        status_font_rom[12'd1218] = 16'h1122; // 端 row2
        status_font_rom[12'd1219] = 16'h1122; // 端 row3
        status_font_rom[12'd1220] = 16'h7d22; // 端 row4
        status_font_rom[12'd1221] = 16'h01fe; // 端 row5
        status_font_rom[12'd1222] = 16'h4400; // 端 row6
        status_font_rom[12'd1223] = 16'h0bfe; // 端 row7
        status_font_rom[12'd1224] = 16'h2820; // 端 row8
        status_font_rom[12'd1225] = 16'h2820; // 端 row9
        status_font_rom[12'd1226] = 16'h29fe; // 端 row10
        status_font_rom[12'd1227] = 16'h2952; // 端 row11
        status_font_rom[12'd1228] = 16'h0b52; // 端 row12
        status_font_rom[12'd1229] = 16'h3f52; // 端 row13
        status_font_rom[12'd1230] = 16'h6152; // 端 row14
        status_font_rom[12'd1231] = 16'h0152; // 端 row15
        status_font_rom[12'd1232] = 16'h0000; // 版 row0
        status_font_rom[12'd1233] = 16'h0000; // 版 row1
        status_font_rom[12'd1234] = 16'h24fc; // 版 row2
        status_font_rom[12'd1235] = 16'h2480; // 版 row3
        status_font_rom[12'd1236] = 16'h2480; // 版 row4
        status_font_rom[12'd1237] = 16'h2c80; // 版 row5
        status_font_rom[12'd1238] = 16'h3efe; // 版 row6
        status_font_rom[12'd1239] = 16'h20c6; // 版 row7
        status_font_rom[12'd1240] = 16'h20c4; // 版 row8
        status_font_rom[12'd1241] = 16'h20a4; // 版 row9
        status_font_rom[12'd1242] = 16'h3ca4; // 版 row10
        status_font_rom[12'd1243] = 16'h24ac; // 版 row11
        status_font_rom[12'd1244] = 16'h2598; // 版 row12
        status_font_rom[12'd1245] = 16'h4518; // 版 row13
        status_font_rom[12'd1246] = 16'h453c; // 版 row14
        status_font_rom[12'd1247] = 16'h4766; // 版 row15
        status_font_rom[12'd1248] = 16'h0000; // 本 row0
        status_font_rom[12'd1249] = 16'h0000; // 本 row1
        status_font_rom[12'd1250] = 16'h0180; // 本 row2
        status_font_rom[12'd1251] = 16'h0180; // 本 row3
        status_font_rom[12'd1252] = 16'h0180; // 本 row4
        status_font_rom[12'd1253] = 16'h7ffe; // 本 row5
        status_font_rom[12'd1254] = 16'h03c0; // 本 row6
        status_font_rom[12'd1255] = 16'h05a0; // 本 row7
        status_font_rom[12'd1256] = 16'h05a0; // 本 row8
        status_font_rom[12'd1257] = 16'h0990; // 本 row9
        status_font_rom[12'd1258] = 16'h1998; // 本 row10
        status_font_rom[12'd1259] = 16'h318c; // 本 row11
        status_font_rom[12'd1260] = 16'h6ff6; // 本 row12
        status_font_rom[12'd1261] = 16'h0180; // 本 row13
        status_font_rom[12'd1262] = 16'h0180; // 本 row14
        status_font_rom[12'd1263] = 16'h0180; // 本 row15
        status_font_rom[12'd1264] = 16'h0000; // 在 row0
        status_font_rom[12'd1265] = 16'h0200; // 在 row1
        status_font_rom[12'd1266] = 16'h0200; // 在 row2
        status_font_rom[12'd1267] = 16'h0600; // 在 row3
        status_font_rom[12'd1268] = 16'h7ffe; // 在 row4
        status_font_rom[12'd1269] = 16'h0400; // 在 row5
        status_font_rom[12'd1270] = 16'h0820; // 在 row6
        status_font_rom[12'd1271] = 16'h1820; // 在 row7
        status_font_rom[12'd1272] = 16'h1020; // 在 row8
        status_font_rom[12'd1273] = 16'h33fc; // 在 row9
        status_font_rom[12'd1274] = 16'h5060; // 在 row10
        status_font_rom[12'd1275] = 16'h1020; // 在 row11
        status_font_rom[12'd1276] = 16'h1020; // 在 row12
        status_font_rom[12'd1277] = 16'h1020; // 在 row13
        status_font_rom[12'd1278] = 16'h1020; // 在 row14
        status_font_rom[12'd1279] = 16'h17fe; // 在 row15
        status_font_rom[12'd1280] = 16'h0000; // 取 row0
        status_font_rom[12'd1281] = 16'h0000; // 取 row1
        status_font_rom[12'd1282] = 16'h7f00; // 取 row2
        status_font_rom[12'd1283] = 16'h22fe; // 取 row3
        status_font_rom[12'd1284] = 16'h2246; // 取 row4
        status_font_rom[12'd1285] = 16'h2244; // 取 row5
        status_font_rom[12'd1286] = 16'h3e44; // 取 row6
        status_font_rom[12'd1287] = 16'h2224; // 取 row7
        status_font_rom[12'd1288] = 16'h2224; // 取 row8
        status_font_rom[12'd1289] = 16'h3e28; // 取 row9
        status_font_rom[12'd1290] = 16'h2238; // 取 row10
        status_font_rom[12'd1291] = 16'h2218; // 取 row11
        status_font_rom[12'd1292] = 16'h2718; // 取 row12
        status_font_rom[12'd1293] = 16'h7e38; // 取 row13
        status_font_rom[12'd1294] = 16'h026c; // 取 row14
        status_font_rom[12'd1295] = 16'h02c6; // 取 row15
        status_font_rom[12'd1296] = 16'h0000; // 卡 row0
        status_font_rom[12'd1297] = 16'h0100; // 卡 row1
        status_font_rom[12'd1298] = 16'h0100; // 卡 row2
        status_font_rom[12'd1299] = 16'h0100; // 卡 row3
        status_font_rom[12'd1300] = 16'h01f8; // 卡 row4
        status_font_rom[12'd1301] = 16'h0100; // 卡 row5
        status_font_rom[12'd1302] = 16'h0100; // 卡 row6
        status_font_rom[12'd1303] = 16'h0100; // 卡 row7
        status_font_rom[12'd1304] = 16'h7ffe; // 卡 row8
        status_font_rom[12'd1305] = 16'h0100; // 卡 row9
        status_font_rom[12'd1306] = 16'h0100; // 卡 row10
        status_font_rom[12'd1307] = 16'h01e0; // 卡 row11
        status_font_rom[12'd1308] = 16'h0138; // 卡 row12
        status_font_rom[12'd1309] = 16'h010c; // 卡 row13
        status_font_rom[12'd1310] = 16'h0100; // 卡 row14
        status_font_rom[12'd1311] = 16'h0100; // 卡 row15
        status_font_rom[12'd1312] = 16'h0000; // 来 row0
        status_font_rom[12'd1313] = 16'h0180; // 来 row1
        status_font_rom[12'd1314] = 16'h0180; // 来 row2
        status_font_rom[12'd1315] = 16'h3ffc; // 来 row3
        status_font_rom[12'd1316] = 16'h0180; // 来 row4
        status_font_rom[12'd1317] = 16'h1988; // 来 row5
        status_font_rom[12'd1318] = 16'h0998; // 来 row6
        status_font_rom[12'd1319] = 16'h0990; // 来 row7
        status_font_rom[12'd1320] = 16'h0190; // 来 row8
        status_font_rom[12'd1321] = 16'h7ffe; // 来 row9
        status_font_rom[12'd1322] = 16'h03c0; // 来 row10
        status_font_rom[12'd1323] = 16'h07e0; // 来 row11
        status_font_rom[12'd1324] = 16'h0db0; // 来 row12
        status_font_rom[12'd1325] = 16'h1998; // 来 row13
        status_font_rom[12'd1326] = 16'h318c; // 来 row14
        status_font_rom[12'd1327] = 16'h4182; // 来 row15
        status_font_rom[12'd1328] = 16'h0000; // 源 row0
        status_font_rom[12'd1329] = 16'h0000; // 源 row1
        status_font_rom[12'd1330] = 16'h37fe; // 源 row2
        status_font_rom[12'd1331] = 16'h1e20; // 源 row3
        status_font_rom[12'd1332] = 16'h0620; // 源 row4
        status_font_rom[12'd1333] = 16'h06fc; // 源 row5
        status_font_rom[12'd1334] = 16'h4686; // 源 row6
        status_font_rom[12'd1335] = 16'h6686; // 源 row7
        status_font_rom[12'd1336] = 16'h16fe; // 源 row8
        status_font_rom[12'd1337] = 16'h0486; // 源 row9
        status_font_rom[12'd1338] = 16'h04fe; // 源 row10
        status_font_rom[12'd1339] = 16'h1420; // 源 row11
        status_font_rom[12'd1340] = 16'h14a4; // 源 row12
        status_font_rom[12'd1341] = 16'h25a4; // 源 row13
        status_font_rom[12'd1342] = 16'h2d22; // 源 row14
        status_font_rom[12'd1343] = 16'h6a22; // 源 row15
        status_font_rom[12'd1344] = 16'h0000; // 健 row0
        status_font_rom[12'd1345] = 16'h0000; // 健 row1
        status_font_rom[12'd1346] = 16'h1010; // 健 row2
        status_font_rom[12'd1347] = 16'h177c; // 健 row3
        status_font_rom[12'd1348] = 16'h3214; // 健 row4
        status_font_rom[12'd1349] = 16'h22fe; // 健 row5
        status_font_rom[12'd1350] = 16'h6414; // 健 row6
        status_font_rom[12'd1351] = 16'h677c; // 健 row7
        status_font_rom[12'd1352] = 16'h2110; // 健 row8
        status_font_rom[12'd1353] = 16'h21fc; // 健 row9
        status_font_rom[12'd1354] = 16'h2a10; // 健 row10
        status_font_rom[12'd1355] = 16'h2610; // 健 row11
        status_font_rom[12'd1356] = 16'h26fe; // 健 row12
        status_font_rom[12'd1357] = 16'h2610; // 健 row13
        status_font_rom[12'd1358] = 16'h2580; // 健 row14
        status_font_rom[12'd1359] = 16'h387e; // 健 row15
        status_font_rom[12'd1360] = 16'h0000; // 康 row0
        status_font_rom[12'd1361] = 16'h0080; // 康 row1
        status_font_rom[12'd1362] = 16'h0080; // 康 row2
        status_font_rom[12'd1363] = 16'h3ffe; // 康 row3
        status_font_rom[12'd1364] = 16'h2080; // 康 row4
        status_font_rom[12'd1365] = 16'h2ffc; // 康 row5
        status_font_rom[12'd1366] = 16'h2084; // 康 row6
        status_font_rom[12'd1367] = 16'h3ffe; // 康 row7
        status_font_rom[12'd1368] = 16'h2084; // 康 row8
        status_font_rom[12'd1369] = 16'h2084; // 康 row9
        status_font_rom[12'd1370] = 16'h2ffc; // 康 row10
        status_font_rom[12'd1371] = 16'h28c4; // 康 row11
        status_font_rom[12'd1372] = 16'h26e8; // 康 row12
        status_font_rom[12'd1373] = 16'h63f0; // 康 row13
        status_font_rom[12'd1374] = 16'h4e98; // 康 row14
        status_font_rom[12'd1375] = 16'h5886; // 康 row15
        status_font_rom[12'd1376] = 16'h0000; // 率 row0
        status_font_rom[12'd1377] = 16'h0100; // 率 row1
        status_font_rom[12'd1378] = 16'h0180; // 率 row2
        status_font_rom[12'd1379] = 16'h7ffe; // 率 row3
        status_font_rom[12'd1380] = 16'h0100; // 率 row4
        status_font_rom[12'd1381] = 16'h224c; // 率 row5
        status_font_rom[12'd1382] = 16'h17d8; // 率 row6
        status_font_rom[12'd1383] = 16'h0180; // 率 row7
        status_font_rom[12'd1384] = 16'h0b58; // 率 row8
        status_font_rom[12'd1385] = 16'h37ec; // 率 row9
        status_font_rom[12'd1386] = 16'h0404; // 率 row10
        status_font_rom[12'd1387] = 16'h0180; // 率 row11
        status_font_rom[12'd1388] = 16'h7ffe; // 率 row12
        status_font_rom[12'd1389] = 16'h0180; // 率 row13
        status_font_rom[12'd1390] = 16'h0180; // 率 row14
        status_font_rom[12'd1391] = 16'h0180; // 率 row15
        status_font_rom[12'd1392] = 16'h0000; // 命 row0
        status_font_rom[12'd1393] = 16'h0080; // 命 row1
        status_font_rom[12'd1394] = 16'h0180; // 命 row2
        status_font_rom[12'd1395] = 16'h03c0; // 命 row3
        status_font_rom[12'd1396] = 16'h0660; // 命 row4
        status_font_rom[12'd1397] = 16'h1c38; // 命 row5
        status_font_rom[12'd1398] = 16'h77ee; // 命 row6
        status_font_rom[12'd1399] = 16'h0000; // 命 row7
        status_font_rom[12'd1400] = 16'h3e7c; // 命 row8
        status_font_rom[12'd1401] = 16'h2244; // 命 row9
        status_font_rom[12'd1402] = 16'h2244; // 命 row10
        status_font_rom[12'd1403] = 16'h2244; // 命 row11
        status_font_rom[12'd1404] = 16'h2244; // 命 row12
        status_font_rom[12'd1405] = 16'h3e5c; // 命 row13
        status_font_rom[12'd1406] = 16'h2040; // 命 row14
        status_font_rom[12'd1407] = 16'h0040; // 命 row15
        status_font_rom[12'd1408] = 16'h0000; // 中 row0
        status_font_rom[12'd1409] = 16'h0100; // 中 row1
        status_font_rom[12'd1410] = 16'h0180; // 中 row2
        status_font_rom[12'd1411] = 16'h0180; // 中 row3
        status_font_rom[12'd1412] = 16'h3ffc; // 中 row4
        status_font_rom[12'd1413] = 16'h2184; // 中 row5
        status_font_rom[12'd1414] = 16'h2184; // 中 row6
        status_font_rom[12'd1415] = 16'h2184; // 中 row7
        status_font_rom[12'd1416] = 16'h2184; // 中 row8
        status_font_rom[12'd1417] = 16'h2184; // 中 row9
        status_font_rom[12'd1418] = 16'h3ffc; // 中 row10
        status_font_rom[12'd1419] = 16'h2184; // 中 row11
        status_font_rom[12'd1420] = 16'h0180; // 中 row12
        status_font_rom[12'd1421] = 16'h0180; // 中 row13
        status_font_rom[12'd1422] = 16'h0180; // 中 row14
        status_font_rom[12'd1423] = 16'h0180; // 中 row15
        status_font_rom[12'd1424] = 16'h0000; // 退 row0
        status_font_rom[12'd1425] = 16'h0000; // 退 row1
        status_font_rom[12'd1426] = 16'h23fc; // 退 row2
        status_font_rom[12'd1427] = 16'h320c; // 退 row3
        status_font_rom[12'd1428] = 16'h120c; // 退 row4
        status_font_rom[12'd1429] = 16'h03fc; // 退 row5
        status_font_rom[12'd1430] = 16'h020c; // 退 row6
        status_font_rom[12'd1431] = 16'h73fc; // 退 row7
        status_font_rom[12'd1432] = 16'h1204; // 退 row8
        status_font_rom[12'd1433] = 16'h126c; // 退 row9
        status_font_rom[12'd1434] = 16'h1238; // 退 row10
        status_font_rom[12'd1435] = 16'h1208; // 退 row11
        status_font_rom[12'd1436] = 16'h13c4; // 退 row12
        status_font_rom[12'd1437] = 16'h1200; // 退 row13
        status_font_rom[12'd1438] = 16'h2c00; // 退 row14
        status_font_rom[12'd1439] = 16'h43fe; // 退 row15
        status_font_rom[12'd1440] = 16'h0000; // 出 row0
        status_font_rom[12'd1441] = 16'h0100; // 出 row1
        status_font_rom[12'd1442] = 16'h0180; // 出 row2
        status_font_rom[12'd1443] = 16'h318c; // 出 row3
        status_font_rom[12'd1444] = 16'h318c; // 出 row4
        status_font_rom[12'd1445] = 16'h318c; // 出 row5
        status_font_rom[12'd1446] = 16'h318c; // 出 row6
        status_font_rom[12'd1447] = 16'h3ffc; // 出 row7
        status_font_rom[12'd1448] = 16'h0180; // 出 row8
        status_font_rom[12'd1449] = 16'h2184; // 出 row9
        status_font_rom[12'd1450] = 16'h2184; // 出 row10
        status_font_rom[12'd1451] = 16'h2184; // 出 row11
        status_font_rom[12'd1452] = 16'h2184; // 出 row12
        status_font_rom[12'd1453] = 16'h2184; // 出 row13
        status_font_rom[12'd1454] = 16'h2184; // 出 row14
        status_font_rom[12'd1455] = 16'h3ffc; // 出 row15
        status_font_rom[12'd1456] = 16'h0000; // 张 row0
        status_font_rom[12'd1457] = 16'h0000; // 张 row1
        status_font_rom[12'd1458] = 16'h3c84; // 张 row2
        status_font_rom[12'd1459] = 16'h048c; // 张 row3
        status_font_rom[12'd1460] = 16'h0488; // 张 row4
        status_font_rom[12'd1461] = 16'h0490; // 张 row5
        status_font_rom[12'd1462] = 16'h3cb0; // 张 row6
        status_font_rom[12'd1463] = 16'h2080; // 张 row7
        status_font_rom[12'd1464] = 16'h23fe; // 张 row8
        status_font_rom[12'd1465] = 16'h2090; // 张 row9
        status_font_rom[12'd1466] = 16'h3c90; // 张 row10
        status_font_rom[12'd1467] = 16'h0490; // 张 row11
        status_font_rom[12'd1468] = 16'h0488; // 张 row12
        status_font_rom[12'd1469] = 16'h0c88; // 张 row13
        status_font_rom[12'd1470] = 16'h0c84; // 张 row14
        status_font_rom[12'd1471] = 16'h08e6; // 张 row15
        status_font_rom[12'd1472] = 16'h0000; // 系 row0
        status_font_rom[12'd1473] = 16'h0000; // 系 row1
        status_font_rom[12'd1474] = 16'h01f8; // 系 row2
        status_font_rom[12'd1475] = 16'h3f80; // 系 row3
        status_font_rom[12'd1476] = 16'h0200; // 系 row4
        status_font_rom[12'd1477] = 16'h0c60; // 系 row5
        status_font_rom[12'd1478] = 16'h1fc0; // 系 row6
        status_font_rom[12'd1479] = 16'h0310; // 系 row7
        status_font_rom[12'd1480] = 16'h0618; // 系 row8
        status_font_rom[12'd1481] = 16'h1ffc; // 系 row9
        status_font_rom[12'd1482] = 16'h3984; // 系 row10
        status_font_rom[12'd1483] = 16'h0080; // 系 row11
        status_font_rom[12'd1484] = 16'h0898; // 系 row12
        status_font_rom[12'd1485] = 16'h108c; // 系 row13
        status_font_rom[12'd1486] = 16'h6086; // 系 row14
        status_font_rom[12'd1487] = 16'h0700; // 系 row15
        status_font_rom[12'd1488] = 16'h0000; // 统 row0
        status_font_rom[12'd1489] = 16'h0020; // 统 row1
        status_font_rom[12'd1490] = 16'h1820; // 统 row2
        status_font_rom[12'd1491] = 16'h1020; // 统 row3
        status_font_rom[12'd1492] = 16'h31fe; // 统 row4
        status_font_rom[12'd1493] = 16'h2440; // 统 row5
        status_font_rom[12'd1494] = 16'h6cc8; // 统 row6
        status_font_rom[12'd1495] = 16'h798c; // 统 row7
        status_font_rom[12'd1496] = 16'h13fe; // 统 row8
        status_font_rom[12'd1497] = 16'h3082; // 统 row9
        status_font_rom[12'd1498] = 16'h7c90; // 统 row10
        status_font_rom[12'd1499] = 16'h6090; // 统 row11
        status_font_rom[12'd1500] = 16'h0090; // 统 row12
        status_font_rom[12'd1501] = 16'h1d92; // 统 row13
        status_font_rom[12'd1502] = 16'h7112; // 统 row14
        status_font_rom[12'd1503] = 16'h061e; // 统 row15
        status_font_rom[12'd1504] = 16'h0000; // 拨 row0
        status_font_rom[12'd1505] = 16'h1020; // 拨 row1
        status_font_rom[12'd1506] = 16'h112c; // 拨 row2
        status_font_rom[12'd1507] = 16'h1124; // 拨 row3
        status_font_rom[12'd1508] = 16'h1160; // 拨 row4
        status_font_rom[12'd1509] = 16'h7bfe; // 拨 row5
        status_font_rom[12'd1510] = 16'h1040; // 拨 row6
        status_font_rom[12'd1511] = 16'h10c0; // 拨 row7
        status_font_rom[12'd1512] = 16'h10fc; // 拨 row8
        status_font_rom[12'd1513] = 16'h3884; // 拨 row9
        status_font_rom[12'd1514] = 16'h71cc; // 拨 row10
        status_font_rom[12'd1515] = 16'h1148; // 拨 row11
        status_font_rom[12'd1516] = 16'h1230; // 拨 row12
        status_font_rom[12'd1517] = 16'h1630; // 拨 row13
        status_font_rom[12'd1518] = 16'h1478; // 拨 row14
        status_font_rom[12'd1519] = 16'h11cc; // 拨 row15
        status_font_rom[12'd1520] = 16'h0000; // 下 row0
        status_font_rom[12'd1521] = 16'h0000; // 下 row1
        status_font_rom[12'd1522] = 16'h0000; // 下 row2
        status_font_rom[12'd1523] = 16'h7ffe; // 下 row3
        status_font_rom[12'd1524] = 16'h0100; // 下 row4
        status_font_rom[12'd1525] = 16'h0100; // 下 row5
        status_font_rom[12'd1526] = 16'h0100; // 下 row6
        status_font_rom[12'd1527] = 16'h01c0; // 下 row7
        status_font_rom[12'd1528] = 16'h0170; // 下 row8
        status_font_rom[12'd1529] = 16'h0118; // 下 row9
        status_font_rom[12'd1530] = 16'h010c; // 下 row10
        status_font_rom[12'd1531] = 16'h0100; // 下 row11
        status_font_rom[12'd1532] = 16'h0100; // 下 row12
        status_font_rom[12'd1533] = 16'h0100; // 下 row13
        status_font_rom[12'd1534] = 16'h0100; // 下 row14
        status_font_rom[12'd1535] = 16'h0100; // 下 row15
        status_font_rom[12'd1536] = 16'h0000; // 标 row0
        status_font_rom[12'd1537] = 16'h0000; // 标 row1
        status_font_rom[12'd1538] = 16'h1000; // 标 row2
        status_font_rom[12'd1539] = 16'h11fc; // 标 row3
        status_font_rom[12'd1540] = 16'h1000; // 标 row4
        status_font_rom[12'd1541] = 16'h7c00; // 标 row5
        status_font_rom[12'd1542] = 16'h1000; // 标 row6
        status_font_rom[12'd1543] = 16'h19fe; // 标 row7
        status_font_rom[12'd1544] = 16'h3c20; // 标 row8
        status_font_rom[12'd1545] = 16'h3420; // 标 row9
        status_font_rom[12'd1546] = 16'h70a4; // 标 row10
        status_font_rom[12'd1547] = 16'h51a4; // 标 row11
        status_font_rom[12'd1548] = 16'h5124; // 标 row12
        status_font_rom[12'd1549] = 16'h1122; // 标 row13
        status_font_rom[12'd1550] = 16'h1222; // 标 row14
        status_font_rom[12'd1551] = 16'h1020; // 标 row15
        status_font_rom[12'd1552] = 16'h0000; // 准 row0
        status_font_rom[12'd1553] = 16'h0120; // 准 row1
        status_font_rom[12'd1554] = 16'h4120; // 准 row2
        status_font_rom[12'd1555] = 16'h2210; // 准 row3
        status_font_rom[12'd1556] = 16'h33fe; // 准 row4
        status_font_rom[12'd1557] = 16'h1630; // 准 row5
        status_font_rom[12'd1558] = 16'h0620; // 准 row6
        status_font_rom[12'd1559] = 16'h0e30; // 准 row7
        status_font_rom[12'd1560] = 16'h0bfe; // 准 row8
        status_font_rom[12'd1561] = 16'h0220; // 准 row9
        status_font_rom[12'd1562] = 16'h1220; // 准 row10
        status_font_rom[12'd1563] = 16'h13fe; // 准 row11
        status_font_rom[12'd1564] = 16'h2230; // 准 row12
        status_font_rom[12'd1565] = 16'h2220; // 准 row13
        status_font_rom[12'd1566] = 16'h63fe; // 准 row14
        status_font_rom[12'd1567] = 16'h0200; // 准 row15
        status_font_rom[12'd1568] = 16'h0000; // 牌 row0
        status_font_rom[12'd1569] = 16'h0820; // 牌 row1
        status_font_rom[12'd1570] = 16'h2820; // 牌 row2
        status_font_rom[12'd1571] = 16'h29fe; // 牌 row3
        status_font_rom[12'd1572] = 16'h2922; // 牌 row4
        status_font_rom[12'd1573] = 16'h2922; // 牌 row5
        status_font_rom[12'd1574] = 16'h3ffe; // 牌 row6
        status_font_rom[12'd1575] = 16'h2122; // 牌 row7
        status_font_rom[12'd1576] = 16'h21fe; // 牌 row8
        status_font_rom[12'd1577] = 16'h2040; // 牌 row9
        status_font_rom[12'd1578] = 16'h3cc8; // 牌 row10
        status_font_rom[12'd1579] = 16'h2508; // 牌 row11
        status_font_rom[12'd1580] = 16'h67fe; // 牌 row12
        status_font_rom[12'd1581] = 16'h4408; // 牌 row13
        status_font_rom[12'd1582] = 16'h4408; // 牌 row14
        status_font_rom[12'd1583] = 16'h4408; // 牌 row15
        status_font_rom[12'd1584] = 16'h0000; // 型 row0
        status_font_rom[12'd1585] = 16'h0004; // 型 row1
        status_font_rom[12'd1586] = 16'h3fa4; // 型 row2
        status_font_rom[12'd1587] = 16'h1224; // 型 row3
        status_font_rom[12'd1588] = 16'h1224; // 型 row4
        status_font_rom[12'd1589] = 16'h7fa4; // 型 row5
        status_font_rom[12'd1590] = 16'h1224; // 型 row6
        status_font_rom[12'd1591] = 16'h1204; // 型 row7
        status_font_rom[12'd1592] = 16'h2204; // 型 row8
        status_font_rom[12'd1593] = 16'h631c; // 型 row9
        status_font_rom[12'd1594] = 16'h0180; // 型 row10
        status_font_rom[12'd1595] = 16'h0180; // 型 row11
        status_font_rom[12'd1596] = 16'h3ffc; // 型 row12
        status_font_rom[12'd1597] = 16'h0180; // 型 row13
        status_font_rom[12'd1598] = 16'h0180; // 型 row14
        status_font_rom[12'd1599] = 16'h7ffe; // 型 row15
        status_font_rom[12'd1600] = 16'h0000; // 号 row0
        status_font_rom[12'd1601] = 16'h0000; // 号 row1
        status_font_rom[12'd1602] = 16'h1ff8; // 号 row2
        status_font_rom[12'd1603] = 16'h1008; // 号 row3
        status_font_rom[12'd1604] = 16'h1008; // 号 row4
        status_font_rom[12'd1605] = 16'h1ff8; // 号 row5
        status_font_rom[12'd1606] = 16'h0000; // 号 row6
        status_font_rom[12'd1607] = 16'h0000; // 号 row7
        status_font_rom[12'd1608] = 16'h7ffe; // 号 row8
        status_font_rom[12'd1609] = 16'h0c00; // 号 row9
        status_font_rom[12'd1610] = 16'h0800; // 号 row10
        status_font_rom[12'd1611] = 16'h0ff8; // 号 row11
        status_font_rom[12'd1612] = 16'h0018; // 号 row12
        status_font_rom[12'd1613] = 16'h0018; // 号 row13
        status_font_rom[12'd1614] = 16'h0010; // 号 row14
        status_font_rom[12'd1615] = 16'h0010; // 号 row15
        status_font_rom[12'd1616] = 16'h0000; // 固 row0
        status_font_rom[12'd1617] = 16'h0000; // 固 row1
        status_font_rom[12'd1618] = 16'h7ffe; // 固 row2
        status_font_rom[12'd1619] = 16'h6006; // 固 row3
        status_font_rom[12'd1620] = 16'h6186; // 固 row4
        status_font_rom[12'd1621] = 16'h6186; // 固 row5
        status_font_rom[12'd1622] = 16'h6ff6; // 固 row6
        status_font_rom[12'd1623] = 16'h6186; // 固 row7
        status_font_rom[12'd1624] = 16'h6186; // 固 row8
        status_font_rom[12'd1625] = 16'h67e6; // 固 row9
        status_font_rom[12'd1626] = 16'h6426; // 固 row10
        status_font_rom[12'd1627] = 16'h6426; // 固 row11
        status_font_rom[12'd1628] = 16'h67e6; // 固 row12
        status_font_rom[12'd1629] = 16'h6006; // 固 row13
        status_font_rom[12'd1630] = 16'h6006; // 固 row14
        status_font_rom[12'd1631] = 16'h7ffe; // 固 row15
        status_font_rom[12'd1632] = 16'h0000; // 件 row0
        status_font_rom[12'd1633] = 16'h0000; // 件 row1
        status_font_rom[12'd1634] = 16'h0920; // 件 row2
        status_font_rom[12'd1635] = 16'h1920; // 件 row3
        status_font_rom[12'd1636] = 16'h1320; // 件 row4
        status_font_rom[12'd1637] = 16'h33fc; // 件 row5
        status_font_rom[12'd1638] = 16'h3220; // 件 row6
        status_font_rom[12'd1639] = 16'h7420; // 件 row7
        status_font_rom[12'd1640] = 16'h5020; // 件 row8
        status_font_rom[12'd1641] = 16'h1020; // 件 row9
        status_font_rom[12'd1642] = 16'h17fe; // 件 row10
        status_font_rom[12'd1643] = 16'h1020; // 件 row11
        status_font_rom[12'd1644] = 16'h1020; // 件 row12
        status_font_rom[12'd1645] = 16'h1020; // 件 row13
        status_font_rom[12'd1646] = 16'h1020; // 件 row14
        status_font_rom[12'd1647] = 16'h1020; // 件 row15
        status_font_rom[12'd1648] = 16'h0000; // 插 row0
        status_font_rom[12'd1649] = 16'h100c; // 插 row1
        status_font_rom[12'd1650] = 16'h11f0; // 插 row2
        status_font_rom[12'd1651] = 16'h1020; // 插 row3
        status_font_rom[12'd1652] = 16'h1020; // 插 row4
        status_font_rom[12'd1653] = 16'h7bfe; // 插 row5
        status_font_rom[12'd1654] = 16'h1020; // 插 row6
        status_font_rom[12'd1655] = 16'h1020; // 插 row7
        status_font_rom[12'd1656] = 16'h13ae; // 插 row8
        status_font_rom[12'd1657] = 16'h3a26; // 插 row9
        status_font_rom[12'd1658] = 16'h7222; // 插 row10
        status_font_rom[12'd1659] = 16'h13ae; // 插 row11
        status_font_rom[12'd1660] = 16'h1222; // 插 row12
        status_font_rom[12'd1661] = 16'h1222; // 插 row13
        status_font_rom[12'd1662] = 16'h1226; // 插 row14
        status_font_rom[12'd1663] = 16'h13fe; // 插 row15
        status_font_rom[12'd1664] = 16'h0000; // 即 row0
        status_font_rom[12'd1665] = 16'h0000; // 即 row1
        status_font_rom[12'd1666] = 16'h3f7e; // 即 row2
        status_font_rom[12'd1667] = 16'h2166; // 即 row3
        status_font_rom[12'd1668] = 16'h2166; // 即 row4
        status_font_rom[12'd1669] = 16'h2166; // 即 row5
        status_font_rom[12'd1670] = 16'h3f66; // 即 row6
        status_font_rom[12'd1671] = 16'h2166; // 即 row7
        status_font_rom[12'd1672] = 16'h2166; // 即 row8
        status_font_rom[12'd1673] = 16'h3f66; // 即 row9
        status_font_rom[12'd1674] = 16'h2066; // 即 row10
        status_font_rom[12'd1675] = 16'h2466; // 即 row11
        status_font_rom[12'd1676] = 16'h227c; // 即 row12
        status_font_rom[12'd1677] = 16'h2f60; // 即 row13
        status_font_rom[12'd1678] = 16'h7960; // 即 row14
        status_font_rom[12'd1679] = 16'h6160; // 即 row15
        status_font_rom[12'd1680] = 16'h0000; // 人 row0
        status_font_rom[12'd1681] = 16'h0000; // 人 row1
        status_font_rom[12'd1682] = 16'h0180; // 人 row2
        status_font_rom[12'd1683] = 16'h0180; // 人 row3
        status_font_rom[12'd1684] = 16'h0180; // 人 row4
        status_font_rom[12'd1685] = 16'h0180; // 人 row5
        status_font_rom[12'd1686] = 16'h0180; // 人 row6
        status_font_rom[12'd1687] = 16'h0180; // 人 row7
        status_font_rom[12'd1688] = 16'h03c0; // 人 row8
        status_font_rom[12'd1689] = 16'h0240; // 人 row9
        status_font_rom[12'd1690] = 16'h0240; // 人 row10
        status_font_rom[12'd1691] = 16'h0620; // 人 row11
        status_font_rom[12'd1692] = 16'h0c30; // 人 row12
        status_font_rom[12'd1693] = 16'h0818; // 人 row13
        status_font_rom[12'd1694] = 16'h300c; // 人 row14
        status_font_rom[12'd1695] = 16'h6006; // 人 row15
        status_font_rom[12'd1696] = 16'h0000; // 值 row0
        status_font_rom[12'd1697] = 16'h0820; // 值 row1
        status_font_rom[12'd1698] = 16'h0860; // 值 row2
        status_font_rom[12'd1699] = 16'h1ffe; // 值 row3
        status_font_rom[12'd1700] = 16'h1040; // 值 row4
        status_font_rom[12'd1701] = 16'h3040; // 值 row5
        status_font_rom[12'd1702] = 16'h33fc; // 值 row6
        status_font_rom[12'd1703] = 16'h7204; // 值 row7
        status_font_rom[12'd1704] = 16'h53fc; // 值 row8
        status_font_rom[12'd1705] = 16'h1204; // 值 row9
        status_font_rom[12'd1706] = 16'h13fc; // 值 row10
        status_font_rom[12'd1707] = 16'h1204; // 值 row11
        status_font_rom[12'd1708] = 16'h1204; // 值 row12
        status_font_rom[12'd1709] = 16'h13fc; // 值 row13
        status_font_rom[12'd1710] = 16'h1204; // 值 row14
        status_font_rom[12'd1711] = 16'h17fe; // 值 row15
        status_font_rom[12'd1712] = 16'h0000; // 守 row0
        status_font_rom[12'd1713] = 16'h0100; // 守 row1
        status_font_rom[12'd1714] = 16'h0180; // 守 row2
        status_font_rom[12'd1715] = 16'h7ffe; // 守 row3
        status_font_rom[12'd1716] = 16'h6006; // 守 row4
        status_font_rom[12'd1717] = 16'h6026; // 守 row5
        status_font_rom[12'd1718] = 16'h0020; // 守 row6
        status_font_rom[12'd1719] = 16'h0020; // 守 row7
        status_font_rom[12'd1720] = 16'h7ffe; // 守 row8
        status_font_rom[12'd1721] = 16'h0020; // 守 row9
        status_font_rom[12'd1722] = 16'h1020; // 守 row10
        status_font_rom[12'd1723] = 16'h0820; // 守 row11
        status_font_rom[12'd1724] = 16'h0c20; // 守 row12
        status_font_rom[12'd1725] = 16'h0420; // 守 row13
        status_font_rom[12'd1726] = 16'h0020; // 守 row14
        status_font_rom[12'd1727] = 16'h0020; // 守 row15
        status_font_rom[12'd1728] = 16'h0000; // 储 row0
        status_font_rom[12'd1729] = 16'h0020; // 储 row1
        status_font_rom[12'd1730] = 16'h1422; // 储 row2
        status_font_rom[12'd1731] = 16'h16fc; // 储 row3
        status_font_rom[12'd1732] = 16'h2224; // 储 row4
        status_font_rom[12'd1733] = 16'h2028; // 储 row5
        status_font_rom[12'd1734] = 16'h60fe; // 储 row6
        status_font_rom[12'd1735] = 16'h6e30; // 储 row7
        status_font_rom[12'd1736] = 16'h2260; // 储 row8
        status_font_rom[12'd1737] = 16'h22fe; // 储 row9
        status_font_rom[12'd1738] = 16'h23c2; // 储 row10
        status_font_rom[12'd1739] = 16'h2242; // 储 row11
        status_font_rom[12'd1740] = 16'h227e; // 储 row12
        status_font_rom[12'd1741] = 16'h2242; // 储 row13
        status_font_rom[12'd1742] = 16'h2742; // 储 row14
        status_font_rom[12'd1743] = 16'h267e; // 储 row15
        status_font_rom[12'd1744] = 16'h0000; // 开 row0
        status_font_rom[12'd1745] = 16'h0000; // 开 row1
        status_font_rom[12'd1746] = 16'h7ffe; // 开 row2
        status_font_rom[12'd1747] = 16'h0430; // 开 row3
        status_font_rom[12'd1748] = 16'h0430; // 开 row4
        status_font_rom[12'd1749] = 16'h0430; // 开 row5
        status_font_rom[12'd1750] = 16'h0430; // 开 row6
        status_font_rom[12'd1751] = 16'h0430; // 开 row7
        status_font_rom[12'd1752] = 16'h7ffe; // 开 row8
        status_font_rom[12'd1753] = 16'h0c30; // 开 row9
        status_font_rom[12'd1754] = 16'h0c30; // 开 row10
        status_font_rom[12'd1755] = 16'h0830; // 开 row11
        status_font_rom[12'd1756] = 16'h0830; // 开 row12
        status_font_rom[12'd1757] = 16'h1830; // 开 row13
        status_font_rom[12'd1758] = 16'h3030; // 开 row14
        status_font_rom[12'd1759] = 16'h6030; // 开 row15
        status_font_rom[12'd1760] = 16'h0000; // 机 row0
        status_font_rom[12'd1761] = 16'h0800; // 机 row1
        status_font_rom[12'd1762] = 16'h08f8; // 机 row2
        status_font_rom[12'd1763] = 16'h0888; // 机 row3
        status_font_rom[12'd1764] = 16'h1888; // 机 row4
        status_font_rom[12'd1765] = 16'h7e88; // 机 row5
        status_font_rom[12'd1766] = 16'h1888; // 机 row6
        status_font_rom[12'd1767] = 16'h1888; // 机 row7
        status_font_rom[12'd1768] = 16'h3c88; // 机 row8
        status_font_rom[12'd1769] = 16'h3c88; // 机 row9
        status_font_rom[12'd1770] = 16'h2a88; // 机 row10
        status_font_rom[12'd1771] = 16'h4888; // 机 row11
        status_font_rom[12'd1772] = 16'h4908; // 机 row12
        status_font_rom[12'd1773] = 16'h0909; // 机 row13
        status_font_rom[12'd1774] = 16'h0b09; // 机 row14
        status_font_rom[12'd1775] = 16'h0a0e; // 机 row15
        status_font_rom[12'd1776] = 16'h0000; // 挂 row0
        status_font_rom[12'd1777] = 16'h1020; // 挂 row1
        status_font_rom[12'd1778] = 16'h1020; // 挂 row2
        status_font_rom[12'd1779] = 16'h1020; // 挂 row3
        status_font_rom[12'd1780] = 16'h11fc; // 挂 row4
        status_font_rom[12'd1781] = 16'h7c20; // 挂 row5
        status_font_rom[12'd1782] = 16'h1020; // 挂 row6
        status_font_rom[12'd1783] = 16'h13fe; // 挂 row7
        status_font_rom[12'd1784] = 16'h1000; // 挂 row8
        status_font_rom[12'd1785] = 16'h1c20; // 挂 row9
        status_font_rom[12'd1786] = 16'h7020; // 挂 row10
        status_font_rom[12'd1787] = 16'h13fe; // 挂 row11
        status_font_rom[12'd1788] = 16'h1020; // 挂 row12
        status_font_rom[12'd1789] = 16'h1020; // 挂 row13
        status_font_rom[12'd1790] = 16'h1020; // 挂 row14
        status_font_rom[12'd1791] = 16'h17fe; // 挂 row15
        status_font_rom[12'd1792] = 16'h0000; // 环 row0
        status_font_rom[12'd1793] = 16'h0000; // 环 row1
        status_font_rom[12'd1794] = 16'h7bfe; // 环 row2
        status_font_rom[12'd1795] = 16'h1030; // 环 row3
        status_font_rom[12'd1796] = 16'h1020; // 环 row4
        status_font_rom[12'd1797] = 16'h1060; // 环 row5
        status_font_rom[12'd1798] = 16'h1070; // 环 row6
        status_font_rom[12'd1799] = 16'h78f8; // 环 row7
        status_font_rom[12'd1800] = 16'h10ec; // 环 row8
        status_font_rom[12'd1801] = 16'h1124; // 环 row9
        status_font_rom[12'd1802] = 16'h1326; // 环 row10
        status_font_rom[12'd1803] = 16'h1020; // 环 row11
        status_font_rom[12'd1804] = 16'h1820; // 环 row12
        status_font_rom[12'd1805] = 16'h7020; // 环 row13
        status_font_rom[12'd1806] = 16'h4020; // 环 row14
        status_font_rom[12'd1807] = 16'h0020; // 环 row15
        status_font_rom[12'd1808] = 16'h0000; // 回 row0
        status_font_rom[12'd1809] = 16'h0000; // 回 row1
        status_font_rom[12'd1810] = 16'h7ffe; // 回 row2
        status_font_rom[12'd1811] = 16'h6006; // 回 row3
        status_font_rom[12'd1812] = 16'h6006; // 回 row4
        status_font_rom[12'd1813] = 16'h6006; // 回 row5
        status_font_rom[12'd1814] = 16'h67e6; // 回 row6
        status_font_rom[12'd1815] = 16'h6426; // 回 row7
        status_font_rom[12'd1816] = 16'h6426; // 回 row8
        status_font_rom[12'd1817] = 16'h6426; // 回 row9
        status_font_rom[12'd1818] = 16'h6426; // 回 row10
        status_font_rom[12'd1819] = 16'h67e6; // 回 row11
        status_font_rom[12'd1820] = 16'h6006; // 回 row12
        status_font_rom[12'd1821] = 16'h6006; // 回 row13
        status_font_rom[12'd1822] = 16'h6006; // 回 row14
        status_font_rom[12'd1823] = 16'h7ffe; // 回 row15
        status_font_rom[12'd1824] = 16'h0000; // 锁 row0
        status_font_rom[12'd1825] = 16'h1020; // 锁 row1
        status_font_rom[12'd1826] = 16'h3124; // 锁 row2
        status_font_rom[12'd1827] = 16'h3ea4; // 锁 row3
        status_font_rom[12'd1828] = 16'h40a8; // 锁 row4
        status_font_rom[12'd1829] = 16'h4020; // 锁 row5
        status_font_rom[12'd1830] = 16'h3dfc; // 锁 row6
        status_font_rom[12'd1831] = 16'h1104; // 锁 row7
        status_font_rom[12'd1832] = 16'h1124; // 锁 row8
        status_font_rom[12'd1833] = 16'h1124; // 锁 row9
        status_font_rom[12'd1834] = 16'h7f24; // 锁 row10
        status_font_rom[12'd1835] = 16'h1124; // 锁 row11
        status_font_rom[12'd1836] = 16'h1124; // 锁 row12
        status_font_rom[12'd1837] = 16'h1024; // 锁 row13
        status_font_rom[12'd1838] = 16'h1c58; // 锁 row14
        status_font_rom[12'd1839] = 16'h1986; // 锁 row15
        status_font_rom[12'd1840] = 16'h0000; // 定 row0
        status_font_rom[12'd1841] = 16'h0100; // 定 row1
        status_font_rom[12'd1842] = 16'h0180; // 定 row2
        status_font_rom[12'd1843] = 16'h7ffe; // 定 row3
        status_font_rom[12'd1844] = 16'h6006; // 定 row4
        status_font_rom[12'd1845] = 16'h6006; // 定 row5
        status_font_rom[12'd1846] = 16'h6006; // 定 row6
        status_font_rom[12'd1847] = 16'h1ff8; // 定 row7
        status_font_rom[12'd1848] = 16'h0180; // 定 row8
        status_font_rom[12'd1849] = 16'h0180; // 定 row9
        status_font_rom[12'd1850] = 16'h1980; // 定 row10
        status_font_rom[12'd1851] = 16'h19f8; // 定 row11
        status_font_rom[12'd1852] = 16'h1980; // 定 row12
        status_font_rom[12'd1853] = 16'h3d80; // 定 row13
        status_font_rom[12'd1854] = 16'h2780; // 定 row14
        status_font_rom[12'd1855] = 16'h61fe; // 定 row15
        status_font_rom[12'd1856] = 16'h0000; // 扫 row0
        status_font_rom[12'd1857] = 16'h1000; // 扫 row1
        status_font_rom[12'd1858] = 16'h1000; // 扫 row2
        status_font_rom[12'd1859] = 16'h11fc; // 扫 row3
        status_font_rom[12'd1860] = 16'h1004; // 扫 row4
        status_font_rom[12'd1861] = 16'h7c04; // 扫 row5
        status_font_rom[12'd1862] = 16'h1004; // 扫 row6
        status_font_rom[12'd1863] = 16'h1004; // 扫 row7
        status_font_rom[12'd1864] = 16'h11fc; // 扫 row8
        status_font_rom[12'd1865] = 16'h3c04; // 扫 row9
        status_font_rom[12'd1866] = 16'h7004; // 扫 row10
        status_font_rom[12'd1867] = 16'h1004; // 扫 row11
        status_font_rom[12'd1868] = 16'h1004; // 扫 row12
        status_font_rom[12'd1869] = 16'h1004; // 扫 row13
        status_font_rom[12'd1870] = 16'h11fc; // 扫 row14
        status_font_rom[12'd1871] = 16'h1004; // 扫 row15
        status_font_rom[12'd1872] = 16'h0000; // 描 row0
        status_font_rom[12'd1873] = 16'h1088; // 描 row1
        status_font_rom[12'd1874] = 16'h1088; // 描 row2
        status_font_rom[12'd1875] = 16'h1088; // 描 row3
        status_font_rom[12'd1876] = 16'h13fe; // 描 row4
        status_font_rom[12'd1877] = 16'h7888; // 描 row5
        status_font_rom[12'd1878] = 16'h1088; // 描 row6
        status_font_rom[12'd1879] = 16'h1000; // 描 row7
        status_font_rom[12'd1880] = 16'h13fe; // 描 row8
        status_font_rom[12'd1881] = 16'h3b26; // 描 row9
        status_font_rom[12'd1882] = 16'h7326; // 描 row10
        status_font_rom[12'd1883] = 16'h13fe; // 描 row11
        status_font_rom[12'd1884] = 16'h1326; // 描 row12
        status_font_rom[12'd1885] = 16'h1326; // 描 row13
        status_font_rom[12'd1886] = 16'h1326; // 描 row14
        status_font_rom[12'd1887] = 16'h13fe; // 描 row15
        status_font_rom[12'd1888] = 16'h0000; // 参 row0
        status_font_rom[12'd1889] = 16'h0000; // 参 row1
        status_font_rom[12'd1890] = 16'h0620; // 参 row2
        status_font_rom[12'd1891] = 16'h0c10; // 参 row3
        status_font_rom[12'd1892] = 16'h1ffc; // 参 row4
        status_font_rom[12'd1893] = 16'h0304; // 参 row5
        status_font_rom[12'd1894] = 16'h0200; // 参 row6
        status_font_rom[12'd1895] = 16'h7ffe; // 参 row7
        status_font_rom[12'd1896] = 16'h0c30; // 参 row8
        status_font_rom[12'd1897] = 16'h1898; // 参 row9
        status_font_rom[12'd1898] = 16'h3f0c; // 参 row10
        status_font_rom[12'd1899] = 16'h6062; // 参 row11
        status_font_rom[12'd1900] = 16'h0380; // 参 row12
        status_font_rom[12'd1901] = 16'h0c18; // 参 row13
        status_font_rom[12'd1902] = 16'h0060; // 参 row14
        status_font_rom[12'd1903] = 16'h0780; // 参 row15
        status_font_rom[12'd1904] = 16'h0000; // 数 row0
        status_font_rom[12'd1905] = 16'h0800; // 数 row1
        status_font_rom[12'd1906] = 16'h2b20; // 数 row2
        status_font_rom[12'd1907] = 16'h2a20; // 数 row3
        status_font_rom[12'd1908] = 16'h7f60; // 数 row4
        status_font_rom[12'd1909] = 16'h1c7e; // 数 row5
        status_font_rom[12'd1910] = 16'h1b44; // 数 row6
        status_font_rom[12'd1911] = 16'h6964; // 数 row7
        status_font_rom[12'd1912] = 16'h40ac; // 数 row8
        status_font_rom[12'd1913] = 16'h08a8; // 数 row9
        status_font_rom[12'd1914] = 16'h7f38; // 数 row10
        status_font_rom[12'd1915] = 16'h1218; // 数 row11
        status_font_rom[12'd1916] = 16'h3218; // 数 row12
        status_font_rom[12'd1917] = 16'h1c38; // 数 row13
        status_font_rom[12'd1918] = 16'h1e6c; // 数 row14
        status_font_rom[12'd1919] = 16'h70c6; // 数 row15
        status_font_rom[12'd1920] = 16'h0000; // 就 row0
        status_font_rom[12'd1921] = 16'h0800; // 就 row1
        status_font_rom[12'd1922] = 16'h0814; // 就 row2
        status_font_rom[12'd1923] = 16'h7f34; // 就 row3
        status_font_rom[12'd1924] = 16'h0030; // 就 row4
        status_font_rom[12'd1925] = 16'h0030; // 就 row5
        status_font_rom[12'd1926] = 16'h3ffe; // 就 row6
        status_font_rom[12'd1927] = 16'h2320; // 就 row7
        status_font_rom[12'd1928] = 16'h2338; // 就 row8
        status_font_rom[12'd1929] = 16'h3e38; // 就 row9
        status_font_rom[12'd1930] = 16'h0838; // 就 row10
        status_font_rom[12'd1931] = 16'h2a28; // 就 row11
        status_font_rom[12'd1932] = 16'h2b48; // 就 row12
        status_font_rom[12'd1933] = 16'h4948; // 就 row13
        status_font_rom[12'd1934] = 16'h48ca; // 就 row14
        status_font_rom[12'd1935] = 16'h088e; // 就 row15
        status_font_rom[12'd1936] = 16'h0000; // 绪 row0
        status_font_rom[12'd1937] = 16'h0020; // 绪 row1
        status_font_rom[12'd1938] = 16'h1062; // 绪 row2
        status_font_rom[12'd1939] = 16'h11fc; // 绪 row3
        status_font_rom[12'd1940] = 16'h206c; // 绪 row4
        status_font_rom[12'd1941] = 16'h2468; // 绪 row5
        status_font_rom[12'd1942] = 16'h6478; // 绪 row6
        status_font_rom[12'd1943] = 16'h7bfe; // 绪 row7
        status_font_rom[12'd1944] = 16'h1060; // 绪 row8
        status_font_rom[12'd1945] = 16'h30fc; // 绪 row9
        status_font_rom[12'd1946] = 16'h7f84; // 绪 row10
        status_font_rom[12'd1947] = 16'h6084; // 绪 row11
        status_font_rom[12'd1948] = 16'h00fc; // 绪 row12
        status_font_rom[12'd1949] = 16'h0484; // 绪 row13
        status_font_rom[12'd1950] = 16'h7884; // 绪 row14
        status_font_rom[12'd1951] = 16'h40fc; // 绪 row15
        status_font_rom[12'd1952] = 16'h0000; // 查 row0
        status_font_rom[12'd1953] = 16'h0100; // 查 row1
        status_font_rom[12'd1954] = 16'h0180; // 查 row2
        status_font_rom[12'd1955] = 16'h7ffe; // 查 row3
        status_font_rom[12'd1956] = 16'h03c0; // 查 row4
        status_font_rom[12'd1957] = 16'h05a0; // 查 row5
        status_font_rom[12'd1958] = 16'h0db0; // 查 row6
        status_font_rom[12'd1959] = 16'h199c; // 查 row7
        status_font_rom[12'd1960] = 16'h6006; // 查 row8
        status_font_rom[12'd1961] = 16'h0ff0; // 查 row9
        status_font_rom[12'd1962] = 16'h0810; // 查 row10
        status_font_rom[12'd1963] = 16'h0ff0; // 查 row11
        status_font_rom[12'd1964] = 16'h0810; // 查 row12
        status_font_rom[12'd1965] = 16'h0ff0; // 查 row13
        status_font_rom[12'd1966] = 16'h0000; // 查 row14
        status_font_rom[12'd1967] = 16'h7ffe; // 查 row15
        status_font_rom[12'd1968] = 16'h0000; // 通 row0
        status_font_rom[12'd1969] = 16'h0000; // 通 row1
        status_font_rom[12'd1970] = 16'h43fc; // 通 row2
        status_font_rom[12'd1971] = 16'h3008; // 通 row3
        status_font_rom[12'd1972] = 16'h1070; // 通 row4
        status_font_rom[12'd1973] = 16'h03fe; // 通 row5
        status_font_rom[12'd1974] = 16'h0226; // 通 row6
        status_font_rom[12'd1975] = 16'h0226; // 通 row7
        status_font_rom[12'd1976] = 16'h73fe; // 通 row8
        status_font_rom[12'd1977] = 16'h1226; // 通 row9
        status_font_rom[12'd1978] = 16'h13fe; // 通 row10
        status_font_rom[12'd1979] = 16'h1226; // 通 row11
        status_font_rom[12'd1980] = 16'h1226; // 通 row12
        status_font_rom[12'd1981] = 16'h122c; // 通 row13
        status_font_rom[12'd1982] = 16'h6c00; // 通 row14
        status_font_rom[12'd1983] = 16'h43fe; // 通 row15
        status_font_rom[12'd1984] = 16'h0000; // 析 row0
        status_font_rom[12'd1985] = 16'h0000; // 析 row1
        status_font_rom[12'd1986] = 16'h183c; // 析 row2
        status_font_rom[12'd1987] = 16'h18e0; // 析 row3
        status_font_rom[12'd1988] = 16'h1880; // 析 row4
        status_font_rom[12'd1989] = 16'h7e80; // 析 row5
        status_font_rom[12'd1990] = 16'h1880; // 析 row6
        status_font_rom[12'd1991] = 16'h18fe; // 析 row7
        status_font_rom[12'd1992] = 16'h3c88; // 析 row8
        status_font_rom[12'd1993] = 16'h3c88; // 析 row9
        status_font_rom[12'd1994] = 16'h3888; // 析 row10
        status_font_rom[12'd1995] = 16'h5988; // 析 row11
        status_font_rom[12'd1996] = 16'h5988; // 析 row12
        status_font_rom[12'd1997] = 16'h1908; // 析 row13
        status_font_rom[12'd1998] = 16'h1908; // 析 row14
        status_font_rom[12'd1999] = 16'h1b08; // 析 row15
        status_font_rom[12'd2000] = 16'h0000; // 写 row0
        status_font_rom[12'd2001] = 16'h0000; // 写 row1
        status_font_rom[12'd2002] = 16'h7ffe; // 写 row2
        status_font_rom[12'd2003] = 16'h6006; // 写 row3
        status_font_rom[12'd2004] = 16'h4406; // 写 row4
        status_font_rom[12'd2005] = 16'h0c00; // 写 row5
        status_font_rom[12'd2006] = 16'h0ff8; // 写 row6
        status_font_rom[12'd2007] = 16'h0800; // 写 row7
        status_font_rom[12'd2008] = 16'h0800; // 写 row8
        status_font_rom[12'd2009] = 16'h0ff8; // 写 row9
        status_font_rom[12'd2010] = 16'h0008; // 写 row10
        status_font_rom[12'd2011] = 16'h0008; // 写 row11
        status_font_rom[12'd2012] = 16'h3fe8; // 写 row12
        status_font_rom[12'd2013] = 16'h0018; // 写 row13
        status_font_rom[12'd2014] = 16'h0010; // 写 row14
        status_font_rom[12'd2015] = 16'h00f0; // 写 row15
        status_font_rom[12'd2016] = 16'h0000; // 目 row0
        status_font_rom[12'd2017] = 16'h0000; // 目 row1
        status_font_rom[12'd2018] = 16'h1ff8; // 目 row2
        status_font_rom[12'd2019] = 16'h1008; // 目 row3
        status_font_rom[12'd2020] = 16'h1008; // 目 row4
        status_font_rom[12'd2021] = 16'h1008; // 目 row5
        status_font_rom[12'd2022] = 16'h1ff8; // 目 row6
        status_font_rom[12'd2023] = 16'h1008; // 目 row7
        status_font_rom[12'd2024] = 16'h1008; // 目 row8
        status_font_rom[12'd2025] = 16'h1008; // 目 row9
        status_font_rom[12'd2026] = 16'h1ff8; // 目 row10
        status_font_rom[12'd2027] = 16'h1008; // 目 row11
        status_font_rom[12'd2028] = 16'h1008; // 目 row12
        status_font_rom[12'd2029] = 16'h1008; // 目 row13
        status_font_rom[12'd2030] = 16'h1ff8; // 目 row14
        status_font_rom[12'd2031] = 16'h1008; // 目 row15
        status_font_rom[12'd2032] = 16'h0000; // 单 row0
        status_font_rom[12'd2033] = 16'h0810; // 单 row1
        status_font_rom[12'd2034] = 16'h0c10; // 单 row2
        status_font_rom[12'd2035] = 16'h0420; // 单 row3
        status_font_rom[12'd2036] = 16'h3ffc; // 单 row4
        status_font_rom[12'd2037] = 16'h3184; // 单 row5
        status_font_rom[12'd2038] = 16'h3184; // 单 row6
        status_font_rom[12'd2039] = 16'h3ffc; // 单 row7
        status_font_rom[12'd2040] = 16'h3184; // 单 row8
        status_font_rom[12'd2041] = 16'h3184; // 单 row9
        status_font_rom[12'd2042] = 16'h3ffc; // 单 row10
        status_font_rom[12'd2043] = 16'h0180; // 单 row11
        status_font_rom[12'd2044] = 16'h0180; // 单 row12
        status_font_rom[12'd2045] = 16'h7ffe; // 单 row13
        status_font_rom[12'd2046] = 16'h0180; // 单 row14
        status_font_rom[12'd2047] = 16'h0180; // 单 row15
        status_font_rom[12'd2048] = 16'h0000; // 档 row0
        status_font_rom[12'd2049] = 16'h1020; // 档 row1
        status_font_rom[12'd2050] = 16'h1020; // 档 row2
        status_font_rom[12'd2051] = 16'h1124; // 档 row3
        status_font_rom[12'd2052] = 16'h1124; // 档 row4
        status_font_rom[12'd2053] = 16'h7dac; // 档 row5
        status_font_rom[12'd2054] = 16'h1028; // 档 row6
        status_font_rom[12'd2055] = 16'h3820; // 档 row7
        status_font_rom[12'd2056] = 16'h3bfe; // 档 row8
        status_font_rom[12'd2057] = 16'h3406; // 档 row9
        status_font_rom[12'd2058] = 16'h3006; // 档 row10
        status_font_rom[12'd2059] = 16'h53fe; // 档 row11
        status_font_rom[12'd2060] = 16'h5006; // 档 row12
        status_font_rom[12'd2061] = 16'h1006; // 档 row13
        status_font_rom[12'd2062] = 16'h13fe; // 档 row14
        status_font_rom[12'd2063] = 16'h1006; // 档 row15
        status_font_rom[12'd2064] = 16'h0000; // 交 row0
        status_font_rom[12'd2065] = 16'h0100; // 交 row1
        status_font_rom[12'd2066] = 16'h0180; // 交 row2
        status_font_rom[12'd2067] = 16'h0180; // 交 row3
        status_font_rom[12'd2068] = 16'h7ffe; // 交 row4
        status_font_rom[12'd2069] = 16'h0000; // 交 row5
        status_font_rom[12'd2070] = 16'h0c30; // 交 row6
        status_font_rom[12'd2071] = 16'h1818; // 交 row7
        status_font_rom[12'd2072] = 16'h3004; // 交 row8
        status_font_rom[12'd2073] = 16'h2420; // 交 row9
        status_font_rom[12'd2074] = 16'h0660; // 交 row10
        status_font_rom[12'd2075] = 16'h0340; // 交 row11
        status_font_rom[12'd2076] = 16'h0180; // 交 row12
        status_font_rom[12'd2077] = 16'h03c0; // 交 row13
        status_font_rom[12'd2078] = 16'h0e70; // 交 row14
        status_font_rom[12'd2079] = 16'h781e; // 交 row15
        status_font_rom[12'd2080] = 16'h0000; // 互 row0
        status_font_rom[12'd2081] = 16'h0000; // 互 row1
        status_font_rom[12'd2082] = 16'h7ffe; // 互 row2
        status_font_rom[12'd2083] = 16'h0400; // 互 row3
        status_font_rom[12'd2084] = 16'h0400; // 互 row4
        status_font_rom[12'd2085] = 16'h0c00; // 互 row5
        status_font_rom[12'd2086] = 16'h0ff0; // 互 row6
        status_font_rom[12'd2087] = 16'h0810; // 互 row7
        status_font_rom[12'd2088] = 16'h0810; // 互 row8
        status_font_rom[12'd2089] = 16'h0810; // 互 row9
        status_font_rom[12'd2090] = 16'h0810; // 互 row10
        status_font_rom[12'd2091] = 16'h1ff0; // 互 row11
        status_font_rom[12'd2092] = 16'h0030; // 互 row12
        status_font_rom[12'd2093] = 16'h0020; // 互 row13
        status_font_rom[12'd2094] = 16'h0020; // 互 row14
        status_font_rom[12'd2095] = 16'h7ffe; // 互 row15
        status_font_rom[12'd2096] = 16'h0000; // 信 row0
        status_font_rom[12'd2097] = 16'h0840; // 信 row1
        status_font_rom[12'd2098] = 16'h0840; // 信 row2
        status_font_rom[12'd2099] = 16'h1000; // 信 row3
        status_font_rom[12'd2100] = 16'h17fe; // 信 row4
        status_font_rom[12'd2101] = 16'h3000; // 信 row5
        status_font_rom[12'd2102] = 16'h73fc; // 信 row6
        status_font_rom[12'd2103] = 16'h7000; // 信 row7
        status_font_rom[12'd2104] = 16'h5000; // 信 row8
        status_font_rom[12'd2105] = 16'h13fc; // 信 row9
        status_font_rom[12'd2106] = 16'h1000; // 信 row10
        status_font_rom[12'd2107] = 16'h13fc; // 信 row11
        status_font_rom[12'd2108] = 16'h1204; // 信 row12
        status_font_rom[12'd2109] = 16'h1204; // 信 row13
        status_font_rom[12'd2110] = 16'h1204; // 信 row14
        status_font_rom[12'd2111] = 16'h13fc; // 信 row15
        status_font_rom[12'd2112] = 16'h0000; // 切 row0
        status_font_rom[12'd2113] = 16'h0000; // 切 row1
        status_font_rom[12'd2114] = 16'h1000; // 切 row2
        status_font_rom[12'd2115] = 16'h11fe; // 切 row3
        status_font_rom[12'd2116] = 16'h1042; // 切 row4
        status_font_rom[12'd2117] = 16'h1642; // 切 row5
        status_font_rom[12'd2118] = 16'h7c42; // 切 row6
        status_font_rom[12'd2119] = 16'h3042; // 切 row7
        status_font_rom[12'd2120] = 16'h1042; // 切 row8
        status_font_rom[12'd2121] = 16'h1042; // 切 row9
        status_font_rom[12'd2122] = 16'h1042; // 切 row10
        status_font_rom[12'd2123] = 16'h16c6; // 切 row11
        status_font_rom[12'd2124] = 16'h3886; // 切 row12
        status_font_rom[12'd2125] = 16'h2184; // 切 row13
        status_font_rom[12'd2126] = 16'h0304; // 切 row14
        status_font_rom[12'd2127] = 16'h063c; // 切 row15
        status_font_rom[12'd2128] = 16'h0000; // 四 row0
        status_font_rom[12'd2129] = 16'h0000; // 四 row1
        status_font_rom[12'd2130] = 16'h0000; // 四 row2
        status_font_rom[12'd2131] = 16'h7ffc; // 四 row3
        status_font_rom[12'd2132] = 16'h6244; // 四 row4
        status_font_rom[12'd2133] = 16'h6244; // 四 row5
        status_font_rom[12'd2134] = 16'h6244; // 四 row6
        status_font_rom[12'd2135] = 16'h6644; // 四 row7
        status_font_rom[12'd2136] = 16'h6444; // 四 row8
        status_font_rom[12'd2137] = 16'h6444; // 四 row9
        status_font_rom[12'd2138] = 16'h6c7c; // 四 row10
        status_font_rom[12'd2139] = 16'h7804; // 四 row11
        status_font_rom[12'd2140] = 16'h6004; // 四 row12
        status_font_rom[12'd2141] = 16'h6004; // 四 row13
        status_font_rom[12'd2142] = 16'h7ffc; // 四 row14
        status_font_rom[12'd2143] = 16'h6004; // 四 row15
        status_font_rom[12'd2144] = 16'h0000; // 备 row0
        status_font_rom[12'd2145] = 16'h0200; // 备 row1
        status_font_rom[12'd2146] = 16'h0600; // 备 row2
        status_font_rom[12'd2147] = 16'h0ff8; // 备 row3
        status_font_rom[12'd2148] = 16'h1c30; // 备 row4
        status_font_rom[12'd2149] = 16'h2660; // 备 row5
        status_font_rom[12'd2150] = 16'h03c0; // 备 row6
        status_font_rom[12'd2151] = 16'h0e78; // 备 row7
        status_font_rom[12'd2152] = 16'h700e; // 备 row8
        status_font_rom[12'd2153] = 16'h1ff8; // 备 row9
        status_font_rom[12'd2154] = 16'h1188; // 备 row10
        status_font_rom[12'd2155] = 16'h1188; // 备 row11
        status_font_rom[12'd2156] = 16'h1ff8; // 备 row12
        status_font_rom[12'd2157] = 16'h1188; // 备 row13
        status_font_rom[12'd2158] = 16'h1188; // 备 row14
        status_font_rom[12'd2159] = 16'h1ff8; // 备 row15
        status_font_rom[12'd2160] = 16'h0000; // 布 row0
        status_font_rom[12'd2161] = 16'h0200; // 布 row1
        status_font_rom[12'd2162] = 16'h0200; // 布 row2
        status_font_rom[12'd2163] = 16'h0200; // 布 row3
        status_font_rom[12'd2164] = 16'h7ffe; // 布 row4
        status_font_rom[12'd2165] = 16'h0400; // 布 row5
        status_font_rom[12'd2166] = 16'h0c80; // 布 row6
        status_font_rom[12'd2167] = 16'h1880; // 布 row7
        status_font_rom[12'd2168] = 16'h1ffc; // 布 row8
        status_font_rom[12'd2169] = 16'h3884; // 布 row9
        status_font_rom[12'd2170] = 16'h6884; // 布 row10
        status_font_rom[12'd2171] = 16'h0884; // 布 row11
        status_font_rom[12'd2172] = 16'h0884; // 布 row12
        status_font_rom[12'd2173] = 16'h0884; // 布 row13
        status_font_rom[12'd2174] = 16'h089c; // 布 row14
        status_font_rom[12'd2175] = 16'h0080; // 布 row15
        status_font_rom[12'd2176] = 16'h0000; // 局 row0
        status_font_rom[12'd2177] = 16'h0000; // 局 row1
        status_font_rom[12'd2178] = 16'h3ff8; // 局 row2
        status_font_rom[12'd2179] = 16'h3008; // 局 row3
        status_font_rom[12'd2180] = 16'h3008; // 局 row4
        status_font_rom[12'd2181] = 16'h3ff8; // 局 row5
        status_font_rom[12'd2182] = 16'h3000; // 局 row6
        status_font_rom[12'd2183] = 16'h3000; // 局 row7
        status_font_rom[12'd2184] = 16'h3ffe; // 局 row8
        status_font_rom[12'd2185] = 16'h2006; // 局 row9
        status_font_rom[12'd2186] = 16'h27e4; // 局 row10
        status_font_rom[12'd2187] = 16'h2424; // 局 row11
        status_font_rom[12'd2188] = 16'h2424; // 局 row12
        status_font_rom[12'd2189] = 16'h2424; // 局 row13
        status_font_rom[12'd2190] = 16'h47e4; // 局 row14
        status_font_rom[12'd2191] = 16'h4404; // 局 row15
        status_font_rom[12'd2192] = 16'h0000; // 息 row0
        status_font_rom[12'd2193] = 16'h0100; // 息 row1
        status_font_rom[12'd2194] = 16'h0100; // 息 row2
        status_font_rom[12'd2195] = 16'h1ff8; // 息 row3
        status_font_rom[12'd2196] = 16'h1008; // 息 row4
        status_font_rom[12'd2197] = 16'h1ff8; // 息 row5
        status_font_rom[12'd2198] = 16'h1008; // 息 row6
        status_font_rom[12'd2199] = 16'h1ff8; // 息 row7
        status_font_rom[12'd2200] = 16'h1008; // 息 row8
        status_font_rom[12'd2201] = 16'h1008; // 息 row9
        status_font_rom[12'd2202] = 16'h1ff8; // 息 row10
        status_font_rom[12'd2203] = 16'h0100; // 息 row11
        status_font_rom[12'd2204] = 16'h2884; // 息 row12
        status_font_rom[12'd2205] = 16'h2814; // 息 row13
        status_font_rom[12'd2206] = 16'h4812; // 息 row14
        status_font_rom[12'd2207] = 16'h07f0; // 息 row15
        status_font_rom[12'd2208] = 16'h0000; // 拍 row0
        status_font_rom[12'd2209] = 16'h1020; // 拍 row1
        status_font_rom[12'd2210] = 16'h1020; // 拍 row2
        status_font_rom[12'd2211] = 16'h1020; // 拍 row3
        status_font_rom[12'd2212] = 16'h11fc; // 拍 row4
        status_font_rom[12'd2213] = 16'h7d04; // 拍 row5
        status_font_rom[12'd2214] = 16'h1104; // 拍 row6
        status_font_rom[12'd2215] = 16'h1104; // 拍 row7
        status_font_rom[12'd2216] = 16'h1504; // 拍 row8
        status_font_rom[12'd2217] = 16'h3dfc; // 拍 row9
        status_font_rom[12'd2218] = 16'h7104; // 拍 row10
        status_font_rom[12'd2219] = 16'h1104; // 拍 row11
        status_font_rom[12'd2220] = 16'h1104; // 拍 row12
        status_font_rom[12'd2221] = 16'h1104; // 拍 row13
        status_font_rom[12'd2222] = 16'h1104; // 拍 row14
        status_font_rom[12'd2223] = 16'h11fc; // 拍 row15
        status_font_rom[12'd2224] = 16'h0000; // 换 row0
        status_font_rom[12'd2225] = 16'h1000; // 换 row1
        status_font_rom[12'd2226] = 16'h1080; // 换 row2
        status_font_rom[12'd2227] = 16'h10f8; // 换 row3
        status_font_rom[12'd2228] = 16'h1108; // 换 row4
        status_font_rom[12'd2229] = 16'h7b10; // 换 row5
        status_font_rom[12'd2230] = 16'h13fc; // 换 row6
        status_font_rom[12'd2231] = 16'h1324; // 换 row7
        status_font_rom[12'd2232] = 16'h1124; // 换 row8
        status_font_rom[12'd2233] = 16'h1924; // 换 row9
        status_font_rom[12'd2234] = 16'h7b24; // 换 row10
        status_font_rom[12'd2235] = 16'h77fe; // 换 row11
        status_font_rom[12'd2236] = 16'h1060; // 换 row12
        status_font_rom[12'd2237] = 16'h10d0; // 换 row13
        status_font_rom[12'd2238] = 16'h1188; // 换 row14
        status_font_rom[12'd2239] = 16'h130c; // 换 row15
        status_font_rom[12'd2240] = 16'h0000; // 新 row0
        status_font_rom[12'd2241] = 16'h0800; // 新 row1
        status_font_rom[12'd2242] = 16'h081c; // 新 row2
        status_font_rom[12'd2243] = 16'h7f60; // 新 row3
        status_font_rom[12'd2244] = 16'h2240; // 新 row4
        status_font_rom[12'd2245] = 16'h2240; // 新 row5
        status_font_rom[12'd2246] = 16'h1440; // 新 row6
        status_font_rom[12'd2247] = 16'h7f7e; // 新 row7
        status_font_rom[12'd2248] = 16'h084c; // 新 row8
        status_font_rom[12'd2249] = 16'h084c; // 新 row9
        status_font_rom[12'd2250] = 16'h7f4c; // 新 row10
        status_font_rom[12'd2251] = 16'h084c; // 新 row11
        status_font_rom[12'd2252] = 16'h2a4c; // 新 row12
        status_font_rom[12'd2253] = 16'h498c; // 新 row13
        status_font_rom[12'd2254] = 16'h088c; // 新 row14
        status_font_rom[12'd2255] = 16'h188c; // 新 row15
        status_font_rom[12'd2256] = 16'h0000; // 无 row0
        status_font_rom[12'd2257] = 16'h0000; // 无 row1
        status_font_rom[12'd2258] = 16'h0000; // 无 row2
        status_font_rom[12'd2259] = 16'h3ffc; // 无 row3
        status_font_rom[12'd2260] = 16'h0100; // 无 row4
        status_font_rom[12'd2261] = 16'h0100; // 无 row5
        status_font_rom[12'd2262] = 16'h0100; // 无 row6
        status_font_rom[12'd2263] = 16'h7ffe; // 无 row7
        status_font_rom[12'd2264] = 16'h03c0; // 无 row8
        status_font_rom[12'd2265] = 16'h0280; // 无 row9
        status_font_rom[12'd2266] = 16'h0280; // 无 row10
        status_font_rom[12'd2267] = 16'h0680; // 无 row11
        status_font_rom[12'd2268] = 16'h0482; // 无 row12
        status_font_rom[12'd2269] = 16'h0c82; // 无 row13
        status_font_rom[12'd2270] = 16'h18c2; // 无 row14
        status_font_rom[12'd2271] = 16'h60fe; // 无 row15
        status_font_rom[12'd2272] = 16'h0000; // 智 row0
        status_font_rom[12'd2273] = 16'h0000; // 智 row1
        status_font_rom[12'd2274] = 16'h2000; // 智 row2
        status_font_rom[12'd2275] = 16'h3f7c; // 智 row3
        status_font_rom[12'd2276] = 16'h4844; // 智 row4
        status_font_rom[12'd2277] = 16'h7f44; // 智 row5
        status_font_rom[12'd2278] = 16'h0844; // 智 row6
        status_font_rom[12'd2279] = 16'h1e7c; // 智 row7
        status_font_rom[12'd2280] = 16'h3300; // 智 row8
        status_font_rom[12'd2281] = 16'h6000; // 智 row9
        status_font_rom[12'd2282] = 16'h1ff8; // 智 row10
        status_font_rom[12'd2283] = 16'h1008; // 智 row11
        status_font_rom[12'd2284] = 16'h1ff8; // 智 row12
        status_font_rom[12'd2285] = 16'h1008; // 智 row13
        status_font_rom[12'd2286] = 16'h1008; // 智 row14
        status_font_rom[12'd2287] = 16'h1ff8; // 智 row15
        status_font_rom[12'd2288] = 16'h0000; // 欢 row0
        status_font_rom[12'd2289] = 16'h0040; // 欢 row1
        status_font_rom[12'd2290] = 16'h0040; // 欢 row2
        status_font_rom[12'd2291] = 16'h7ec0; // 欢 row3
        status_font_rom[12'd2292] = 16'h06fe; // 欢 row4
        status_font_rom[12'd2293] = 16'h0482; // 欢 row5
        status_font_rom[12'd2294] = 16'h65a4; // 欢 row6
        status_font_rom[12'd2295] = 16'h2524; // 欢 row7
        status_font_rom[12'd2296] = 16'h1c20; // 欢 row8
        status_font_rom[12'd2297] = 16'h1820; // 欢 row9
        status_font_rom[12'd2298] = 16'h0830; // 欢 row10
        status_font_rom[12'd2299] = 16'h1c70; // 欢 row11
        status_font_rom[12'd2300] = 16'h3458; // 欢 row12
        status_font_rom[12'd2301] = 16'h24c8; // 欢 row13
        status_font_rom[12'd2302] = 16'h418c; // 欢 row14
        status_font_rom[12'd2303] = 16'h0306; // 欢 row15
        status_font_rom[12'd2304] = 16'h0000; // 画 row0
        status_font_rom[12'd2305] = 16'h0000; // 画 row1
        status_font_rom[12'd2306] = 16'h3ffc; // 画 row2
        status_font_rom[12'd2307] = 16'h0000; // 画 row3
        status_font_rom[12'd2308] = 16'h0000; // 画 row4
        status_font_rom[12'd2309] = 16'h0ff0; // 画 row5
        status_font_rom[12'd2310] = 16'h2916; // 画 row6
        status_font_rom[12'd2311] = 16'h2916; // 画 row7
        status_font_rom[12'd2312] = 16'h2916; // 画 row8
        status_font_rom[12'd2313] = 16'h2ff6; // 画 row9
        status_font_rom[12'd2314] = 16'h2916; // 画 row10
        status_font_rom[12'd2315] = 16'h2916; // 画 row11
        status_font_rom[12'd2316] = 16'h2ff6; // 画 row12
        status_font_rom[12'd2317] = 16'h2006; // 画 row13
        status_font_rom[12'd2318] = 16'h2006; // 画 row14
        status_font_rom[12'd2319] = 16'h3ffe; // 画 row15
        status_font_rom[12'd2320] = 16'h0000; // 看 row0
        status_font_rom[12'd2321] = 16'h0008; // 看 row1
        status_font_rom[12'd2322] = 16'h3ff0; // 看 row2
        status_font_rom[12'd2323] = 16'h0300; // 看 row3
        status_font_rom[12'd2324] = 16'h3ffc; // 看 row4
        status_font_rom[12'd2325] = 16'h0200; // 看 row5
        status_font_rom[12'd2326] = 16'h0600; // 看 row6
        status_font_rom[12'd2327] = 16'h7ffe; // 看 row7
        status_font_rom[12'd2328] = 16'h0c00; // 看 row8
        status_font_rom[12'd2329] = 16'h0ff8; // 看 row9
        status_font_rom[12'd2330] = 16'h1808; // 看 row10
        status_font_rom[12'd2331] = 16'h6ff8; // 看 row11
        status_font_rom[12'd2332] = 16'h4808; // 看 row12
        status_font_rom[12'd2333] = 16'h0ff8; // 看 row13
        status_font_rom[12'd2334] = 16'h0808; // 看 row14
        status_font_rom[12'd2335] = 16'h0ff8; // 看 row15
        status_font_rom[12'd2336] = 16'h0000; // 能 row0
        status_font_rom[12'd2337] = 16'h1040; // 能 row1
        status_font_rom[12'd2338] = 16'h1440; // 能 row2
        status_font_rom[12'd2339] = 16'h224c; // 能 row3
        status_font_rom[12'd2340] = 16'h6678; // 能 row4
        status_font_rom[12'd2341] = 16'h7b40; // 能 row5
        status_font_rom[12'd2342] = 16'h0042; // 能 row6
        status_font_rom[12'd2343] = 16'h3e42; // 能 row7
        status_font_rom[12'd2344] = 16'h227e; // 能 row8
        status_font_rom[12'd2345] = 16'h2240; // 能 row9
        status_font_rom[12'd2346] = 16'h3e40; // 能 row10
        status_font_rom[12'd2347] = 16'h224c; // 能 row11
        status_font_rom[12'd2348] = 16'h3e70; // 能 row12
        status_font_rom[12'd2349] = 16'h2240; // 能 row13
        status_font_rom[12'd2350] = 16'h2242; // 能 row14
        status_font_rom[12'd2351] = 16'h2242; // 能 row15
        status_font_rom[12'd2352] = 16'h0000; // 节 row0
        status_font_rom[12'd2353] = 16'h0420; // 节 row1
        status_font_rom[12'd2354] = 16'h0420; // 节 row2
        status_font_rom[12'd2355] = 16'h7ffe; // 节 row3
        status_font_rom[12'd2356] = 16'h0420; // 节 row4
        status_font_rom[12'd2357] = 16'h0420; // 节 row5
        status_font_rom[12'd2358] = 16'h0000; // 节 row6
        status_font_rom[12'd2359] = 16'h3ffc; // 节 row7
        status_font_rom[12'd2360] = 16'h020c; // 节 row8
        status_font_rom[12'd2361] = 16'h020c; // 节 row9
        status_font_rom[12'd2362] = 16'h020c; // 节 row10
        status_font_rom[12'd2363] = 16'h020c; // 节 row11
        status_font_rom[12'd2364] = 16'h020c; // 节 row12
        status_font_rom[12'd2365] = 16'h0238; // 节 row13
        status_font_rom[12'd2366] = 16'h0200; // 节 row14
        status_font_rom[12'd2367] = 16'h0200; // 节 row15
        status_font_rom[12'd2368] = 16'h0000; // 观 row0
        status_font_rom[12'd2369] = 16'h0000; // 观 row1
        status_font_rom[12'd2370] = 16'h01fc; // 观 row2
        status_font_rom[12'd2371] = 16'h7d84; // 观 row3
        status_font_rom[12'd2372] = 16'h0584; // 观 row4
        status_font_rom[12'd2373] = 16'h05a4; // 观 row5
        status_font_rom[12'd2374] = 16'h65a4; // 观 row6
        status_font_rom[12'd2375] = 16'h2da4; // 观 row7
        status_font_rom[12'd2376] = 16'h19a4; // 观 row8
        status_font_rom[12'd2377] = 16'h19a4; // 观 row9
        status_font_rom[12'd2378] = 16'h1824; // 观 row10
        status_font_rom[12'd2379] = 16'h1c30; // 观 row11
        status_font_rom[12'd2380] = 16'h3450; // 观 row12
        status_font_rom[12'd2381] = 16'h24d2; // 观 row13
        status_font_rom[12'd2382] = 16'h4192; // 观 row14
        status_font_rom[12'd2383] = 16'h031e; // 观 row15
        status_font_rom[12'd2384] = 16'h0000; // 设 row0
        status_font_rom[12'd2385] = 16'h0000; // 设 row1
        status_font_rom[12'd2386] = 16'h30f8; // 设 row2
        status_font_rom[12'd2387] = 16'h1888; // 设 row3
        status_font_rom[12'd2388] = 16'h0088; // 设 row4
        status_font_rom[12'd2389] = 16'h0188; // 设 row5
        status_font_rom[12'd2390] = 16'h030e; // 设 row6
        status_font_rom[12'd2391] = 16'h7200; // 设 row7
        status_font_rom[12'd2392] = 16'h1000; // 设 row8
        status_font_rom[12'd2393] = 16'h13fc; // 设 row9
        status_font_rom[12'd2394] = 16'h1104; // 设 row10
        status_font_rom[12'd2395] = 16'h1088; // 设 row11
        status_font_rom[12'd2396] = 16'h10d8; // 设 row12
        status_font_rom[12'd2397] = 16'h1c70; // 设 row13
        status_font_rom[12'd2398] = 16'h1870; // 设 row14
        status_font_rom[12'd2399] = 16'h339e; // 设 row15
        status_font_rom[12'd2400] = 16'h0000; // 路 row0
        status_font_rom[12'd2401] = 16'h0000; // 路 row1
        status_font_rom[12'd2402] = 16'h7e40; // 路 row2
        status_font_rom[12'd2403] = 16'h627c; // 路 row3
        status_font_rom[12'd2404] = 16'h62cc; // 路 row4
        status_font_rom[12'd2405] = 16'h63c8; // 路 row5
        status_font_rom[12'd2406] = 16'h7f38; // 路 row6
        status_font_rom[12'd2407] = 16'h0830; // 路 row7
        status_font_rom[12'd2408] = 16'h0838; // 路 row8
        status_font_rom[12'd2409] = 16'h484c; // 路 row9
        status_font_rom[12'd2410] = 16'h4f86; // 路 row10
        status_font_rom[12'd2411] = 16'h48fc; // 路 row11
        status_font_rom[12'd2412] = 16'h4884; // 路 row12
        status_font_rom[12'd2413] = 16'h4884; // 路 row13
        status_font_rom[12'd2414] = 16'h7e84; // 路 row14
        status_font_rom[12'd2415] = 16'h60fc; // 路 row15
        status_font_rom[12'd2416] = 16'h0000; // 迎 row0
        status_font_rom[12'd2417] = 16'h0000; // 迎 row1
        status_font_rom[12'd2418] = 16'h0180; // 迎 row2
        status_font_rom[12'd2419] = 16'h633e; // 迎 row3
        status_font_rom[12'd2420] = 16'h1222; // 迎 row4
        status_font_rom[12'd2421] = 16'h0222; // 迎 row5
        status_font_rom[12'd2422] = 16'h0222; // 迎 row6
        status_font_rom[12'd2423] = 16'h7222; // 迎 row7
        status_font_rom[12'd2424] = 16'h1222; // 迎 row8
        status_font_rom[12'd2425] = 16'h1222; // 迎 row9
        status_font_rom[12'd2426] = 16'h1222; // 迎 row10
        status_font_rom[12'd2427] = 16'h17a2; // 迎 row11
        status_font_rom[12'd2428] = 16'h162c; // 迎 row12
        status_font_rom[12'd2429] = 16'h1020; // 迎 row13
        status_font_rom[12'd2430] = 16'h3c00; // 迎 row14
        status_font_rom[12'd2431] = 16'h43fe; // 迎 row15
        status_font_rom[12'd2432] = 16'h0000; // 重 row0
        status_font_rom[12'd2433] = 16'h0018; // 重 row1
        status_font_rom[12'd2434] = 16'h3fe0; // 重 row2
        status_font_rom[12'd2435] = 16'h0180; // 重 row3
        status_font_rom[12'd2436] = 16'h7ffe; // 重 row4
        status_font_rom[12'd2437] = 16'h0180; // 重 row5
        status_font_rom[12'd2438] = 16'h1ff8; // 重 row6
        status_font_rom[12'd2439] = 16'h118c; // 重 row7
        status_font_rom[12'd2440] = 16'h1ffc; // 重 row8
        status_font_rom[12'd2441] = 16'h118c; // 重 row9
        status_font_rom[12'd2442] = 16'h118c; // 重 row10
        status_font_rom[12'd2443] = 16'h1ff8; // 重 row11
        status_font_rom[12'd2444] = 16'h0180; // 重 row12
        status_font_rom[12'd2445] = 16'h3ffc; // 重 row13
        status_font_rom[12'd2446] = 16'h0180; // 重 row14
        status_font_rom[12'd2447] = 16'h7ffe; // 重 row15
        status_font_rom[12'd2448] = 16'h0000; // 需 row0
        status_font_rom[12'd2449] = 16'h0000; // 需 row1
        status_font_rom[12'd2450] = 16'h3ffc; // 需 row2
        status_font_rom[12'd2451] = 16'h0100; // 需 row3
        status_font_rom[12'd2452] = 16'h7ffe; // 需 row4
        status_font_rom[12'd2453] = 16'h5d7a; // 需 row5
        status_font_rom[12'd2454] = 16'h4102; // 需 row6
        status_font_rom[12'd2455] = 16'h1d78; // 需 row7
        status_font_rom[12'd2456] = 16'h0100; // 需 row8
        status_font_rom[12'd2457] = 16'h7ffe; // 需 row9
        status_font_rom[12'd2458] = 16'h0100; // 需 row10
        status_font_rom[12'd2459] = 16'h0100; // 需 row11
        status_font_rom[12'd2460] = 16'h3ffc; // 需 row12
        status_font_rom[12'd2461] = 16'h2244; // 需 row13
        status_font_rom[12'd2462] = 16'h2244; // 需 row14
        status_font_rom[12'd2463] = 16'h2244; // 需 row15
        status_font_rom[12'd2464] = 16'h0000; // 面 row0
        status_font_rom[12'd2465] = 16'h0000; // 面 row1
        status_font_rom[12'd2466] = 16'h7ffe; // 面 row2
        status_font_rom[12'd2467] = 16'h0100; // 面 row3
        status_font_rom[12'd2468] = 16'h0100; // 面 row4
        status_font_rom[12'd2469] = 16'h0100; // 面 row5
        status_font_rom[12'd2470] = 16'h3ffc; // 面 row6
        status_font_rom[12'd2471] = 16'h2424; // 面 row7
        status_font_rom[12'd2472] = 16'h2424; // 面 row8
        status_font_rom[12'd2473] = 16'h27e4; // 面 row9
        status_font_rom[12'd2474] = 16'h2424; // 面 row10
        status_font_rom[12'd2475] = 16'h2424; // 面 row11
        status_font_rom[12'd2476] = 16'h27e4; // 面 row12
        status_font_rom[12'd2477] = 16'h2424; // 面 row13
        status_font_rom[12'd2478] = 16'h2424; // 面 row14
        status_font_rom[12'd2479] = 16'h3ffc; // 面 row15
        status_font_rom[12'd2480] = 16'h0000; // 驱 row0
        status_font_rom[12'd2481] = 16'h0000; // 驱 row1
        status_font_rom[12'd2482] = 16'h7dfe; // 驱 row2
        status_font_rom[12'd2483] = 16'h0500; // 驱 row3
        status_font_rom[12'd2484] = 16'h0504; // 驱 row4
        status_font_rom[12'd2485] = 16'h2544; // 驱 row5
        status_font_rom[12'd2486] = 16'h252c; // 驱 row6
        status_font_rom[12'd2487] = 16'h4d38; // 驱 row7
        status_font_rom[12'd2488] = 16'h4918; // 驱 row8
        status_font_rom[12'd2489] = 16'h7f18; // 驱 row9
        status_font_rom[12'd2490] = 16'h071c; // 驱 row10
        status_font_rom[12'd2491] = 16'h0524; // 驱 row11
        status_font_rom[12'd2492] = 16'h3d66; // 驱 row12
        status_font_rom[12'd2493] = 16'h4540; // 驱 row13
        status_font_rom[12'd2494] = 16'h0500; // 驱 row14
        status_font_rom[12'd2495] = 16'h05fe; // 驱 row15
        status_font_rom[12'd2496] = 16'h0000; // 驻 row0
        status_font_rom[12'd2497] = 16'h0000; // 驻 row1
        status_font_rom[12'd2498] = 16'h7c20; // 驻 row2
        status_font_rom[12'd2499] = 16'h0430; // 驻 row3
        status_font_rom[12'd2500] = 16'h0400; // 驻 row4
        status_font_rom[12'd2501] = 16'h25fe; // 驻 row5
        status_font_rom[12'd2502] = 16'h2430; // 驻 row6
        status_font_rom[12'd2503] = 16'h2430; // 驻 row7
        status_font_rom[12'd2504] = 16'h4c30; // 驻 row8
        status_font_rom[12'd2505] = 16'h7e30; // 驻 row9
        status_font_rom[12'd2506] = 16'h03fc; // 驻 row10
        status_font_rom[12'd2507] = 16'h0630; // 驻 row11
        status_font_rom[12'd2508] = 16'h1c30; // 驻 row12
        status_font_rom[12'd2509] = 16'h6430; // 驻 row13
        status_font_rom[12'd2510] = 16'h0430; // 驻 row14
        status_font_rom[12'd2511] = 16'h07fe; // 驻 row15
        status_font_rom[12'd2512] = 16'h0000; // A row0
        status_font_rom[12'd2513] = 16'h0000; // A row1
        status_font_rom[12'd2514] = 16'h0000; // A row2
        status_font_rom[12'd2515] = 16'h0180; // A row3
        status_font_rom[12'd2516] = 16'h0180; // A row4
        status_font_rom[12'd2517] = 16'h0280; // A row5
        status_font_rom[12'd2518] = 16'h0240; // A row6
        status_font_rom[12'd2519] = 16'h0240; // A row7
        status_font_rom[12'd2520] = 16'h0640; // A row8
        status_font_rom[12'd2521] = 16'h0460; // A row9
        status_font_rom[12'd2522] = 16'h07e0; // A row10
        status_font_rom[12'd2523] = 16'h0c20; // A row11
        status_font_rom[12'd2524] = 16'h0830; // A row12
        status_font_rom[12'd2525] = 16'h0810; // A row13
        status_font_rom[12'd2526] = 16'h1810; // A row14
        status_font_rom[12'd2527] = 16'h0000; // A row15
        status_font_rom[12'd2528] = 16'h0000; // B row0
        status_font_rom[12'd2529] = 16'h0000; // B row1
        status_font_rom[12'd2530] = 16'h0000; // B row2
        status_font_rom[12'd2531] = 16'h0fc0; // B row3
        status_font_rom[12'd2532] = 16'h0860; // B row4
        status_font_rom[12'd2533] = 16'h0820; // B row5
        status_font_rom[12'd2534] = 16'h0820; // B row6
        status_font_rom[12'd2535] = 16'h0860; // B row7
        status_font_rom[12'd2536] = 16'h0fc0; // B row8
        status_font_rom[12'd2537] = 16'h0860; // B row9
        status_font_rom[12'd2538] = 16'h0830; // B row10
        status_font_rom[12'd2539] = 16'h0830; // B row11
        status_font_rom[12'd2540] = 16'h0830; // B row12
        status_font_rom[12'd2541] = 16'h0860; // B row13
        status_font_rom[12'd2542] = 16'h0fc0; // B row14
        status_font_rom[12'd2543] = 16'h0000; // B row15
        status_font_rom[12'd2544] = 16'h0000; // C row0
        status_font_rom[12'd2545] = 16'h0000; // C row1
        status_font_rom[12'd2546] = 16'h0000; // C row2
        status_font_rom[12'd2547] = 16'h01e0; // C row3
        status_font_rom[12'd2548] = 16'h0330; // C row4
        status_font_rom[12'd2549] = 16'h0600; // C row5
        status_font_rom[12'd2550] = 16'h0c00; // C row6
        status_font_rom[12'd2551] = 16'h0c00; // C row7
        status_font_rom[12'd2552] = 16'h0800; // C row8
        status_font_rom[12'd2553] = 16'h0c00; // C row9
        status_font_rom[12'd2554] = 16'h0c00; // C row10
        status_font_rom[12'd2555] = 16'h0c00; // C row11
        status_font_rom[12'd2556] = 16'h0600; // C row12
        status_font_rom[12'd2557] = 16'h0330; // C row13
        status_font_rom[12'd2558] = 16'h01e0; // C row14
        status_font_rom[12'd2559] = 16'h0000; // C row15
        status_font_rom[12'd2560] = 16'h0000; // D row0
        status_font_rom[12'd2561] = 16'h0000; // D row1
        status_font_rom[12'd2562] = 16'h0000; // D row2
        status_font_rom[12'd2563] = 16'h0f80; // D row3
        status_font_rom[12'd2564] = 16'h08c0; // D row4
        status_font_rom[12'd2565] = 16'h0860; // D row5
        status_font_rom[12'd2566] = 16'h0830; // D row6
        status_font_rom[12'd2567] = 16'h0830; // D row7
        status_font_rom[12'd2568] = 16'h0830; // D row8
        status_font_rom[12'd2569] = 16'h0830; // D row9
        status_font_rom[12'd2570] = 16'h0830; // D row10
        status_font_rom[12'd2571] = 16'h0830; // D row11
        status_font_rom[12'd2572] = 16'h0860; // D row12
        status_font_rom[12'd2573] = 16'h08c0; // D row13
        status_font_rom[12'd2574] = 16'h0f80; // D row14
        status_font_rom[12'd2575] = 16'h0000; // D row15
        status_font_rom[12'd2576] = 16'h0000; // E row0
        status_font_rom[12'd2577] = 16'h0000; // E row1
        status_font_rom[12'd2578] = 16'h0000; // E row2
        status_font_rom[12'd2579] = 16'h07e0; // E row3
        status_font_rom[12'd2580] = 16'h0400; // E row4
        status_font_rom[12'd2581] = 16'h0400; // E row5
        status_font_rom[12'd2582] = 16'h0400; // E row6
        status_font_rom[12'd2583] = 16'h0400; // E row7
        status_font_rom[12'd2584] = 16'h07e0; // E row8
        status_font_rom[12'd2585] = 16'h0400; // E row9
        status_font_rom[12'd2586] = 16'h0400; // E row10
        status_font_rom[12'd2587] = 16'h0400; // E row11
        status_font_rom[12'd2588] = 16'h0400; // E row12
        status_font_rom[12'd2589] = 16'h0400; // E row13
        status_font_rom[12'd2590] = 16'h07f0; // E row14
        status_font_rom[12'd2591] = 16'h0000; // E row15
        status_font_rom[12'd2592] = 16'h0000; // F row0
        status_font_rom[12'd2593] = 16'h0000; // F row1
        status_font_rom[12'd2594] = 16'h0000; // F row2
        status_font_rom[12'd2595] = 16'h07e0; // F row3
        status_font_rom[12'd2596] = 16'h0400; // F row4
        status_font_rom[12'd2597] = 16'h0400; // F row5
        status_font_rom[12'd2598] = 16'h0400; // F row6
        status_font_rom[12'd2599] = 16'h0400; // F row7
        status_font_rom[12'd2600] = 16'h07e0; // F row8
        status_font_rom[12'd2601] = 16'h0400; // F row9
        status_font_rom[12'd2602] = 16'h0400; // F row10
        status_font_rom[12'd2603] = 16'h0400; // F row11
        status_font_rom[12'd2604] = 16'h0400; // F row12
        status_font_rom[12'd2605] = 16'h0400; // F row13
        status_font_rom[12'd2606] = 16'h0400; // F row14
        status_font_rom[12'd2607] = 16'h0000; // F row15
        status_font_rom[12'd2608] = 16'h0000; // G row0
        status_font_rom[12'd2609] = 16'h0000; // G row1
        status_font_rom[12'd2610] = 16'h0000; // G row2
        status_font_rom[12'd2611] = 16'h03c0; // G row3
        status_font_rom[12'd2612] = 16'h0660; // G row4
        status_font_rom[12'd2613] = 16'h0c00; // G row5
        status_font_rom[12'd2614] = 16'h1800; // G row6
        status_font_rom[12'd2615] = 16'h1800; // G row7
        status_font_rom[12'd2616] = 16'h1800; // G row8
        status_font_rom[12'd2617] = 16'h18f0; // G row9
        status_font_rom[12'd2618] = 16'h1830; // G row10
        status_font_rom[12'd2619] = 16'h1830; // G row11
        status_font_rom[12'd2620] = 16'h0c30; // G row12
        status_font_rom[12'd2621] = 16'h0630; // G row13
        status_font_rom[12'd2622] = 16'h03c0; // G row14
        status_font_rom[12'd2623] = 16'h0000; // G row15
        status_font_rom[12'd2624] = 16'h0000; // H row0
        status_font_rom[12'd2625] = 16'h0000; // H row1
        status_font_rom[12'd2626] = 16'h0000; // H row2
        status_font_rom[12'd2627] = 16'h0810; // H row3
        status_font_rom[12'd2628] = 16'h0810; // H row4
        status_font_rom[12'd2629] = 16'h0810; // H row5
        status_font_rom[12'd2630] = 16'h0810; // H row6
        status_font_rom[12'd2631] = 16'h0810; // H row7
        status_font_rom[12'd2632] = 16'h0ff0; // H row8
        status_font_rom[12'd2633] = 16'h0830; // H row9
        status_font_rom[12'd2634] = 16'h0810; // H row10
        status_font_rom[12'd2635] = 16'h0810; // H row11
        status_font_rom[12'd2636] = 16'h0810; // H row12
        status_font_rom[12'd2637] = 16'h0810; // H row13
        status_font_rom[12'd2638] = 16'h0810; // H row14
        status_font_rom[12'd2639] = 16'h0000; // H row15
        status_font_rom[12'd2640] = 16'h0000; // I row0
        status_font_rom[12'd2641] = 16'h0000; // I row1
        status_font_rom[12'd2642] = 16'h0000; // I row2
        status_font_rom[12'd2643] = 16'h0100; // I row3
        status_font_rom[12'd2644] = 16'h0100; // I row4
        status_font_rom[12'd2645] = 16'h0100; // I row5
        status_font_rom[12'd2646] = 16'h0100; // I row6
        status_font_rom[12'd2647] = 16'h0100; // I row7
        status_font_rom[12'd2648] = 16'h0100; // I row8
        status_font_rom[12'd2649] = 16'h0100; // I row9
        status_font_rom[12'd2650] = 16'h0100; // I row10
        status_font_rom[12'd2651] = 16'h0100; // I row11
        status_font_rom[12'd2652] = 16'h0100; // I row12
        status_font_rom[12'd2653] = 16'h0100; // I row13
        status_font_rom[12'd2654] = 16'h0100; // I row14
        status_font_rom[12'd2655] = 16'h0000; // I row15
        status_font_rom[12'd2656] = 16'h0000; // J row0
        status_font_rom[12'd2657] = 16'h0000; // J row1
        status_font_rom[12'd2658] = 16'h0000; // J row2
        status_font_rom[12'd2659] = 16'h0040; // J row3
        status_font_rom[12'd2660] = 16'h0040; // J row4
        status_font_rom[12'd2661] = 16'h0040; // J row5
        status_font_rom[12'd2662] = 16'h0040; // J row6
        status_font_rom[12'd2663] = 16'h0040; // J row7
        status_font_rom[12'd2664] = 16'h0040; // J row8
        status_font_rom[12'd2665] = 16'h0040; // J row9
        status_font_rom[12'd2666] = 16'h0040; // J row10
        status_font_rom[12'd2667] = 16'h00c0; // J row11
        status_font_rom[12'd2668] = 16'h00c0; // J row12
        status_font_rom[12'd2669] = 16'h0d80; // J row13
        status_font_rom[12'd2670] = 16'h0780; // J row14
        status_font_rom[12'd2671] = 16'h0000; // J row15
        status_font_rom[12'd2672] = 16'h0000; // K row0
        status_font_rom[12'd2673] = 16'h0000; // K row1
        status_font_rom[12'd2674] = 16'h0000; // K row2
        status_font_rom[12'd2675] = 16'h0410; // K row3
        status_font_rom[12'd2676] = 16'h0420; // K row4
        status_font_rom[12'd2677] = 16'h0460; // K row5
        status_font_rom[12'd2678] = 16'h04c0; // K row6
        status_font_rom[12'd2679] = 16'h0580; // K row7
        status_font_rom[12'd2680] = 16'h07c0; // K row8
        status_font_rom[12'd2681] = 16'h0640; // K row9
        status_font_rom[12'd2682] = 16'h0660; // K row10
        status_font_rom[12'd2683] = 16'h0420; // K row11
        status_font_rom[12'd2684] = 16'h0430; // K row12
        status_font_rom[12'd2685] = 16'h0410; // K row13
        status_font_rom[12'd2686] = 16'h0418; // K row14
        status_font_rom[12'd2687] = 16'h0000; // K row15
        status_font_rom[12'd2688] = 16'h0000; // L row0
        status_font_rom[12'd2689] = 16'h0000; // L row1
        status_font_rom[12'd2690] = 16'h0000; // L row2
        status_font_rom[12'd2691] = 16'h0400; // L row3
        status_font_rom[12'd2692] = 16'h0400; // L row4
        status_font_rom[12'd2693] = 16'h0400; // L row5
        status_font_rom[12'd2694] = 16'h0400; // L row6
        status_font_rom[12'd2695] = 16'h0400; // L row7
        status_font_rom[12'd2696] = 16'h0400; // L row8
        status_font_rom[12'd2697] = 16'h0400; // L row9
        status_font_rom[12'd2698] = 16'h0400; // L row10
        status_font_rom[12'd2699] = 16'h0400; // L row11
        status_font_rom[12'd2700] = 16'h0400; // L row12
        status_font_rom[12'd2701] = 16'h0400; // L row13
        status_font_rom[12'd2702] = 16'h07e0; // L row14
        status_font_rom[12'd2703] = 16'h0000; // L row15
        status_font_rom[12'd2704] = 16'h0000; // M row0
        status_font_rom[12'd2705] = 16'h0000; // M row1
        status_font_rom[12'd2706] = 16'h0000; // M row2
        status_font_rom[12'd2707] = 16'h1830; // M row3
        status_font_rom[12'd2708] = 16'h1830; // M row4
        status_font_rom[12'd2709] = 16'h1830; // M row5
        status_font_rom[12'd2710] = 16'h1c70; // M row6
        status_font_rom[12'd2711] = 16'h1450; // M row7
        status_font_rom[12'd2712] = 16'h1450; // M row8
        status_font_rom[12'd2713] = 16'h16d0; // M row9
        status_font_rom[12'd2714] = 16'h1290; // M row10
        status_font_rom[12'd2715] = 16'h1390; // M row11
        status_font_rom[12'd2716] = 16'h1110; // M row12
        status_font_rom[12'd2717] = 16'h1110; // M row13
        status_font_rom[12'd2718] = 16'h1010; // M row14
        status_font_rom[12'd2719] = 16'h0000; // M row15
        status_font_rom[12'd2720] = 16'h0000; // N row0
        status_font_rom[12'd2721] = 16'h0000; // N row1
        status_font_rom[12'd2722] = 16'h0000; // N row2
        status_font_rom[12'd2723] = 16'h0810; // N row3
        status_font_rom[12'd2724] = 16'h0c10; // N row4
        status_font_rom[12'd2725] = 16'h0e10; // N row5
        status_font_rom[12'd2726] = 16'h0a10; // N row6
        status_font_rom[12'd2727] = 16'h0b10; // N row7
        status_font_rom[12'd2728] = 16'h0910; // N row8
        status_font_rom[12'd2729] = 16'h0990; // N row9
        status_font_rom[12'd2730] = 16'h0890; // N row10
        status_font_rom[12'd2731] = 16'h08d0; // N row11
        status_font_rom[12'd2732] = 16'h0870; // N row12
        status_font_rom[12'd2733] = 16'h0830; // N row13
        status_font_rom[12'd2734] = 16'h0830; // N row14
        status_font_rom[12'd2735] = 16'h0000; // N row15
        status_font_rom[12'd2736] = 16'h0000; // O row0
        status_font_rom[12'd2737] = 16'h0000; // O row1
        status_font_rom[12'd2738] = 16'h0000; // O row2
        status_font_rom[12'd2739] = 16'h03c0; // O row3
        status_font_rom[12'd2740] = 16'h0660; // O row4
        status_font_rom[12'd2741] = 16'h0c30; // O row5
        status_font_rom[12'd2742] = 16'h1818; // O row6
        status_font_rom[12'd2743] = 16'h1818; // O row7
        status_font_rom[12'd2744] = 16'h1018; // O row8
        status_font_rom[12'd2745] = 16'h1818; // O row9
        status_font_rom[12'd2746] = 16'h1818; // O row10
        status_font_rom[12'd2747] = 16'h1818; // O row11
        status_font_rom[12'd2748] = 16'h0c30; // O row12
        status_font_rom[12'd2749] = 16'h0660; // O row13
        status_font_rom[12'd2750] = 16'h03c0; // O row14
        status_font_rom[12'd2751] = 16'h0000; // O row15
        status_font_rom[12'd2752] = 16'h0000; // P row0
        status_font_rom[12'd2753] = 16'h0000; // P row1
        status_font_rom[12'd2754] = 16'h0000; // P row2
        status_font_rom[12'd2755] = 16'h07c0; // P row3
        status_font_rom[12'd2756] = 16'h0430; // P row4
        status_font_rom[12'd2757] = 16'h0410; // P row5
        status_font_rom[12'd2758] = 16'h0410; // P row6
        status_font_rom[12'd2759] = 16'h0410; // P row7
        status_font_rom[12'd2760] = 16'h0430; // P row8
        status_font_rom[12'd2761] = 16'h07e0; // P row9
        status_font_rom[12'd2762] = 16'h0400; // P row10
        status_font_rom[12'd2763] = 16'h0400; // P row11
        status_font_rom[12'd2764] = 16'h0400; // P row12
        status_font_rom[12'd2765] = 16'h0400; // P row13
        status_font_rom[12'd2766] = 16'h0400; // P row14
        status_font_rom[12'd2767] = 16'h0000; // P row15
        status_font_rom[12'd2768] = 16'h0000; // Q row0
        status_font_rom[12'd2769] = 16'h0000; // Q row1
        status_font_rom[12'd2770] = 16'h0000; // Q row2
        status_font_rom[12'd2771] = 16'h03c0; // Q row3
        status_font_rom[12'd2772] = 16'h0660; // Q row4
        status_font_rom[12'd2773] = 16'h0c30; // Q row5
        status_font_rom[12'd2774] = 16'h1818; // Q row6
        status_font_rom[12'd2775] = 16'h1818; // Q row7
        status_font_rom[12'd2776] = 16'h1018; // Q row8
        status_font_rom[12'd2777] = 16'h1018; // Q row9
        status_font_rom[12'd2778] = 16'h1818; // Q row10
        status_font_rom[12'd2779] = 16'h1818; // Q row11
        status_font_rom[12'd2780] = 16'h0830; // Q row12
        status_font_rom[12'd2781] = 16'h0e60; // Q row13
        status_font_rom[12'd2782] = 16'h03c0; // Q row14
        status_font_rom[12'd2783] = 16'h0180; // Q row15
        status_font_rom[12'd2784] = 16'h0000; // R row0
        status_font_rom[12'd2785] = 16'h0000; // R row1
        status_font_rom[12'd2786] = 16'h0000; // R row2
        status_font_rom[12'd2787] = 16'h07e0; // R row3
        status_font_rom[12'd2788] = 16'h0430; // R row4
        status_font_rom[12'd2789] = 16'h0410; // R row5
        status_font_rom[12'd2790] = 16'h0410; // R row6
        status_font_rom[12'd2791] = 16'h0410; // R row7
        status_font_rom[12'd2792] = 16'h0430; // R row8
        status_font_rom[12'd2793] = 16'h07e0; // R row9
        status_font_rom[12'd2794] = 16'h04c0; // R row10
        status_font_rom[12'd2795] = 16'h0460; // R row11
        status_font_rom[12'd2796] = 16'h0420; // R row12
        status_font_rom[12'd2797] = 16'h0430; // R row13
        status_font_rom[12'd2798] = 16'h0410; // R row14
        status_font_rom[12'd2799] = 16'h0000; // R row15
        status_font_rom[12'd2800] = 16'h0000; // S row0
        status_font_rom[12'd2801] = 16'h0000; // S row1
        status_font_rom[12'd2802] = 16'h0000; // S row2
        status_font_rom[12'd2803] = 16'h03c0; // S row3
        status_font_rom[12'd2804] = 16'h0660; // S row4
        status_font_rom[12'd2805] = 16'h0c00; // S row5
        status_font_rom[12'd2806] = 16'h0c00; // S row6
        status_font_rom[12'd2807] = 16'h0600; // S row7
        status_font_rom[12'd2808] = 16'h0380; // S row8
        status_font_rom[12'd2809] = 16'h00e0; // S row9
        status_font_rom[12'd2810] = 16'h0030; // S row10
        status_font_rom[12'd2811] = 16'h0030; // S row11
        status_font_rom[12'd2812] = 16'h0030; // S row12
        status_font_rom[12'd2813] = 16'h0e60; // S row13
        status_font_rom[12'd2814] = 16'h03c0; // S row14
        status_font_rom[12'd2815] = 16'h0000; // S row15
        status_font_rom[12'd2816] = 16'h0000; // T row0
        status_font_rom[12'd2817] = 16'h0000; // T row1
        status_font_rom[12'd2818] = 16'h0000; // T row2
        status_font_rom[12'd2819] = 16'h1ff0; // T row3
        status_font_rom[12'd2820] = 16'h0180; // T row4
        status_font_rom[12'd2821] = 16'h0180; // T row5
        status_font_rom[12'd2822] = 16'h0180; // T row6
        status_font_rom[12'd2823] = 16'h0180; // T row7
        status_font_rom[12'd2824] = 16'h0180; // T row8
        status_font_rom[12'd2825] = 16'h0180; // T row9
        status_font_rom[12'd2826] = 16'h0180; // T row10
        status_font_rom[12'd2827] = 16'h0180; // T row11
        status_font_rom[12'd2828] = 16'h0180; // T row12
        status_font_rom[12'd2829] = 16'h0180; // T row13
        status_font_rom[12'd2830] = 16'h0180; // T row14
        status_font_rom[12'd2831] = 16'h0000; // T row15
        status_font_rom[12'd2832] = 16'h0000; // U row0
        status_font_rom[12'd2833] = 16'h0000; // U row1
        status_font_rom[12'd2834] = 16'h0000; // U row2
        status_font_rom[12'd2835] = 16'h0810; // U row3
        status_font_rom[12'd2836] = 16'h0810; // U row4
        status_font_rom[12'd2837] = 16'h0810; // U row5
        status_font_rom[12'd2838] = 16'h0810; // U row6
        status_font_rom[12'd2839] = 16'h0810; // U row7
        status_font_rom[12'd2840] = 16'h0810; // U row8
        status_font_rom[12'd2841] = 16'h0810; // U row9
        status_font_rom[12'd2842] = 16'h0830; // U row10
        status_font_rom[12'd2843] = 16'h0830; // U row11
        status_font_rom[12'd2844] = 16'h0c30; // U row12
        status_font_rom[12'd2845] = 16'h0660; // U row13
        status_font_rom[12'd2846] = 16'h03c0; // U row14
        status_font_rom[12'd2847] = 16'h0000; // U row15
        status_font_rom[12'd2848] = 16'h0000; // V row0
        status_font_rom[12'd2849] = 16'h0000; // V row1
        status_font_rom[12'd2850] = 16'h0000; // V row2
        status_font_rom[12'd2851] = 16'h1810; // V row3
        status_font_rom[12'd2852] = 16'h1830; // V row4
        status_font_rom[12'd2853] = 16'h0820; // V row5
        status_font_rom[12'd2854] = 16'h0c20; // V row6
        status_font_rom[12'd2855] = 16'h0c60; // V row7
        status_font_rom[12'd2856] = 16'h0440; // V row8
        status_font_rom[12'd2857] = 16'h0440; // V row9
        status_font_rom[12'd2858] = 16'h0640; // V row10
        status_font_rom[12'd2859] = 16'h02c0; // V row11
        status_font_rom[12'd2860] = 16'h0280; // V row12
        status_font_rom[12'd2861] = 16'h0380; // V row13
        status_font_rom[12'd2862] = 16'h0180; // V row14
        status_font_rom[12'd2863] = 16'h0000; // V row15
        status_font_rom[12'd2864] = 16'h0000; // W row0
        status_font_rom[12'd2865] = 16'h0000; // W row1
        status_font_rom[12'd2866] = 16'h0000; // W row2
        status_font_rom[12'd2867] = 16'h2186; // W row3
        status_font_rom[12'd2868] = 16'h2184; // W row4
        status_font_rom[12'd2869] = 16'h2184; // W row5
        status_font_rom[12'd2870] = 16'h31c4; // W row6
        status_font_rom[12'd2871] = 16'h324c; // W row7
        status_font_rom[12'd2872] = 16'h1248; // W row8
        status_font_rom[12'd2873] = 16'h1248; // W row9
        status_font_rom[12'd2874] = 16'h1268; // W row10
        status_font_rom[12'd2875] = 16'h1428; // W row11
        status_font_rom[12'd2876] = 16'h1c38; // W row12
        status_font_rom[12'd2877] = 16'h0c30; // W row13
        status_font_rom[12'd2878] = 16'h0c30; // W row14
        status_font_rom[12'd2879] = 16'h0000; // W row15
        status_font_rom[12'd2880] = 16'h0000; // Y row0
        status_font_rom[12'd2881] = 16'h0000; // Y row1
        status_font_rom[12'd2882] = 16'h0000; // Y row2
        status_font_rom[12'd2883] = 16'h1820; // Y row3
        status_font_rom[12'd2884] = 16'h0860; // Y row4
        status_font_rom[12'd2885] = 16'h0c40; // Y row5
        status_font_rom[12'd2886] = 16'h04c0; // Y row6
        status_font_rom[12'd2887] = 16'h0680; // Y row7
        status_font_rom[12'd2888] = 16'h0380; // Y row8
        status_font_rom[12'd2889] = 16'h0300; // Y row9
        status_font_rom[12'd2890] = 16'h0300; // Y row10
        status_font_rom[12'd2891] = 16'h0100; // Y row11
        status_font_rom[12'd2892] = 16'h0100; // Y row12
        status_font_rom[12'd2893] = 16'h0100; // Y row13
        status_font_rom[12'd2894] = 16'h0100; // Y row14
        status_font_rom[12'd2895] = 16'h0000; // Y row15
        status_font_rom[12'd2896] = 16'h0000; // Z row0
        status_font_rom[12'd2897] = 16'h0000; // Z row1
        status_font_rom[12'd2898] = 16'h0000; // Z row2
        status_font_rom[12'd2899] = 16'h0ff0; // Z row3
        status_font_rom[12'd2900] = 16'h0020; // Z row4
        status_font_rom[12'd2901] = 16'h0060; // Z row5
        status_font_rom[12'd2902] = 16'h0040; // Z row6
        status_font_rom[12'd2903] = 16'h00c0; // Z row7
        status_font_rom[12'd2904] = 16'h0180; // Z row8
        status_font_rom[12'd2905] = 16'h0100; // Z row9
        status_font_rom[12'd2906] = 16'h0300; // Z row10
        status_font_rom[12'd2907] = 16'h0600; // Z row11
        status_font_rom[12'd2908] = 16'h0400; // Z row12
        status_font_rom[12'd2909] = 16'h0c00; // Z row13
        status_font_rom[12'd2910] = 16'h0ff0; // Z row14
        status_font_rom[12'd2911] = 16'h0000; // Z row15
        status_font_rom[12'd2912] = 16'h0000; // . row0
        status_font_rom[12'd2913] = 16'h0000; // . row1
        status_font_rom[12'd2914] = 16'h0000; // . row2
        status_font_rom[12'd2915] = 16'h0000; // . row3
        status_font_rom[12'd2916] = 16'h0000; // . row4
        status_font_rom[12'd2917] = 16'h0000; // . row5
        status_font_rom[12'd2918] = 16'h0000; // . row6
        status_font_rom[12'd2919] = 16'h0000; // . row7
        status_font_rom[12'd2920] = 16'h0000; // . row8
        status_font_rom[12'd2921] = 16'h0000; // . row9
        status_font_rom[12'd2922] = 16'h0000; // . row10
        status_font_rom[12'd2923] = 16'h0000; // . row11
        status_font_rom[12'd2924] = 16'h0000; // . row12
        status_font_rom[12'd2925] = 16'h0180; // . row13
        status_font_rom[12'd2926] = 16'h0180; // . row14
        status_font_rom[12'd2927] = 16'h0000; // . row15
        status_font_rom[12'd2928] = 16'h0000; // - row0
        status_font_rom[12'd2929] = 16'h0000; // - row1
        status_font_rom[12'd2930] = 16'h0000; // - row2
        status_font_rom[12'd2931] = 16'h0000; // - row3
        status_font_rom[12'd2932] = 16'h0000; // - row4
        status_font_rom[12'd2933] = 16'h0000; // - row5
        status_font_rom[12'd2934] = 16'h0000; // - row6
        status_font_rom[12'd2935] = 16'h0000; // - row7
        status_font_rom[12'd2936] = 16'h0000; // - row8
        status_font_rom[12'd2937] = 16'h0000; // - row9
        status_font_rom[12'd2938] = 16'h03c0; // - row10
        status_font_rom[12'd2939] = 16'h0000; // - row11
        status_font_rom[12'd2940] = 16'h0000; // - row12
        status_font_rom[12'd2941] = 16'h0000; // - row13
        status_font_rom[12'd2942] = 16'h0000; // - row14
        status_font_rom[12'd2943] = 16'h0000; // - row15
        status_font_rom[12'd2944] = 16'h0000; // / row0
        status_font_rom[12'd2945] = 16'h0000; // / row1
        status_font_rom[12'd2946] = 16'h0020; // / row2
        status_font_rom[12'd2947] = 16'h0020; // / row3
        status_font_rom[12'd2948] = 16'h0040; // / row4
        status_font_rom[12'd2949] = 16'h0040; // / row5
        status_font_rom[12'd2950] = 16'h0040; // / row6
        status_font_rom[12'd2951] = 16'h0080; // / row7
        status_font_rom[12'd2952] = 16'h0080; // / row8
        status_font_rom[12'd2953] = 16'h0080; // / row9
        status_font_rom[12'd2954] = 16'h0180; // / row10
        status_font_rom[12'd2955] = 16'h0100; // / row11
        status_font_rom[12'd2956] = 16'h0100; // / row12
        status_font_rom[12'd2957] = 16'h0100; // / row13
        status_font_rom[12'd2958] = 16'h0200; // / row14
        status_font_rom[12'd2959] = 16'h0200; // / row15
        status_font_rom[12'd2960] = 16'h0000; // 分 row0
        status_font_rom[12'd2961] = 16'h0000; // 分 row1
        status_font_rom[12'd2962] = 16'h0420; // 分 row2
        status_font_rom[12'd2963] = 16'h0c30; // 分 row3
        status_font_rom[12'd2964] = 16'h0810; // 分 row4
        status_font_rom[12'd2965] = 16'h1808; // 分 row5
        status_font_rom[12'd2966] = 16'h300c; // 分 row6
        status_font_rom[12'd2967] = 16'h6006; // 分 row7
        status_font_rom[12'd2968] = 16'h5ffa; // 分 row8
        status_font_rom[12'd2969] = 16'h0208; // 分 row9
        status_font_rom[12'd2970] = 16'h0208; // 分 row10
        status_font_rom[12'd2971] = 16'h0608; // 分 row11
        status_font_rom[12'd2972] = 16'h0418; // 分 row12
        status_font_rom[12'd2973] = 16'h0c18; // 分 row13
        status_font_rom[12'd2974] = 16'h1810; // 分 row14
        status_font_rom[12'd2975] = 16'h70f0; // 分 row15
        status_font_rom[12'd2976] = 16'h0000; // 辨 row0
        status_font_rom[12'd2977] = 16'h0000; // 辨 row1
        status_font_rom[12'd2978] = 16'h3088; // 辨 row2
        status_font_rom[12'd2979] = 16'h1088; // 辨 row3
        status_font_rom[12'd2980] = 16'h7cbe; // 辨 row4
        status_font_rom[12'd2981] = 16'h0882; // 辨 row5
        status_font_rom[12'd2982] = 16'h2894; // 辨 row6
        status_font_rom[12'd2983] = 16'h2a94; // 辨 row7
        status_font_rom[12'd2984] = 16'h7efe; // 辨 row8
        status_font_rom[12'd2985] = 16'h1288; // 辨 row9
        status_font_rom[12'd2986] = 16'h1088; // 辨 row10
        status_font_rom[12'd2987] = 16'h7c88; // 辨 row11
        status_font_rom[12'd2988] = 16'h10be; // 辨 row12
        status_font_rom[12'd2989] = 16'h1108; // 辨 row13
        status_font_rom[12'd2990] = 16'h2108; // 辨 row14
        status_font_rom[12'd2991] = 16'h6208; // 辨 row15
        status_font_rom[12'd2992] = 16'h0000; // 记 row0
        status_font_rom[12'd2993] = 16'h0000; // 记 row1
        status_font_rom[12'd2994] = 16'h2000; // 记 row2
        status_font_rom[12'd2995] = 16'h11fc; // 记 row3
        status_font_rom[12'd2996] = 16'h0804; // 记 row4
        status_font_rom[12'd2997] = 16'h0004; // 记 row5
        status_font_rom[12'd2998] = 16'h7004; // 记 row6
        status_font_rom[12'd2999] = 16'h1004; // 记 row7
        status_font_rom[12'd3000] = 16'h11fc; // 记 row8
        status_font_rom[12'd3001] = 16'h1104; // 记 row9
        status_font_rom[12'd3002] = 16'h1100; // 记 row10
        status_font_rom[12'd3003] = 16'h1100; // 记 row11
        status_font_rom[12'd3004] = 16'h1100; // 记 row12
        status_font_rom[12'd3005] = 16'h1d02; // 记 row13
        status_font_rom[12'd3006] = 16'h1902; // 记 row14
        status_font_rom[12'd3007] = 16'h11fe; // 记 row15
        status_font_rom[12'd3008] = 16'h0000; // 录 row0
        status_font_rom[12'd3009] = 16'h0000; // 录 row1
        status_font_rom[12'd3010] = 16'h3ff8; // 录 row2
        status_font_rom[12'd3011] = 16'h0008; // 录 row3
        status_font_rom[12'd3012] = 16'h0008; // 录 row4
        status_font_rom[12'd3013] = 16'h1ff8; // 录 row5
        status_font_rom[12'd3014] = 16'h0008; // 录 row6
        status_font_rom[12'd3015] = 16'h0008; // 录 row7
        status_font_rom[12'd3016] = 16'h7ffe; // 录 row8
        status_font_rom[12'd3017] = 16'h0180; // 录 row9
        status_font_rom[12'd3018] = 16'h118c; // 录 row10
        status_font_rom[12'd3019] = 16'h0dd0; // 录 row11
        status_font_rom[12'd3020] = 16'h03e0; // 录 row12
        status_font_rom[12'd3021] = 16'h0fb0; // 录 row13
        status_font_rom[12'd3022] = 16'h3998; // 录 row14
        status_font_rom[12'd3023] = 16'h2186; // 录 row15
        status_font_rom[12'd3024] = 16'h0000; // 时 row0
        status_font_rom[12'd3025] = 16'h0000; // 时 row1
        status_font_rom[12'd3026] = 16'h0008; // 时 row2
        status_font_rom[12'd3027] = 16'h7c08; // 时 row3
        status_font_rom[12'd3028] = 16'h4408; // 时 row4
        status_font_rom[12'd3029] = 16'h45fe; // 时 row5
        status_font_rom[12'd3030] = 16'h4408; // 时 row6
        status_font_rom[12'd3031] = 16'h6408; // 时 row7
        status_font_rom[12'd3032] = 16'h7c88; // 时 row8
        status_font_rom[12'd3033] = 16'h44c8; // 时 row9
        status_font_rom[12'd3034] = 16'h4448; // 时 row10
        status_font_rom[12'd3035] = 16'h4428; // 时 row11
        status_font_rom[12'd3036] = 16'h6408; // 时 row12
        status_font_rom[12'd3037] = 16'h7c08; // 时 row13
        status_font_rom[12'd3038] = 16'h4008; // 时 row14
        status_font_rom[12'd3039] = 16'h0078; // 时 row15
        status_font_rom[12'd3040] = 16'h0000; // 间 row0
        status_font_rom[12'd3041] = 16'h0000; // 间 row1
        status_font_rom[12'd3042] = 16'h33fe; // 间 row2
        status_font_rom[12'd3043] = 16'h1006; // 间 row3
        status_font_rom[12'd3044] = 16'h0006; // 间 row4
        status_font_rom[12'd3045] = 16'h2006; // 间 row5
        status_font_rom[12'd3046] = 16'h27e6; // 间 row6
        status_font_rom[12'd3047] = 16'h2426; // 间 row7
        status_font_rom[12'd3048] = 16'h2426; // 间 row8
        status_font_rom[12'd3049] = 16'h27e6; // 间 row9
        status_font_rom[12'd3050] = 16'h2426; // 间 row10
        status_font_rom[12'd3051] = 16'h2426; // 间 row11
        status_font_rom[12'd3052] = 16'h2426; // 间 row12
        status_font_rom[12'd3053] = 16'h27e6; // 间 row13
        status_font_rom[12'd3054] = 16'h2006; // 间 row14
        status_font_rom[12'd3055] = 16'h2006; // 间 row15
        status_font_rom[12'd3056] = 16'h0000; // 事 row0
        status_font_rom[12'd3057] = 16'h0000; // 事 row1
        status_font_rom[12'd3058] = 16'h0180; // 事 row2
        status_font_rom[12'd3059] = 16'h7ffe; // 事 row3
        status_font_rom[12'd3060] = 16'h0180; // 事 row4
        status_font_rom[12'd3061] = 16'h1ff8; // 事 row5
        status_font_rom[12'd3062] = 16'h1188; // 事 row6
        status_font_rom[12'd3063] = 16'h1ff8; // 事 row7
        status_font_rom[12'd3064] = 16'h0180; // 事 row8
        status_font_rom[12'd3065] = 16'h3ffc; // 事 row9
        status_font_rom[12'd3066] = 16'h018c; // 事 row10
        status_font_rom[12'd3067] = 16'h7ffe; // 事 row11
        status_font_rom[12'd3068] = 16'h018c; // 事 row12
        status_font_rom[12'd3069] = 16'h3ffc; // 事 row13
        status_font_rom[12'd3070] = 16'h018c; // 事 row14
        status_font_rom[12'd3071] = 16'h0180; // 事 row15
        status_font_rom[12'd3072] = 16'h0000; // 启 row0
        status_font_rom[12'd3073] = 16'h0100; // 启 row1
        status_font_rom[12'd3074] = 16'h0180; // 启 row2
        status_font_rom[12'd3075] = 16'h0080; // 启 row3
        status_font_rom[12'd3076] = 16'h1ffc; // 启 row4
        status_font_rom[12'd3077] = 16'h1004; // 启 row5
        status_font_rom[12'd3078] = 16'h1004; // 启 row6
        status_font_rom[12'd3079] = 16'h3ffc; // 启 row7
        status_font_rom[12'd3080] = 16'h3000; // 启 row8
        status_font_rom[12'd3081] = 16'h3000; // 启 row9
        status_font_rom[12'd3082] = 16'h3ffc; // 启 row10
        status_font_rom[12'd3083] = 16'h2c04; // 启 row11
        status_font_rom[12'd3084] = 16'h2c04; // 启 row12
        status_font_rom[12'd3085] = 16'h2c04; // 启 row13
        status_font_rom[12'd3086] = 16'h6c04; // 启 row14
        status_font_rom[12'd3087] = 16'h4ffc; // 启 row15
        status_font_rom[12'd3088] = 16'h0000; // 失 row0
        status_font_rom[12'd3089] = 16'h0100; // 失 row1
        status_font_rom[12'd3090] = 16'h1980; // 失 row2
        status_font_rom[12'd3091] = 16'h1180; // 失 row3
        status_font_rom[12'd3092] = 16'h1ffc; // 失 row4
        status_font_rom[12'd3093] = 16'h3180; // 失 row5
        status_font_rom[12'd3094] = 16'h2180; // 失 row6
        status_font_rom[12'd3095] = 16'h4100; // 失 row7
        status_font_rom[12'd3096] = 16'h0180; // 失 row8
        status_font_rom[12'd3097] = 16'h7ffe; // 失 row9
        status_font_rom[12'd3098] = 16'h0180; // 失 row10
        status_font_rom[12'd3099] = 16'h0340; // 失 row11
        status_font_rom[12'd3100] = 16'h0640; // 失 row12
        status_font_rom[12'd3101] = 16'h0420; // 失 row13
        status_font_rom[12'd3102] = 16'h1818; // 失 row14
        status_font_rom[12'd3103] = 16'h700e; // 失 row15
        status_font_rom[12'd3104] = 16'h0000; // 败 row0
        status_font_rom[12'd3105] = 16'h0000; // 败 row1
        status_font_rom[12'd3106] = 16'h7e20; // 败 row2
        status_font_rom[12'd3107] = 16'h4240; // 败 row3
        status_font_rom[12'd3108] = 16'h4a7e; // 败 row4
        status_font_rom[12'd3109] = 16'h4a44; // 败 row5
        status_font_rom[12'd3110] = 16'h4a84; // 败 row6
        status_font_rom[12'd3111] = 16'h4ac4; // 败 row7
        status_font_rom[12'd3112] = 16'h4ac8; // 败 row8
        status_font_rom[12'd3113] = 16'h4a48; // 败 row9
        status_font_rom[12'd3114] = 16'h4a28; // 败 row10
        status_font_rom[12'd3115] = 16'h5a30; // 败 row11
        status_font_rom[12'd3116] = 16'h1010; // 败 row12
        status_font_rom[12'd3117] = 16'h1438; // 败 row13
        status_font_rom[12'd3118] = 16'h226c; // 败 row14
        status_font_rom[12'd3119] = 16'h62c6; // 败 row15
        status_font_rom[12'd3120] = 16'h0000; // 移 row0
        status_font_rom[12'd3121] = 16'h0020; // 移 row1
        status_font_rom[12'd3122] = 16'h3c60; // 移 row2
        status_font_rom[12'd3123] = 16'h70fc; // 移 row3
        status_font_rom[12'd3124] = 16'h118c; // 移 row4
        status_font_rom[12'd3125] = 16'h1058; // 移 row5
        status_font_rom[12'd3126] = 16'h7c70; // 移 row6
        status_font_rom[12'd3127] = 16'h10f0; // 移 row7
        status_font_rom[12'd3128] = 16'h3b30; // 移 row8
        status_font_rom[12'd3129] = 16'h3c3e; // 移 row9
        status_font_rom[12'd3130] = 16'h34c6; // 移 row10
        status_font_rom[12'd3131] = 16'h5184; // 移 row11
        status_font_rom[12'd3132] = 16'h506c; // 移 row12
        status_font_rom[12'd3133] = 16'h1038; // 移 row13
        status_font_rom[12'd3134] = 16'h1070; // 移 row14
        status_font_rom[12'd3135] = 16'h11c0; // 移 row15
        status_font_rom[12'd3136] = 16'h0000; // 除 row0
        status_font_rom[12'd3137] = 16'h0020; // 除 row1
        status_font_rom[12'd3138] = 16'h7c30; // 除 row2
        status_font_rom[12'd3139] = 16'h4858; // 除 row3
        status_font_rom[12'd3140] = 16'h498c; // 除 row4
        status_font_rom[12'd3141] = 16'h5306; // 除 row5
        status_font_rom[12'd3142] = 16'h51fc; // 除 row6
        status_font_rom[12'd3143] = 16'h4820; // 除 row7
        status_font_rom[12'd3144] = 16'h4820; // 除 row8
        status_font_rom[12'd3145] = 16'h4820; // 除 row9
        status_font_rom[12'd3146] = 16'h47fe; // 除 row10
        status_font_rom[12'd3147] = 16'h4c20; // 除 row11
        status_font_rom[12'd3148] = 16'h592c; // 除 row12
        status_font_rom[12'd3149] = 16'h4124; // 除 row13
        status_font_rom[12'd3150] = 16'h4222; // 除 row14
        status_font_rom[12'd3151] = 16'h4222; // 除 row15
        status_font_rom[12'd3152] = 16'h0000; // 错 row0
        status_font_rom[12'd3153] = 16'h1008; // 错 row1
        status_font_rom[12'd3154] = 16'h2048; // 错 row2
        status_font_rom[12'd3155] = 16'h3c48; // 错 row3
        status_font_rom[12'd3156] = 16'h41fe; // 错 row4
        status_font_rom[12'd3157] = 16'h4048; // 错 row5
        status_font_rom[12'd3158] = 16'h3c48; // 错 row6
        status_font_rom[12'd3159] = 16'h11fe; // 错 row7
        status_font_rom[12'd3160] = 16'h1000; // 错 row8
        status_font_rom[12'd3161] = 16'h10fc; // 错 row9
        status_font_rom[12'd3162] = 16'h7e84; // 错 row10
        status_font_rom[12'd3163] = 16'h1084; // 错 row11
        status_font_rom[12'd3164] = 16'h10fc; // 错 row12
        status_font_rom[12'd3165] = 16'h1084; // 错 row13
        status_font_rom[12'd3166] = 16'h1c84; // 错 row14
        status_font_rom[12'd3167] = 16'h18fc; // 错 row15
        status_font_rom[12'd3168] = 16'h0000; // 误 row0
        status_font_rom[12'd3169] = 16'h0000; // 误 row1
        status_font_rom[12'd3170] = 16'h21fc; // 误 row2
        status_font_rom[12'd3171] = 16'h1104; // 误 row3
        status_font_rom[12'd3172] = 16'h1904; // 误 row4
        status_font_rom[12'd3173] = 16'h0104; // 误 row5
        status_font_rom[12'd3174] = 16'h71fc; // 误 row6
        status_font_rom[12'd3175] = 16'h1000; // 误 row7
        status_font_rom[12'd3176] = 16'h13fe; // 误 row8
        status_font_rom[12'd3177] = 16'h1020; // 误 row9
        status_font_rom[12'd3178] = 16'h1020; // 误 row10
        status_font_rom[12'd3179] = 16'h13fe; // 误 row11
        status_font_rom[12'd3180] = 16'h1060; // 误 row12
        status_font_rom[12'd3181] = 16'h1c50; // 误 row13
        status_font_rom[12'd3182] = 16'h1888; // 误 row14
        status_font_rom[12'd3183] = 16'h130e; // 误 row15
        status_font_rom[12'd3184] = 16'h0000; // 未 row0
        status_font_rom[12'd3185] = 16'h0000; // 未 row1
        status_font_rom[12'd3186] = 16'h0180; // 未 row2
        status_font_rom[12'd3187] = 16'h0180; // 未 row3
        status_font_rom[12'd3188] = 16'h3ffc; // 未 row4
        status_font_rom[12'd3189] = 16'h0180; // 未 row5
        status_font_rom[12'd3190] = 16'h0180; // 未 row6
        status_font_rom[12'd3191] = 16'h0180; // 未 row7
        status_font_rom[12'd3192] = 16'h7ffe; // 未 row8
        status_font_rom[12'd3193] = 16'h03c0; // 未 row9
        status_font_rom[12'd3194] = 16'h03c0; // 未 row10
        status_font_rom[12'd3195] = 16'h05a0; // 未 row11
        status_font_rom[12'd3196] = 16'h0990; // 未 row12
        status_font_rom[12'd3197] = 16'h1198; // 未 row13
        status_font_rom[12'd3198] = 16'h6186; // 未 row14
        status_font_rom[12'd3199] = 16'h4182; // 未 row15
        status_font_rom[12'd3200] = 16'h0000; // 知 row0
        status_font_rom[12'd3201] = 16'h0000; // 知 row1
        status_font_rom[12'd3202] = 16'h3000; // 知 row2
        status_font_rom[12'd3203] = 16'h207c; // 知 row3
        status_font_rom[12'd3204] = 16'h3f44; // 知 row4
        status_font_rom[12'd3205] = 16'h6844; // 知 row5
        status_font_rom[12'd3206] = 16'h4844; // 知 row6
        status_font_rom[12'd3207] = 16'h0844; // 知 row7
        status_font_rom[12'd3208] = 16'h7f44; // 知 row8
        status_font_rom[12'd3209] = 16'h0844; // 知 row9
        status_font_rom[12'd3210] = 16'h0844; // 知 row10
        status_font_rom[12'd3211] = 16'h0c44; // 知 row11
        status_font_rom[12'd3212] = 16'h1644; // 知 row12
        status_font_rom[12'd3213] = 16'h1344; // 知 row13
        status_font_rom[12'd3214] = 16'h217c; // 知 row14
        status_font_rom[12'd3215] = 16'h6044; // 知 row15
        status_font_rom[12'd3216] = 16'h0000; // 暂 row0
        status_font_rom[12'd3217] = 16'h0804; // 暂 row1
        status_font_rom[12'd3218] = 16'h7f78; // 暂 row2
        status_font_rom[12'd3219] = 16'h3040; // 暂 row3
        status_font_rom[12'd3220] = 16'h2440; // 暂 row4
        status_font_rom[12'd3221] = 16'h7f7e; // 暂 row5
        status_font_rom[12'd3222] = 16'h0448; // 暂 row6
        status_font_rom[12'd3223] = 16'h0f48; // 暂 row7
        status_font_rom[12'd3224] = 16'h7cc8; // 暂 row8
        status_font_rom[12'd3225] = 16'h0488; // 暂 row9
        status_font_rom[12'd3226] = 16'h0000; // 暂 row10
        status_font_rom[12'd3227] = 16'h1ff8; // 暂 row11
        status_font_rom[12'd3228] = 16'h1008; // 暂 row12
        status_font_rom[12'd3229] = 16'h1ff8; // 暂 row13
        status_font_rom[12'd3230] = 16'h1008; // 暂 row14
        status_font_rom[12'd3231] = 16'h1ff8; // 暂 row15
        status_font_rom[12'd3232] = 16'h0000; // 公 row0
        status_font_rom[12'd3233] = 16'h0000; // 公 row1
        status_font_rom[12'd3234] = 16'h0420; // 公 row2
        status_font_rom[12'd3235] = 16'h0c20; // 公 row3
        status_font_rom[12'd3236] = 16'h0810; // 公 row4
        status_font_rom[12'd3237] = 16'h1818; // 公 row5
        status_font_rom[12'd3238] = 16'h100c; // 公 row6
        status_font_rom[12'd3239] = 16'h2106; // 公 row7
        status_font_rom[12'd3240] = 16'h6302; // 公 row8
        status_font_rom[12'd3241] = 16'h0200; // 公 row9
        status_font_rom[12'd3242] = 16'h0620; // 公 row10
        status_font_rom[12'd3243] = 16'h0c30; // 公 row11
        status_font_rom[12'd3244] = 16'h0818; // 公 row12
        status_font_rom[12'd3245] = 16'h18f8; // 公 row13
        status_font_rom[12'd3246] = 16'h3fcc; // 公 row14
        status_font_rom[12'd3247] = 16'h0004; // 公 row15
        status_font_rom[12'd3248] = 16'h0000; // 区 row0
        status_font_rom[12'd3249] = 16'h0000; // 区 row1
        status_font_rom[12'd3250] = 16'h3ffe; // 区 row2
        status_font_rom[12'd3251] = 16'h2000; // 区 row3
        status_font_rom[12'd3252] = 16'h2010; // 区 row4
        status_font_rom[12'd3253] = 16'h2c10; // 区 row5
        status_font_rom[12'd3254] = 16'h2620; // 区 row6
        status_font_rom[12'd3255] = 16'h2360; // 区 row7
        status_font_rom[12'd3256] = 16'h21c0; // 区 row8
        status_font_rom[12'd3257] = 16'h20c0; // 区 row9
        status_font_rom[12'd3258] = 16'h2160; // 区 row10
        status_font_rom[12'd3259] = 16'h2630; // 区 row11
        status_font_rom[12'd3260] = 16'h2c18; // 区 row12
        status_font_rom[12'd3261] = 16'h2808; // 区 row13
        status_font_rom[12'd3262] = 16'h2000; // 区 row14
        status_font_rom[12'd3263] = 16'h3ffe; // 区 row15
        status_font_rom[12'd3264] = 16'h0000; // 发 row0
        status_font_rom[12'd3265] = 16'h0100; // 发 row1
        status_font_rom[12'd3266] = 16'h1918; // 发 row2
        status_font_rom[12'd3267] = 16'h1108; // 发 row3
        status_font_rom[12'd3268] = 16'h1100; // 发 row4
        status_font_rom[12'd3269] = 16'h3ffe; // 发 row5
        status_font_rom[12'd3270] = 16'h0300; // 发 row6
        status_font_rom[12'd3271] = 16'h0200; // 发 row7
        status_font_rom[12'd3272] = 16'h07f8; // 发 row8
        status_font_rom[12'd3273] = 16'h0608; // 发 row9
        status_font_rom[12'd3274] = 16'h0f10; // 发 row10
        status_font_rom[12'd3275] = 16'h0930; // 发 row11
        status_font_rom[12'd3276] = 16'h10e0; // 发 row12
        status_font_rom[12'd3277] = 16'h30e0; // 发 row13
        status_font_rom[12'd3278] = 16'h41b0; // 发 row14
        status_font_rom[12'd3279] = 16'h0f1e; // 发 row15
        status_font_rom[12'd3280] = 16'h0000; // 告 row0
        status_font_rom[12'd3281] = 16'h0080; // 告 row1
        status_font_rom[12'd3282] = 16'h0880; // 告 row2
        status_font_rom[12'd3283] = 16'h1880; // 告 row3
        status_font_rom[12'd3284] = 16'h1ffc; // 告 row4
        status_font_rom[12'd3285] = 16'h3080; // 告 row5
        status_font_rom[12'd3286] = 16'h6080; // 告 row6
        status_font_rom[12'd3287] = 16'h0080; // 告 row7
        status_font_rom[12'd3288] = 16'h7ffe; // 告 row8
        status_font_rom[12'd3289] = 16'h0000; // 告 row9
        status_font_rom[12'd3290] = 16'h1ff8; // 告 row10
        status_font_rom[12'd3291] = 16'h1008; // 告 row11
        status_font_rom[12'd3292] = 16'h1008; // 告 row12
        status_font_rom[12'd3293] = 16'h1008; // 告 row13
        status_font_rom[12'd3294] = 16'h1008; // 告 row14
        status_font_rom[12'd3295] = 16'h1ff8; // 告 row15
        status_font_rom[12'd3296] = 16'h0000; // 园 row0
        status_font_rom[12'd3297] = 16'h0000; // 园 row1
        status_font_rom[12'd3298] = 16'h7ffe; // 园 row2
        status_font_rom[12'd3299] = 16'h6006; // 园 row3
        status_font_rom[12'd3300] = 16'h6006; // 园 row4
        status_font_rom[12'd3301] = 16'h6ff6; // 园 row5
        status_font_rom[12'd3302] = 16'h6006; // 园 row6
        status_font_rom[12'd3303] = 16'h6006; // 园 row7
        status_font_rom[12'd3304] = 16'h7ffe; // 园 row8
        status_font_rom[12'd3305] = 16'h6246; // 园 row9
        status_font_rom[12'd3306] = 16'h6246; // 园 row10
        status_font_rom[12'd3307] = 16'h6446; // 园 row11
        status_font_rom[12'd3308] = 16'h644e; // 园 row12
        status_font_rom[12'd3309] = 16'h7876; // 园 row13
        status_font_rom[12'd3310] = 16'h6006; // 园 row14
        status_font_rom[12'd3311] = 16'h7ffe; // 园 row15
        status_font_rom[12'd3312] = 16'h0000; // 均 row0
        status_font_rom[12'd3313] = 16'h0040; // 均 row1
        status_font_rom[12'd3314] = 16'h1040; // 均 row2
        status_font_rom[12'd3315] = 16'h1080; // 均 row3
        status_font_rom[12'd3316] = 16'h10fe; // 均 row4
        status_font_rom[12'd3317] = 16'h1102; // 均 row5
        status_font_rom[12'd3318] = 16'h7f02; // 均 row6
        status_font_rom[12'd3319] = 16'h1202; // 均 row7
        status_font_rom[12'd3320] = 16'h10c2; // 均 row8
        status_font_rom[12'd3321] = 16'h1062; // 均 row9
        status_font_rom[12'd3322] = 16'h1022; // 均 row10
        status_font_rom[12'd3323] = 16'h141e; // 均 row11
        status_font_rom[12'd3324] = 16'h1c64; // 均 row12
        status_font_rom[12'd3325] = 16'h71c4; // 均 row13
        status_font_rom[12'd3326] = 16'h4104; // 均 row14
        status_font_rom[12'd3327] = 16'h0004; // 均 row15
        status_font_rom[12'd3328] = 16'h0000; // 复 row0
        status_font_rom[12'd3329] = 16'h0800; // 复 row1
        status_font_rom[12'd3330] = 16'h0800; // 复 row2
        status_font_rom[12'd3331] = 16'h1ffc; // 复 row3
        status_font_rom[12'd3332] = 16'h2000; // 复 row4
        status_font_rom[12'd3333] = 16'h6ff8; // 复 row5
        status_font_rom[12'd3334] = 16'h1808; // 复 row6
        status_font_rom[12'd3335] = 16'h1ff8; // 复 row7
        status_font_rom[12'd3336] = 16'h1808; // 复 row8
        status_font_rom[12'd3337] = 16'h1ff8; // 复 row9
        status_font_rom[12'd3338] = 16'h0400; // 复 row10
        status_font_rom[12'd3339] = 16'h0ff8; // 复 row11
        status_font_rom[12'd3340] = 16'h1c10; // 复 row12
        status_font_rom[12'd3341] = 16'h2660; // 复 row13
        status_font_rom[12'd3342] = 16'h03c0; // 复 row14
        status_font_rom[12'd3343] = 16'h0ff0; // 复 row15
        status_font_rom[12'd3344] = 16'h0000; // 展 row0
        status_font_rom[12'd3345] = 16'h0000; // 展 row1
        status_font_rom[12'd3346] = 16'h3ffc; // 展 row2
        status_font_rom[12'd3347] = 16'h3004; // 展 row3
        status_font_rom[12'd3348] = 16'h3004; // 展 row4
        status_font_rom[12'd3349] = 16'h3ffc; // 展 row5
        status_font_rom[12'd3350] = 16'h2010; // 展 row6
        status_font_rom[12'd3351] = 16'h2310; // 展 row7
        status_font_rom[12'd3352] = 16'h2ffe; // 展 row8
        status_font_rom[12'd3353] = 16'h2310; // 展 row9
        status_font_rom[12'd3354] = 16'h2310; // 展 row10
        status_font_rom[12'd3355] = 16'h3ffe; // 展 row11
        status_font_rom[12'd3356] = 16'h2444; // 展 row12
        status_font_rom[12'd3357] = 16'h2438; // 展 row13
        status_font_rom[12'd3358] = 16'h6430; // 展 row14
        status_font_rom[12'd3359] = 16'h478c; // 展 row15
        status_font_rom[12'd3360] = 16'h0000; // 巡 row0
        status_font_rom[12'd3361] = 16'h0000; // 巡 row1
        status_font_rom[12'd3362] = 16'h6124; // 巡 row2
        status_font_rom[12'd3363] = 16'h3264; // 巡 row3
        status_font_rom[12'd3364] = 16'h1248; // 巡 row4
        status_font_rom[12'd3365] = 16'h06c8; // 巡 row5
        status_font_rom[12'd3366] = 16'h0490; // 巡 row6
        status_font_rom[12'd3367] = 16'h7490; // 巡 row7
        status_font_rom[12'd3368] = 16'h1648; // 巡 row8
        status_font_rom[12'd3369] = 16'h1248; // 巡 row9
        status_font_rom[12'd3370] = 16'h1364; // 巡 row10
        status_font_rom[12'd3371] = 16'h1124; // 巡 row11
        status_font_rom[12'd3372] = 16'h1132; // 巡 row12
        status_font_rom[12'd3373] = 16'h3000; // 巡 row13
        status_font_rom[12'd3374] = 16'h6c00; // 巡 row14
        status_font_rom[12'd3375] = 16'h43fe; // 巡 row15
        status_font_rom[12'd3376] = 16'h0000; // 应 row0
        status_font_rom[12'd3377] = 16'h0080; // 应 row1
        status_font_rom[12'd3378] = 16'h0080; // 应 row2
        status_font_rom[12'd3379] = 16'h00c0; // 应 row3
        status_font_rom[12'd3380] = 16'h3ffe; // 应 row4
        status_font_rom[12'd3381] = 16'h2000; // 应 row5
        status_font_rom[12'd3382] = 16'h2084; // 应 row6
        status_font_rom[12'd3383] = 16'h2084; // 应 row7
        status_font_rom[12'd3384] = 16'h248c; // 应 row8
        status_font_rom[12'd3385] = 16'h24c8; // 应 row9
        status_font_rom[12'd3386] = 16'h2448; // 应 row10
        status_font_rom[12'd3387] = 16'h2258; // 应 row11
        status_font_rom[12'd3388] = 16'h2210; // 应 row12
        status_font_rom[12'd3389] = 16'h2030; // 应 row13
        status_font_rom[12'd3390] = 16'h6020; // 应 row14
        status_font_rom[12'd3391] = 16'h5ffe; // 应 row15
        status_font_rom[12'd3392] = 16'h0000; // 急 row0
        status_font_rom[12'd3393] = 16'h0400; // 急 row1
        status_font_rom[12'd3394] = 16'h0400; // 急 row2
        status_font_rom[12'd3395] = 16'h0fe0; // 急 row3
        status_font_rom[12'd3396] = 16'h1040; // 急 row4
        status_font_rom[12'd3397] = 16'h3ff8; // 急 row5
        status_font_rom[12'd3398] = 16'h4008; // 急 row6
        status_font_rom[12'd3399] = 16'h0008; // 急 row7
        status_font_rom[12'd3400] = 16'h1ff8; // 急 row8
        status_font_rom[12'd3401] = 16'h0008; // 急 row9
        status_font_rom[12'd3402] = 16'h1ff8; // 急 row10
        status_font_rom[12'd3403] = 16'h0100; // 急 row11
        status_font_rom[12'd3404] = 16'h298c; // 急 row12
        status_font_rom[12'd3405] = 16'h28c4; // 急 row13
        status_font_rom[12'd3406] = 16'h6812; // 急 row14
        status_font_rom[12'd3407] = 16'h47f0; // 急 row15
        status_font_rom[12'd3408] = 16'h0000; // 恢 row0
        status_font_rom[12'd3409] = 16'h1080; // 恢 row1
        status_font_rom[12'd3410] = 16'h1080; // 恢 row2
        status_font_rom[12'd3411] = 16'h1080; // 恢 row3
        status_font_rom[12'd3412] = 16'h1bfe; // 恢 row4
        status_font_rom[12'd3413] = 16'h7880; // 恢 row5
        status_font_rom[12'd3414] = 16'h5510; // 恢 row6
        status_font_rom[12'd3415] = 16'h5110; // 恢 row7
        status_font_rom[12'd3416] = 16'h5152; // 恢 row8
        status_font_rom[12'd3417] = 16'h1154; // 恢 row9
        status_font_rom[12'd3418] = 16'h1254; // 恢 row10
        status_font_rom[12'd3419] = 16'h1230; // 恢 row11
        status_font_rom[12'd3420] = 16'h1638; // 恢 row12
        status_font_rom[12'd3421] = 16'h1468; // 恢 row13
        status_font_rom[12'd3422] = 16'h104c; // 恢 row14
        status_font_rom[12'd3423] = 16'h1186; // 恢 row15
        status_font_rom[12'd3424] = 16'h0000; // 日 row0
        status_font_rom[12'd3425] = 16'h0000; // 日 row1
        status_font_rom[12'd3426] = 16'h0000; // 日 row2
        status_font_rom[12'd3427] = 16'h1ff8; // 日 row3
        status_font_rom[12'd3428] = 16'h1008; // 日 row4
        status_font_rom[12'd3429] = 16'h1008; // 日 row5
        status_font_rom[12'd3430] = 16'h1008; // 日 row6
        status_font_rom[12'd3431] = 16'h1008; // 日 row7
        status_font_rom[12'd3432] = 16'h1ff8; // 日 row8
        status_font_rom[12'd3433] = 16'h1008; // 日 row9
        status_font_rom[12'd3434] = 16'h1008; // 日 row10
        status_font_rom[12'd3435] = 16'h1008; // 日 row11
        status_font_rom[12'd3436] = 16'h1008; // 日 row12
        status_font_rom[12'd3437] = 16'h1008; // 日 row13
        status_font_rom[12'd3438] = 16'h1ff8; // 日 row14
        status_font_rom[12'd3439] = 16'h1008; // 日 row15
        status_font_rom[12'd3440] = 16'h0000; // 果 row0
        status_font_rom[12'd3441] = 16'h0000; // 果 row1
        status_font_rom[12'd3442] = 16'h1ffc; // 果 row2
        status_font_rom[12'd3443] = 16'h118c; // 果 row3
        status_font_rom[12'd3444] = 16'h118c; // 果 row4
        status_font_rom[12'd3445] = 16'h1ffc; // 果 row5
        status_font_rom[12'd3446] = 16'h118c; // 果 row6
        status_font_rom[12'd3447] = 16'h118c; // 果 row7
        status_font_rom[12'd3448] = 16'h1ffc; // 果 row8
        status_font_rom[12'd3449] = 16'h0180; // 果 row9
        status_font_rom[12'd3450] = 16'h7ffe; // 果 row10
        status_font_rom[12'd3451] = 16'h03c0; // 果 row11
        status_font_rom[12'd3452] = 16'h07a0; // 果 row12
        status_font_rom[12'd3453] = 16'h0998; // 果 row13
        status_font_rom[12'd3454] = 16'h318c; // 果 row14
        status_font_rom[12'd3455] = 16'h6186; // 果 row15
        status_font_rom[12'd3456] = 16'h0000; // 校 row0
        status_font_rom[12'd3457] = 16'h1000; // 校 row1
        status_font_rom[12'd3458] = 16'h1020; // 校 row2
        status_font_rom[12'd3459] = 16'h1020; // 校 row3
        status_font_rom[12'd3460] = 16'h13fe; // 校 row4
        status_font_rom[12'd3461] = 16'h7c00; // 校 row5
        status_font_rom[12'd3462] = 16'h1088; // 校 row6
        status_font_rom[12'd3463] = 16'h3984; // 校 row7
        status_font_rom[12'd3464] = 16'h3b0e; // 校 row8
        status_font_rom[12'd3465] = 16'h3488; // 校 row9
        status_font_rom[12'd3466] = 16'h14d8; // 校 row10
        status_font_rom[12'd3467] = 16'h5050; // 校 row11
        status_font_rom[12'd3468] = 16'h5030; // 校 row12
        status_font_rom[12'd3469] = 16'h1070; // 校 row13
        status_font_rom[12'd3470] = 16'h10d8; // 校 row14
        status_font_rom[12'd3471] = 16'h138e; // 校 row15
        status_font_rom[12'd3472] = 16'h0000; // 用 row0
        status_font_rom[12'd3473] = 16'h0000; // 用 row1
        status_font_rom[12'd3474] = 16'h0000; // 用 row2
        status_font_rom[12'd3475] = 16'h3ffc; // 用 row3
        status_font_rom[12'd3476] = 16'h3184; // 用 row4
        status_font_rom[12'd3477] = 16'h3184; // 用 row5
        status_font_rom[12'd3478] = 16'h3ffc; // 用 row6
        status_font_rom[12'd3479] = 16'h3184; // 用 row7
        status_font_rom[12'd3480] = 16'h3184; // 用 row8
        status_font_rom[12'd3481] = 16'h3184; // 用 row9
        status_font_rom[12'd3482] = 16'h3ffc; // 用 row10
        status_font_rom[12'd3483] = 16'h2184; // 用 row11
        status_font_rom[12'd3484] = 16'h2184; // 用 row12
        status_font_rom[12'd3485] = 16'h2184; // 用 row13
        status_font_rom[12'd3486] = 16'h2184; // 用 row14
        status_font_rom[12'd3487] = 16'h4184; // 用 row15
        status_font_rom[12'd3488] = 16'h0000; // 维 row0
        status_font_rom[12'd3489] = 16'h0000; // 维 row1
        status_font_rom[12'd3490] = 16'h1090; // 维 row2
        status_font_rom[12'd3491] = 16'h1080; // 维 row3
        status_font_rom[12'd3492] = 16'h21fe; // 维 row4
        status_font_rom[12'd3493] = 16'h2590; // 维 row5
        status_font_rom[12'd3494] = 16'h4b90; // 维 row6
        status_font_rom[12'd3495] = 16'h7b90; // 维 row7
        status_font_rom[12'd3496] = 16'h11fe; // 维 row8
        status_font_rom[12'd3497] = 16'h1190; // 维 row9
        status_font_rom[12'd3498] = 16'h2d90; // 维 row10
        status_font_rom[12'd3499] = 16'h71fe; // 维 row11
        status_font_rom[12'd3500] = 16'h0190; // 维 row12
        status_font_rom[12'd3501] = 16'h0d90; // 维 row13
        status_font_rom[12'd3502] = 16'h71fe; // 维 row14
        status_font_rom[12'd3503] = 16'h0180; // 维 row15
        status_font_rom[12'd3504] = 16'h0000; // 衡 row0
        status_font_rom[12'd3505] = 16'h1000; // 衡 row1
        status_font_rom[12'd3506] = 16'h320e; // 衡 row2
        status_font_rom[12'd3507] = 16'h63c0; // 衡 row3
        status_font_rom[12'd3508] = 16'h4480; // 衡 row4
        status_font_rom[12'd3509] = 16'h1fe0; // 衡 row5
        status_font_rom[12'd3510] = 16'h1420; // 衡 row6
        status_font_rom[12'd3511] = 16'h343e; // 衡 row7
        status_font_rom[12'd3512] = 16'h67e4; // 衡 row8
        status_font_rom[12'd3513] = 16'h6424; // 衡 row9
        status_font_rom[12'd3514] = 16'h27e4; // 衡 row10
        status_font_rom[12'd3515] = 16'h2004; // 衡 row11
        status_font_rom[12'd3516] = 16'h27e4; // 衡 row12
        status_font_rom[12'd3517] = 16'h2184; // 衡 row13
        status_font_rom[12'd3518] = 16'h23c4; // 衡 row14
        status_font_rom[12'd3519] = 16'h2664; // 衡 row15
        status_font_rom[12'd3520] = 16'h0000; // 陈 row0
        status_font_rom[12'd3521] = 16'h0040; // 陈 row1
        status_font_rom[12'd3522] = 16'h7c40; // 陈 row2
        status_font_rom[12'd3523] = 16'h4cc0; // 陈 row3
        status_font_rom[12'd3524] = 16'h4bfe; // 陈 row4
        status_font_rom[12'd3525] = 16'h4880; // 陈 row5
        status_font_rom[12'd3526] = 16'h48a0; // 陈 row6
        status_font_rom[12'd3527] = 16'h5920; // 陈 row7
        status_font_rom[12'd3528] = 16'h4920; // 陈 row8
        status_font_rom[12'd3529] = 16'h4bfe; // 陈 row9
        status_font_rom[12'd3530] = 16'h4420; // 陈 row10
        status_font_rom[12'd3531] = 16'h4c20; // 陈 row11
        status_font_rom[12'd3532] = 16'h5924; // 陈 row12
        status_font_rom[12'd3533] = 16'h4324; // 陈 row13
        status_font_rom[12'd3534] = 16'h4222; // 陈 row14
        status_font_rom[12'd3535] = 16'h4622; // 陈 row15
    end

    // 静态文案 ROM：行 0~9 = 信息页（产品名/版本/分隔线/提示），行 16~19 = 封面，
    // 每行 32 列，值是 16 位字符码（0 = 空白）。放 BRAM：case 表会把面积顶爆（实测 slice 超限）。
    reg [15:0] page_text_rom [0:1023]; // synthesis ram_style = bram
    integer page_init_i;
    initial begin
        for (page_init_i = 0; page_init_i < 1024; page_init_i = page_init_i + 1)
            page_text_rom[page_init_i] = 16'd0;
        page_text_rom[10'd0] = 16'h004c; // 行0 列0 L
        page_text_rom[10'd1] = 16'h0047; // 行0 列1 G
        page_text_rom[10'd2] = 16'h0054; // 行0 列2 T
        page_text_rom[10'd4] = 16'h97f3; // 行0 列4 音
        page_text_rom[10'd5] = 16'h753b; // 行0 列5 画
        page_text_rom[10'd6] = 16'h540c; // 行0 列6 同
        page_text_rom[10'd7] = 16'h9891; // 行0 列7 频
        page_text_rom[10'd8] = 16'h6570; // 行0 列8 数
        page_text_rom[10'd9] = 16'h5b57; // 行0 列9 字
        page_text_rom[10'd10] = 16'h6807; // 行0 列10 标
        page_text_rom[10'd11] = 16'h724c; // 行0 列11 牌
        page_text_rom[10'd32] = 16'h578b; // 行1 列0 型
        page_text_rom[10'd33] = 16'h53f7; // 行1 列1 号
        page_text_rom[10'd35] = 16'h004c; // 行1 列3 L
        page_text_rom[10'd36] = 16'h0047; // 行1 列4 G
        page_text_rom[10'd37] = 16'h0054; // 行1 列5 T
        page_text_rom[10'd38] = 16'h002d; // 行1 列6 -
        page_text_rom[10'd39] = 16'h0053; // 行1 列7 S
        page_text_rom[10'd40] = 16'h0031; // 行1 列8 1
        page_text_rom[10'd43] = 16'h56fa; // 行1 列11 固
        page_text_rom[10'd44] = 16'h4ef6; // 行1 列12 件
        page_text_rom[10'd46] = 16'h0031; // 行1 列14 1
        page_text_rom[10'd47] = 16'h002e; // 行1 列15 .
        page_text_rom[10'd48] = 16'h0030; // 行1 列16 0
        page_text_rom[10'd49] = 16'h002e; // 行1 列17 .
        page_text_rom[10'd50] = 16'h0030; // 行1 列18 0
        page_text_rom[10'd64] = 16'h6821; // 行2 列0 校
        page_text_rom[10'd65] = 16'h56ed; // 行2 列1 园
        page_text_rom[10'd66] = 16'h002f; // 行2 列2 /
        page_text_rom[10'd67] = 16'h56ed; // 行2 列3 园
        page_text_rom[10'd68] = 16'h533a; // 行2 列4 区
        page_text_rom[10'd69] = 16'h591a; // 行2 列5 多
        page_text_rom[10'd70] = 16'h5a92; // 行2 列6 媒
        page_text_rom[10'd71] = 16'h4f53; // 行2 列7 体
        page_text_rom[10'd72] = 16'h4fe1; // 行2 列8 信
        page_text_rom[10'd73] = 16'h606f; // 行2 列9 息
        page_text_rom[10'd74] = 16'h7ec8; // 行2 列10 终
        page_text_rom[10'd75] = 16'h7aef; // 行2 列11 端
        page_text_rom[10'd256] = 16'h002d; // 行8 列0 -
        page_text_rom[10'd257] = 16'h002d; // 行8 列1 -
        page_text_rom[10'd258] = 16'h002d; // 行8 列2 -
        page_text_rom[10'd259] = 16'h002d; // 行8 列3 -
        page_text_rom[10'd260] = 16'h002d; // 行8 列4 -
        page_text_rom[10'd261] = 16'h002d; // 行8 列5 -
        page_text_rom[10'd262] = 16'h002d; // 行8 列6 -
        page_text_rom[10'd263] = 16'h002d; // 行8 列7 -
        page_text_rom[10'd264] = 16'h002d; // 行8 列8 -
        page_text_rom[10'd265] = 16'h002d; // 行8 列9 -
        page_text_rom[10'd266] = 16'h002d; // 行8 列10 -
        page_text_rom[10'd267] = 16'h002d; // 行8 列11 -
        page_text_rom[10'd268] = 16'h002d; // 行8 列12 -
        page_text_rom[10'd269] = 16'h002d; // 行8 列13 -
        page_text_rom[10'd270] = 16'h002d; // 行8 列14 -
        page_text_rom[10'd271] = 16'h002d; // 行8 列15 -
        page_text_rom[10'd272] = 16'h002d; // 行8 列16 -
        page_text_rom[10'd273] = 16'h002d; // 行8 列17 -
        page_text_rom[10'd274] = 16'h002d; // 行8 列18 -
        page_text_rom[10'd275] = 16'h002d; // 行8 列19 -
        page_text_rom[10'd276] = 16'h002d; // 行8 列20 -
        page_text_rom[10'd277] = 16'h002d; // 行8 列21 -
        page_text_rom[10'd278] = 16'h002d; // 行8 列22 -
        page_text_rom[10'd279] = 16'h002d; // 行8 列23 -
        page_text_rom[10'd280] = 16'h002d; // 行8 列24 -
        page_text_rom[10'd281] = 16'h002d; // 行8 列25 -
        page_text_rom[10'd282] = 16'h002d; // 行8 列26 -
        page_text_rom[10'd283] = 16'h002d; // 行8 列27 -
        page_text_rom[10'd284] = 16'h002d; // 行8 列28 -
        page_text_rom[10'd285] = 16'h002d; // 行8 列29 -
        page_text_rom[10'd286] = 16'h002d; // 行8 列30 -
        page_text_rom[10'd287] = 16'h002d; // 行8 列31 -
        page_text_rom[10'd288] = 16'h0053; // 行9 列0 S
        page_text_rom[10'd289] = 16'h0057; // 行9 列1 W
        page_text_rom[10'd290] = 16'h0031; // 行9 列2 1
        page_text_rom[10'd292] = 16'h62e8; // 行9 列4 拨
        page_text_rom[10'd293] = 16'h4e0b; // 行9 列5 下
        page_text_rom[10'd295] = 16'h9000; // 行9 列7 退
        page_text_rom[10'd296] = 16'h51fa; // 行9 列8 出
        page_text_rom[10'd320] = 16'h64ad; // 行10 列0 播
        page_text_rom[10'd321] = 16'h653e; // 行10 列1 放
        page_text_rom[10'd322] = 16'h8bb0; // 行10 列2 记
        page_text_rom[10'd323] = 16'h5f55; // 行10 列3 录
        page_text_rom[10'd352] = 16'h65f6; // 行11 列0 时
        page_text_rom[10'd353] = 16'h95f4; // 行11 列1 间
        page_text_rom[10'd357] = 16'h4e8b; // 行11 列5 事
        page_text_rom[10'd358] = 16'h4ef6; // 行11 列6 件
        page_text_rom[10'd363] = 16'h56fe; // 行11 列11 图
        page_text_rom[10'd364] = 16'h7247; // 行11 列12 片
        page_text_rom[10'd384] = 16'h6682; // 行12 列0 暂
        page_text_rom[10'd385] = 16'h65e0; // 行12 列1 无
        page_text_rom[10'd386] = 16'h64ad; // 行12 列2 播
        page_text_rom[10'd387] = 16'h653e; // 行12 列3 放
        page_text_rom[10'd388] = 16'h8bb0; // 行12 列4 记
        page_text_rom[10'd389] = 16'h5f55; // 行12 列5 录
        page_text_rom[10'd416] = 16'h004e; // 行13 列0 N
        page_text_rom[10'd417] = 16'h004f; // 行13 列1 O
        page_text_rom[10'd419] = 16'h0043; // 行13 列3 C
        page_text_rom[10'd420] = 16'h004f; // 行13 列4 O
        page_text_rom[10'd421] = 16'h004e; // 行13 列5 N
        page_text_rom[10'd422] = 16'h0054; // 行13 列6 T
        page_text_rom[10'd423] = 16'h0045; // 行13 列7 E
        page_text_rom[10'd424] = 16'h004e; // 行13 列8 N
        page_text_rom[10'd425] = 16'h0054; // 行13 列9 T
        page_text_rom[10'd448] = 16'h0050; // 行14 列0 P
        page_text_rom[10'd449] = 16'h0055; // 行14 列1 U
        page_text_rom[10'd450] = 16'h0054; // 行14 列2 T
        page_text_rom[10'd452] = 16'h0042; // 行14 列4 B
        page_text_rom[10'd453] = 16'h004d; // 行14 列5 M
        page_text_rom[10'd454] = 16'h0050; // 行14 列6 P
        page_text_rom[10'd456] = 16'h004f; // 行14 列8 O
        page_text_rom[10'd457] = 16'h004e; // 行14 列9 N
        page_text_rom[10'd459] = 16'h0054; // 行14 列11 T
        page_text_rom[10'd460] = 16'h0046; // 行14 列12 F
        page_text_rom[10'd462] = 16'h0043; // 行14 列14 C
        page_text_rom[10'd463] = 16'h0041; // 行14 列15 A
        page_text_rom[10'd464] = 16'h0052; // 行14 列16 R
        page_text_rom[10'd465] = 16'h0044; // 行14 列17 D
        page_text_rom[10'd480] = 16'h0043; // 行15 列0 C
        page_text_rom[10'd481] = 16'h0048; // 行15 列1 H
        page_text_rom[10'd482] = 16'h0045; // 行15 列2 E
        page_text_rom[10'd483] = 16'h0043; // 行15 列3 C
        page_text_rom[10'd484] = 16'h004b; // 行15 列4 K
        page_text_rom[10'd486] = 16'h0046; // 行15 列6 F
        page_text_rom[10'd487] = 16'h0041; // 行15 列7 A
        page_text_rom[10'd488] = 16'h0054; // 行15 列8 T
        page_text_rom[10'd489] = 16'h0033; // 行15 列9 3
        page_text_rom[10'd490] = 16'h0032; // 行15 列10 2
        page_text_rom[10'd492] = 16'h0046; // 行15 列12 F
        page_text_rom[10'd493] = 16'h004f; // 行15 列13 O
        page_text_rom[10'd494] = 16'h0052; // 行15 列14 R
        page_text_rom[10'd495] = 16'h004d; // 行15 列15 M
        page_text_rom[10'd496] = 16'h0041; // 行15 列16 A
        page_text_rom[10'd497] = 16'h0054; // 行15 列17 T
        page_text_rom[10'd512] = 16'h004c; // 行16 列0 L
        page_text_rom[10'd513] = 16'h0047; // 行16 列1 G
        page_text_rom[10'd514] = 16'h0054; // 行16 列2 T
        page_text_rom[10'd516] = 16'h97f3; // 行16 列4 音
        page_text_rom[10'd517] = 16'h753b; // 行16 列5 画
        page_text_rom[10'd518] = 16'h540c; // 行16 列6 同
        page_text_rom[10'd519] = 16'h9891; // 行16 列7 频
        page_text_rom[10'd520] = 16'h6570; // 行16 列8 数
        page_text_rom[10'd521] = 16'h5b57; // 行16 列9 字
        page_text_rom[10'd522] = 16'h6807; // 行16 列10 标
        page_text_rom[10'd523] = 16'h724c; // 行16 列11 牌
        page_text_rom[10'd544] = 16'h6821; // 行17 列0 校
        page_text_rom[10'd545] = 16'h56ed; // 行17 列1 园
        page_text_rom[10'd546] = 16'h002f; // 行17 列2 /
        page_text_rom[10'd547] = 16'h56ed; // 行17 列3 园
        page_text_rom[10'd548] = 16'h533a; // 行17 列4 区
        page_text_rom[10'd549] = 16'h591a; // 行17 列5 多
        page_text_rom[10'd550] = 16'h5a92; // 行17 列6 媒
        page_text_rom[10'd551] = 16'h4f53; // 行17 列7 体
        page_text_rom[10'd552] = 16'h4fe1; // 行17 列8 信
        page_text_rom[10'd553] = 16'h606f; // 行17 列9 息
        page_text_rom[10'd554] = 16'h7ec8; // 行17 列10 终
        page_text_rom[10'd555] = 16'h7aef; // 行17 列11 端
        page_text_rom[10'd576] = 16'h63d2; // 行18 列0 插
        page_text_rom[10'd577] = 16'h5361; // 行18 列1 卡
        page_text_rom[10'd578] = 16'h5373; // 行18 列2 即
        page_text_rom[10'd579] = 16'h64ad; // 行18 列3 播
        page_text_rom[10'd581] = 16'h65e0; // 行18 列5 无
        page_text_rom[10'd582] = 16'h4eba; // 行18 列6 人
        page_text_rom[10'd583] = 16'h503c; // 行18 列7 值
        page_text_rom[10'd584] = 16'h5b88; // 行18 列8 守
        page_text_rom[10'd608] = 16'h6b63; // 行19 列0 正
        page_text_rom[10'd609] = 16'h5728; // 行19 列1 在
        page_text_rom[10'd610] = 16'h8bfb; // 行19 列2 读
        page_text_rom[10'd611] = 16'h53d6; // 行19 列3 取
        page_text_rom[10'd613] = 16'h0054; // 行19 列5 T
        page_text_rom[10'd614] = 16'h0046; // 行19 列6 F
        page_text_rom[10'd616] = 16'h5361; // 行19 列8 卡
        page_text_rom[10'd640] = 16'h5f00; // 行20 列0 开
        page_text_rom[10'd641] = 16'h673a; // 行20 列1 机
        page_text_rom[10'd642] = 16'h81ea; // 行20 列2 自
        page_text_rom[10'd643] = 16'h68c0; // 行20 列3 检
        page_text_rom[10'd645] = 16'h7cfb; // 行20 列5 系
        page_text_rom[10'd646] = 16'h7edf; // 行20 列6 统
        page_text_rom[10'd647] = 16'h5c31; // 行20 列7 就
        page_text_rom[10'd648] = 16'h7eea; // 行20 列8 绪
        page_text_rom[10'd649] = 16'h68c0; // 行20 列9 检
        page_text_rom[10'd650] = 16'h67e5; // 行20 列10 查
        page_text_rom[10'd672] = 16'h0054; // 行21 列0 T
        page_text_rom[10'd673] = 16'h0046; // 行21 列1 F
        page_text_rom[10'd675] = 16'h5361; // 行21 列3 卡
        page_text_rom[10'd676] = 16'h6302; // 行21 列4 挂
        page_text_rom[10'd677] = 16'h8f7d; // 行21 列5 载
        page_text_rom[10'd704] = 16'h56fe; // 行22 列0 图
        page_text_rom[10'd705] = 16'h7247; // 行22 列1 片
        page_text_rom[10'd706] = 16'h626b; // 行22 列2 扫
        page_text_rom[10'd707] = 16'h63cf; // 行22 列3 描
        page_text_rom[10'd736] = 16'h0053; // 行23 列0 S
        page_text_rom[10'd737] = 16'h0044; // 行23 列1 D
        page_text_rom[10'd738] = 16'h0052; // 行23 列2 R
        page_text_rom[10'd739] = 16'h0041; // 行23 列3 A
        page_text_rom[10'd740] = 16'h004d; // 行23 列4 M
        page_text_rom[10'd742] = 16'h8bfb; // 行23 列6 读
        page_text_rom[10'd743] = 16'h5199; // 行23 列7 写
        page_text_rom[10'd744] = 16'h73af; // 行23 列8 环
        page_text_rom[10'd745] = 16'h56de; // 行23 列9 回
        page_text_rom[10'd768] = 16'h97f3; // 行24 列0 音
        page_text_rom[10'd769] = 16'h9891; // 行24 列1 频
        page_text_rom[10'd770] = 16'h901a; // 行24 列2 通
        page_text_rom[10'd771] = 16'h8def; // 行24 列3 路
        page_text_rom[10'd800] = 16'h0048; // 行25 列0 H
        page_text_rom[10'd801] = 16'h0044; // 行25 列1 D
        page_text_rom[10'd802] = 16'h004d; // 行25 列2 M
        page_text_rom[10'd803] = 16'h0049; // 行25 列3 I
        page_text_rom[10'd805] = 16'h663e; // 行25 列5 显
        page_text_rom[10'd806] = 16'h793a; // 行25 列6 示
        page_text_rom[10'd807] = 16'h9501; // 行25 列7 锁
        page_text_rom[10'd808] = 16'h5b9a; // 行25 列8 定
        page_text_rom[10'd832] = 16'h5b58; // 行26 列0 存
        page_text_rom[10'd833] = 16'h50a8; // 行26 列1 储
        page_text_rom[10'd834] = 16'h81ea; // 行26 列2 自
        page_text_rom[10'd835] = 16'h68c0; // 行26 列3 检
        page_text_rom[10'd864] = 16'h8282; // 行27 列0 节
        page_text_rom[10'd865] = 16'h76ee; // 行27 列1 目
        page_text_rom[10'd866] = 16'h5355; // 行27 列2 单
        page_text_rom[10'd867] = 16'h89e3; // 行27 列3 解
        page_text_rom[10'd868] = 16'h6790; // 行27 列4 析
        page_text_rom[10'd960] = 16'h0053; // 行30 列0 S
        page_text_rom[10'd961] = 16'h0057; // 行30 列1 W
        page_text_rom[10'd962] = 16'h0031; // 行30 列2 1
        page_text_rom[10'd964] = 16'h0044; // 行30 列4 D
        page_text_rom[10'd965] = 16'h0045; // 行30 列5 E
        page_text_rom[10'd966] = 16'h0056; // 行30 列6 V
        page_text_rom[10'd967] = 16'h0049; // 行30 列7 I
        page_text_rom[10'd968] = 16'h0043; // 行30 列8 C
        page_text_rom[10'd969] = 16'h0045; // 行30 列9 E
        page_text_rom[10'd971] = 16'h0049; // 行30 列11 I
        page_text_rom[10'd972] = 16'h004e; // 行30 列12 N
        page_text_rom[10'd973] = 16'h0046; // 行30 列13 F
        page_text_rom[10'd974] = 16'h004f; // 行30 列14 O
    end
    // END GENERATED STATUS FONT

    function [7:0] source_char;
        input [3:0] slot;
        input [1:0] scale;
        begin
            case (slot)
                0: source_char="S"; 1: source_char="R"; 2: source_char="C";
                3: source_char=" ";
                4: source_char=scale==2 ? "1" : (scale==1 || scale==3) ? "3" : "6";
                5: source_char=scale==2 ? (source_large_q ? "0" : "2") :
                                    (scale==1 || scale==3) ? "2" : "4";
                6: source_char=scale==2 ? (source_large_q ? "2" : "8") : "0";
                7: source_char=scale==2 ? (source_large_q ? "4" : "0") : "X";
                8: source_char=scale==2 ? "X" : scale==1 ? "2" : scale==3 ? "1" : "4";
                9: source_char=scale==2 ? (source_large_q ? "7" : "9") :
                                    scale==1 ? "4" : scale==3 ? "8" : "8";
                10: source_char=scale==2 ? (source_large_q ? "6" : "6") : "0";
                11: source_char=scale==2 ? (source_large_q ? "8" : "0") : " ";
                13: source_char=scale==2 ? "D" : scale==1 ? "U" : scale==3 ? "S" : "1";
                14: source_char=scale==2 ? "N" : scale==1 ? "P" : scale==3 ? "T" : "X";
                default: source_char=" ";
            endcase
        end
    endfunction

    function [7:0] blend;
        input [7:0] bg, fg;
        input [1:0] strength;
        reg [15:0] sum;
        begin
            case (strength)
                2'd1: begin sum = bg * 8'd128 + fg * 8'd128 + 16'd128; blend = sum[15:8]; end
                2'd2: begin sum = bg * 8'd64 + fg * 8'd192 + 16'd128; blend = sum[15:8]; end
                2'd3: blend = fg;
                default: blend = bg;
            endcase
        end
    endfunction

    function [23:0] product_page_bg;
        input [11:0] px, py;
        begin
            if (py < 12'd28 || py >= 12'd456) begin
                if (px < 12'd160) product_page_bg = 24'h00a9be;
                else if (px < 12'd320) product_page_bg = 24'h51a77b;
                else if (px < 12'd480) product_page_bg = 24'he0a63b;
                else product_page_bg = 24'hd96c5a;
            end else if (px < 12'd160)
                product_page_bg = 24'hdcf5f1;
            else if (px < 12'd320)
                product_page_bg = 24'he3edf9;
            else if (px < 12'd480)
                product_page_bg = 24'hfff0d4;
            else
                product_page_bg = 24'hfbe4dd;
        end
    endfunction

    function [3:0] selfcheck_row;
        input [11:0] py;
        begin
            case (py[8:4])
                5'd4: selfcheck_row=4'd0;
                5'd7: selfcheck_row=4'd1;
                5'd10: selfcheck_row=4'd2;
                5'd13: selfcheck_row=4'd3;
                5'd16: selfcheck_row=4'd4;
                5'd19: selfcheck_row=4'd5;
                5'd22: selfcheck_row=4'd6;
                5'd25: selfcheck_row=4'd7;
                default: selfcheck_row=4'hf;
            endcase
        end
    endfunction

    reg [11:0] local_x;


    // ---- 状态栏点阵走 eRAM（BRAM）ROM：整块 OSD 层因此统一延后一拍 ----
    // 地址由当前像素坐标组合产生，ROM 数据下一拍回来，正好对应"被打了一拍"的坐标，
    // 所以面板、四行中文和底部字幕一起右移 1 像素，内部相对位置不变。
    reg [11:0] x0, y0, x1, y1;
    reg        de1;
    reg [23:0] rgb_in1;
    reg [15:0] glyph_code;
    reg [3:0]  glyph_row_sel;
    reg [15:0] glyph_bits_raw;
    reg        glyph_blank_q;
    // Keep status_font_rom as an unconditional BRAM read; mask blank codes after it.
    wire [15:0] glyph_bits = glyph_blank_q ? 16'd0 : glyph_bits_raw;
    wire page_ink = glyph_bits[15-local_x[3:0]] ||
                    (local_x[3:0] != 4'd0 && glyph_bits[16-local_x[3:0]]);

    wire [11:0] glyph_lx = x - 12'd8;
    // 静态文案 ROM 地址：行由当前模式/行号决定，列是当前像素所在的字符槽。
    // 读数据与坐标同拍寄存（page_code_q 与 x1/y1 一起延后一拍），因此不会多出错位。
    wire        log_title_row = log_page && (y >= 12'd36) && (y < 12'd68);
    wire        log_head_row  = log_page && (y >= 12'd88) && (y < 12'd120);
    wire        log_noev_row  = log_page && !log_any_valid &&
                                (y >= 12'd136) && (y < 12'd168);
    wire [2:0] log_data_row_w = y >= 12'd376 ? 3'd6 :
                                y >= 12'd336 ? 3'd5 :
                                y >= 12'd296 ? 3'd4 :
                                y >= 12'd256 ? 3'd3 :
                                y >= 12'd216 ? 3'd2 :
                                y >= 12'd176 ? 3'd1 : 3'd0;
    wire [11:0] log_data_base_w = 12'd136 +
                                   ({9'd0,log_data_row_w} << 5) +
                                   ({9'd0,log_data_row_w} << 3);
    wire log_data_active = log_page && y >= log_data_base_w &&
                           y < log_data_base_w + 12'd32;
    wire        guide_row13   = guide_page && (y >= 12'd40)  && (y < 12'd56);
    wire        guide_row14   = guide_page && (y >= 12'd72)  && (y < 12'd88);
    wire        guide_row15   = guide_page && (y >= 12'd104) && (y < 12'd120);
    wire        guide_row30   = guide_page && (y >= 12'd136) && (y < 12'd152);
    wire [4:0]  page_row_w = log_title_row ? 5'd10 :
                             log_head_row  ? 5'd11 :
                             log_noev_row  ? 5'd12 :
                             guide_row13   ? 5'd13 :
                             guide_row14   ? 5'd14 :
                             guide_row15   ? 5'd15 :
                             guide_row30   ? 5'd30 :
                             selfcheck_page ? (5'd20 + {1'b0,selfcheck_row(y)}) :
                             info_page ? ((y - 12'd40) >> 5) : (5'd16 + ((y - 12'd216) >> 4));
    wire [4:0]  page_col_w = log_page ? ((x - 12'd96) >> 5) : (glyph_lx >> 4);
    wire [9:0]  page_addr  = {page_row_w, page_col_w};
    reg  [15:0] page_code_q, page_code_q2;
    // 节目单字幕行：字符槽 = (x-8)>>4，24 格 x 16 像素；地址组合给出，码与坐标同拍取回
    wire [11:0] sub_lx      = x - 12'd8;
    wire [3:0]  sub_cell_col = x1[3:0] - 4'd8;
    assign playlist_sub_char = sub_lx[9:4];
    assign playlist_sub_lang = (y >= 12'd456) && (y < 12'd472);
    // 自检页：错误行数的两位十进制（0..15）与按行取的健康点
    wire [3:0]  sc_err_tens  = (playlist_errors >= 4'd10) ? 4'd1 : 4'd0;
    wire [3:0]  sc_err_units = playlist_errors - ((playlist_errors >= 4'd10) ? 4'd10 : 4'd0);
    wire [3:0]  sc_row_n     = selfcheck_row(y1);
    wire [3:0]  sc_row_in    = selfcheck_row(y);
    wire [2:0]  sc_item_idx  = sc_row_n[2:0] - 3'd1;        // 条目号 0..6（标题行不画点）
    wire [23:0] selfcheck_dot = selfcheck_ok[sc_item_idx] ? 24'h2ee06a : 24'he0483c;
    // 自检页"节目单 n/mm"里的条数改成两位数（容量到 16 条）：十位/个位分开放
    wire [3:0] playlist_entries_tens  = (playlist_entries >= 5'd10) ? 4'd1 : 4'd0;
    wire [3:0] playlist_entries_units = playlist_entries - ((playlist_entries >= 5'd10) ? 5'd10 : 5'd0);
    always @* begin
        glyph_code = 16'd0;
        // 四行的行基址对 16 取模都等于 8，行内行号统一是 y[3:0]-8
        glyph_row_sel = y[3:0] - 4'd8;
        if (selfcheck_page && sc_row_in < 4'd8)
            glyph_row_sel = y[3:0];
        if (log_title_row)
            glyph_row_sel = (y - 12'd36) >> 1;
        else if (log_head_row)
            glyph_row_sel = (y - 12'd88) >> 1;
        else if (log_data_active)
            glyph_row_sel = (y - log_data_base_w) >> 1;
        if (log_page) begin
            if (log_title_row && x >= 12'd96 && x < 12'd512)
                glyph_code = page_code_q2;
            else if (log_head_row && x >= 12'd96 && x < 12'd512)
                glyph_code = page_code_q2;
            else if (log_noev_row && x >= 12'd96 && x < 12'd512)
                glyph_code = page_code_q2;
            else if (log_any_valid && log_data_active &&
                     x >= 12'd96 && x < 12'd512)
                glyph_code = log_cell_char(log_data_row_w, (x - 12'd96) >> 5);
            else
                glyph_code = 16'h0020;
        end
        else if (guide_page) begin
            // 无内容引导页：四行静态文案直接查页面 ROM
            if ((y >= 12'd40 && y < 12'd56) || (y >= 12'd72 && y < 12'd88) ||
                (y >= 12'd104 && y < 12'd120) || (y >= 12'd136 && y < 12'd152))
                glyph_code = page_code_q2;
            else
                glyph_code = 16'h0020;
        end
        else if (status_q && !info_page && !cover_active &&
                 x >= 12'd8 && x < 12'd504 && y < 12'd72) begin
            if (y >= 12'd8 && y < 12'd24)
                glyph_code = status_main_code(glyph_lx[8:4], image_q, alpha_q,
                                              brightness_q, contrast_q, auto_q);
            else if (y >= 12'd24 && y < 12'd40)
                glyph_code = status_volume_code(glyph_lx[8:4], volume_q);
            else if (y >= 12'd40 && y < 12'd56)
                glyph_code = status_detail_code(glyph_lx[8:4], scale_q, transition_q, edit_q);
            else if (y >= 12'd56 && y < 12'd72)
                glyph_code = status_line4_code(glyph_lx[8:4], diag_q);
        end
        else if (info_page && x >= 12'd8 && x < 12'd520 && y >= 12'd40 && y < 12'd360 &&
                 y[4:0] >= 5'd8 && y[4:0] < 5'd24) begin
            // 信息页：动态行直接复用状态栏那四行函数，静态行查生成表（产品名/版本/分隔线/提示）
            case ((y - 12'd40) >> 5)
                4'd3: glyph_code = status_main_code(glyph_lx[8:4], image_q, alpha_q,
                                                    brightness_q, contrast_q, auto_q);
                4'd4: glyph_code = status_detail_code(glyph_lx[8:4], scale_q, transition_q, edit_q);
                4'd5: glyph_code = status_volume_code(glyph_lx[8:4], volume_q);
                4'd6: glyph_code = status_line4_code(glyph_lx[8:4], 1'b1);
                4'd7: glyph_code = status_line4_code(glyph_lx[8:4], 1'b0);
                default: glyph_code = page_code_q2;
            endcase
        end
        else if (cover_active && !info_page && !log_page && !guide_page &&
                 !selfcheck_page && x >= 12'd256 && x < 12'd384 &&
                 y >= 12'd304 && y < 12'd336) begin
            glyph_row_sel = (y - 12'd304) >> 1;
            if (standby_mode)
                glyph_code = 16'h0020;
            else
                case ((x - 12'd256) >> 5)
                    2'd0: glyph_code = 16'h63d2; // 插
                    2'd1: glyph_code = 16'h5361; // 卡
                    2'd2: glyph_code = 16'h5373; // 即
                    default: glyph_code = 16'h64ad; // 播
                endcase
        end
        // The log page owns the glyphs even while a playlist subtitle is active.
        if (playlist_subtitle && !log_page && x >= 12'd8 && x < 12'd632 &&
            ((y >= 12'd432 && y < 12'd448) ||
             (y >= 12'd456 && y < 12'd472))) begin
            glyph_code    = playlist_sub_code;
            glyph_row_sel = y >= 12'd456 ? y - 12'd456 : y - 12'd432;
        end
        if (selfcheck_page && sc_row_in < 4'd8 && x >= 12'd8 && x < 12'd328) begin
            // 开机自检页：左侧 0~15 列是静态标签（页面 ROM 行 20~27），
            // 第 14 列画健康点（在像素链里画），第 16~19 列是计数：
            //   图片扫描行 = "n/4"，节目单行 = "n/mm"（错误行数两位十进制）
            case ((x - 12'd8) >> 4)
                // 第 15、16 格：自检页的"节目单条数"两位数（图片扫描行的计数仍在第 16 格）
                5'd15: glyph_code = (sc_row_in == 4'd7) ?
                                    (16'h0030 + {13'd0, playlist_entries_tens}) : 16'h0020;
                5'd16: glyph_code = (sc_row_in == 4'd2)
                                    ? (16'h0030 + {13'd0, img_found})
                                    : (sc_row_in == 4'd7) ? (16'h0030 + {13'd0, playlist_entries_units})
                                                     : 16'h0020;
                5'd17: glyph_code = (sc_row_in == 4'd2 || sc_row_in == 4'd7) ? 16'h002f : 16'h0020;
                5'd18: glyph_code = (sc_row_in == 4'd2) ? 16'h0034 :
                                    (sc_row_in == 4'd7) ? (16'h0030 + {13'd0, sc_err_tens}) : 16'h0020;
                5'd19: glyph_code = (sc_row_in == 4'd7) ? (16'h0030 + {13'd0, sc_err_units}) : 16'h0020;
                default: glyph_code = page_code_q2;
            endcase
        end
        if ((info_page || selfcheck_page || guide_page) &&
            y >= 12'd40 && y < 12'd56 && x >= 12'd544 && x < 12'd592)
            glyph_code = x < 12'd560 ? "L" : x < 12'd576 ? "G" : "T";
    end

    always @(posedge clk) begin
        glyph_code_q    <= glyph_code;
        glyph_row_sel_q <= glyph_row_sel;
        // Blank cells in page_text_rom are code 0; dynamic text may use 0x0020.
        // Both must bypass the low-10-bit table (a Chinese code can occupy slot 0).
        if (glyph_code_q == 16'h0000 || glyph_code_q == 16'h0020)
            glyph_index_q <= 8'd0;
        else case (glyph_code_q[9:8])
            2'd0: glyph_index_q <= glyph_map0[glyph_code_q[7:0]];
            2'd1: glyph_index_q <= glyph_map1[glyph_code_q[7:0]];
            2'd2: glyph_index_q <= glyph_map2[glyph_code_q[7:0]];
            default: glyph_index_q <= glyph_map3[glyph_code_q[7:0]];
        endcase
        glyph_blank_q <= (glyph_code_q == 16'h0000 || glyph_code_q == 16'h0020);
        glyph_bits_raw <= status_font_rom[{glyph_index_d, glyph_row_sel_q}];
        page_code_q <= page_text_rom[page_addr];
        page_code_q2 <= page_code_q;
        x0 <= x;
        y0 <= y;
        x1 <= x0;
        y1 <= y0;
        de1 <= de;
        rgb_in1 <= rgb_in;
    end

    always @* begin
        local_x = 12'd0;
        rgb_out = rgb_in1;
        if (de1) begin
            if (cover_active && !info_page && !log_page && !guide_page &&
                !selfcheck_page && y1 >= 12'd304 && y1 < 12'd336 &&
                x1 >= 12'd256 && x1 < 12'd384) begin
                local_x = (x1 - 12'd256) >> 1;
                if (glyph_bits[15-local_x[3:0]]) rgb_out = 24'h17464c;
            end else if (info_page) begin
                // 整屏产品信息页：深色玻璃底 + 左侧 4px 品牌条 + 上下品牌描边
                rgb_out = product_page_bg(x1,y1);
                if (x1 < 12'd4)
                    rgb_out = 24'h00a9be;
                else if (y1 == 12'd24 || y1 == 12'd383)
                    rgb_out = 24'h00a9be;
                if (x1 >= 12'd8 && x1 < 12'd520 && y1 >= 12'd40 && y1 < 12'd360 &&
                    y1[4:0] >= 5'd8 && y1[4:0] < 5'd24) begin
                    local_x = x1 - 12'd8;
                    if (page_ink) rgb_out = 24'h17464c;
                end
            end else if (log_page) begin
                // Readable event history on a quiet background.
                rgb_out = (y1 < 12'd28 || y1 >= 12'd456) ?
                          product_page_bg(x1,y1) : 24'hf3f7f6;
                if (x1 < 12'd4)
                    rgb_out = 24'h00a9be;
                else if (y1 == 12'd76 || y1 == 12'd128)
                    rgb_out = 24'hb9d6d2;
                else if (x1 >= 12'd96 && x1 < 12'd512 &&
                         y1 >= 12'd36 && y1 < 12'd448) begin
                    local_x = (x1 - 12'd96) >> 1;
                    if (glyph_bits[15-local_x[3:0]]) rgb_out = 24'h17464c;
                end
            end else if (guide_page) begin
                // 无内容引导页：深色玻璃底 + 左侧品牌条 + 四行大写文案
                rgb_out = product_page_bg(x1,y1);
                if (x1 < 12'd4)
                    rgb_out = 24'h00a9be;
                else if (x1 >= 12'd8 && x1 < 12'd520 && y1 >= 12'd40 && y1 < 12'd152) begin
                    local_x = x1 - 12'd8;
                    if (page_ink) rgb_out = 24'h17464c;
                end
            end else if (selfcheck_page) begin
                // 开机自检页：深色玻璃底 + 左侧品牌竖条（和信息页同一套观感）
                rgb_out = product_page_bg(x1,y1);
                if (x1 < 12'd4)
                    rgb_out = 24'h00a9be;
                else if (sc_row_n < 4'd8 && x1 >= 12'd8 && x1 < 12'd328) begin
                    local_x = x1 - 12'd8;
                    if (page_ink) rgb_out = 24'h17464c;
                end
                // 状态点：第 14 列（x 236..243）每个条目一个 8px 方块，绿=通过、红=失败
                if (sc_row_n >= 4'd1 && sc_row_n < 4'd8 &&
                    x1 >= 12'd236 && x1 < 12'd244 &&
                    y1[3:0] >= 4'd4 && y1[3:0] < 4'd12)
                    rgb_out = selfcheck_dot;
            end else if (status_q && !cover_active && x1 < 12'd512 && y1 < 12'd80) begin
                rgb_out = 24'h102030;
                if (x1 >= 12'd8 && x1 < 12'd504 && y1 >= 12'd8 && y1 < 12'd72) begin
                    local_x = x1 - 12'd8;
                    if (glyph_bits[15-local_x[3:0]]) rgb_out = 24'hf7f9f8;
                end
            end else if (playlist_subtitle && subtitle_q && !cover_active &&
                         ((y1 >= 12'd432 && y1 < 12'd448) ||
                          (y1 >= 12'd456 && y1 < 12'd472)) &&
                         x1 >= 12'd8 && x1 < 12'd632) begin
                if (glyph_bits[15 - sub_cell_col])
                    rgb_out = {blend(rgb_in1[23:16],8'hf7,alpha_q),
                               blend(rgb_in1[15:8],8'hf9,alpha_q),
                               blend(rgb_in1[7:0],8'hf8,alpha_q)};
                else if (sub_cell_col != 4'd0 && glyph_bits[16 - sub_cell_col])
                    rgb_out = 24'h17464c;
            end
            if ((info_page || selfcheck_page || guide_page) &&
                y1 >= 12'd40 && y1 < 12'd56 && x1 >= 12'd544 && x1 < 12'd592 &&
                glyph_bits[15-x1[3:0]])
                rgb_out = x1 < 12'd560 ? 24'h008a9b :
                          x1 < 12'd576 ? 24'h238b62 : 24'hc36246;
        end
    end
endmodule
module video_output_stage (
    input  wire        clk,
    input  wire        rst,
    input  wire        hs,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb,
    output reg         hs_out,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out
);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hs_out <= 1'b0;
            vs_out <= 1'b0;
            de_out <= 1'b0;
            rgb_out <= 24'd0;
        end else begin
            hs_out <= hs;
            vs_out <= vs;
            de_out <= de;
            rgb_out <= rgb;
        end
    end
endmodule
module video_startup_screen (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        photo_valid,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [23:0] photo_rgb,
    output wire        cover_active,
    output wire [23:0] rgb_out
);
    reg photo_frame_valid;
    reg [23:0] boot_rgb;
    reg [1:0] letter;
    reg [6:0] letter_x;
    reg letter_active;
    reg [4:0] pixels;

    always @(posedge clk or posedge rst) begin
        if (rst)
            photo_frame_valid <= 1'b0;
        else if (frame_start)
            photo_frame_valid <= photo_valid;
    end

    function [4:0] letter_row;
        input [1:0] index;
        input [2:0] row;
        reg [34:0] glyph;
        begin
            case (index)
                2'd0: glyph = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111}; // L
                2'd1: glyph = {5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01111}; // G
                2'd2: glyph = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100}; // T
                default: glyph = 35'd0;
            endcase
            letter_row = glyph[34 - row*5 -: 5];
        end
    endfunction

    always @* begin
        boot_rgb = 24'hdcebea;
        letter = 2'd0;
        letter_x = 7'd0;
        letter_active = 1'b0;
        pixels = 5'd0;
        if (x >= 12'd640 || y >= 12'd480)
            boot_rgb = 24'd0;
        else begin
            if (y >= 12'd128 && y < 12'd352)
                boot_rgb = 24'heff7f4;
            if (y >= 12'd144 && y < 12'd256) begin
                if (x >= 12'd174 && x < 12'd254) begin
                    letter = 2'd0; letter_x = x - 12'd174; letter_active = 1'b1;
                end else if (x >= 12'd280 && x < 12'd360) begin
                    letter = 2'd1; letter_x = x - 12'd280; letter_active = 1'b1;
                end else if (x >= 12'd386 && x < 12'd466) begin
                    letter = 2'd2; letter_x = x - 12'd386; letter_active = 1'b1;
                end
                if (letter_active) begin
                    pixels = letter_row(letter, (y - 12'd144) >> 4);
                    if (pixels[4 - letter_x[6:4]])
                        boot_rgb = letter == 2'd0 ? 24'h008a9b :
                                   letter == 2'd1 ? 24'h238b62 : 24'hc36246;
                end
            end
            if (y >= 12'd280 && y < 12'd288 && x >= 12'd208 && x < 12'd432) begin
                if (x < 12'd264) boot_rgb = 24'h00a9be;
                else if (x < 12'd320) boot_rgb = 24'h51a77b;
                else if (x < 12'd376) boot_rgb = 24'he0a63b;
                else boot_rgb = 24'hd96c5a;
            end
        end
    end

    assign rgb_out = photo_frame_valid ? photo_rgb : boot_rgb;
    assign cover_active = ~photo_frame_valid;      // 首图未就绪：封面文字层由 video_osd_overlay 画
endmodule
module audio_visualizer #(
    parameter integer DECIMATE = 25
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               frame_start,
    input  wire               de,
    input  wire [11:0]        x,
    input  wire [11:0]        y,
    input  wire [23:0]        rgb_in,
    input  wire               pcm_valid,
    input  wire signed [15:0] pcm,
    input  wire               led_enable,
    input  wire               video_enable,
    output reg  [23:0]        rgb_out,
    output reg  [7:0]         led_red,
    output reg  [7:0]         led_green
);
    reg signed [15:0] low_slow, low_mid, low_fast;
    reg signed [7:0] sample_bank0 [0:31];
    reg signed [7:0] sample_bank1 [0:31];
    reg [7:0] band_capture [0:3];
    reg [7:0] band_display [0:3];
    reg [8:0] previous_low_energy;
    reg [3:0] chase_frames, chase_cooldown;
    reg [2:0] chase_pos;
    reg [1:0] palette_phase;
    reg [4:0] pwm_phase;
    reg [5:0] sample_count;
    reg [5:0] decimate_count;
    reg write_bank, display_bank, display_valid;
    integer k;
    wire signed [16:0] v0 = $signed({pcm[15],pcm}) - $signed({low_fast[15],low_fast});
    wire signed [16:0] v1 = {low_fast[15],low_fast} - {low_mid[15],low_mid};
    wire signed [16:0] v2 = {low_mid[15],low_mid} - {low_slow[15],low_slow};
    wire signed [16:0] v3 = {low_slow[15],low_slow};
    wire signed [16:0] mid_delta = $signed({pcm[15],pcm}) - $signed({low_mid[15],low_mid});
    wire signed [16:0] slow_delta = $signed({pcm[15],pcm}) - $signed({low_slow[15],low_slow});

    function [7:0] magnitude;
        input signed [16:0] value;
        reg [16:0] absolute;
        begin
            absolute = value[16] ? -value : value;
            magnitude = (absolute > 17'd32640) ? 8'd255 : absolute[14:7];
        end
    endfunction

    function [7:0] visible_level;
        input [7:0] raw;
        input [1:0] shift;
        reg [10:0] scaled;
        begin
            scaled = {3'b0,raw} << shift;
            visible_level = (scaled > 11'd255) ? 8'd255 : scaled[7:0];
        end
    endfunction

    function [9:0] led_duty;
        input [7:0] level;
        input [1:0] hue;
        reg [4:0] intensity;
        reg [4:0] red_duty, green_duty;
        begin
            if (level < 8'd8)
                intensity = 5'd0;
            else if (level >= 8'd124)
                intensity = 5'd31;
            else
                intensity = level[6:2];
            case (hue)
                2'd0: begin red_duty = 5'd0;           green_duty = intensity; end
                2'd1: begin red_duty = intensity >> 1; green_duty = intensity; end
                2'd2: begin red_duty = intensity;      green_duty = intensity >> 2; end
                default: begin red_duty = intensity;   green_duty = 5'd0; end
            endcase
            led_duty = {red_duty, green_duty};
        end
    endfunction

    wire [7:0] band_now0 = visible_level(magnitude(v3),2'd1);
    wire [7:0] band_now1 = visible_level(magnitude(v2),2'd1);
    wire [7:0] band_now2 = visible_level(magnitude(v1),2'd2);
    wire [7:0] band_now3 = visible_level(magnitude(v0),2'd3);
    wire [8:0] low_energy = {1'b0,band_capture[0]} + {1'b0,band_capture[1]};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            low_slow <= 16'sd0;
            low_mid <= 16'sd0;
            low_fast <= 16'sd0;
            sample_count <= 6'd0;
            decimate_count <= 6'd0;
            write_bank <= 1'b0;
            display_bank <= 1'b1;
            display_valid <= 1'b0;
            previous_low_energy <= 9'd0;
            chase_frames <= 4'd0;
            chase_cooldown <= 4'd0;
            chase_pos <= 3'd0;
            palette_phase <= 2'd0;
            pwm_phase <= 5'd0;
            for (k=0; k<4; k=k+1) begin
                band_capture[k] <= 8'd0;
                band_display[k] <= 8'd0;
            end
        end else begin
            pwm_phase <= led_enable ? pwm_phase + 5'd1 : 5'd0;
            if (frame_start) begin
                if (chase_frames != 0) begin
                    chase_frames <= chase_frames - 4'd1;
                    chase_pos <= chase_pos + 3'd1;
                end
                if (chase_cooldown != 0) chase_cooldown <= chase_cooldown - 4'd1;
                if (sample_count == 6'd32) begin
                    display_bank <= write_bank;
                    display_valid <= 1'b1;
                    write_bank <= ~write_bank;
                    for (k=0; k<4; k=k+1)
                        band_display[k] <= band_capture[k];
                    if (chase_cooldown == 0 && low_energy >= 9'd48 &&
                        {1'b0,low_energy} > {1'b0,previous_low_energy} + 10'd36) begin
                        chase_frames <= 4'd8;
                        chase_cooldown <= 4'd10;
                        chase_pos <= 3'd0;
                        palette_phase <= palette_phase + 2'd1;
                    end
                    previous_low_energy <= low_energy;
                end
                sample_count <= 6'd0;
                decimate_count <= 6'd0;
                for (k=0; k<4; k=k+1)
                    band_capture[k] <= 8'd0;
            end else if (pcm_valid) begin
                low_fast <= low_fast + (v0 >>> 2);
                low_mid <= low_mid + (mid_delta >>> 4);
                low_slow <= low_slow + (slow_delta >>> 6);
                if (band_now0 > band_capture[0]) band_capture[0] <= band_now0;
                if (band_now1 > band_capture[1]) band_capture[1] <= band_now1;
                if (band_now2 > band_capture[2]) band_capture[2] <= band_now2;
                if (band_now3 > band_capture[3]) band_capture[3] <= band_now3;
                if (decimate_count == DECIMATE - 1)
                    decimate_count <= 6'd0;
                else
                    decimate_count <= decimate_count + 6'd1;
                if (decimate_count == 0 && sample_count < 6'd32) begin
                    if (write_bank)
                        sample_bank1[sample_count[4:0]] <= pcm[15:8];
                    else
                        sample_bank0[sample_count[4:0]] <= pcm[15:8];
                    sample_count <= sample_count + 6'd1;
                end
            end
        end
    end

    reg signed [7:0] selected_sample;
    reg signed [9:0] wave_y;
    reg [4:0] wave_index;
    reg [1:0] bar_index;
    reg [6:0] bar_height;
    reg [4:0] label_x, label_row;
    reg [7:0] label_char;
    reg [7:0] secondary_level;
    reg [9:0] first_duty, second_duty;
    integer j;

    function [4:0] label_glyph;
        input [7:0] ch;
        input [2:0] row;
        reg [34:0] glyph;
        begin
            case (ch)
                "L": glyph={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "O": glyph={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "M": glyph={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "H": glyph={5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "I": glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
                default: glyph=35'd0;
            endcase
            label_glyph=glyph[34-row*5 -: 5];
        end
    endfunction

    always @* begin
        rgb_out = rgb_in;
        wave_index = 5'd0;
        selected_sample = 8'sd0;
        wave_y = 10'sd384;
        bar_index = 2'd0;
        bar_height = 7'd0;
        label_x = 5'd0;
        label_row = 5'd0;
        label_char = " ";
        secondary_level = 8'd0;
        first_duty = 10'd0;
        second_duty = 10'd0;
        led_red = 8'd0;
        led_green = 8'd0;
        for (j=0; j<4; j=j+1) begin
            secondary_level = (band_display[j] > 8'd24) ? band_display[j] - 8'd24 : 8'd0;
            first_duty = led_duty(band_display[j], palette_phase + j[1:0]);
            second_duty = led_duty(secondary_level, palette_phase + j[1:0] + 2'd1);
            led_red[j*2] = pwm_phase < first_duty[9:5];
            led_green[j*2] = pwm_phase < first_duty[4:0];
            led_red[j*2+1] = pwm_phase < second_duty[9:5];
            led_green[j*2+1] = pwm_phase < second_duty[4:0];
        end
        if (chase_frames != 0) begin
            led_red[chase_pos] = 1'b1;
            led_green[chase_pos] = 1'b0;
        end
        if (!led_enable) begin
            led_red = 8'd0;
            led_green = 8'd0;
        end
        if (video_enable && de && display_valid && x >= 12'd16 && x < 12'd464 &&
            y >= 12'd352 && y < 12'd416) begin
            wave_index = (x - 12'd16) >> 4;
            selected_sample = display_bank ? sample_bank1[wave_index] : sample_bank0[wave_index];
            wave_y = 10'sd384 - ($signed(selected_sample) >>> 2);
            if ($signed({1'b0,y}) >= wave_y - 10'sd1 &&
                $signed({1'b0,y}) <= wave_y + 10'sd1)
                rgb_out = 24'h53d8c5;
            else if (y == 12'd384)
                rgb_out = 24'h596c75;
        end else if (video_enable && de && display_valid && x >= 12'd512 && x < 12'd624 &&
                     y >= 12'd352 && y < 12'd416) begin
            bar_index = (x - 12'd512) / 28;
            bar_height = band_display[bar_index] >> 2;
            if (x[1:0] != 2'b11 && y >= 12'd416 - {5'd0,bar_height})
                case (bar_index)
                    2'd0: rgb_out = 24'h55c98b;
                    2'd1: rgb_out = 24'hdcc45e;
                    2'd2: rgb_out = 24'he99364;
                    default: rgb_out = 24'hd9717a;
                endcase
        end else if (video_enable && de && display_valid && x >= 12'd512 && x < 12'd624 &&
                     y >= 12'd420 && y < 12'd427) begin
            bar_index = (x - 12'd512) / 28;
            label_x = (x - 12'd512) % 28;
            if (label_x >= 5'd8 && label_x < 5'd19) begin
                case (bar_index)
                    2'd0: label_char = (label_x < 5'd14) ? "L" : "O";
                    2'd1: label_char = (label_x < 5'd14) ? "L" : "M";
                    2'd2: label_char = (label_x < 5'd14) ? "H" : "M";
                    default: label_char = (label_x < 5'd14) ? "H" : "I";
                endcase
                label_row = label_glyph(label_char, y - 12'd420);
                if (label_x < 5'd13 && label_row[4-(label_x-5'd8)])
                    rgb_out = 24'hd6e9e8;
                else if (label_x >= 5'd14 && label_row[4-(label_x-5'd14)])
                    rgb_out = 24'hd6e9e8;
            end
        end
    end
endmodule

module auto_breathe_led #(
    parameter integer PWM_PRESCALE = 128
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        photo_valid,
    input  wire        auto_enabled,
    input  wire        browse_mode,
    input  wire        wav_ready,
    input  wire        wav_played,
    input  wire [20:0] segment_samples,
    input  wire [1:0]  image_index,
    output wire [3:0]  led
);
    localparam integer PWM_BITS = (PWM_PRESCALE < 2) ? 1 : $clog2(PWM_PRESCALE);
    reg [7:0] breath_phase;
    reg [20:0] sample_remainder;
    reg [5:0] frame_pos;
    reg [1:0] image_prev;
    reg [PWM_BITS-1:0] pwm_div;
    reg [6:0] pwm_phase;
    wire active = photo_valid && auto_enabled && !browse_mode;
    wire [21:0] sample_sum = {1'b0,sample_remainder} + 22'd256;
    wire [6:0] wav_duty = breath_phase[7] ? ~breath_phase[6:0] : breath_phase[6:0];
    wire [6:0] timer_duty = frame_pos < 6'd30 ? {frame_pos[4:0],2'b00} :
                            ((7'd59 - {1'b0,frame_pos}) << 2);
    wire [6:0] duty = wav_ready ? wav_duty : timer_duty;
    assign led = browse_mode ? 4'b1111 : {4{active && pwm_phase < duty}};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            breath_phase <= 8'd0;
            sample_remainder <= 21'd0;
            frame_pos <= 6'd0;
            image_prev <= 2'd0;
            pwm_div <= {PWM_BITS{1'b0}};
            pwm_phase <= 7'd0;
        end else begin
            image_prev <= image_index;
            if (!active || image_index != image_prev) begin
                breath_phase <= 8'd0;
                sample_remainder <= 21'd0;
                frame_pos <= 6'd0;
            end else if (wav_ready && wav_played && segment_samples != 21'd0 &&
                         breath_phase != 8'hff) begin
                if (sample_sum >= {1'b0,segment_samples}) begin
                    sample_remainder <= sample_sum - {1'b0,segment_samples};
                    breath_phase <= breath_phase + 8'd1;
                end else
                    sample_remainder <= sample_sum[20:0];
            end else if (!wav_ready && frame_start && frame_pos < 6'd59)
                frame_pos <= frame_pos + 6'd1;

            if (!active) begin
                pwm_div <= {PWM_BITS{1'b0}};
                pwm_phase <= 7'd0;
            end else if (pwm_div == PWM_PRESCALE - 1) begin
                pwm_div <= {PWM_BITS{1'b0}};
                pwm_phase <= pwm_phase + 7'd1;
            end else
                pwm_div <= pwm_div + 1'b1;
        end
    end
endmodule

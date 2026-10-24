module bmp_read #(
    parameter integer FRAME_WIDTH = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter [20:0] WAV_MAX_WORDS = 21'd1329152,   // 2M - 两块帧缓存 - 四张高清预览，须为 256 的倍数
    parameter [31:0] SCAN_WAV_GAP  = 32'd1024       // BMP 找齐后最多再往后找多少个扇区的 WAV（512KB）
)(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input                       scan_resume,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_paused,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // WAV（第 5 步新增）：扫描时顺带记下第一个 48kHz / 16 位 / 立体声 PCM WAV
    output reg                  wav_found,
    output reg [31:0]           wav_sector,
    output reg [20:0]           wav_words,      // 要载入的 32 位字数（一字 = 一对左右声道样本），256 的整数倍

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,     // 加载超时时由 sd_card_bmp 发出，强制回到空闲（移植自 lab_ex4）
    input  [31:0]               load_sector,
    input  [20:0]               wav_load_words,
    input                       load_wav,       // 1 = 这次加载 WAV（按 32 位字线性输出），0 = BMP
    output reg                  load_error,     // 文件头无效，写请求尚未发出

    input                       sd_init_done,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output [15:0]               source_width,
    output [15:0]               source_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,
    // 当前像素的真实坐标 {行低位, 列[10:0]}：供下游 2x2 均值用。
    // 不能靠"数 wr_en 脉冲"推行列——SD 扇区边界等处会有空拍，数脉冲会整行漂移。
    output wire [11:0]          bmp_pix_pos,
    output reg [31:0]           wav_word        // WAV 模式的输出字，与 bmp_data_wr_en 同拍有效：{左声道, 右声道}
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;

reg [2:0]  state;
reg [9:0]  rd_cnt;
reg        header_valid_q;
reg [9:0]  header_index_q;
reg [7:0]  header_data_q;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;
reg [15:0] source_x, source_y;
reg        downscale_2x;
reg        downscale_16;                 // 1024x768 → 640x480：每 8 个源像素/行取 5 个（8:5 最近邻）
// 8 抽 5 的相位表：源坐标低位为 {1,3,4,6,7} 时保留（0..7 里正好 5 个，1024/8*5 = 640、768/8*5 = 480）。
wire keep_x16 = (source_x[2:0] == 3'd1) || (source_x[2:0] == 3'd3) ||
                (source_x[2:0] == 3'd4) || (source_x[2:0] == 3'd6) || (source_x[2:0] == 3'd7);
wire keep_y16 = (source_y[2:0] == 3'd1) || (source_y[2:0] == 3'd3) ||
                (source_y[2:0] == 3'd4) || (source_y[2:0] == 3'd6) || (source_y[2:0] == 3'd7);
wire keep_16  = keep_x16 && keep_y16;

// ---------------- WAV 文件头（第 5 步新增）----------------
// 只认 44 字节标准头：RIFF / WAVE / 16 字节 "fmt " PCM / "data"，样本从第 44 字节开始
// （scripts/convert_wav.py 转出来的文件就是这种格式）
reg [31:0] wav_riff_tag;     // 字节 0~3   "RIFF"
reg [31:0] wav_riff_size;    // 字节 4~7   文件长度 - 8
reg [31:0] wav_wave_tag;     // 字节 8~11  "WAVE"
reg [31:0] wav_fmt_tag;      // 字节 12~15 "fmt "
reg [15:0] wav_audio_fmt;    // 字节 20~21 1 = PCM
reg [15:0] wav_channels;     // 字节 22~23
reg [31:0] wav_rate;         // 字节 24~27
reg [15:0] wav_bits;         // 字节 34~35
reg [31:0] wav_data_tag;     // 字节 36~39 "data"
reg [31:0] wav_data_size;    // 字节 40~43 样本数据字节数

// 判断结果寄存一拍：头部字节在扇区开头，远早于扇区读完，不影响判断
reg        wav_match;
reg [31:0] wav_file_sectors;
reg [20:0] wav_words_calc;

reg        wav_mode;              // 当前这次加载是 WAV
reg        scan_target_reached;   // BMP 已找齐，接下来只找 WAV
reg [31:0] scan_gap_cnt;          // 找齐之后连续没找到东西的扇区数

wire [31:0] wav_data_words = {2'd0, wav_data_size[31:2]};
reg  [31:0] wav_load_end;   // WAV 扫描结果先锁存结束位置，加载开始前早已稳定
always @(posedge clk or posedge rst) begin
    if (rst)
        wav_load_end <= 32'd44;
    else
        wav_load_end <= 32'd44 + {9'd0, wav_words, 2'b00};
end
wire        scan_bmp_full  = scan_target_reached || (scan_found_total + 3'd1 >= scan_target_count);

reg  header_match;           // 寄存一拍：文件头在扇区开头 34 字节内收齐，扇区读完（512 字节后）才用，早到上万拍
wire [31:0] required_pixel_bytes =
    (width == FRAME_WIDTH && height == FRAME_HEIGHT) ? FRAME_WIDTH * FRAME_HEIGHT * 3 :
    (width == FRAME_WIDTH/2 && height == FRAME_HEIGHT/2) ? FRAME_WIDTH * FRAME_HEIGHT * 3 / 4 :
    (width == FRAME_WIDTH/2 && height == (FRAME_HEIGHT*3)/8) ?
        (FRAME_WIDTH/2) * ((FRAME_HEIGHT*3)/8) * 3 :
    (width == FRAME_WIDTH*2 && height == FRAME_HEIGHT*2) ? FRAME_WIDTH * FRAME_HEIGHT * 12 :
    (width == 16'd1024 && height == 16'd768) ? 32'd1024 * 32'd768 * 32'd3 :
    32'd0;
reg [31:0] required_file_len_q;
reg declared_pixels_complete_q;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        required_file_len_q <= 32'd0;
        declared_pixels_complete_q <= 1'b0;
    end else begin
        required_file_len_q <= pixel_offset + required_pixel_bytes;
        declared_pixels_complete_q <= pixel_offset >= 32'd54 &&
                                      required_pixel_bytes != 32'd0 &&
                                      file_len >= required_file_len_q;
    end
end
wire bmp_data_valid;
reg  bmp_range_active;
// 相位判定用一个字节提前寄存（idx==1 时 source_x/y 仍是当前像素），写使能那拍只需选一个寄存器值，
// 不给 SD 域那条本来就只剩 0.1ns 余量的写通路再串两级比较/与门。
reg keep_16_q;
reg keep_1x_q;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        keep_16_q <= 1'b0;
        keep_1x_q <= 1'b0;
    end else if (bmp_data_valid && !wav_mode && bmp_byte_idx == 2'd1) begin
        // 两条通路的写使能都在这里结算（同一像素、同一相位），写使能那拍只剩一个或门，
        // SD 域那条本来就贴着 20ns 的写通路不再被比较器/选择器拉长。
        keep_16_q <= downscale_16 && keep_16;
        // 两条通路互斥：16:10 降采样时 1x 那路必须关掉，否则写使能会被或成恒 1（会写出 1024 列）
        keep_1x_q <= downscale_16 ? 1'b0 :
                     (!downscale_2x ? 1'b1 : (!source_x[0] && !source_y[0]));
    end
end
wire [31:0] file_sector_count;
reg  [31:0] file_sector_count_q;
reg  [31:0] next_scan_sector_if_match;   // 寄存一拍，见下
reg         match_past_max;
wire [31:0] next_scan_sector_if_miss;

// scan_max_sector 在 FAT32 建表阶段就定下来，扫描阶段一直是常数，所以寄存一拍再用
// 完全等价，但能把 "virtual_last -> scan_max_sector -> 32 位比较 -> scan_gap_cnt.ce"
// 这条 10.5ns 的链切断（100MHz 域余量最紧的一条，随布局种子在 ±1ns 间跳）。
reg  [31:0] scan_max_sector_q;
always @(posedge clk or posedge rst) begin
    if (rst)
        scan_max_sector_q <= 32'd0;
    else
        scan_max_sector_q <= scan_max_sector;
end

assign ready = (state == ST_IDLE);
assign source_width = width[15:0];
assign source_height = height[15:0];
    assign bmp_pix_pos = {source_y[0], source_x[10:0]};
always @(posedge clk or posedge rst) begin
    if (rst)
        header_match <= 1'b0;
    else
        header_match <= (header_0 == "B") &&
                        (header_1 == "M") &&
                        (width[31:16] == 16'd0) && (height[31:16] == 16'd0) &&
                        (((width[15:0] == bmp_width) && (height[15:0] == bmp_height)) ||
                         ((width[15:0] == (bmp_width >> 1)) &&
                          (height[15:0] == (bmp_height >> 1))) ||
                         ((width[15:0] == (bmp_width >> 1)) &&
                          (height[15:0] == ((bmp_height * 3) >> 3))) ||
                         ((width[15:0] == (bmp_width << 1)) &&
                          (height[15:0] == (bmp_height << 1))) ||
                         ((width[15:0] == 16'd1024) && (height[15:0] == 16'd768))) &&
                        declared_pixels_complete_q &&
                        (bit_count    == 16'd24) &&
                        (compression  == 32'd0);
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        source_x <= 16'd0;
        source_y <= 16'd0;
        downscale_2x <= 1'b0;
        downscale_16 <= 1'b0;
    end else if (state != ST_LOAD_DATA) begin
        source_x <= 16'd0;
        source_y <= 16'd0;
        if (state == ST_LOAD_WAIT && write_req_ack) begin
            downscale_2x <= (width[15:0] == (bmp_width << 1)) &&
                            (height[15:0] == (bmp_height << 1));
            downscale_16 <= (width[15:0] == 16'd1024) && (height[15:0] == 16'd768);
        end
    end else if (bmp_data_valid && !wav_mode && bmp_byte_idx == 2'd2) begin
        if (source_x == width[15:0] - 16'd1) begin
            source_x <= 16'd0;
            source_y <= source_y + 16'd1;
        end else
            source_x <= source_x + 16'd1;
    end
end
always @(posedge clk or posedge rst) begin
    if (rst)
        bmp_range_active <= 1'b0;
    else
        bmp_range_active <= wav_mode ?
            ((bmp_len_cnt >= 32'd44) && (bmp_len_cnt < wav_load_end)) :
            ((bmp_len_cnt >= pixel_offset) && (bmp_len_cnt < file_len));
end
assign bmp_data_valid = sd_sec_read_data_valid && bmp_range_active;
assign file_sector_count = (file_len == 32'd0) ? 32'd1 : ((file_len + 32'd511) >> 9);
// 下一个扫描位置和"是否超出扫描上限"提前一拍寄存：file_len 在扇区第 2~5 字节就收齐，scan_sector 整个扇区不变，
// 扇区读完（512 字节后）才用。原来"file_len → 扇区数 → 加法 → 32 位比较 → 状态机"一拍做完，100MHz 下余量为负
always @(posedge clk or posedge rst) begin
    if (rst) begin
        file_sector_count_q <= 32'd1;
        next_scan_sector_if_match <= 32'd0;
        match_past_max            <= 1'b0;
    end else begin
        file_sector_count_q <= file_sector_count;
        next_scan_sector_if_match <= scan_sector + file_sector_count_q;
        match_past_max            <= (scan_sector + file_sector_count_q > scan_max_sector);
    end
end
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_valid_q <= 1'b0;
        header_index_q <= 10'd0;
        header_data_q <= 8'd0;
    end else begin
        header_valid_q <= ((state == ST_SCAN) || (state == ST_LOAD_HDR)) &&
                          sd_sec_read_data_valid;
        header_index_q <= rd_cnt;
        header_data_q <= sd_sec_read_data;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (header_valid_q) begin
        case (header_index_q)
            10'd0 : header_0 <= header_data_q;
            10'd1 : header_1 <= header_data_q;

            10'd2 : file_len[7:0] <= header_data_q;
            10'd3 : file_len[15:8] <= header_data_q;
            10'd4 : file_len[23:16] <= header_data_q;
            10'd5 : file_len[31:24] <= header_data_q;

            10'd10: pixel_offset[7:0] <= header_data_q;
            10'd11: pixel_offset[15:8] <= header_data_q;
            10'd12: pixel_offset[23:16] <= header_data_q;
            10'd13: pixel_offset[31:24] <= header_data_q;

            10'd18: width[7:0] <= header_data_q;
            10'd19: width[15:8] <= header_data_q;
            10'd20: width[23:16] <= header_data_q;
            10'd21: width[31:24] <= header_data_q;

            10'd22: height[7:0] <= header_data_q;
            10'd23: height[15:8] <= header_data_q;
            10'd24: height[23:16] <= header_data_q;
            10'd25: height[31:24] <= header_data_q;

            10'd28: bit_count[7:0] <= header_data_q;
            10'd29: bit_count[15:8] <= header_data_q;

            10'd30: compression[7:0] <= header_data_q;
            10'd31: compression[15:8] <= header_data_q;
            10'd32: compression[23:16] <= header_data_q;
            10'd33: compression[31:24] <= header_data_q;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wav_riff_tag  <= 32'd0;
        wav_riff_size <= 32'd0;
        wav_wave_tag  <= 32'd0;
        wav_fmt_tag   <= 32'd0;
        wav_audio_fmt <= 16'd0;
        wav_channels  <= 16'd0;
        wav_rate      <= 32'd0;
        wav_bits      <= 16'd0;
        wav_data_tag  <= 32'd0;
        wav_data_size <= 32'd0;
    end else if (header_valid_q) begin
        case (header_index_q)
            // 四字符标签按到达顺序移入，可直接和 "RIFF" 这样的字符串比较
            10'd0, 10'd1, 10'd2, 10'd3:     wav_riff_tag <= {wav_riff_tag[23:0], header_data_q};
            10'd8, 10'd9, 10'd10, 10'd11:   wav_wave_tag <= {wav_wave_tag[23:0], header_data_q};
            10'd12, 10'd13, 10'd14, 10'd15: wav_fmt_tag  <= {wav_fmt_tag[23:0],  header_data_q};
            10'd36, 10'd37, 10'd38, 10'd39: wav_data_tag <= {wav_data_tag[23:0], header_data_q};
            // 数值字段小端
            10'd4 : wav_riff_size[7:0]   <= header_data_q;
            10'd5 : wav_riff_size[15:8]  <= header_data_q;
            10'd6 : wav_riff_size[23:16] <= header_data_q;
            10'd7 : wav_riff_size[31:24] <= header_data_q;
            10'd20: wav_audio_fmt[7:0]   <= header_data_q;
            10'd21: wav_audio_fmt[15:8]  <= header_data_q;
            10'd22: wav_channels[7:0]    <= header_data_q;
            10'd23: wav_channels[15:8]   <= header_data_q;
            10'd24: wav_rate[7:0]        <= header_data_q;
            10'd25: wav_rate[15:8]       <= header_data_q;
            10'd26: wav_rate[23:16]      <= header_data_q;
            10'd27: wav_rate[31:24]      <= header_data_q;
            10'd34: wav_bits[7:0]        <= header_data_q;
            10'd35: wav_bits[15:8]       <= header_data_q;
            10'd40: wav_data_size[7:0]   <= header_data_q;
            10'd41: wav_data_size[15:8]  <= header_data_q;
            10'd42: wav_data_size[23:16] <= header_data_q;
            10'd43: wav_data_size[31:24] <= header_data_q;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wav_match        <= 1'b0;
        wav_file_sectors <= 32'd0;
        wav_words_calc   <= 21'd0;
    end else begin
        wav_match        <= (wav_riff_tag  == "RIFF") &&
                            (wav_wave_tag  == "WAVE") &&
                            (wav_fmt_tag   == "fmt ") &&
                            (wav_audio_fmt == 16'd1)  &&
                            (wav_channels  == 16'd2)  &&
                            (wav_rate      == 32'd48000) &&
                            (wav_bits      == 16'd16) &&
                            (wav_data_tag  == "data") &&
                            (wav_data_words >= 32'd256);
        wav_file_sectors <= (wav_riff_size + 32'd8 + 32'd511) >> 9;
        // 超过音频区就截断；再向下取整到 256 字（帧缓存写通道按 256 字一包突发，不支持零头）
        wav_words_calc   <= (wav_data_words > {11'd0, WAV_MAX_WORDS}) ? WAV_MAX_WORDS : {wav_data_words[20:8], 8'd0};
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == (wav_mode ? 2'd3 : 2'd2)) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
        wav_word       <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid && wav_mode) begin
            // WAV 样本小端：左低 左高 右低 右高 → {左声道, 右声道}
            case (bmp_byte_idx)
                2'd0: wav_word[23:16] <= sd_sec_read_data;
                2'd1: wav_word[31:24] <= sd_sec_read_data;
                2'd2: wav_word[7:0]   <= sd_sec_read_data;
                2'd3: wav_word[15:8]  <= sd_sec_read_data;
            endcase
            bmp_data_wr_en <= (bmp_byte_idx == 2'd3);
        end else if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_data_wr_en  <= keep_16_q || keep_1x_q;
                    bmp_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        load_error        <= 1'b0;
        scan_done         <= 1'b0;
        scan_paused       <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        wav_mode          <= 1'b0;
        wav_found         <= 1'b0;
        wav_sector        <= 32'd0;
        wav_words         <= 21'd0;
        scan_target_reached <= 1'b0;
        scan_gap_cnt      <= 32'd0;
    end else if (load_abort) begin
        // 加载超时：只放弃这次加载回到空闲，扫描结果保留
        // （lab_ex4 原写法在这里连 scan_done 一起清掉，之后 sd_card_bmp 的所有加载条件都不满足，按键失灵）
        state             <= ST_IDLE;
        sd_sec_read       <= 1'b0;
        write_req         <= 1'b0;
        load_error        <= 1'b0;
        wav_mode          <= 1'b0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        load_error        <= 1'b0;
        scan_done         <= 1'b0;
        scan_paused       <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        wav_mode          <= 1'b0;
        wav_found         <= 1'b0;
        wav_sector        <= 32'd0;
        wav_words         <= 21'd0;
        scan_target_reached <= 1'b0;
        scan_gap_cnt      <= 32'd0;
    end else begin
        scan_found_valid <= 1'b0;
        load_error <= 1'b0;

        case (state)
            ST_IDLE: begin
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_paused      <= 1'b0;
                    scan_found_total <= 3'd0;
                    wav_found        <= 1'b0;
                    scan_target_reached <= 1'b0;
                    scan_gap_cnt     <= 32'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    if (load_wav && wav_load_words != 0)
                        wav_words <= wav_load_words;
                    sd_sec_read_addr    <= load_sector;
                    wav_mode            <= load_wav;
                    state               <= ST_LOAD_HDR;
                end else if (scan_resume && scan_paused) begin
                    scan_paused       <= 1'b0;
                    sd_sec_read_addr  <= scan_sector;
                    state             <= ST_SCAN;
                end
            end

            ST_SCAN: begin
                sd_sec_read <= 1'b1;

                // 结束条件：BMP 找齐且 WAV 已找到；或 BMP 找齐后又连续 SCAN_WAV_GAP 个扇区没找到 WAV；或扫到上限
                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_match) begin
                        // 找齐之前的 BMP 才登记（sd_card_bmp 只存前 scan_target_count 张）
                        if (!scan_target_reached) begin
                            scan_found_valid  <= 1'b1;
                            scan_found_sector <= scan_sector;
                            scan_found_total  <= scan_found_total + 3'd1;
                        end
                        scan_target_reached <= scan_bmp_full;
                        scan_gap_cnt     <= 32'd0;
                        sd_sec_read_addr <= next_scan_sector_if_match;
                        scan_sector      <= next_scan_sector_if_match;
                        if ((scan_bmp_full && wav_found) || match_past_max) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else if (scan_found_total == 3'd0) begin
                            scan_paused <= 1'b1;
                            state       <= ST_IDLE;
                        end
                    end else if (wav_match) begin
                        // 只记第一个 WAV；不管是不是第一个都整个跳过，不逐扇区扫它的样本数据
                        if (!wav_found) begin
                            wav_found  <= 1'b1;
                            wav_sector <= scan_sector;
                            wav_words  <= wav_words_calc;
                        end
                        scan_gap_cnt     <= 32'd0;
                        sd_sec_read_addr <= scan_sector + wav_file_sectors;
                        scan_sector      <= scan_sector + wav_file_sectors;
                        if (scan_found_total != 3'd0 ||
                            (scan_sector + wav_file_sectors > scan_max_sector_q)) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end
                    end else begin
                        if ((scan_sector >= scan_max_sector_q) ||
                            (scan_target_reached && (scan_gap_cnt >= SCAN_WAV_GAP - 32'd1))) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                            if (scan_target_reached)
                                scan_gap_cnt <= scan_gap_cnt + 32'd1;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (wav_mode ? wav_match : header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        load_error <= 1'b1;
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (wav_mode ? (bmp_len_cnt >= wav_load_end) : (bmp_len_cnt >= file_len)) begin
                        state <= ST_IDLE;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end
            end

            default: begin
                state       <= ST_IDLE;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule

`timescale 1ns/1ps

// Presents root-directory BMP/WAV files as adjacent logical sectors to the
// existing bmp_read parser. A sector request follows the FAT chain on demand.
// Cards without a supported FAT32 volume pass through the legacy raw scanner.
module fat32_virtual_disk #(
    parameter integer MAX_ROOT_SECTORS = 128,
    parameter integer SCAN_TAIL_SECTORS = 1024,
    parameter integer FAT32_ONLY = 0,
    parameter integer ENABLE_TEXT = 1,
    // Compatibility switch: still parse the BPB to learn data_start, then use
    // the official raw scanner instead of the virtual FAT mapping.
    parameter integer FORCE_RAW = 0,
    // If the FAT32 index does not finish (non-standard BPB/root, bad card),
    // fall back to the official raw-sector scanner instead of blocking
    // bmp_read forever on fat_index_ready.
    parameter integer FAT_TIMEOUT_CYCLES = 250_000_000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sd_ready,
    input  wire        logical_read,
    input  wire [31:0] logical_addr,
    output wire        logical_valid,
    output wire [7:0]  logical_data,
    output wire        logical_end,
    output reg         ready,
    output reg         fat_mode,
    output reg         mapping_fault,
    output reg  [31:0] virtual_last,
    // Physical sector where the FAT32 data area starts.  Raw fallback scans
    // from here instead of sector 0, so the first file is found immediately.
    output reg  [31:0] raw_start_sector,
    output wire [2:0]  wav_count,
    input  wire [1:0]  wav_index,
    output wire [31:0] wav_base,
    output wire [31:0] wav_bytes,
    // 数字标牌配置文件的虚拟空间位置（卡根目录固定文件名）：PLAYLIST.TXT / TEXT.TXT
    output wire [31:0] list_base,
    output wire [31:0] list_bytes,
    output wire [31:0] text_base,
    output wire [31:0] text_bytes,
    output wire        physical_read,
    output wire [31:0] physical_addr,
    input  wire        physical_valid,
    input  wire [7:0]  physical_data,
    input  wire        physical_end
);
    localparam [5:0] WAIT_CARD=0, READ_ZERO=1, WAIT_ZERO=2,
        PARSE_ZERO=3, READ_BOOT=4, WAIT_BOOT=5, PARSE_BOOT=6,
        READ_ROOT=7, WAIT_ROOT=8, PARSE_ROOT=9,
        READ_ROOT_FAT=10, WAIT_ROOT_FAT=11, PARSE_ROOT_FAT=12,
        BUILD_INIT=13, BUILD=14, IDLE=15, RESOLVE=16,
        READ_FILE_FAT=17, WAIT_FILE_FAT=18, PARSE_FILE_FAT=19,
        READ_DATA=20, WAIT_DATA=21, ZERO_DATA=22,
        WAIT_RELEASE=23, RAW=24, SEARCH=25, PREP=26,
        START_RESOLVE=27, CHOOSE_CACHE=28,
        CALC_ROOT_OFFSET=29, CALC_ROOT_LBA=30, BUILD_COMMIT=31,
        CALC_DATA_OFFSET=32, CALC_DATA_LBA=33, BUILD_COUNT=34,
        CALC_ROOT_DELTA=35, PARSE_ROOT_CHECK=36, VERIFY_FILE_FAT=37,
        PARSE_ROOT_DELAY=38, SEARCH_FETCH=39;
    reg [5:0] state;
    reg request_q;
    reg raw_read_done;
    reg [31:0] address_q;
    reg valid_q, end_q;
    reg [7:0] data_q;
    reg [7:0] sector_buffer [0:63];
    reg [7:0] dir_entry [0:31];
    reg [7:0] sig_lo, sig_hi, mbr_type;
    reg [31:0] mbr_lba, fat_word;
    reg root_done;
    reg dir_entry_pending;
    reg dir_commit_pending, dir_end_q, dir_bmp_q, dir_wav_q;
    reg dir_list_q, dir_text_q;
    reg [31:0] dir_cluster_q, dir_size_q;
    reg [8:0] byte_index;
    reg [15:0] root_sector_count;
    reg [7:0] root_sector_in_cluster;
    reg [31:0] partition_lba, fat_start, data_start;
    reg fat_next_valid;
    reg [31:0] root_cluster, root_lba, fat_sectors;
    reg [31:0] root_offset;
    reg [31:0] root_delta;
    reg [31:0] data_offset;
    reg [27:0] init_wait_cnt;
    reg [7:0] sectors_per_cluster;
    reg [2:0] spc_shift;
    reg [2:0] bmp_count;
    reg [3:0] wav_count_q, file_count, build_index;
    reg [31:0] wav_cluster [0:3];
    reg [31:0] wav_size [0:3];
    reg [31:0] list_cluster, list_size;
    reg [31:0] text_cluster, text_size;
    reg        list_found, text_found;
    reg [31:0] bmp_cluster [0:3];
    reg [31:0] bmp_size [0:3];
    reg [31:0] file_base [0:10];
    reg [31:0] build_cursor;
    reg [31:0] build_size;
    reg [31:0] build_length;
    reg [3:0] active_file, cache_file;
    reg cache_valid;
    reg [31:0] active_cluster, active_cluster_index;
    reg [31:0] cache_cluster, cache_cluster_index;
    reg [31:0] target_cluster_index;
    reg [7:0] target_sector_in_cluster;
    reg [8:0] fat_entry_offset, zero_index;
    reg [31:0] lookup_addr, selected_offset, selected_base;
    reg [31:0] search_base_q, search_limit_q;
    reg [3:0] search_file;
    integer i;
    integer k;
    wire [31:0] fat_next = fat_word & 32'h0fffffff;
    wire [31:0] dir_size = {dir_entry[31],dir_entry[30],
                            dir_entry[29],dir_entry[28]};
    wire [63:0] dir_name_q = {dir_entry[0],dir_entry[1],dir_entry[2],dir_entry[3],
                              dir_entry[4],dir_entry[5],dir_entry[6],dir_entry[7]};
    wire dir_list_name = dir_name_q == "PLAYLIST";
    wire dir_text_name = dir_name_q == "TEXT    ";
    wire [3:0] media_slots = bmp_count + wav_count_q;
    wire [3:0] list_slot   = media_slots;
    wire [3:0] text_slot   = media_slots + {3'd0, list_found};

    assign physical_read = (ready && !fat_mode) ?
                           (logical_read && !raw_read_done) : request_q;
    assign physical_addr = (ready && !fat_mode) ? logical_addr : address_q;
    assign logical_valid = valid_q;
    assign logical_data = data_q;
    assign logical_end = end_q;
    assign wav_count = wav_count_q[2:0];
    assign wav_base = file_base[bmp_count+{1'b0,wav_index}];
    assign wav_bytes = wav_size[wav_index];
    assign list_base  = file_base[list_slot];
    assign list_bytes = list_found ? list_size : 32'd0;
    assign text_base  = ENABLE_TEXT ? file_base[text_slot] : 32'd0;
    assign text_bytes = ENABLE_TEXT && text_found ? text_size : 32'd0;

    function [15:0] le16;
        input integer offset;
        begin le16 = {sector_buffer[offset+1],sector_buffer[offset]}; end
    endfunction
    function [31:0] le32;
        input integer offset;
        begin
            le32 = {sector_buffer[offset+3],sector_buffer[offset+2],
                    sector_buffer[offset+1],sector_buffer[offset]};
        end
    endfunction
    function [2:0] cluster_shift;
        input [7:0] sectors;
        begin
            case (sectors)
                8'd2: cluster_shift=1;
                8'd4: cluster_shift=2;
                8'd8: cluster_shift=3;
                8'd16:cluster_shift=4;
                8'd32:cluster_shift=5;
                8'd64:cluster_shift=6;
                8'd128:cluster_shift=7;
                default:cluster_shift=0;
            endcase
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (k=0;k<11;k=k+1) begin
                file_base[k] <= 32'd0;
            end
        end else if (state == BUILD_COMMIT) begin
            file_base[build_index] <= build_cursor;
            file_base[build_index+4'd1] <= build_cursor + build_length;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) selected_offset <= 32'd0;
        else if (state == PREP) selected_offset <= lookup_addr - selected_base;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= WAIT_CARD;
            request_q <= 1'b0;
            raw_read_done <= 1'b0;
            init_wait_cnt <= 28'd0;
            address_q <= 32'd0;
            valid_q <= 1'b0;
            end_q <= 1'b0;
            data_q <= 8'd0;
            byte_index <= 9'd0;
            root_done <= 1'b0;
            dir_entry_pending <= 1'b0;
            dir_commit_pending <= 1'b0;
            dir_end_q <= 1'b0;
            dir_bmp_q <= 1'b0;
            dir_wav_q <= 1'b0;
            dir_list_q <= 1'b0;
            dir_text_q <= 1'b0;
            dir_cluster_q <= 32'd0;
            dir_size_q <= 32'd0;
            sig_lo <= 8'd0;
            sig_hi <= 8'd0;
            mbr_type <= 8'd0;
            mbr_lba <= 32'd0;
            fat_word <= 32'd0;
            fat_next_valid <= 1'b0;
            root_sector_count <= 16'd0;
            root_sector_in_cluster <= 8'd0;
            partition_lba <= 32'd0;
            fat_start <= 32'd0;
            data_start <= 32'd0;
            root_cluster <= 32'd0;
            root_lba <= 32'd0;
            root_offset <= 32'd0;
            root_delta <= 32'd0;
            data_offset <= 32'd0;
            fat_sectors <= 32'd0;
            sectors_per_cluster <= 8'd0;
            spc_shift <= 3'd0;
            bmp_count <= 3'd0;
            file_count <= 4'd0;
            build_index <= 3'd0;
            wav_count_q <= 4'd0;
            for (i=0;i<4;i=i+1) begin
                wav_cluster[i] <= 32'd0;
                wav_size[i] <= 32'd0;
            end
            list_cluster <= 32'd0;
            list_size    <= 32'd0;
            text_cluster <= 32'd0;
            text_size    <= 32'd0;
            list_found   <= 1'b0;
            text_found   <= 1'b0;
            build_cursor <= 32'd0;
            build_size <= 32'd0;
            build_length <= 32'd0;
            lookup_addr <= 32'd0;
            selected_base <= 32'd0;
            search_base_q <= 32'd0;
            search_limit_q <= 32'd0;
            search_file <= 3'd0;
            active_file <= 3'd0;
            active_cluster <= 32'd0;
            active_cluster_index <= 32'd0;
            target_cluster_index <= 32'd0;
            target_sector_in_cluster <= 8'd0;
            cache_valid <= 1'b0;
            cache_file <= 3'd0;
            cache_cluster <= 32'd0;
            cache_cluster_index <= 32'd0;
            fat_entry_offset <= 9'd0;
            zero_index <= 9'd0;
            ready <= 1'b0;
            fat_mode <= 1'b0;
            mapping_fault <= 1'b0;
            virtual_last <= 32'd0;
            raw_start_sector <= 32'd0;
            for (i=0;i<4;i=i+1) begin
                bmp_cluster[i] <= 32'd0;
                bmp_size[i] <= 32'd0;
            end
        end else if (!sd_ready) begin
            state <= WAIT_CARD;
            request_q <= 1'b0;
            raw_read_done <= 1'b0;
            ready <= 1'b0;
            fat_mode <= 1'b0;
            mapping_fault <= 1'b0;
            bmp_count <= 3'd0;
            wav_count_q <= 4'd0;
            list_found <= 1'b0;
            text_found <= 1'b0;
            cache_valid <= 1'b0;
            valid_q <= 1'b0;
            end_q <= 1'b0;
            dir_entry_pending <= 1'b0;
            dir_commit_pending <= 1'b0;
        end else begin
            valid_q <= 1'b0;
            end_q <= 1'b0;
            mapping_fault <= 1'b0;
            dir_entry_pending <= 1'b0;
            dir_commit_pending <= 1'b0;
            if (dir_entry_pending && !root_done) begin
                dir_end_q <= dir_entry[0] == 8'h00;
                dir_bmp_q <= dir_entry[0] != 8'he5 && dir_entry[11] != 8'h0f &&
                             !dir_entry[11][3] && !dir_entry[11][4] &&
                             |dir_cluster_q[31:1] && dir_entry[8] == "B" &&
                             dir_entry[9] == "M" && dir_entry[10] == "P" &&
                             dir_size >= 32'd54;
                dir_wav_q <= dir_entry[0] != 8'he5 && dir_entry[11] != 8'h0f &&
                             !dir_entry[11][3] && !dir_entry[11][4] &&
                             |dir_cluster_q[31:1] && dir_entry[8] == "W" &&
                             dir_entry[9] == "A" && dir_entry[10] == "V" &&
                             dir_size >= 32'd44;
                dir_list_q <= dir_entry[0] != 8'he5 && dir_entry[11] != 8'h0f &&
                              !dir_entry[11][3] && !dir_entry[11][4] &&
                              |dir_cluster_q[31:1] && dir_list_name &&
                              dir_entry[8] == "T" && dir_entry[9] == "X" &&
                              dir_entry[10] == "T" && dir_size >= 32'd8;
                dir_text_q <= ENABLE_TEXT && dir_entry[0] != 8'he5 && dir_entry[11] != 8'h0f &&
                              !dir_entry[11][3] && !dir_entry[11][4] &&
                              |dir_cluster_q[31:1] && dir_text_name &&
                              dir_entry[8] == "T" && dir_entry[9] == "X" &&
                              dir_entry[10] == "T" && dir_size >= 32'd2;
                dir_size_q <= dir_size;
                dir_commit_pending <= 1'b1;
            end
            if (dir_commit_pending) begin
                if (dir_end_q)
                    root_done <= 1'b1;
                else if (dir_bmp_q && bmp_count < 3'd4) begin
                    bmp_cluster[bmp_count] <= dir_cluster_q;
                    bmp_size[bmp_count] <= dir_size_q;
                    bmp_count <= bmp_count + 3'd1;
                end else if (dir_wav_q && wav_count_q < 4'd4) begin
                    wav_cluster[wav_count_q] <= dir_cluster_q;
                    wav_size[wav_count_q] <= dir_size_q;
                    wav_count_q <= wav_count_q + 4'd1;
                end else if (dir_list_q && !list_found) begin
                    list_cluster <= dir_cluster_q;
                    list_size    <= dir_size_q;
                    list_found   <= 1'b1;
                end else if (dir_text_q && !text_found) begin
                    text_cluster <= dir_cluster_q;
                    text_size    <= dir_size_q;
                    text_found   <= 1'b1;
                end
            end
            if (physical_valid && state != WAIT_DATA) begin
                byte_index <= byte_index + 9'd1;
                if (state == WAIT_ZERO || state == WAIT_BOOT) begin
                    if (byte_index < 9'd64)
                        sector_buffer[byte_index[5:0]] <= physical_data;
                    if (byte_index == 9'd510) sig_lo <= physical_data;
                    if (byte_index == 9'd511) sig_hi <= physical_data;
                    if (state == WAIT_ZERO) begin
                        if (byte_index == 9'd450) mbr_type <= physical_data;
                        case (byte_index)
                            9'd454: mbr_lba[7:0] <= physical_data;
                            9'd455: mbr_lba[15:8] <= physical_data;
                            9'd456: mbr_lba[23:16] <= physical_data;
                            9'd457: mbr_lba[31:24] <= physical_data;
                        endcase
                    end
                end else if (state == WAIT_ROOT) begin
                    dir_entry[byte_index[4:0]] <= physical_data;
                    case (byte_index[4:0])
                        5'd20: dir_cluster_q[31:24] <= physical_data;
                        5'd21: dir_cluster_q[23:16] <= physical_data;
                        5'd26: dir_cluster_q[7:0] <= physical_data;
                        5'd27: dir_cluster_q[15:8] <= physical_data;
                        default: ;
                    endcase
                    if (byte_index[4:0] == 5'd31)
                        dir_entry_pending <= 1'b1;
                end else if ((state == WAIT_ROOT_FAT || state == WAIT_FILE_FAT) &&
                             byte_index[8:2] == fat_entry_offset[8:2]) begin
                    case (byte_index[1:0])
                        2'd0: fat_word[7:0] <= physical_data;
                        2'd1: fat_word[15:8] <= physical_data;
                        2'd2: fat_word[23:16] <= physical_data;
                        2'd3: fat_word[31:24] <= physical_data;
                    endcase
                end
            end
            case (state)
                WAIT_CARD: state <= READ_ZERO;
                READ_ZERO: begin
                    address_q <= 32'd0;
                    byte_index <= 9'd0;
                    request_q <= 1'b1;
                    state <= WAIT_ZERO;
                end
                WAIT_ZERO: if (physical_end) begin
                    request_q <= 1'b0;
                    state <= PARSE_ZERO;
                end
                PARSE_ZERO: begin
                    if (sig_lo != 8'h55 || sig_hi != 8'haa) begin
                        ready <= 1'b1;
                        if (FAT32_ONLY) begin
                            fat_mode <= 1'b1; virtual_last <= 32'd0; state <= IDLE;
                        end else state <= RAW;
                    end else if (sector_buffer[0] == 8'heb || sector_buffer[0] == 8'he9) begin
                        partition_lba <= 32'd0;
                        state <= PARSE_BOOT;
                    end else if (mbr_type == 8'h0b || mbr_type == 8'h0c) begin
                        partition_lba <= mbr_lba;
                        state <= READ_BOOT;
                    end else begin
                        ready <= 1'b1;
                        if (FAT32_ONLY) begin
                            fat_mode <= 1'b1; virtual_last <= 32'd0; state <= IDLE;
                        end else state <= RAW;
                    end
                end
                READ_BOOT: begin
                    address_q <= partition_lba;
                    byte_index <= 9'd0;
                    request_q <= 1'b1;
                    state <= WAIT_BOOT;
                end
                WAIT_BOOT: if (physical_end) begin
                    request_q <= 1'b0;
                    state <= PARSE_BOOT;
                end
                PARSE_BOOT: begin
                    if (sig_lo != 8'h55 || sig_hi != 8'haa ||
                        le16(11) != 16'd512 || sector_buffer[13] == 0 ||
                        (sector_buffer[13] & (sector_buffer[13]-8'd1)) != 0 ||
                        le16(14) == 0 || (sector_buffer[16] != 1 && sector_buffer[16] != 2) ||
                        le32(36) == 0 || le32(44) < 2) begin
                        ready <= 1'b1;
                        if (FAT32_ONLY) begin
                            fat_mode <= 1'b1; virtual_last <= 32'd0; state <= IDLE;
                        end else state <= RAW;
                    end else begin
                        sectors_per_cluster <= sector_buffer[13];
                        spc_shift <= cluster_shift(sector_buffer[13]);
                        fat_start <= partition_lba + {16'd0,le16(14)};
                        fat_sectors <= le32(36);
                        raw_start_sector <= partition_lba + {16'd0,le16(14)} +
                                            (sector_buffer[16] == 8'd2 ?
                                             (le32(36) << 1) : le32(36));
                        data_start <= partition_lba + {16'd0,le16(14)} +
                                      (sector_buffer[16] == 8'd2 ?
                                       (le32(36) << 1) : le32(36));
                        root_cluster <= le32(44) & 32'h0fffffff;
                        root_sector_in_cluster <= 8'd0;
                        root_sector_count <= 16'd0;
                        state <= CALC_ROOT_DELTA;
                    end
                end
                CALC_ROOT_DELTA: begin
                    root_delta <= root_cluster - 32'd2;
                    state <= CALC_ROOT_OFFSET;
                end
                CALC_ROOT_OFFSET: begin
                    root_offset <= root_delta << spc_shift;
                    state <= CALC_ROOT_LBA;
                end
                CALC_ROOT_LBA: begin
                    root_lba <= data_start + root_offset;
                    state <= READ_ROOT;
                end
                READ_ROOT: begin
                    address_q <= root_lba;
                    byte_index <= 9'd0;
                    root_done <= 1'b0;
                    request_q <= 1'b1;
                    state <= WAIT_ROOT;
                end
                WAIT_ROOT: if (physical_end) begin
                    request_q <= 1'b0;
                    state <= PARSE_ROOT;
                end
                PARSE_ROOT: begin
                    state <= PARSE_ROOT_DELAY;
                end
                PARSE_ROOT_DELAY: begin
                    state <= PARSE_ROOT_CHECK;
                end
                PARSE_ROOT_CHECK: begin
                    if (root_done || dir_entry[0] == 8'h00 ||
                        root_sector_count == MAX_ROOT_SECTORS-1)
                        state <= BUILD_INIT;
                    else begin
                        if ({1'b0,root_sector_in_cluster}+9'd1 <
                                 {1'b0,sectors_per_cluster}) begin
                            root_sector_in_cluster <= root_sector_in_cluster + 8'd1;
                            root_sector_count <= root_sector_count + 16'd1;
                            root_lba <= root_lba + 32'd1;
                            state <= READ_ROOT;
                        end else begin
                            fat_entry_offset <= {root_cluster[6:0],2'b00};
                            state <= READ_ROOT_FAT;
                        end
                    end
                end
                READ_ROOT_FAT: begin
                    address_q <= fat_start + (root_cluster >> 7);
                    byte_index <= 9'd0;
                    request_q <= 1'b1;
                    state <= WAIT_ROOT_FAT;
                end
                WAIT_ROOT_FAT: if (physical_end) begin
                    request_q <= 1'b0;
                    state <= PARSE_ROOT_FAT;
                end
                PARSE_ROOT_FAT: begin
                    if (fat_next < 32'd2 || fat_next >= 32'h0ffffff8)
                        state <= BUILD_INIT;
                    else begin
                        root_cluster <= fat_next;
                        root_sector_in_cluster <= 8'd0;
                        root_sector_count <= root_sector_count + 16'd1;
                        state <= CALC_ROOT_DELTA;
                    end
                end
                BUILD_INIT: begin
                    if (bmp_count == 0) begin
                        ready <= 1'b1;
                        if (FAT32_ONLY) begin
                            fat_mode <= 1'b1; virtual_last <= 32'd0; state <= IDLE;
                        end else state <= RAW;
                    end else begin
                        file_count <= media_slots + {3'd0, list_found} + {3'd0, text_found};
                        build_index <= 3'd0;
                        build_cursor <= 32'd0;
                        state <= BUILD;
                    end
                end
                BUILD: begin
                    if (build_index < file_count) begin
                        build_size <= (build_index < bmp_count) ?
                            bmp_size[build_index[1:0]] :
                            (build_index < media_slots) ?
                                wav_size[build_index-bmp_count] :
                                (build_index == list_slot) ? list_size : text_size;
                        state <= BUILD_COUNT;
                    end else begin
                        virtual_last <= build_cursor + SCAN_TAIL_SECTORS;
                        ready <= 1'b1;
                        fat_mode <= 1'b1;
                        state <= IDLE;
                    end
                end
                BUILD_COUNT: begin
                    build_length <= (build_size >> 9) + (|build_size[8:0]);
                    state <= BUILD_COMMIT;
                end
                BUILD_COMMIT: begin
                    build_cursor <= build_cursor + build_length;
                    build_index <= build_index + 3'd1;
                    state <= BUILD;
                end
                IDLE: if (logical_read) begin
                    lookup_addr <= logical_addr;
                    search_file <= 3'd0;
                    state <= SEARCH_FETCH;
                end
                SEARCH_FETCH: begin
                    search_base_q <= file_base[search_file];
                    search_limit_q <= file_base[search_file+4'd1];
                    state <= SEARCH;
                end
                SEARCH: begin
                    if (lookup_addr >= search_base_q &&
                        lookup_addr < search_limit_q) begin
                        selected_base <= search_base_q;
                        state <= PREP;
                    end else if (search_file + 3'd1 < file_count)
                        begin
                            search_file <= search_file + 3'd1;
                            state <= SEARCH_FETCH;
                        end
                    else begin
                        zero_index <= 9'd0;
                        state <= ZERO_DATA;
                    end
                end
                PREP: begin
                    active_file <= search_file;
                    state <= START_RESOLVE;
                end
                START_RESOLVE: begin
                    target_cluster_index <= selected_offset >> spc_shift;
                    target_sector_in_cluster <=
                        selected_offset & ({24'd0,sectors_per_cluster}-32'd1);
                    state <= CHOOSE_CACHE;
                end
                CHOOSE_CACHE: begin
                    if (cache_valid && cache_file == active_file &&
                        cache_cluster_index <= target_cluster_index) begin
                        active_cluster <= cache_cluster;
                        active_cluster_index <= cache_cluster_index;
                    end else begin
                        active_cluster <= (active_file < bmp_count) ?
                            bmp_cluster[active_file[1:0]] :
                            (active_file < media_slots) ?
                                wav_cluster[active_file-bmp_count] :
                                (active_file == list_slot) ? list_cluster : text_cluster;
                        active_cluster_index <= 32'd0;
                    end
                    state <= RESOLVE;
                end
                RESOLVE: begin
                    if (active_cluster_index == target_cluster_index) begin
                        state <= CALC_DATA_OFFSET;
                    end else begin
                        fat_entry_offset <= {active_cluster[6:0],2'b00};
                        state <= READ_FILE_FAT;
                    end
                end
                CALC_DATA_OFFSET: begin
                    data_offset <= (active_cluster-32'd2) << spc_shift;
                    state <= CALC_DATA_LBA;
                end
                CALC_DATA_LBA: begin
                    address_q <= data_start + data_offset +
                                 {24'd0,target_sector_in_cluster};
                    state <= READ_DATA;
                end
                READ_FILE_FAT: begin
                    address_q <= fat_start + (active_cluster >> 7);
                    byte_index <= 9'd0;
                    request_q <= 1'b1;
                    state <= WAIT_FILE_FAT;
                end
                WAIT_FILE_FAT: if (physical_end) begin
                    request_q <= 1'b0;
                    state <= VERIFY_FILE_FAT;
                end
                VERIFY_FILE_FAT: begin
                    fat_next_valid <= fat_next >= 32'd2 &&
                                      fat_next < 32'h0ffffff8 &&
                                      fat_next != active_cluster;
                    state <= PARSE_FILE_FAT;
                end
                PARSE_FILE_FAT: begin
                    if (!fat_next_valid) begin
                        mapping_fault <= 1'b1;
                        zero_index <= 9'd0;
                        state <= ZERO_DATA;
                    end else begin
                        active_cluster <= fat_next;
                        active_cluster_index <= active_cluster_index + 32'd1;
                        cache_valid <= 1'b1;
                        cache_file <= active_file;
                        cache_cluster <= fat_next;
                        cache_cluster_index <= active_cluster_index + 32'd1;
                        state <= RESOLVE;
                    end
                end
                READ_DATA: begin
                    request_q <= 1'b1;
                    state <= WAIT_DATA;
                end
                WAIT_DATA: begin
                    if (physical_valid) begin
                        valid_q <= 1'b1;
                        data_q <= physical_data;
                    end
                    if (physical_end) begin
                        request_q <= 1'b0;
                        end_q <= 1'b1;
                        cache_valid <= 1'b1;
                        cache_file <= active_file;
                        cache_cluster <= active_cluster;
                        cache_cluster_index <= active_cluster_index;
                        state <= WAIT_RELEASE;
                    end
                end
                ZERO_DATA: begin
                    valid_q <= 1'b1;
                    data_q <= 8'd0;
                    if (zero_index == 9'd511) begin
                        end_q <= 1'b1;
                        state <= WAIT_RELEASE;
                    end else zero_index <= zero_index + 9'd1;
                end
                WAIT_RELEASE: if (!logical_read) state <= IDLE;
                RAW: begin
                    valid_q <= physical_valid;
                    if (physical_valid) data_q <= physical_data;
                    end_q <= physical_end;
                    if (physical_end) raw_read_done <= 1'b1;
                    else if (!logical_read) raw_read_done <= 1'b0;
                end
                default: state <= WAIT_CARD;
            endcase

            if (FORCE_RAW && !FAT32_ONLY && ready && fat_mode) begin
                fat_mode <= 1'b0;
                state    <= RAW;
            end

            // FAT32 index watchdog: never block bmp_read forever.  A normal
            // clean card finishes in well under a second; a non-standard BPB
            // or a stuck physical read falls back to the official raw scan.
            if (sd_ready && !ready) begin
                if (init_wait_cnt == FAT_TIMEOUT_CYCLES - 1) begin
                    ready         <= 1'b1;
                    fat_mode      <= FAT32_ONLY ? 1'b1 : 1'b0;
                    mapping_fault <= 1'b1;
                    virtual_last  <= FAT32_ONLY ? 32'd0 : virtual_last;
                    state         <= FAT32_ONLY ? IDLE : RAW;
                    request_q     <= 1'b0;
                    valid_q       <= 1'b0;
                    end_q         <= 1'b0;
                end else begin
                    init_wait_cnt <= init_wait_cnt + 28'd1;
                end
            end else begin
                init_wait_cnt <= 28'd0;
            end
        end
    end
endmodule

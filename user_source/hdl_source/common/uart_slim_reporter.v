`timescale 1ns/1ps

// 精简串口报文（只发不收）：每 FRAMES_PER_REPORT 帧发一行 190 字节可读状态。
// 事件日志不再经串口导出，只供 OSD LOG 页使用：按 newest_slot 往前读最近 7 个槽，
// 展开成 log_view（7 × 36 bit）。
module uart_slim_reporter #(
    parameter integer CLK_HZ = 25_200_000,
    parameter integer BAUD = 115_200,
    parameter integer FRAMES_PER_REPORT = 60
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire [2:0]  brightness,
    input  wire [2:0]  contrast,
    input  wire [1:0]  transition,
    input  wire [2:0]  volume,
    input  wire [1:0]  image_index,
    input  wire [2:0]  image_count,
    input  wire [23:0] uptime_bcd,
    input  wire        auto_mode,
    input  wire        tf_mounted,
    input  wire        wav_ready,
    input  wire [3:0]  health,
    input  wire [3:0]  load_stage,
    input  wire [3:0]  playlist_errors,
    // 事件日志快照：scan_done / append_done 后刷新，7 行 × 36 bit
    //   [15:0] seq / [27:16] 秒数 BCD(百/十/个) / [30:28] kind / [34:32] item / [35] valid
    input  wire        log_refresh,
    input  wire [3:0]  log_newest_slot,
    output reg         log_rd_start,
    output reg  [3:0]  log_rd_slot,
    input  wire        log_rd_done,
    input  wire        log_rd_valid,
    input  wire [95:0] log_rd_data,
    output wire [251:0] log_view,
    output wire        log_any_valid,
    output wire        uart_tx
);
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer FB = (FRAMES_PER_REPORT < 2) ? 1 : $clog2(FRAMES_PER_REPORT);
    localparam integer STATUS_LAST = 189;
    localparam integer LOG_ROWS    = 7;

    // ---------------- 发送器 ----------------
    localparam [1:0] T_IDLE = 2'd0, T_LOAD = 2'd1, T_WAIT = 2'd2;
    reg [1:0]  tx_state;
    reg [7:0]  char_index;
    reg        tx_start;
    reg [7:0]  tx_data;
    reg        status_done;
    wire       tx_busy;

    // ---------------- 状态行请求 ----------------
    reg [FB-1:0] frame_count;
    reg          status_req, status_wait;
    reg [2:0]    b_q, c_q, v_q;
    reg [1:0]    t_q, i_q;
    reg [3:0]    e_q;
    reg [2:0]    count_q;
    reg [23:0]   time_q;
    reg          auto_q, sd_q, wav_q;
    reg [3:0]    health_q, stage_q;

    // ---------------- 日志快照 ----------------
    localparam [2:0] S_IDLE  = 3'd0, S_ISSUE = 3'd1, S_RD = 3'd2,
                     S_CONV  = 3'd3, S_ROW   = 3'd4;
    reg [2:0]  snap_state;
    reg [3:0]  base_slot, slot_idx;
    reg        refresh_pending;

    reg [15:0] v_seq  [0:LOG_ROWS-1];
    reg [11:0] v_bcd  [0:LOG_ROWS-1];
    reg [2:0]  v_kind [0:LOG_ROWS-1];
    reg [3:0]  v_item [0:LOG_ROWS-1];
    reg        v_valid[0:LOG_ROWS-1];

    // 32 位 / 10 的串行恢复除法：三次得到 秒数 mod 1000 的个/十/百位。
    reg [31:0] div_sh, div_q;
    reg [3:0]  div_rem;
    reg [5:0]  div_count;
    reg [1:0]  div_digit;
    reg [3:0]  bcd_units, bcd_tens, bcd_hundreds;
    wire [5:0] div_twice = {2'b0,div_rem} << 1;
    wire [5:0] div_sum   = div_twice + {5'b0,div_sh[31]};
    wire       div_ge10  = (div_sum >= 6'd10);
    wire [5:0] div_sub   = div_ge10 ? (div_sum - 6'd10) : div_sum;

    wire       status_take = (tx_state == T_IDLE) && status_req;
    integer    vi;

    uart_tx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst), .start(tx_start), .data(tx_data),
        .tx(uart_tx), .busy(tx_busy), .done()
    );

    function [7:0] hex_char;              // 0..15 -> '0'..'9','A'..'F'
        input [3:0] v;
        begin
            hex_char = (v < 4'd10) ? (8'h30 + {4'd0,v}) : (8'h37 + {4'd0,v});
        end
    endfunction

    localparam integer STATUS_TEXT_LEN = 188;
    localparam [8*STATUS_TEXT_LEN-1:0] STATUS_TEXT =
        "UPTIME=00:00:00 IMAGE=0/0 AUTO_MODE=OFF TF_CARD=ABSENT WAV_AUDIO=WAIT   BRIGHTNESS_LEVEL=0 CONTRAST_LEVEL=0 VOLUME_LEVEL=0 TRANSITION=FADE    PLAYLIST_ERRORS=0 LOAD_PHASE=SD_INIT  HEALTH=0";
    reg [7:0] status_rom [0:STATUS_TEXT_LEN-1];
    reg [7:0] status_template_q;
    integer status_i;
    initial begin
        for (status_i=0;status_i<STATUS_TEXT_LEN;status_i=status_i+1)
            status_rom[status_i] = STATUS_TEXT[8*(STATUS_TEXT_LEN-1-status_i) +: 8];
    end
    wire [7:0] status_rom_addr = tx_state == T_IDLE ? 8'd0 :
                                  tx_state == T_WAIT ? char_index + 8'd1 : char_index;
    always @(posedge clk)
        status_template_q <= status_rom[status_rom_addr];

    function [7:0] transition_name;
        input [1:0] kind;
        input [2:0] col;
        reg [63:0] word;
        begin
            case (kind)
                2'd1: word = "LEFT    ";
                2'd2: word = "RIGHT   ";
                2'd3: word = "DIAMOND ";
                default: word = "FADE    ";
            endcase
            transition_name = word[8*(7-col) +: 8];
        end
    endfunction

    function [7:0] phase_name;
        input [3:0] stage;
        input [2:0] col;
        reg [63:0] word;
        begin
            case (stage)
                4'd0: word = "SD_INIT ";
                4'd1: word = "FAT_WAIT";
                4'd2: word = "BMP_WAIT";
                4'd3: word = "LIST_CFG";
                4'd4: word = "SCANNING";
                4'd5: word = "NO_IMAGE";
                4'd6: word = "FRAME_IO";
                4'd7: word = "WAV_WAIT";
                4'd8: word = "INDEXING";
                4'd10: word = "SD_CMD0 ";
                4'd11: word = "SD_CMD8 ";
                4'd12: word = "SD_CMD55";
                4'd13: word = "ACMD41  ";
                4'd14: word = "SD_CMD16";
                default: word = "READY   ";
            endcase
            phase_name = word[8*(7-col) +: 8];
        end
    endfunction

    function [7:0] status_char;
        input [7:0] n;
        reg [47:0] word6;
        begin
            status_char = n == 8'd188 ? 8'h0d :
                          n == 8'd189 ? 8'h0a :
                          status_template_q;
            case (n)
                8'd7: status_char = hex_char(time_q[23:20]);
                8'd8: status_char = hex_char(time_q[19:16]);
                8'd10: status_char = hex_char(time_q[15:12]);
                8'd11: status_char = hex_char(time_q[11:8]);
                8'd13: status_char = hex_char(time_q[7:4]);
                8'd14: status_char = hex_char(time_q[3:0]);
                8'd22: status_char = count_q == 3'd0 ? "0" : ("1" + {6'd0,i_q});
                8'd24: status_char = "0" + {5'd0,count_q};
                8'd36,8'd37,8'd38:
                    status_char = auto_q ? (n == 8'd36 ? "O" : n == 8'd37 ? "N" : " ") :
                                           (n == 8'd36 ? "O" : n == 8'd37 ? "F" : "F");
                8'd48,8'd49,8'd50,8'd51,8'd52,8'd53: begin
                    word6 = sd_q ? "READY " : "ABSENT";
                    status_char = word6[8*(53-n) +: 8];
                end
                8'd65,8'd66,8'd67,8'd68,8'd69,8'd70: begin
                    word6 = wav_q ? "READY " : "WAIT  ";
                    status_char = word6[8*(70-n) +: 8];
                end
                8'd89: status_char = hex_char({1'b0,b_q});
                8'd106: status_char = hex_char({1'b0,c_q});
                8'd121: status_char = hex_char({1'b0,v_q});
                8'd134,8'd135,8'd136,8'd137,8'd138,8'd139,8'd140,8'd141:
                    status_char = transition_name(t_q,n-8'd134);
                8'd158: status_char = hex_char(e_q);
                8'd171,8'd172,8'd173,8'd174,8'd175,8'd176,8'd177,8'd178:
                    status_char = phase_name(stage_q,n-8'd171);
                8'd187: status_char = hex_char(health_q);
                default: ;
            endcase
        end
    endfunction

    genvar gv;
    generate
        for (gv = 0; gv < LOG_ROWS; gv = gv + 1) begin: g_log_view
            assign log_view[gv*36    +: 16] = v_seq[gv];
            assign log_view[gv*36+16 +: 12] = v_bcd[gv];
            assign log_view[gv*36+28 +: 3]  = v_kind[gv];
            assign log_view[gv*36+31 +: 4]  = v_item[gv];
            assign log_view[gv*36+35]       = v_valid[gv];
        end
    endgenerate
    assign log_any_valid = |{v_valid[6],v_valid[5],v_valid[4],v_valid[3],
                             v_valid[2],v_valid[1],v_valid[0]};

    // ---------------- 发送器 ----------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_state   <= T_IDLE;
            char_index <= 5'd0;
            tx_start   <= 1'b0;
            tx_data    <= 8'd0;
            status_done<= 1'b0;
        end else begin
            tx_start <= 1'b0;
            status_done <= 1'b0;
            case (tx_state)
                T_IDLE: begin
                    if (status_req) begin
                        char_index <= 5'd0;
                        tx_state   <= T_LOAD;
                    end
                end
                T_LOAD: begin
                    if (!tx_busy) begin
                        tx_data  <= status_char(char_index);
                        tx_start <= 1'b1;
                        tx_state <= T_WAIT;
                    end
                end
                T_WAIT: begin
                    if (tx_busy && tx_start)
                        ;                                   // 等这一位真正开始
                    else if (!tx_busy && !tx_start) begin
                        if (char_index == STATUS_LAST) begin
                            tx_state <= T_IDLE;
                            status_done <= 1'b1;
                        end else begin
                            char_index <= char_index + 5'd1;
                            tx_state   <= T_LOAD;
                        end
                    end
                end
                default: tx_state <= T_IDLE;
            endcase
        end
    end

    // ---------------- 状态行 ----------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            frame_count <= {FB{1'b0}};
            status_req  <= 1'b0;
            status_wait <= 1'b0;
            b_q <= 3'd0; c_q <= 3'd0; v_q <= 3'd0;
            t_q <= 2'd0; i_q <= 2'd0; e_q <= 4'd0;
            count_q <= 3'd0; time_q <= 24'd0;
            auto_q <= 1'b0; sd_q <= 1'b0; wav_q <= 1'b0;
            health_q <= 4'd0; stage_q <= 4'd0;
        end else begin
            if (status_take)
                status_req <= 1'b0;
            if (status_done)
                status_wait <= 1'b0;

            if (!status_req && !status_wait) begin
                if (frame_start) begin
                    if (frame_count + 1'b1 >= FRAMES_PER_REPORT) begin
                        frame_count <= {FB{1'b0}};
                        b_q <= brightness; c_q <= contrast; v_q <= volume;
                        t_q <= transition; i_q <= image_index; e_q <= playlist_errors;
                        count_q <= image_count; time_q <= uptime_bcd;
                        auto_q <= auto_mode; sd_q <= tf_mounted; wav_q <= wav_ready;
                        health_q <= health; stage_q <= load_stage;
                        status_req  <= 1'b1;
                        status_wait <= 1'b1;
                    end else begin
                        frame_count <= frame_count + 1'b1;
                    end
                end
            end
        end
    end

    // ---------------- 日志快照（只供 OSD LOG 页） ----------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            snap_state      <= S_IDLE;
            base_slot       <= 4'd0;
            slot_idx        <= 4'd0;
            refresh_pending <= 1'b0;
            log_rd_start    <= 1'b0;
            log_rd_slot     <= 4'd0;
            div_sh          <= 32'd0;
            div_q           <= 32'd0;
            div_rem         <= 4'd0;
            div_count       <= 6'd0;
            div_digit       <= 2'd0;
            bcd_units       <= 4'd0;
            bcd_tens        <= 4'd0;
            bcd_hundreds    <= 4'd0;
            for (vi = 0; vi < LOG_ROWS; vi = vi + 1) begin
                v_seq[vi]   <= 16'd0;
                v_bcd[vi]   <= 12'd0;
                v_kind[vi]  <= 3'd0;
                v_item[vi]  <= 4'd0;
                v_valid[vi] <= 1'b0;
            end
        end else begin
            log_rd_start <= 1'b0;

            if (log_refresh && snap_state != S_IDLE)
                refresh_pending <= 1'b1;

            case (snap_state)
                S_IDLE: begin
                    if (log_refresh || refresh_pending) begin
                        refresh_pending <= 1'b0;
                        base_slot   <= log_newest_slot;
                        slot_idx    <= 4'd0;
                        snap_state  <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    log_rd_slot  <= base_slot - slot_idx;
                    log_rd_start <= 1'b1;
                    snap_state   <= S_RD;
                end

                S_RD: if (log_rd_done) begin
                    v_seq[slot_idx]  <= log_rd_data[63:48];
                    v_kind[slot_idx] <= log_rd_data[87:80];
                    v_item[slot_idx] <= log_rd_data[79:72];
                    v_valid[slot_idx]<= log_rd_valid;
                    div_sh    <= log_rd_data[47:16];
                    div_q     <= 32'd0;
                    div_rem   <= 4'd0;
                    div_count <= 6'd32;
                    div_digit <= 2'd0;
                    bcd_units <= 4'd0;
                    bcd_tens  <= 4'd0;
                    bcd_hundreds <= 4'd0;
                    if (log_rd_valid)
                        snap_state <= S_CONV;
                    else begin
                        v_bcd[slot_idx] <= 12'd0;
                        snap_state <= S_ROW;
                    end
                end

                S_CONV: begin
                    if (div_count != 6'd0) begin
                        div_rem   <= div_sub[3:0];
                        div_q     <= {div_q[30:0], div_ge10};
                        div_sh    <= {div_sh[30:0], 1'b0};
                        div_count <= div_count - 6'd1;
                    end else begin
                        case (div_digit)
                            2'd0: bcd_units <= div_rem;
                            2'd1: bcd_tens  <= div_rem;
                            default: bcd_hundreds <= div_rem;
                        endcase
                        if (div_digit == 2'd2) begin
                            v_bcd[slot_idx] <= {div_rem, bcd_tens, bcd_units};
                            snap_state <= S_ROW;
                        end else begin
                            div_digit <= div_digit + 2'd1;
                            div_sh    <= div_q;
                            div_q     <= 32'd0;
                            div_rem   <= 4'd0;
                            div_count <= 6'd32;
                        end
                    end
                end

                S_ROW: begin
                    if (slot_idx == LOG_ROWS-1) begin
                        snap_state <= S_IDLE;
                    end else begin
                        slot_idx   <= slot_idx + 4'd1;
                        snap_state <= S_ISSUE;
                    end
                end

                default: snap_state <= S_IDLE;
            endcase
        end
    end
endmodule

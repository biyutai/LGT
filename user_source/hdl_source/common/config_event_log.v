`timescale 1ns/1ps

// 播放证明 · 事件日志（B1：扫描 + 追加 + 单槽回读）
//
// 存储：一个事件占一个 4KB 扇区（slot 0..SLOTS-1，SLOTS 为 2 的幂），
// 地址 = LOG_BASE + slot*0x1000。这样可以直接复用 w25q64_record_store
// （它每次写都先擦扇区、且要求 4KB 对齐），不需要改参数日志那条链。
//
// 12 字节记录（MSB first）：
//   [95:88] marker = 8'h5a
//   [87:80] kind     0 上电 / 1 换条 / 2 加载失败 / 3 无卡 / 4 节目单错误
//   [79:72] item
//   [71:64] detail
//   [63:48] seq
//   [47:16] uptime_s
//   [15:0]  sum      前 10 个字节的 16 位字节和（≡ 面积：查表 CRC 要 1 块 BRAM + 57 LUT，
//                    事件是低频、写后还有 store 的回读校验，字节和足够抓"半条记录"；
//                    真正的参数记录仍然用 CRC-16）
//
// 不变量：序号来自 Flash 扫描；有效条目必须 marker+校验都过；事件只保留最新一条待写。
module config_event_log #(
    parameter integer CLK_DIV = 2,
    parameter integer SLOTS = 16,
    parameter integer POLL_INTERVAL_CYCLES = 5000,
    parameter [31:0] ERASE_TIMEOUT_CYCLES = 32'd250000000,
    parameter [31:0] PROGRAM_TIMEOUT_CYCLES = 32'd5000000,
    parameter [23:0] LOG_BASE = 24'h700000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        event_pulse,
    input  wire [2:0]  event_kind,
    input  wire [3:0]  event_item,
    input  wire [7:0]  event_detail,
    input  wire [31:0] uptime_s,
    output reg         busy,
    output reg         scan_done,
    output reg         append_done,
    output reg         error,
    output reg  [7:0]  error_code,
    output reg         newest_valid,
    output reg  [15:0] newest_seq,
    output reg  [3:0]  newest_slot,
    input  wire        rd_start,
    input  wire [3:0]  rd_slot,
    output reg         rd_done,
    output reg         rd_valid,
    output wire [95:0] rd_data,
    output wire        bus_req,
    input  wire        bus_grant,
    output wire        st_start,
    output wire        st_op_write,
    output wire [23:0] st_address,
    output wire [95:0] st_write_data,
    input  wire        st_busy,
    input  wire        st_done,
    input  wire        st_error,
    input  wire [3:0]  st_error_code,
    input  wire [95:0] st_read_data
);
    localparam [7:0] MARKER = 8'h5a;
    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_SCAN_RD  = 3'd1;
    localparam [2:0] ST_SCAN_END = 3'd2;
    localparam [2:0] ST_RD       = 3'd3;
    localparam [2:0] ST_WR       = 3'd4;

    reg [2:0]  state;
    reg        scanned, pending;
    reg [2:0]  pend_kind;
    reg [3:0]  pend_item;
    reg [7:0]  pend_detail;
    reg [31:0] pend_uptime;
    reg [3:0]  scan_slot, max_slot, target_slot, rd_slot_pend;
    reg [15:0] max_seq, new_seq;
    reg        found, rd_pend, bus_grant_q;
    reg [95:0] store_write_data;
    reg        store_start_r, store_op_write;
    reg [23:0] store_address;

    assign bus_req = !scanned || pending || rd_pend;
    assign rd_data = st_read_data;
    assign st_start      = store_start_r;
    assign st_op_write   = store_op_write;
    assign st_address    = store_address;
    assign st_write_data = store_write_data;
    wire grant_ok = bus_grant & bus_grant_q;

    // 10 字节 → 16 位字节和（组合，10 个 8 位加法器树）
    function [15:0] byte_sum;
        input [79:0] p;
        integer i;
        reg [15:0] s;
        begin
            s = 16'd0;
            for (i = 0; i < 10; i = i + 1)
                s = s + {8'd0,p[79 - i*8 -: 8]};
            byte_sum = s;
        end
    endfunction

    wire [15:0] read_sum  = byte_sum(st_read_data[95:16]);
    wire        read_good = (st_read_data[95:88] == MARKER) &&
                            (read_sum == st_read_data[15:0]);
    wire [15:0] seq_delta  = st_read_data[63:48] - max_seq;
    wire        read_newer = (st_read_data[63:48] != max_seq) && !seq_delta[15];
    wire [15:0] seq_next   = found ? (max_seq + 16'd1) : 16'd1;
    wire [15:0] write_sum = byte_sum({MARKER,{5'd0,pend_kind},{4'd0,pend_item},
                                      pend_detail,seq_next,pend_uptime});
    wire [95:0] write_word = {MARKER,{5'd0,pend_kind},{4'd0,pend_item},
                              pend_detail,seq_next,pend_uptime,write_sum};
    wire [3:0]  next_slot  = (scan_slot + 4'd1) & (SLOTS-1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=ST_IDLE; scanned<=1'b0; pending<=1'b0;
            pend_kind<=3'd0; pend_item<=4'd0; pend_detail<=8'd0; pend_uptime<=32'd0;
            scan_slot<=4'd0; max_slot<=4'd0; max_seq<=16'd0; found<=1'b0;
            target_slot<=4'd0; new_seq<=16'd0; rd_slot_pend<=4'd0;
            rd_pend<=1'b0; bus_grant_q<=1'b0;
            busy<=1'b0; scan_done<=1'b0; append_done<=1'b0;
            error<=1'b0; error_code<=8'd0;
            newest_valid<=1'b0; newest_seq<=16'd0;
            newest_slot<=4'd0;
            rd_done<=1'b0; rd_valid<=1'b0;
            store_write_data<=96'd0; store_start_r<=1'b0;
            store_op_write<=1'b0; store_address<=LOG_BASE;
        end else begin
            bus_grant_q   <= bus_grant;
            scan_done     <= 1'b0;
            append_done   <= 1'b0;
            rd_done       <= 1'b0;
            store_start_r <= 1'b0;

            if (event_pulse) begin
                pending     <= 1'b1;
                pend_kind   <= event_kind;
                pend_item   <= event_item;
                pend_detail <= event_detail;
                pend_uptime <= uptime_s;
            end
            if (rd_start) begin
                rd_pend      <= 1'b1;
                rd_slot_pend <= rd_slot;
            end

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (!scanned && grant_ok) begin
                        busy           <= 1'b1;
                        scan_slot      <= 4'd0;
                        found          <= 1'b0;
                        max_seq        <= 16'd0;
                        max_slot       <= 4'd0;
                        store_op_write <= 1'b0;
                        store_address  <= LOG_BASE;
                        store_start_r  <= 1'b1;
                        state          <= ST_SCAN_RD;
                    end else if (pending && grant_ok) begin
                        busy           <= 1'b1;
                        pending        <= 1'b0;
                        new_seq        <= seq_next;
                        target_slot    <= found ? ((max_slot + 4'd1) & (SLOTS-1)) : 4'd0;
                        store_write_data <= write_word;
                        store_op_write <= 1'b1;
                        store_address  <= LOG_BASE + {8'd0,(found ? ((max_slot + 4'd1) & (SLOTS-1)) : 4'd0),12'd0};
                        store_start_r  <= 1'b1;
                        state          <= ST_WR;
                    end else if (rd_pend && grant_ok) begin
                        busy           <= 1'b1;
                        rd_pend        <= 1'b0;
                        store_op_write <= 1'b0;
                        store_address  <= LOG_BASE + {8'd0,rd_slot_pend,12'd0};
                        store_start_r  <= 1'b1;
                        state          <= ST_RD;
                    end
                end

                ST_SCAN_RD: if (st_done) begin
                    if (st_error) begin
                        error      <= 1'b1;
                        error_code <= {4'h4,st_error_code};
                        busy       <= 1'b0;
                        scanned    <= 1'b1;
                        state      <= ST_IDLE;
                    end else begin
                        if (read_good && (!found || read_newer)) begin
                            max_seq  <= st_read_data[63:48];
                            max_slot <= scan_slot;
                            found    <= 1'b1;
                        end
                        if (scan_slot == SLOTS-1) begin
                            state <= ST_SCAN_END;
                        end else begin
                            scan_slot     <= next_slot;
                            store_address <= LOG_BASE + {8'd0,next_slot,12'd0};
                            store_start_r <= 1'b1;
                        end
                    end
                end
                ST_SCAN_END: begin
                    newest_valid <= found;
                    newest_seq   <= max_seq;
                    newest_slot  <= found ? max_slot : 4'd0;
                    scanned      <= 1'b1;
                    scan_done    <= 1'b1;
                    busy         <= 1'b0;
                    state        <= ST_IDLE;
                end

                ST_RD: if (st_done) begin
                    if (st_error) begin
                        error      <= 1'b1;
                        error_code <= {4'h5,st_error_code};
                        rd_valid   <= 1'b0;
                        rd_done    <= 1'b1;
                    end else begin
                        rd_valid <= read_good;
                        rd_done  <= 1'b1;
                    end
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end

                ST_WR: if (st_done) begin
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                    if (st_error) begin
                        error      <= 1'b1;
                        error_code <= {4'h6,st_error_code};
                    end else begin
                        append_done  <= 1'b1;
                        newest_valid <= 1'b1;
                        newest_seq   <= new_seq;
                        newest_slot  <= target_slot;
                        max_seq      <= new_seq;
                        max_slot     <= target_slot;
                        found        <= 1'b1;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

// 数字标牌节目单解析：把 PLAYLIST.TXT 的字节流解析成"节目表 + 字幕文本"。
//
// 每行格式：序号, 显示秒数, 转场, 字幕文本（字段前导空白忽略）
//   序号  1..7（消费侧再按实际图片数过滤）；0/8/9/多位记为越界，按第 7 张提交并计一次错误
//   秒数  0..99；0 = 跟随音频节拍，留空 = 8 秒（三位以上只取前两位）
//   转场  淡入/左揭示/右揭示/菱形溶解（也接受 0..3 的数字）；只看字段里第一个词，
//         未知值回落淡入并计入 error_count
//   字幕  该行第 3 个逗号之后的全部内容（含逗号），UTF-8 解码成 16 位码，
//         最多 SUBTITLE_WORDS 个，超出部分静默截断，不足的槽位补空格
//   '#' 开头的行、空行忽略；行尾与文件尾都会提交当前行；无序号或超出条数的行计入 error_count
//
// 字节流由调用方提供（读 PLAYLIST.TXT 的扇区数据），本模块只在启动时工作一次：
// start 后逐字节喂入，eof 表示文件结束，done 拉高表示解析完成。
`timescale 1ns / 1ps

module playlist_parse #(
    // 容量按"资源换能力"定：字幕表落块 RAM，加容量几乎不花 LUT（BRAM 还有 16 块富余）。
    // 单条字幕 24 → 32 字（跑马灯会把整句轮完）；节目条数上限仍是 8（entry_count 保持 4 位，
    // 不动与顶层/自检页的接口）。
    parameter integer MAX_ENTRIES     = 16,
    parameter integer SUBTITLE_WORDS  = 39,
    parameter [7:0]   DEFAULT_SECONDS = 8'd8
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,
    input  wire        eof,
    output reg  [4:0]  entry_count,
    output reg  [3:0]  error_count,
    output reg         present,
    output reg         done,
    // 读口：消费侧按需索引节目表与字幕（避免整表拉成大 mux，也让字幕表能落 eRAM）
    input  wire [3:0]  rd_entry,
    output wire [2:0]  rd_img_index,
    output wire [7:0]  rd_seconds,
    output wire [1:0]  rd_transition,
    input  wire [3:0]  rd_sub_entry,
    input  wire        rd_sub_lang,
    input  wire [5:0]  rd_sub_char,
    input  wire        rd_sub_clk,
    output wire [15:0] rd_sub_code
);
    reg [2:0]  img_index  [0:MAX_ENTRIES-1];
    reg [7:0]  seconds    [0:MAX_ENTRIES-1];
    reg [1:0]  transition [0:MAX_ENTRIES-1];
    // 字幕表：每条占 SUB_STRIDE 个字（24 字正文 + 补齐），地址直接用位拼接——写地址里
    // 一旦出现"序号*24"这种乘法，TD 就不再按 RAM 推断，只能综合成触发器 + 大 mux
    // （实测多花 3,084 个寄存器与 2,730 个 LUT）。初始化放 initial，不放异步复位分支。
    localparam integer SUB_STRIDE = 64;
    localparam integer SUB_ENTRIES = MAX_ENTRIES * 2;   // 每条两种语言
    reg [15:0] subtitle   [0:SUB_ENTRIES*SUB_STRIDE-1]; // synthesis ram_style = block
    reg        sub_we;
    reg [15:0] sub_wdata;
    reg [10:0] sub_waddr;
    reg [15:0] sub_rd_q;
    integer init_i;
    initial begin
        for (init_i = 0; init_i < SUB_ENTRIES * SUB_STRIDE; init_i = init_i + 1)
            subtitle[init_i] = 16'h0020;
    end
    assign rd_img_index  = img_index[rd_entry];
    assign rd_seconds    = seconds[rd_entry];
    assign rd_transition = transition[rd_entry];
    assign rd_sub_code   = sub_rd_q;

    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;

    reg [1:0]  state;
    reg [1:0]  field;                      // 0=序号 1=秒数 2=转场 3=字幕
    reg        bare_mode;                  // 本行是"只有字幕的条目"（TEXT.TXT 那种没有逗号的行）
    reg        skip_line;                  // 本行是注释
    reg        blank_line;                 // 本行还没有非空白字节
    reg        index_seen, index_over;     // 序号已见 / 序号越界
    reg [2:0]  cur_index;
    reg        sec_seen;
    reg [7:0]  cur_seconds;
    reg        trans_seen, trans_done;     // 转场已定 / 转场字段第一个词已解析完
    reg [1:0]  cur_transition;
    reg [5:0]  sub_pos;                    // 当前语言已写入的字数（比 32 宽 1 位）
    reg        cur_lang;                   // 0 = 第一种语言，1 = '|' 之后的第二种语言
    reg        sub_seen;                   // 字幕字段已出现非空白内容
    reg [15:0] sub_acc;                    // UTF-8 累积
    reg [1:0]  sub_need;                   // 还差几个 UTF-8 续字节

    // 本行能否提交：有待提交内容 + 有序号 + 未超条数
    // TEXT.TXT 的每行是纯词条（没有逗号）：行首第一个字节不是数字 ⇒ 整行按字幕处理。
    // 这样 TEXT.TXT 直接走同一套解析与字幕表，不需要第二块 RAM/第二个解析器；
    // 该字节当拍就按字幕落字（不会丢第一个字），之后本行的逗号也算字幕正文。
    wire byte_is_digit = (byte_data >= "0" && byte_data <= "9");
    wire bare_now   = bare_mode || (field == 2'd0 && !index_seen && !byte_is_digit);
    wire bare_line  = bare_now && !skip_line && !blank_line;
    wire [1:0] field_eff = bare_now ? 2'd3 : field;
    wire commit_ok = !skip_line && !blank_line && (index_seen || bare_now) &&
                     (entry_count != MAX_ENTRIES);

    // 转场关键字首字的 UTF-8 解码结果：淡 6de1 / 左 5de6 / 右 53f3 / 菱 83f1
    // 返回 {有效, 转场值}，未知值回落淡入（0）
    function [2:0] trans_sel;
        input [15:0] code;
        begin
            case (code)
                16'h6de1: trans_sel = {1'b1, 2'd0};
                16'h5de6: trans_sel = {1'b1, 2'd1};
                16'h53f3: trans_sel = {1'b1, 2'd2};
                16'h83f1: trans_sel = {1'b1, 2'd3};
                default:  trans_sel = 3'd0;
            endcase
        end
    endfunction

    wire [2:0] trans_now = trans_sel({sub_acc[9:0], byte_data[5:0]});

    task clear_line;
        begin
            field       <= 2'd0;
            bare_mode   <= 1'b0;
            skip_line   <= 1'b0;
            blank_line  <= 1'b1;
            index_seen  <= 1'b0;
            index_over  <= 1'b0;
            cur_index   <= 3'd1;
            sec_seen    <= 1'b0;
            cur_seconds <= DEFAULT_SECONDS;
            trans_seen  <= 1'b0;
            trans_done  <= 1'b0;
            cur_transition <= 2'd0;
            sub_pos     <= 6'd0;
            sub_seen    <= 1'b0;
            cur_lang    <= 1'b0;
            sub_acc     <= 16'd0;
            sub_need    <= 2'd0;
        end
    endtask

    task bump_error;
        begin
            if (error_count != 4'hf) error_count <= error_count + 4'd1;
        end
    endtask

    task commit_line;
        begin
            img_index[entry_count]  <= index_over ? 3'd7 : cur_index;
            seconds[entry_count]    <= sec_seen ? cur_seconds : DEFAULT_SECONDS;
            transition[entry_count] <= trans_seen ? cur_transition : 2'd0;
            entry_count             <= entry_count + 4'd1;
            present                 <= 1'b1;
        end
    endtask

    // 往本行字幕尾部追加一个 16 位码；满 SUBTITLE_WORDS 后静默截断
    task push_word;
        input [15:0] code;
        begin
            if (sub_pos < SUBTITLE_WORDS) begin
                sub_we    <= 1'b1;
                sub_wdata <= code;
                sub_waddr <= {entry_count[3:0], cur_lang, sub_pos[5:0]};
                sub_pos   <= sub_pos + 6'd1;
            end
        end
    endtask

    // 行尾/文件尾收口：能提交就提交（序号越界额外计一次错误），否则整行计一次错误
    task finish_line;
        begin
            if (!skip_line && !blank_line) begin
                if (commit_ok) begin
                    commit_line;
                    if (index_over) bump_error;
                end else begin
                    bump_error;
                end
            end
            clear_line;
        end
    endtask

    integer i;
    // 经典单时钟"寄存器写 + 寄存器读"模板：TD 才肯按块 RAM 推断
    // （组合读会退化成触发器 + 大 mux，实测多花 3,084 个寄存器与 2,730 个 LUT）
    always @(posedge clk) begin
        if (sub_we)
            subtitle[sub_waddr] <= sub_wdata;
    end
    always @(posedge rd_sub_clk)
        sub_rd_q <= subtitle[{rd_sub_entry, rd_sub_lang, rd_sub_char}];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= S_IDLE;
            entry_count <= 4'd0;
            error_count <= 4'd0;
            present     <= 1'b0;
            done        <= 1'b0;
            clear_line;
            for (i = 0; i < MAX_ENTRIES; i = i + 1) begin
                img_index[i]  <= 3'd1;
                seconds[i]    <= DEFAULT_SECONDS;
                transition[i] <= 2'd0;
            end
        end else if (state == S_IDLE) begin
            if (start) begin
                state <= S_RUN;
                clear_line;
            end
        end else if (state == S_RUN) begin
            sub_we <= 1'b0;                                     // 字幕表写使能：只在 push_word 那一拍拉高
            // 只在真正收到字节那一拍判定：行间空闲拍 byte_data 还停在换行符上，会把 bare_mode 误拉高
            if (byte_valid) bare_mode <= bare_now;
            if (byte_valid && (byte_data == 8'h0a || byte_data == 8'h0d)) begin
                finish_line;                                    // 行尾
            end else if (byte_valid) begin
                // skip_line 为 1 时下面所有分支都不成立，等效于"注释行吃到行尾"
                if (!skip_line && (byte_data == 8'h20 || byte_data == 8'h09)) begin
                    // 空白：字段前导空白自然跳过，只有字幕字段内部的空格要落字
                    if (field_eff == 2'd3 && sub_seen && sub_need == 2'd0) push_word(16'h0020);
                end else if (!skip_line && byte_data == 8'h2c && field_eff != 2'd3) begin
                    // 逗号：进下一个字段（第 3 个逗号之后的逗号属于字幕正文）
                    field    <= field + 2'd1;
                    sub_need <= 2'd0;
                end else if (!skip_line && blank_line && byte_data == 8'h23) begin
                    skip_line <= 1'b1;                          // '#' 开头为注释
                end else if (!skip_line) begin
                    blank_line <= 1'b0;
                    case (field_eff)
                    2'd0: begin                                 // 序号
                        if (byte_data >= "0" && byte_data <= "9") begin
                            if (!index_seen && byte_data != "0") begin
                                index_seen <= 1'b1;
                                cur_index  <= byte_data - 8'd48;
                            end else begin
                                index_seen <= 1'b1;             // 0/多位：越界，按第 7 张提交
                                index_over <= 1'b1;
                                cur_index  <= 3'd7;
                            end
                        end
                    end
                    2'd1: begin                                 // 秒数
                        if (byte_data >= "0" && byte_data <= "9") begin
                            if (!sec_seen) begin
                                sec_seen    <= 1'b1;
                                cur_seconds <= byte_data - 8'd48;
                            end else if (cur_seconds < 8'd10) begin
                                // ×10 用移位加法（TD 对 "reg*const" 会占一个 DSP）
                                cur_seconds <= ({cur_seconds, 3'b000} + {cur_seconds, 1'b0}) +
                                               (byte_data - 8'd48);
                            end
                        end
                    end
                    2'd2: begin                                 // 转场：只看第一个词
                        if (sub_need != 2'd0) begin
                            sub_acc  <= {sub_acc[9:0], byte_data[5:0]};
                            sub_need <= sub_need - 2'd1;
                            if (sub_need == 2'd1) begin         // 本拍拼完一个汉字
                                trans_done <= 1'b1;
                                if (trans_now[2]) begin
                                    trans_seen     <= 1'b1;
                                    cur_transition <= trans_now[1:0];
                                end else begin
                                    bump_error;                 // 未知转场：回落淡入
                                end
                            end
                        end else if (!trans_done) begin
                            if (byte_data >= "0" && byte_data <= "9") begin
                                trans_done <= 1'b1;
                                if (byte_data <= "3") begin
                                    trans_seen     <= 1'b1;
                                    cur_transition <= byte_data[1:0];
                                end else begin
                                    bump_error;
                                end
                            end else if (byte_data >= 8'he0) begin
                                sub_acc  <= {12'd0, byte_data[3:0]};
                                sub_need <= 2'd2;
                            end else if (byte_data >= 8'hc0) begin
                                sub_acc  <= {11'd0, byte_data[4:0]};
                                sub_need <= 2'd1;
                            end else begin
                                trans_done <= 1'b1;
                                bump_error;
                            end
                        end
                    end
                    default: begin                              // 字幕
                        if (byte_data == 8'h7c) begin           // '|'：切换第二种语言
                            cur_lang <= 1'b1;
                            sub_pos  <= 6'd0;
                            sub_seen <= 1'b1;
                        end else if (sub_need != 2'd0) begin
                            sub_acc  <= {sub_acc[9:0], byte_data[5:0]};
                            sub_need <= sub_need - 2'd1;
                            if (sub_need == 2'd1)
                                push_word({sub_acc[9:0], byte_data[5:0]});
                        end else if (byte_data < 8'h80) begin
                            sub_seen <= 1'b1;
                            // 字体只有大写：所有 ASCII 小写统一转大写（中英双语都可能用）
                            push_word({8'd0, (byte_data >= "a" && byte_data <= "z") ?
                                              (byte_data - 8'd32) : byte_data});
                        end else if (byte_data >= 8'he0) begin
                            sub_seen <= 1'b1;
                            sub_acc  <= {12'd0, byte_data[3:0]};
                            sub_need <= 2'd2;
                        end else if (byte_data >= 8'hc0) begin
                            sub_seen <= 1'b1;
                            sub_acc  <= {11'd0, byte_data[4:0]};
                            sub_need <= 2'd1;
                        end
                    end
                    endcase
                end
            end else if (eof) begin
                finish_line;                                    // 文件尾：末行没有换行也要提交
                state <= S_DONE;
                done  <= 1'b1;
                if (!commit_ok) present <= (entry_count != 4'd0);
            end
        end
    end
endmodule

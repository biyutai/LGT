// playlist_parse：节目单解析的行为验证
//   覆盖：正常条目 / 注释与空行 / 缺字段用默认 / 未知转场回落并计数 / 超长字幕截断
// 运行：sim/run.sh tb_playlist
`timescale 1ns / 1ps

module tb_playlist;
localparam integer MAXE = 16, SUBW = 39;

reg clk = 0, rst = 1, start = 0, byte_valid = 0, eof = 0;
reg [7:0] byte_data = 8'd0;
wire [4:0] entry_count;
wire [3:0] error_count;
wire present, done;
reg  [3:0] rd_entry = 4'd0, rd_sub_entry = 4'd0;
reg        rd_sub_lang = 1'b0;
reg  [5:0] rd_sub_char = 6'd0;
wire [2:0] rd_img_index;
wire [7:0] rd_seconds;
wire [1:0] rd_transition;
wire [15:0] rd_sub_code;

always #5 clk = ~clk;

playlist_parse #(.MAX_ENTRIES(MAXE), .SUBTITLE_WORDS(SUBW)) dut (
    .clk(clk), .rst(rst), .start(start), .byte_valid(byte_valid), .byte_data(byte_data),
    .eof(eof), .entry_count(entry_count), .error_count(error_count),
    .present(present), .done(done),
    .rd_entry(rd_entry), .rd_img_index(rd_img_index), .rd_seconds(rd_seconds),
    .rd_transition(rd_transition), .rd_sub_entry(rd_sub_entry),
    .rd_sub_lang(rd_sub_lang),
    .rd_sub_char(rd_sub_char), .rd_sub_clk(clk), .rd_sub_code(rd_sub_code)
);

// 通过读口取一条节目的某个字段（组合读，等一个 negedge 让值稳定）
task get_entry(input [3:0] e, output [2:0] img, output [7:0] sec, output [1:0] tr);
    begin @(negedge clk); rd_entry = e; @(negedge clk); img = rd_img_index; sec = rd_seconds; tr = rd_transition; end
endtask

task get_sub(input [3:0] e, input [5:0] c, output [15:0] code);
    begin @(negedge clk); rd_sub_entry = e; rd_sub_char = c; @(negedge clk); code = rd_sub_code; end
endtask

integer errors = 0;
task check(input cond, input [8*72-1:0] msg);
    begin
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s  (t=%0t)", msg, $time); errors = errors + 1; end
    end
endtask

// 送一个字节
task send(input [7:0] b);
    begin
        @(negedge clk); byte_data = b; byte_valid = 1'b1;
        @(posedge clk); @(negedge clk); byte_valid = 1'b0;
    end
endtask

// 送一段 ASCII（字符串在向量里右对齐，逐字节从左到右发；0 字节视为结束）
task send_ascii(input [8*64-1:0] s);
    integer i;
    reg [7:0] c;
    begin
        for (i = 8*64-1; i >= 0; i = i - 1) begin
            c = s[i*8 +: 8];
            if (c != 8'd0) send(c);
        end
    end
endtask

// 送一个汉字（写死的常用字 UTF-8：淡 E6 B7 A1、左 E5 B7 A6、右 E5 8F B3、菱 E8 8F B1）
task send_han(input [7:0] b2, input [7:0] b3, input [7:0] b4);
    begin send(8'he0 | (b2 >> 4)); send(8'h80 | ((b2 & 8'h0f) << 2) | (b3 >> 6)); send(8'h80 | (b3 & 8'h3f)); send(8'h80 | (b4 & 8'h3f)); end
endtask

integer k;
initial begin
    $display("== playlist_parse：节目单解析");
    repeat (4) @(posedge clk);
    rst = 1'b0;
    @(negedge clk); start = 1'b1; @(posedge clk); @(negedge clk); start = 1'b0;

    // 第 1 行：注释；第 2 行：空行
    send_ascii("# 这是注释");
    send(8'h0a);
    send(8'h0a);
    // 第 3 行：正常条目 1, 8, 淡入, Hi
    send_ascii("1, 8, ");
    send(8'he6); send(8'hb7); send(8'ha1);      // 淡（UTF-8）
    send(8'he5); send(8'h85); send(8'ha5);      // 入（UTF-8）
    send_ascii(", Hi");
    send(8'h0a);
    // 第 4 行：缺秒数（应为默认 8）+ 未知转场（应为淡入且 error+1）+ 超长字幕
    send_ascii("2, , X, ");
    for (k = 0; k < 42; k = k + 1) send("A");
    send(8'h0a);
    // 第 5 行：秒数 0（跟节拍）与数字转场
    send_ascii("3, 0, 2, OK");
    send(8'h0a);
    @(negedge clk); eof = 1'b1; @(posedge clk); @(negedge clk); eof = 1'b0;
    repeat (4) @(posedge clk);

    // 先把实际解析结果用十六进制打出来（中文日志会乱码，数字不会），便于定位解析错误
    begin : hex_dump
        integer e, c;
        $display("DUMP: done=%0d present=%0d entry_count=%0d error_count=%0d",
                 done, present, entry_count, error_count);
        for (e = 0; e < MAXE; e = e + 1) begin
            @(negedge clk); rd_entry = e[3:0]; @(negedge clk);
            $display("DUMP: entry[%0d] img=%0d sec=%0d tr=%0d",
                     e, rd_img_index, rd_seconds, rd_transition);
        end
        for (e = 0; e < 3; e = e + 1) begin
            $write("DUMP: sub[%0d] =", e);
            for (c = 0; c < SUBW; c = c + 1) begin
                @(negedge clk); rd_sub_entry = e[3:0]; rd_sub_char = c[5:0]; @(negedge clk);
                $write(" %04h", rd_sub_code);
            end
            $write("\n");
        end
    end

    begin : field_checks
        reg [2:0] i0, i1, i2;
        reg [7:0] s0, s1, s2;
        reg [1:0] t0, t1, t2;
        reg [15:0] c;
        check(done && present, "解析完成 done 且 present");
        check(entry_count == 4'd3, "解析出 3 条节目（注释/空行被忽略）");
        get_entry(3'd0, i0, s0, t0);
        get_entry(3'd1, i1, s1, t1);
        get_entry(3'd2, i2, s2, t2);
        check(i0 == 3'd1 && i1 == 3'd2 && i2 == 3'd3, "三条的图片序号 1/2/3");
        check(s0 == 8'd8 && s1 == 8'd8 && s2 == 8'd0, "秒数 8 / 缺省 8 / 0（跟节拍）");
        check(t0 == 2'd0 && t1 == 2'd0 && t2 == 2'd2, "转场 淡入 / 未知回落淡入 / 数字 2 = 右揭示");
        check(error_count == 4'd1, "未知转场记一次错误");
        get_sub(3'd0, 5'd0, c); check(c == 16'h0048, "第 1 条字幕首字 H");
        get_sub(3'd2, 5'd0, c); check(c == 16'h004f, "第 3 条字幕首字 O");
    end
    begin : truncation
        integer kk;
        integer nz;
        reg [15:0] cc;
        nz = 0;
        for (kk = 0; kk < SUBW; kk = kk + 1) begin
            get_sub(3'd1, kk, cc);
            if (cc != 16'h0020) nz = nz + 1;
        end
        check(nz == SUBW, "超长字幕按 32 字截断（一行写满）");
    end

    // 双语字幕：'|' 之前的进 lang0，之后进 lang1，ASCII 小写转大写
    begin : bilingual
        reg [15:0] cc;
        rst = 1'b1; repeat (3) @(posedge clk); rst = 1'b0;
        @(negedge clk); start = 1'b1; @(posedge clk); @(negedge clk); start = 1'b0;
        send_ascii("1, 8, 0, cn|en");
        send(8'h0a);
        @(negedge clk); eof = 1'b1; @(posedge clk); @(negedge clk); eof = 1'b0;
        repeat (4) @(posedge clk);
        rd_sub_lang = 1'b0; get_sub(4'd0, 5'd0, cc);
        check(cc == 16'h0043, "双语 lang0 首字 C");
        rd_sub_lang = 1'b1; get_sub(4'd0, 5'd0, cc);
        check(cc == 16'h0045, "双语 lang1 首字 E（小写转大写）");
        rd_sub_lang = 1'b0;
    end

    // 复位后喂一个空文件：present 应为 0
    rst = 1'b1; repeat (3) @(posedge clk); rst = 1'b0;
    @(negedge clk); start = 1'b1; @(posedge clk); @(negedge clk); start = 1'b0;
    @(negedge clk); eof = 1'b1; @(posedge clk); @(negedge clk); eof = 1'b0;
    repeat (4) @(posedge clk);
    check(!present && entry_count == 4'd0 && error_count == 4'd0, "空文件 → present=0、无错误");

    // 只有字幕的行（TEXT.TXT 的样子）：整行当字幕，序号/秒数/转场取默认，且不算错误
    begin : bare_lines
        reg [15:0] cc;
        reg [2:0]  ii;
        reg [7:0]  ss;
        reg [1:0]  tt;
        rst = 1'b1; repeat (3) @(posedge clk); rst = 1'b0;
        @(negedge clk); start = 1'b1; @(posedge clk); @(negedge clk); start = 1'b0;
        send_ascii("Hi"); send(8'h0a);
        send(8'he6); send(8'hb7); send(8'ha1); send(8'h0a);     // 淡
        @(negedge clk); eof = 1'b1; @(posedge clk); @(negedge clk); eof = 1'b0;
        repeat (4) @(posedge clk);
        check(done && present && entry_count == 4'd2 && error_count == 4'd0,
              "纯字幕行 → 2 条、无错误");
        get_sub(3'd0, 5'd0, cc); check(cc == 16'h0048, "纯字幕行 1 首字 H");
        get_sub(3'd1, 5'd0, cc); check(cc == 16'h6de1, "纯字幕行 2 首字 淡");
        get_entry(3'd0, ii, ss, tt);
        check(ii == 3'd1 && ss == 8'd8 && tt == 2'd0, "纯字幕行取默认序号/秒数/转场");
    end

    if (errors == 0) $display("ALL PASSED: playlist parse");
    else $fatal(1, "playlist parse failures: %0d", errors);
    $finish;
end
endmodule

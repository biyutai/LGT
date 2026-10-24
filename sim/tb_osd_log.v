`timescale 1ns/1ps

// 播放证明 LOG 页像素级验证：标题/表头/7 行数据/无事件提示，逐点阵比对。
module tb_osd_log;
localparam PHOTO = 24'hffffff;

reg clk = 1'b0;
reg rst = 1'b1, frame_start = 1'b0, de = 1'b1;
reg [11:0] x = 12'd0, y = 12'd0;
reg [23:0] rgb_in = PHOTO;
reg log_page = 1'b1;
reg [251:0] log_view = 252'd0;
reg log_any_valid = 1'b1;
reg subtitle_enable = 1'b0;
reg playlist_subtitle = 1'b0;
wire [23:0] rgb_out;
wire [5:0] playlist_sub_char;

always #5 clk = ~clk;

video_osd_overlay dut (
    .clk(clk), .rst(rst), .frame_start(frame_start), .de(de), .x(x), .y(y), .rgb_in(rgb_in),
    .subtitle_enable(subtitle_enable), .status_enable(1'b0), .alpha(2'd3),
    .info_page(1'b0), .cover_active(1'b0),
    .selfcheck_page(1'b0), .selfcheck_ok(7'h7f), .img_found(3'd4),
    .playlist_entries(5'd4), .playlist_errors(4'd0),
    .log_page(log_page), .log_view(log_view), .log_any_valid(log_any_valid),
    .guide_page(1'b0), .av_err_01ms(10'd0),
    .image_index(2'd0), .browse_mode(1'b0), .browse_index(2'd0), .browse_scale_mode(2'd0),
    .auto_enabled(1'b0), .demo_mode(1'b0),
    .brightness_level(3'd2), .contrast_level(3'd2), .volume_level(3'd4), .edit_mode(3'd0),
    .transition_kind(2'd0), .scale_mode(2'd0), .source_large_1024(1'b0),
    .standby_mode(1'b0), .timestamp(24'h000000),
    .effect_level(4'd0), .audio_effect_level(3'd0), .health(4'd0), .fps(8'd60),
    .load_seconds(8'd0), .cache_hits(8'd0), .underrun_count(8'd0), .diag_view(1'b0),
    .playlist_subtitle(playlist_subtitle), .playlist_sub_code(16'h64ad), .playlist_sub_char(playlist_sub_char),
    .playlist_sub_lang(),
    .rgb_out(rgb_out)
);

task set_entry;
    input integer r;
    input [15:0] seq;
    input [11:0] bcd;
    input [2:0]  kind;
    input [3:0]  item;
    input        valid;
    begin
        log_view[r*36    +: 16] = seq;
        log_view[r*36+16 +: 12] = bcd;
        log_view[r*36+28 +: 3]  = kind;
        log_view[r*36+31 +: 4]  = item;
        log_view[r*36+35]       = valid;
    end
endtask

reg [23:0] captured;
task sample;
    input [11:0] sx, sy;
    begin
        @(negedge clk); x = sx; y = sy; @(negedge clk); @(posedge clk); #1;
        captured = rgb_out;
    end
endtask

task frames;
    input integer n;
    integer i;
    begin
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk); frame_start = 1'b1;
            @(negedge clk); frame_start = 1'b0;
        end
    end
endtask

integer col;
task check_glyph;
    input integer cell_x, cell_y;
    input [15:0] code;
    integer hits;
    begin
        sample(cell_x + 16, cell_y);
        if (dut.glyph_code !== code || dut.status_glyph_index(code) == 8'd0)
            $fatal(1, "wrong glyph x=%0d y=%0d got=%h want=%h",
                   cell_x, cell_y, dut.glyph_code, code);
        hits = 0;
        for (col = 0; col < 32; col = col + 1) begin
            sample(cell_x + col, cell_y);
            if (captured == 24'h17464c) hits = hits + 1;
        end
        if (hits < 2)
            $fatal(1, "glyph strokes x=%0d y=%0d hits=%0d code=%h idx=%0d row=%0d bits=%h",
                   cell_x, cell_y, hits, dut.glyph_code, dut.glyph_index_d,
                   dut.glyph_row_sel_q, dut.glyph_bits);
    end
endtask

// A loaded playlist must never paint subtitle strokes below the seventh log row,
// including when the user has switched subtitles off.
task check_blank_footer;
    integer px, py;
    reg [23:0] expected;
    begin
        for (py = 408; py < 480; py = py + 1)
            for (px = 4; px < 640; px = px + 1) begin
                sample(px, py);
                expected = py < 456 ? 24'hf3f7f6 : dut.product_page_bg(px, py);
                if (captured !== expected)
                    $fatal(1, "playlist leaked into log footer x=%0d y=%0d subtitles=%b rgb=%h expected=%h",
                           px, py, subtitle_enable, captured, expected);
            end
    end
endtask

integer i;
initial begin
    // 7 行快照：第 0 行最新；第 2 行无效
    set_entry(0, 16'h1234, 12'h123, 3'd0, 4'd0, 1'b1);
    set_entry(1, 16'h00AB, 12'h007, 3'd1, 4'd1, 1'b1);
    set_entry(2, 16'h00AC, 12'h000, 3'd3, 4'd2, 1'b0);
    set_entry(3, 16'h00AD, 12'h999, 3'd2, 4'd4, 1'b1);
    set_entry(4, 16'h00AE, 12'h010, 3'd3, 4'd3, 1'b1);
    set_entry(5, 16'h00AF, 12'h020, 3'd0, 4'd0, 1'b1);
    set_entry(6, 16'h00B0, 12'h030, 3'd4, 4'd7, 1'b1);

    repeat (3) @(negedge clk); rst = 1'b0;
    frames(2);

    // The judge-facing page needs a visible Chinese title and event meaning.
    sample(96, 52);
    if (dut.glyph_code !== 16'h64ad ||
        dut.status_glyph_index(dut.glyph_code) == 8'd0)
        $fatal(1, "playback log title is not rendered in Chinese");
    sample(256, 152);
    if (dut.glyph_code !== 16'h8bbe)
        $fatal(1, "boot event has no readable Chinese label: %h", dut.glyph_code);

    // 1) Neutral page and brand accent.
    sample(400, 300);
    if (captured !== 24'hf3f7f6) $fatal(1, "page background=%h", captured);
    sample(1, 100);
    if (captured !== 24'h00a9be) $fatal(1, "brand bar=%h", captured);

    // 2) Human-readable heading, column names, uptime and event labels.
    check_glyph(96,  52, 16'h64ad); // 播
    check_glyph(128, 52, 16'h653e); // 放
    check_glyph(160, 52, 16'h8bb0); // 记
    check_glyph(192, 52, 16'h5f55); // 录
    check_glyph(96, 104, 16'h65f6); // 时
    check_glyph(256,104, 16'h4e8b); // 事
    check_glyph(96, 152, 16'h0031);
    check_glyph(192,152, 16'h79d2); // 秒
    check_glyph(256,152, 16'h8bbe); // 设
    check_glyph(352,152, 16'h52a8); // 动
    check_glyph(256,192, 16'h56fe); // 图
    check_glyph(480,192, 16'h0032); // 图2, item is one-based
    check_glyph(256,272, 16'h8bfb); // 读取失败
    check_glyph(256,312, 16'h5361); // 卡片移除
    check_glyph(256,392, 16'h8282); // 节目错误（第 7 行，页面最后一行）
    // 第 8 行位置不再渲染
    sample(256, 432);
    if (dut.glyph_code !== 16'h0020)
        $fatal(1, "row 8 must stay blank, got %h", dut.glyph_code);

    playlist_subtitle = 1'b1;
    for (i = 0; i < 2; i = i + 1) begin
        subtitle_enable = (i != 0);
        frames(1);
        check_glyph(256, 392, 16'h8282); // Keep the final valid record visible.
        check_blank_footer;
    end
    playlist_subtitle = 1'b0;
    subtitle_enable = 1'b0;

    // 3) Empty log uses a clear Chinese message.
    log_any_valid = 1'b0;
    frames(1);
    check_glyph(96, 152, 16'h6682); // 暂
    check_glyph(160,152, 16'h64ad); // 播

    // 9) 关掉 LOG 页：整屏保持输入像素
    log_page = 1'b0;
    frames(1);
    sample(200, 100);
    if (captured !== PHOTO) $fatal(1, "page off=%h", captured);

    $display("ALL PASSED: OSD playback-proof LOG page");
    $finish;
end
initial begin
    #5_000_000;
    $fatal(1, "osd log timeout");
end
endmodule

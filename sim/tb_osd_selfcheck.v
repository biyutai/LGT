`timescale 1ns/1ps

// 开机自检页：静态标签（页面 ROM）+ 健康点（绿/红）+ 计数（图片 n/4、节目单 n/错误 mm）
module tb_osd_selfcheck;
localparam PHOTO = 24'hffffff;

reg clk = 1'b0;
reg rst = 1'b1, frame_start = 1'b0, de = 1'b1;
reg [11:0] x = 12'd0, y = 12'd0;
reg [23:0] rgb_in = PHOTO;
reg selfcheck = 1'b1;
reg [6:0] ok = 7'h7f;
reg [2:0] img_found = 3'd4;
reg [4:0] entries = 5'd4;
reg [3:0] errors = 4'd7;
wire [23:0] rgb_out;
wire [5:0]  playlist_sub_char;

always #5 clk = ~clk;

video_osd_overlay dut (
    .clk(clk), .rst(rst), .frame_start(frame_start), .de(de), .x(x), .y(y), .rgb_in(rgb_in),
    .subtitle_enable(1'b0), .status_enable(1'b0), .alpha(2'd3),
    .info_page(1'b0), .cover_active(1'b0),
    .selfcheck_page(selfcheck), .selfcheck_ok(ok), .img_found(img_found),
    .playlist_entries(entries), .playlist_errors(errors),
    .playlist_sub_lang(),
    .log_page(1'b0), .log_view(252'd0), .log_any_valid(1'b0),
    .guide_page(1'b0), .av_err_01ms(10'd0),
    .image_index(2'd0), .browse_mode(1'b0), .browse_index(2'd0), .browse_scale_mode(2'd0),
    .auto_enabled(1'b0), .demo_mode(1'b0),
    .brightness_level(3'd2), .contrast_level(3'd2), .volume_level(3'd4), .edit_mode(3'd0),
    .transition_kind(2'd0), .scale_mode(2'd0), .source_large_1024(1'b0),
    .standby_mode(1'b0), .timestamp(24'h000000),
    .effect_level(4'd0), .audio_effect_level(3'd0), .health(4'd0), .fps(8'd60),
    .load_seconds(8'd0), .cache_hits(8'd0), .underrun_count(8'd0), .diag_view(1'b0),
    .playlist_subtitle(1'b0), .playlist_sub_code(16'd0), .playlist_sub_char(playlist_sub_char),
    .rgb_out(rgb_out)
);

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

// 取一个字模格：期望点阵用 RTL 自己的字库 ROM 反查（和别处的 tb 一个做法），逐位比对
reg [15:0] cell_bits;
integer col;
task check_cell;
    input integer cell_x, cell_y;
    input [15:0] code;
    reg [7:0] idx;
    begin
        idx = dut.status_glyph_index(code);
        cell_bits = dut.status_font_rom[{idx, cell_y[3:0]}];
        cell_bits = cell_bits | (cell_bits >> 1);
        for (col = 0; col < 16; col = col + 1) begin
            sample(cell_x + col, cell_y);
            if (captured !== (cell_bits[15-col] ? 24'h17464c :
                                               dut.product_page_bg(cell_x+col,cell_y)))
                $fatal(1, "cell x=%0d y=%0d col=%0d got=%h want=%h",
                       cell_x, cell_y, col, captured,
                       cell_bits[15-col] ? 24'h17464c :
                                           dut.product_page_bg(cell_x+col,cell_y));
        end
    end
endtask

integer i, hits, row;
initial begin
    repeat (3) @(negedge clk); rst = 1'b0;
    frames(2);

    // 1) 页底与左侧品牌条
    sample(200, 100);
    if (captured !== 24'he3edf9) $fatal(1, "page background=%h", captured);
    sample(1, 100);
    if (captured !== 24'h00a9be) $fatal(1, "brand bar=%h", captured);
    sample(40, 10);
    if (captured !== 24'h00a9be) $fatal(1,"self-check top teal band=%h",captured);
    sample(200, 10);
    if (captured !== 24'h51a77b) $fatal(1,"self-check top green band=%h",captured);
    hits=0;
    for (i=544;i<592;i=i+1) begin
        sample(i,48);
        if (captured==24'h008a9b || captured==24'h238b62 || captured==24'hc36246)
            hits=hits+1;
    end
    if (hits<3) $fatal(1,"self-check logo missing");

    // 2) The title and seven checks occupy the height of the screen.
    sample(8, 96);
    if (captured !== 24'hdcf5f1) $fatal(1,"self-check row gap missing");
    for (row=0;row<8;row=row+1) begin
        hits=0;
        for (i=8;i<200;i=i+1) begin
            sample(i,72+48*row);
            if (captured===24'h17464c) hits=hits+1;
        end
        if (hits<4) $fatal(1,"self-check row %0d invisible",row);
    end
    // The TF mount label is the first check row.
    hits = 0;
    for (i = 0; i < 128; i = i + 1) begin
        sample(8 + i, 120);
        if (captured === 24'h17464c) hits = hits + 1;
    end
    if (hits < 5) $fatal(1, "label glyphs=%0d", hits);

    // 3) 全绿时第 2 行的健康点是绿色
    sample(240, 116);
    if (captured !== 24'h2ee06a) $fatal(1, "dot green=%h", captured);
    // 4) 把 TF 卡那一项置失败：同一个点变红
    ok = 7'b1111110;
    frames(1);
    sample(240, 116);
    if (captured !== 24'he0483c) $fatal(1, "dot red=%h", captured);
    ok = 7'h7f;
    frames(1);

    // 5/6) 计数：直接用 RTL 自己的字库 ROM 反查期望点阵，逐位比对
    sample(264,120);
    if (captured !== 24'he3edf9) $fatal(1,"TF mount row must not show image count");
    check_cell(264, 168, 16'h0034);
    check_cell(280, 168, 16'h002f);
    check_cell(296, 168, 16'h0034);
    check_cell(296, 408, 16'h0030);
    check_cell(312, 408, 16'h0037);

    // 7) 关掉自检页：整屏不画（保持输入像素）
    selfcheck = 1'b0;
    frames(1);
    sample(200, 100);
    if (captured !== PHOTO) $fatal(1, "page off=%h", captured);

    $display("ALL PASSED: OSD self-check page");
    $finish;
end
endmodule

`timescale 1ns/1ps

// C 段像素级验证：无内容引导页 + 坏图运营提示（IMG3 ERR SKIP）。
module tb_osd_guide;
localparam PHOTO = 24'hffffff;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst = 1'b1, frame_start = 1'b0, de = 1'b1;
reg [11:0] x = 12'd0, y = 12'd0;
reg [23:0] rgb_in = PHOTO;
reg guide_page = 1'b0;
wire [23:0] rgb_out;
wire [4:0] playlist_sub_char;

video_osd_overlay dut (
    .clk(clk), .rst(rst), .frame_start(frame_start), .de(de), .x(x), .y(y), .rgb_in(rgb_in),
    .subtitle_enable(1'b0), .status_enable(1'b0), .alpha(2'd3),
    .info_page(1'b0), .cover_active(1'b0),
    .selfcheck_page(1'b0), .selfcheck_ok(7'h7f), .img_found(3'd0),
    .playlist_entries(5'd0), .playlist_errors(4'd0),
    .log_page(1'b0), .log_view(252'd0), .log_any_valid(1'b0),
    .guide_page(guide_page), .av_err_01ms(10'd0),
    .image_index(2'd0), .browse_mode(1'b0), .browse_index(2'd0), .browse_scale_mode(2'd0),
    .auto_enabled(1'b0), .demo_mode(1'b0),
    .brightness_level(3'd2), .contrast_level(3'd2), .volume_level(3'd4), .edit_mode(3'd0),
    .transition_kind(2'd0), .scale_mode(2'd0), .source_large_1024(1'b0),
    .standby_mode(1'b0), .timestamp(24'h000000),
    .effect_level(4'd0), .audio_effect_level(3'd0), .health(4'd0), .fps(8'd60),
    .load_seconds(8'd0), .cache_hits(8'd0), .underrun_count(8'd0), .diag_view(1'b0),
    .playlist_subtitle(1'b0), .playlist_sub_code(16'd0), .playlist_sub_char(playlist_sub_char),
    .playlist_sub_lang(),
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

reg [15:0] cell_bits;
integer col;
task check_cell;
    input integer cell_x, cell_y;
    input [15:0] code;
    reg [7:0] idx;
    begin
        idx = dut.status_glyph_index(code);
        cell_bits = dut.status_font_rom[{idx, cell_y[3:0] - 4'd8}];
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

initial begin
    repeat (3) @(negedge clk); rst = 1'b0;
    guide_page = 1'b1;
    frames(2);

    sample(400, 300);
    if (captured !== 24'hfff0d4) $fatal(1, "guide background=%h", captured);
    sample(1, 100);
    if (captured !== 24'h00a9be) $fatal(1, "guide brand bar=%h", captured);

    // "NO CONTENT"
    check_cell(8,  40, 16'h004e);
    check_cell(24, 40, 16'h004f);
    check_cell(56, 40, 16'h0043);
    check_cell(72, 40, 16'h004f);
    check_cell(88, 40, 16'h004e);
    check_cell(104,40, 16'h0054);
    check_cell(120,40, 16'h0045);
    check_cell(136,40, 16'h004e);
    check_cell(152,40, 16'h0054);

    // "PUT BMP ON TF CARD"
    check_cell(8,  72, 16'h0050);
    check_cell(24, 72, 16'h0055);
    check_cell(40, 72, 16'h0054);
    check_cell(72, 72, 16'h0042);
    check_cell(88, 72, 16'h004d);
    check_cell(104,72, 16'h0050);
    check_cell(136,72, 16'h004f);
    check_cell(152,72, 16'h004e);
    check_cell(184,72, 16'h0054);
    check_cell(200,72, 16'h0046);

    // guide 关闭，触发坏图提示
    guide_page = 1'b0;
    frames(1);
    frames(2);
    sample(72, 360);
    if (captured !== 24'hffffff) $fatal(1,"old error toast must not cover photo");

    $display("ALL PASSED: OSD guide page without middle toast");
    $finish;
end
initial begin
    #5_000_000;
    $fatal(1, "osd guide timeout");
end
endmodule

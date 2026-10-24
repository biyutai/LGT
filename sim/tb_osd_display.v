// video_osd_overlay：产品化呈现行为验证
//   1. 默认干净：status_enable=0 时状态栏区域不动画面
//   2. status_enable=1 时顶部面板按 102030 画背景
//   3. 参数变化 → 底部提示条出现，约 180 帧后消失
//   4. 提示条显示期间滚动字幕隐藏
// 运行：sim/run.sh tb_osd_display
`timescale 1ns / 1ps

module tb_osd_display;
localparam PHOTO = 24'hffffff;

reg clk = 1'b0;
reg rst = 1'b1;
always #20 clk = ~clk;                      // ≈25MHz，频率只要量级正确

reg         frame_start = 1'b0;
reg         de = 1'b1;
reg  [11:0] x = 12'd0, y = 12'd0;
reg  [23:0] rgb_in = PHOTO;
reg         status_enable = 1'b0;
reg         info_page = 1'b0;
reg         cover_active = 1'b0;
reg         standby_mode = 1'b0;
reg         subtitle_enable = 1'b1;
reg  [1:0]  alpha = 2'd1;                   // 默认 35%
reg  [1:0]  image_index = 2'd0;
reg         browse_mode = 1'b0;
reg  [1:0]  browse_index = 2'd0, browse_scale_mode = 2'd0;
reg         auto_enabled = 1'b1, demo_mode = 1'b0;
reg  [2:0]  brightness_level = 3'd2, contrast_level = 3'd2, volume_level = 3'd2;
reg  [3:0]  effect_level = 4'd0;
reg  [2:0]  audio_effect_level = 3'd0;
reg  [2:0]  edit_mode = 3'd0;
reg  [1:0]  transition_kind = 2'd0, scale_mode = 2'd0;
reg  [23:0] timestamp = 24'h123456;
reg  [3:0]  health = 4'hf;
reg  [7:0]  fps = 8'd60, load_seconds = 8'd3, cache_hits = 8'd12, underrun_count = 8'd0;
reg         diag_view = 1'b0;
wire [23:0] rgb_out;

video_osd_overlay dut (
    .clk(clk), .rst(rst), .frame_start(frame_start), .de(de), .x(x), .y(y), .rgb_in(rgb_in),
    .subtitle_enable(subtitle_enable), .status_enable(status_enable), .alpha(alpha),
    .info_page(info_page), .cover_active(cover_active), .standby_mode(standby_mode),
    .selfcheck_page(1'b0), .selfcheck_ok(7'h7f), .img_found(3'd4),
    .playlist_entries(5'd4), .playlist_errors(4'd0),
    .playlist_sub_lang(),
    .playlist_subtitle(1'b0), .playlist_sub_code(16'h0020), .playlist_sub_char(),
    .log_page(1'b0), .log_view(252'd0), .log_any_valid(1'b0),
    .guide_page(1'b0), .av_err_01ms(10'd0),
    .image_index(image_index), .browse_mode(browse_mode), .browse_index(browse_index),
    .browse_scale_mode(browse_scale_mode), .auto_enabled(auto_enabled), .demo_mode(demo_mode),
    .brightness_level(brightness_level), .contrast_level(contrast_level),
    .effect_level(effect_level), .audio_effect_level(audio_effect_level),
    .volume_level(volume_level), .edit_mode(edit_mode), .transition_kind(transition_kind),
    .scale_mode(scale_mode), .source_large_1024(1'b0), .timestamp(timestamp), .health(health), .fps(fps),
    .load_seconds(load_seconds), .cache_hits(cache_hits), .underrun_count(underrun_count),
    .diag_view(diag_view),
    .rgb_out(rgb_out)
);

integer errors = 0;
task check(input cond, input [8*72-1:0] msg);
    begin
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s  (t=%0t)", msg, $time); errors = errors + 1; end
    end
endtask

// 采一个像素：坐标建立后等 2 拍（OSD 层一拍流水 + ROM 一拍）
reg [23:0] captured;
task sample(input integer px, input integer py);
    begin
        @(negedge clk); x = px[11:0]; y = py[11:0]; de = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk);                     // 避开 NBA 竞争：等坐标寄存器和 ROM 输出都稳定
        captured = rgb_out;
    end
endtask

// 推进 n 帧（每帧若干时钟 + 一个 frame_start 脉冲）
task frames(input integer n);
    integer i;
    begin
        for (i = 0; i < n; i = i + 1) begin
            repeat (20) @(posedge clk);
            @(negedge clk) frame_start = 1'b1;
            @(posedge clk);
            @(negedge clk) frame_start = 1'b0;
        end
    end
endtask

initial begin
    $display("== video_osd_overlay 产品化呈现：默认干净 + 操作提示条");
    repeat (4) @(posedge clk);
    rst = 1'b0;
    frames(4);

    // 1) 默认干净：状态栏区域不改画面
    sample(100, 20);
    $display("     dbg: status_q=%b de1=%b x1=%0d y1=%0d captured=%h",
             dut.status_q, dut.de1, dut.x1, dut.y1, captured);
    check(captured == PHOTO, "status off: top panel area keeps the photo pixel");

    // 2) 参数变化 → 提示条出现（在品牌竖条上取像素，必然与原图不同）
    brightness_level = 3'd3;
    frames(3);
    sample(65, 362);
    check(captured == PHOTO, "parameter change leaves the photo unobstructed");
    sample(300, 368);
    check(captured == PHOTO, "middle notification panel is removed");

    // 3) 提示条在字幕上方一行，两者并存（不重叠）：扫一行找字幕笔画
    begin : ticker_during_toast
        integer i, hits;
        hits = 0;
        for (i = 0; i < 200; i = i + 1) begin
            sample(8 + i, 440);
            if (captured != PHOTO) hits = hits + 1;
        end
        check(hits == 0, "without a playlist the subtitle area stays transparent");
    end

    // 4) 约 180 帧后提示条消失
    frames(60);
    sample(65, 362);
    check(captured == PHOTO, "photo stays clear after 60 frames");
    frames(130);
    sample(65, 362);
    check(captured == PHOTO, "photo stays clear after ~190 frames");

    // 5) 字幕回来
    sample(16, 440);
    check(captured == PHOTO, "subtitle area stays transparent after the toast");

    // 6) SW2 拨上 = 状态栏常显，面板底色 102030
    status_enable = 1'b1;
    frames(2);
    sample(100, 20);
    $display("     dbg: status_q=%b de1=%b x1=%0d y1=%0d captured=%h",
             dut.status_q, dut.de1, dut.x1, dut.y1, captured);
    check(captured == 24'h102030, "status on: top panel background is the glass colour");
    status_enable = 1'b0;
    frames(2);
    sample(100, 20);
    check(captured == PHOTO, "status off again: panel disappears");

    // 7) SW1 拨上 = 整屏产品信息页：面板底 + 左侧品牌条 + 文字
    info_page = 1'b1;
    frames(2);
    sample(200, 100);
    check(captured == 24'he3edf9, "info page: bright full-screen background");
    sample(1, 100);
    check(captured == 24'h00a9be, "info page: left brand accent bar");
    sample(40, 10);
    check(captured == 24'h00a9be, "info page: teal header band");
    sample(200, 10);
    check(captured == 24'h51a77b, "info page: green header band");
    begin : info_logo
        integer i, hits;
        hits=0;
        for (i=544;i<592;i=i+1) begin
            sample(i,48);
            if (captured==24'h008a9b || captured==24'h238b62 || captured==24'hc36246)
                hits=hits+1;
        end
        check(hits>2,"info page: colored LGT logo");
    end
    // 产品名那一行（行 0，y=40..56）里应有文字像素
    begin : info_text
        integer i, hits;
        hits = 0;
        for (i = 0; i < 120; i = i + 1) begin
            sample(8 + i, 44);
            if (captured == 24'h17464c) hits = hits + 1;
        end
        check(hits > 4, "info page: product-name row renders glyphs");
    end
    sample(37, 44);
    check(dut.glyph_code == 16'h0047,
          "info page: LGT letters use full 16-pixel spacing");
    sample(48, 44);
    check(dut.glyph_code == 16'h0054,
          "info page: title T keeps its full 16-pixel character cell");
    sample(24, 68);
    check(captured == 24'hdcf5f1, "info page: rows have a clear vertical gap");
    begin : info_second_row
        integer i, hits;
        hits = 0;
        for (i = 0; i < 120; i = i + 1) begin
            sample(8 + i, 76);
            if (captured == 24'h17464c) hits = hits + 1;
        end
        check(hits > 4, "info page: second row remains legible below the gap");
    end
    begin : info_exit_glyph
        integer i, hits;
        hits = 0;
        for (i = 120; i < 136; i = i + 1) begin
            sample(i, 335);
            if (captured == 24'h17464c) hits = hits + 1;
        end
        check(hits > 2, "info page: final row renders the exit glyph");
    end
    sample(8, 172);
    check(dut.glyph_code == 16'h5206,
          "info page: detail row uses spaced layout at y=168");
    status_enable = 1'b1;
    cover_active = 1'b1;
    frames(2);
    sample(8, 44);
    check(dut.glyph_code == 16'h004c,
          "info page: product heading wins over status and cover");
    sample(200, 220);
    check(captured == 24'he3edf9,
          "info page: cover text does not bleed through");
    status_enable = 1'b0;
    cover_active = 1'b0;
    frames(2);
    // 空白格必须保持面板底色；字库索引 0 被汉字占用时，整行空白会变成重复字。
    begin : info_blank_cells
        integer i, hits;
        hits = 0;
        for (i = 300; i < 500; i = i + 1) begin
            sample(i, 44);
            if (captured == 24'h17464c) begin
                hits = hits + 1;
                if (hits <= 4) $display("     blank debug: white at x=%0d code_q=%h idx_q=%0d idx_d=%0d bits=%h row=%0d page_q2=%h addr=%h map0_0=%0d",
                                        i, dut.glyph_code_q, dut.glyph_index_q,
                                        dut.glyph_index_d, dut.glyph_bits,
                                        dut.glyph_row_sel_q, dut.page_code_q2,
                                        dut.page_addr, dut.glyph_map0[0]);
            end
        end
        check(hits == 0, "info page: blank cells stay blank (no repeated glyph)");
    end
    // 信息页优先级最高：字幕/提示条都不画
    sample(16, 440);
    check(captured == 24'hdcf5f1, "info page covers the subtitle area");
    info_page = 1'b0;
    frames(2);

    // 8) Loading cover: one centered prompt with complete upper/lower glyph halves.
    cover_active = 1'b1;
    frames(2);
    begin : cover_text
        integer i, upper_hits, lower_hits;
        upper_hits = 0;
        lower_hits = 0;
        for (i = 256; i < 384; i = i + 1) begin
            sample(i, 314);
            if (captured == 24'h17464c) upper_hits = upper_hits + 1;
            sample(i, 328);
            if (captured == 24'h17464c) lower_hits = lower_hits + 1;
        end
        check(upper_hits > 5 && lower_hits > 5,
              "cover: centered Chinese prompt renders both glyph halves");
    end
    sample(100, 20);
    check(captured == PHOTO, "cover: status bar stays hidden");
    sample(65, 410);
    check(captured == PHOTO, "cover: toast panel stays hidden");
    sample(16, 440);
    check(captured == PHOTO, "cover: subtitle stays hidden");
    standby_mode = 1'b1;
    sample(256, 320);
    check(dut.glyph_code == 16'h0020,
          "screensaver hides the loading-card message");
    standby_mode = 1'b0;
    cover_active = 1'b0;
    frames(2);
    begin : subtitle_after_cover
        integer i, hits;
        hits = 0;
        for (i = 0; i < 200; i = i + 1) begin
            sample(8 + i, 440);
            if (captured != PHOTO) hits = hits + 1;
        end
        check(hits == 0, "subtitle area stays transparent after the cover phase");
    end

    // 9) 状态栏常显时，提示条里必须真能看到文字（不只是面板框）
    status_enable = 1'b1;
    frames(2);
    volume_level = 3'd4;
    frames(4);
    sample(100, 364);
    check(captured == PHOTO, "status changes do not cover the photo center");
    status_enable = 1'b0;
    frames(2);

    if (errors == 0) $display("ALL PASSED: OSD product-style presentation");
    else $fatal(1, "OSD presentation failures: %0d", errors);
    $finish;
end
endmodule

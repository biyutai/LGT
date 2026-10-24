`timescale 1ns/1ps

module tb_video_osd;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg frame_start = 0;
    reg de = 1;
    reg [11:0] x = 0, y = 0;
    reg [23:0] rgb_in = 24'h204060;
    reg subtitle_enable = 1;
    reg status_enable = 1;
    reg [1:0] alpha = 2;
    reg [1:0] image_index = 0;
    reg auto_enabled = 1;
    reg browse_mode = 0;
    reg [1:0] browse_index = 0;
    reg [1:0] browse_scale_mode = 0;
    reg demo_mode = 0;
    reg [2:0] brightness_level = 2, contrast_level = 2;
    reg [2:0] volume_level = 4;
    reg [2:0] edit_mode = 0;
    reg [1:0] transition_kind = 0;
    reg [1:0] scale_mode = 0;
    reg [23:0] timestamp = 24'h123456;
    reg [3:0] effect_level = 4'd0;
    reg [2:0] audio_effect_level = 3'd0;
    reg [3:0] health = 4'd0;
    reg [7:0] fps = 8'd60;
    reg [7:0] load_seconds = 8'd3;
    reg [7:0] cache_hits = 8'd12;
    reg [7:0] underrun_count = 8'd0;
    reg diag_view = 1'b0;
    reg [9:0] av_err_01ms = 10'd123;
    wire [23:0] rgb_out;
    integer slot_idx, mode_idx, scale_idx, transition_idx, row_idx;
    reg [15:0] code_at, glyph_union;

    video_osd_overlay dut (
        .clk(clk), .rst(rst), .frame_start(frame_start), .de(de),
        .x(x), .y(y), .rgb_in(rgb_in),
        .subtitle_enable(subtitle_enable), .status_enable(status_enable),
        .info_page(1'b0), .cover_active(1'b0),
        .playlist_subtitle(1'b0), .playlist_sub_code(16'h0020),
        .playlist_sub_char(), .playlist_sub_lang(),
        .log_page(1'b0), .log_view(252'd0), .log_any_valid(1'b0),
        .guide_page(1'b0), .av_err_01ms(av_err_01ms),
        .alpha(alpha), .image_index(image_index),
        .browse_mode(browse_mode), .browse_index(browse_index),
        .browse_scale_mode(browse_scale_mode),
        .auto_enabled(auto_enabled),
        .demo_mode(demo_mode),
        .brightness_level(brightness_level), .contrast_level(contrast_level),
        .volume_level(volume_level),
        .edit_mode(edit_mode), .transition_kind(transition_kind),
        .scale_mode(scale_mode), .source_large_1024(1'b0), .standby_mode(1'b0),
        .timestamp(timestamp),
        .effect_level(effect_level),
        .audio_effect_level(audio_effect_level),
        .health(health),
        .fps(fps),
        .load_seconds(load_seconds),
        .cache_hits(cache_hits),
        .underrun_count(underrun_count),
        .diag_view(diag_view),
        .rgb_out(rgb_out)
    );

    task frame;
        begin
            @(negedge clk); frame_start = 1;
            @(negedge clk); frame_start = 0;
            #1;
        end
    endtask

    task expect_rgb;
        input [23:0] expected;
        begin
            @(posedge clk); @(posedge clk); @(posedge clk); #1;   // 字模索引+字模 ROM 共三拍
            if (rgb_out !== expected) begin
                $display("FAIL x=%0d y=%0d got=%h expected=%h", x, y, rgb_out, expected);
                $fatal(1);
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 0;
        frame();
        x = 12'd300; y = 12'd200; expect_rgb(24'h204060);
        x = 12'd15; y = 12'd13;
        expect_rgb(24'hf7f9f8); // top status starts with Chinese 'picture'
        x = 12'd470; y = 12'd8; expect_rgb(24'h102030); // Chinese status row fits
        de = 0; x = 12'd16; y = 12'd432; expect_rgb(24'h204060);
        de = 1;
        // First pixel of 'A' is empty; its middle top pixel is set.
        x = 12'd16; y = 12'd432; expect_rgb(24'h204060);
        x = 12'd20; y = 12'd432; expect_rgb(24'h204060);
        alpha = 2'd3; expect_rgb(24'h204060);
        frame(); expect_rgb(24'h204060);
        x = 12'd132; expect_rgb(24'h204060); // transparent letter spacing
        subtitle_enable = 0; frame(); expect_rgb(24'h204060);
        subtitle_enable = 1; alpha = 0; frame(); expect_rgb(24'h204060);
        alpha = 1; frame();
        x = 12'd20; expect_rgb(24'h204060);
        alpha = 2; frame();
        expect_rgb(24'h204060);
        x = 12'd503; y = 12'd8; expect_rgb(24'h102030);
        x = 12'd512; y = 12'd40; expect_rgb(24'h204060);   // 面板右边界外（y=40 避开右上角标）
        // 右上角常驻角标：x 504..555 / y 8..23，深色底 + 左侧 2px 品牌竖条
        x = 12'd504; y = 12'd16; expect_rgb(24'h102030);
        x = 12'd520; y = 12'd10; expect_rgb(24'h204060);
        if (dut.status_main_code(0,0,3,2,2,1) !== 16'h56fe ||
            dut.status_main_code(1,0,3,2,2,1) !== 16'h7247 ||
            dut.status_main_code(2,0,3,2,2,1) !== "1")
            $fatal(1,"top row must say picture and its current number");
        if (dut.status_main_code(6,0,3,2,2,1) !== 16'h81ea ||
            dut.status_main_code(6,0,3,2,2,0) !== 16'h624b ||
            dut.status_main_code(7,0,3,2,2,1) !== 16'h52a8)
            $fatal(1,"playback mode must say automatic or manual in Chinese");
        if ({dut.status_main_code(9,0,3,2,2,1),
             dut.status_main_code(10,0,3,2,2,1),
             dut.status_main_code(11,0,3,2,2,1),
             dut.status_main_code(12,0,3,2,2,1)} !==
             {16'h4eae,16'h5ea6,16'h7b49,16'h7ea7} ||
            {dut.status_main_code(15,0,3,2,2,1),
             dut.status_main_code(16,0,3,2,2,1),
             dut.status_main_code(17,0,3,2,2,1),
             dut.status_main_code(18,0,3,2,2,1),
             dut.status_main_code(19,0,3,2,2,1)} !==
             {16'h5bf9,16'h6bd4,16'h5ea6,16'h7b49,16'h7ea7} ||
            dut.status_main_code(22,0,3,2,2,1) !== 16'h5b57 ||
            {dut.status_main_code(24,0,3,2,2,1),
             dut.status_main_code(25,0,3,2,2,1),
             dut.status_main_code(26,0,3,2,2,1),
             dut.status_main_code(27,0,3,2,2,1)} !==
             {16'h0031,16'h0030,16'h0030,16'h0025})
            $fatal(1,"brightness and contrast must be labeled as levels");
        if ({dut.status_main_code(24,0,0,2,2,1),
             dut.status_main_code(25,0,0,2,2,1)} !== {16'h0030,16'h0025} ||
            {dut.status_main_code(24,0,1,2,2,1),
             dut.status_main_code(25,0,1,2,2,1),
             dut.status_main_code(26,0,1,2,2,1)} !== {16'h0035,16'h0030,16'h0025} ||
            {dut.status_main_code(24,0,2,2,2,1),
             dut.status_main_code(25,0,2,2,2,1),
             dut.status_main_code(26,0,2,2,2,1)} !== {16'h0037,16'h0035,16'h0025})
            $fatal(1,"subtitle percentage mapping is wrong");
        if ({dut.status_volume_code(0,3'd4), dut.status_volume_code(1,3'd4),
             dut.status_volume_code(3,3'd4), dut.status_volume_code(4,3'd4),
             dut.status_volume_code(5,3'd4), dut.status_volume_code(6,3'd4)} !==
            {16'h97f3,16'h91cf,16'h0031,16'h0030,16'h0030,16'h0025} ||
            {dut.status_volume_code(3,3'd0), dut.status_volume_code(4,3'd0)} !==
            {16'h0030,16'h0025} ||
            {dut.status_volume_code(3,3'd1), dut.status_volume_code(4,3'd1),
             dut.status_volume_code(5,3'd1)} !== {16'h0033,16'h0035,16'h0025} ||
            {dut.status_volume_code(3,3'd2), dut.status_volume_code(4,3'd2),
             dut.status_volume_code(5,3'd2)} !== {16'h0037,16'h0030,16'h0025} ||
            {dut.status_volume_code(3,3'd3), dut.status_volume_code(4,3'd3),
             dut.status_volume_code(5,3'd3)} !== {16'h0037,16'h0035,16'h0025})
            $fatal(1,"top volume label must show the selected percentage");
        if (dut.status_glyph_index(16'h97f3)==7'd0 ||
            dut.status_font_rom[{dut.status_glyph_index(16'h97f3),4'd2}]==16'd0 ||
            dut.status_glyph_index(16'h91cf)==7'd0 ||
            dut.status_font_rom[{dut.status_glyph_index(16'h91cf),4'd2}]==16'd0)
            $fatal(1,"top volume glyphs are missing");
        // 第 4 行：运行时间戳（动态文字）
        if ({dut.status_line4_code(0, dut.diag_q), dut.status_line4_code(1, dut.diag_q)} !== {16'h8fd0,16'h884c})
            $fatal(1,"uptime row must be labeled 运行");
        if ({dut.status_line4_code(3, dut.diag_q), dut.status_line4_code(4, dut.diag_q)} !== {16'h0031,16'h0032} ||
            dut.status_line4_code(5, dut.diag_q) !== 16'h003a ||
            {dut.status_line4_code(6, dut.diag_q), dut.status_line4_code(7, dut.diag_q)} !== {16'h0033,16'h0034} ||
            dut.status_line4_code(8, dut.diag_q) !== 16'h003a ||
            {dut.status_line4_code(9, dut.diag_q), dut.status_line4_code(10, dut.diag_q)} !== {16'h0035,16'h0036})
            $fatal(1,"uptime digits must show the latched 12:34:56");
        // 时间戳右侧空槽 12~21：音画误差 xx.x MS
        if ({dut.status_line4_code(12, dut.diag_q), dut.status_line4_code(13, dut.diag_q)} !== {16'h0041,16'h0056} ||
            dut.status_line4_code(15, dut.diag_q) !== 16'h0031 ||
            dut.status_line4_code(16, dut.diag_q) !== 16'h0032 ||
            dut.status_line4_code(17, dut.diag_q) !== 16'h002e ||
            dut.status_line4_code(18, dut.diag_q) !== 16'h0033 ||
            {dut.status_line4_code(20, dut.diag_q), dut.status_line4_code(21, dut.diag_q)} !== {16'h004d,16'h0053})
            $fatal(1,"AV sync must render 12.3 MS in the free timestamp slots");
        if (dut.status_glyph_index(16'h8fd0)==7'd0 ||
            dut.status_font_rom[{dut.status_glyph_index(16'h8fd0),4'd2}]==16'd0)
            $fatal(1,"uptime label glyph is missing");
        // 第 4 行切换到自检视图：自检 V A S 帧 PP 读图 PP 秒 缓存 PP 欠载 PP
        diag_view = 1'b1; underrun_count = 8'd42; frame();
        if ({dut.status_line4_code(0, dut.diag_q), dut.status_line4_code(1, dut.diag_q)} !== {16'h81ea,16'h68c0})
            $fatal(1,"diagnostics row must start with 自检");
        if (dut.status_line4_code(3, dut.diag_q)!=="1" || dut.status_line4_code(4, dut.diag_q)!=="1" ||
            dut.status_line4_code(5, dut.diag_q)!=="1")
            $fatal(1,"healthy flags must read 111");
        if (dut.status_line4_code(8, dut.diag_q) !== 16'h0036 || dut.status_line4_code(9, dut.diag_q) !== 16'h0030 ||
            dut.status_line4_code(13, dut.diag_q) !== 16'h0030 || dut.status_line4_code(14, dut.diag_q) !== 16'h0033 ||
            dut.status_line4_code(19, dut.diag_q) !== 16'h0031 || dut.status_line4_code(20, dut.diag_q) !== 16'h0032)
            $fatal(1,"fps/load/cache numbers must show 60/03/12");
        if (dut.status_line4_code(22, dut.diag_q) !== 16'h6b20 || dut.status_line4_code(23, dut.diag_q) !== 16'h8f7d ||
            dut.status_line4_code(24, dut.diag_q) !== 16'h0034 || dut.status_line4_code(25, dut.diag_q) !== 16'h0032)
            $fatal(1,"audio underrun count must show 欠载 42");
        if (dut.status_glyph_index(16'h6b20)==7'd0 || dut.status_glyph_index(16'h8f7d)==7'd0 ||
            dut.status_font_rom[{dut.status_glyph_index(16'h6b20),4'd2}]==16'd0 ||
            dut.status_font_rom[{dut.status_glyph_index(16'h8f7d),4'd2}]==16'd0)
            $fatal(1,"underrun glyphs are missing from the status font");
        health = 4'b0011; frame();
        if (dut.status_line4_code(3, dut.diag_q)!=="0" || dut.status_line4_code(4, dut.diag_q)!=="0" ||
            dut.status_line4_code(5, dut.diag_q)!=="1")
            $fatal(1,"failed video/audio flags must read 001");
        health = 4'd0; underrun_count = 8'd0; diag_view = 1'b0; frame();
        if (dut.status_line4_code(0, dut.diag_q) !== 16'h8fd0)
            $fatal(1,"leaving diagnostics must restore the uptime row");
        x = 12'd9; y = 12'd58; expect_rgb(24'hf7f9f8); // 运行 第 3 行的点亮像素
        x = 12'd300; y = 12'd70; expect_rgb(24'h102030); // 状态栏已加高到 80 行
        x = 12'd300; y = 12'd80; expect_rgb(24'h204060); // 框外仍是画面
        x=12'd15; y=12'd26; expect_rgb(24'hf7f9f8);
        volume_level=3'd1; #1;
        if (dut.volume_q !== 3'd4)
            $fatal(1,"volume text changed before frame boundary");
        frame();
        if (dut.volume_q !== 3'd1)
            $fatal(1,"volume text did not update on frame boundary");
        browse_mode=1; volume_level=3'd2; frame();
        if (dut.volume_q !== 3'd2)
            $fatal(1,"volume status must update while browsing thumbnails");
        browse_mode=0; volume_level=3'd4; frame();
        x=12'd15; y=12'd13;
        image_index=1; auto_enabled=0; brightness_level=3; contrast_level=4; frame();
        if (dut.status_main_code(2,dut.image_q,dut.alpha_q,dut.brightness_q,
                                 dut.contrast_q,dut.auto_q) !== "2" ||
            dut.status_main_code(13,dut.image_q,dut.alpha_q,dut.brightness_q,
                                 dut.contrast_q,dut.auto_q) !== "3" ||
            dut.status_main_code(20,dut.image_q,dut.alpha_q,dut.brightness_q,
                                 dut.contrast_q,dut.auto_q) !== "4")
            $fatal(1,"top status values must track frame-latched controls");
        demo_mode=1; frame();
        if (dut.status_main_code(6,dut.image_q,dut.alpha_q,dut.brightness_q,
                                 dut.contrast_q,dut.auto_q) !== 16'h6f14 ||
            dut.status_main_code(7,dut.image_q,dut.alpha_q,dut.brightness_q,
                                 dut.contrast_q,dut.auto_q) !== 16'h793a)
            $fatal(1,"demo mode must read as 演示");
        browse_mode=1; browse_index=2'd2; image_index=2'd0; frame();
        if (dut.image_q !== 2'd2)
            $fatal(1,"browse status must show KEY2 focus during demo mode");
        image_index=2'd3; frame();
        if (dut.image_q !== 2'd2)
            $fatal(1,"automatic playback must not change browse status");
        browse_index=2'd3; frame();
        if (dut.image_q !== 2'd3)
            $fatal(1,"KEY2 focus must update browse status");
        demo_mode=0; auto_enabled=1; browse_index=2'd0; frame();
        image_index=2'd1; frame();
        if (dut.image_q !== 2'd0)
            $fatal(1,"automatic browse status must ignore playback image changes");
        demo_mode=0; auto_enabled=0; browse_index=2'd1; frame();
        if (dut.image_q !== 2'd1)
            $fatal(1,"manual browse status must show KEY2 focus");
        browse_mode=0; frame();
        if (dut.image_q !== image_index)
            $fatal(1,"leaving browse must restore playback image status");
        edit_mode=1; frame();
        if ({dut.status_detail_code(19,0,0,dut.edit_q),
             dut.status_detail_code(20,0,0,dut.edit_q),
             dut.status_detail_code(21,0,0,dut.edit_q),
             dut.status_detail_code(22,0,0,dut.edit_q)} !==
             {16'h4eae,16'h5ea6,16'h7b49,16'h7ea7})
            $fatal(1,"brightness edit mode label is wrong");
        edit_mode=2; frame();
        if ({dut.status_detail_code(19,0,0,dut.edit_q),
             dut.status_detail_code(20,0,0,dut.edit_q),
             dut.status_detail_code(21,0,0,dut.edit_q),
             dut.status_detail_code(22,0,0,dut.edit_q),
             dut.status_detail_code(23,0,0,dut.edit_q)} !==
             {16'h5bf9,16'h6bd4,16'h5ea6,16'h7b49,16'h7ea7})
            $fatal(1,"contrast edit mode label is wrong");
        edit_mode=3; effect_level=4'd8; frame();
        if ({dut.status_detail_code(19,0,0,dut.edit_q),
             dut.status_detail_code(20,0,0,dut.edit_q),
             dut.status_detail_code(21,0,0,dut.edit_q),
             dut.status_detail_code(22,0,0,dut.edit_q),
             dut.status_detail_code(23,0,0,dut.edit_q)} !==
             {16'h7279,16'h6548,16'h7b49,16'h7ea7,16'h0038})
            $fatal(1,"effect edit mode must read 特效等级 and its level");
        edit_mode=4; audio_effect_level=3'd5; frame();
        if ({dut.status_detail_code(19,0,0,dut.edit_q),
             dut.status_detail_code(20,0,0,dut.edit_q),
             dut.status_detail_code(21,0,0,dut.edit_q),
             dut.status_detail_code(22,0,0,dut.edit_q),
             dut.status_detail_code(23,0,0,dut.edit_q)} !==
             {16'h97f3,16'h6548,16'h7b49,16'h7ea7,16'h0035})
            $fatal(1,"audio edit mode must read 音效等级 and its level");
        effect_level=4'd0; audio_effect_level=3'd0; edit_mode=0;
        edit_mode=0; transition_kind=1; frame();
        if ({dut.status_detail_code(27,0,dut.transition_q,dut.edit_q),
             dut.status_detail_code(28,0,dut.transition_q,dut.edit_q),
             dut.status_detail_code(29,0,dut.transition_q,dut.edit_q)} !==
             {16'h5de6,16'h63ed,16'h793a})
            $fatal(1,"normal mode must explain the selected transition");
        transition_kind=3; frame();
        if ({dut.status_detail_code(27,0,dut.transition_q,dut.edit_q),
             dut.status_detail_code(28,0,dut.transition_q,dut.edit_q),
             dut.status_detail_code(29,0,dut.transition_q,dut.edit_q),
             dut.status_detail_code(30,0,dut.transition_q,dut.edit_q)} !==
             {16'h83f1,16'h5f62,16'h6eb6,16'h89e3})
            $fatal(1,"new transition must read diamond dissolve in Chinese");
        status_enable=0; frame();
        x=12'd15; y=12'd13; expect_rgb(24'h204060);
        status_enable=1; scale_mode=2; frame();
        if ({dut.status_detail_code(0,dut.scale_q,0,0),
             dut.status_detail_code(1,dut.scale_q,0,0),
             dut.status_detail_code(2,dut.scale_q,0,0)} !==
            {16'h5206,16'h8fa8,16'h7387})
            $fatal(1,"status label must say resolution");
        if ({dut.status_detail_code(3,dut.scale_q,0,0),
             dut.status_detail_code(4,dut.scale_q,0,0),
             dut.status_detail_code(5,dut.scale_q,0,0),
             dut.status_detail_code(6,dut.scale_q,0,0)} !==
            {16'h0031,16'h0032,16'h0038,16'h0030})
            $fatal(1,"1280 source label got %h %h %h %h, scale=%d",
                   dut.status_detail_code(3,dut.scale_q,0,0),
                   dut.status_detail_code(4,dut.scale_q,0,0),
                   dut.status_detail_code(5,dut.scale_q,0,0),
                   dut.status_detail_code(6,dut.scale_q,0,0),dut.scale_q);
        dut.source_large_q = 1'b1;
        if ({dut.status_detail_code(3,2,0,0),dut.status_detail_code(4,2,0,0),
             dut.status_detail_code(5,2,0,0),dut.status_detail_code(6,2,0,0),
             dut.status_detail_code(7,2,0,0),dut.status_detail_code(8,2,0,0),
             dut.status_detail_code(9,2,0,0),dut.status_detail_code(10,2,0,0)} !==
            {16'h0031,16'h0030,16'h0032,16'h0034,16'h0058,16'h0037,16'h0036,16'h0038})
            $fatal(1,"1024x768 source must not display 1280x960");
        dut.source_large_q = 1'b0;
        if ({dut.status_detail_code(14,dut.scale_q,0,0),
             dut.status_detail_code(15,dut.scale_q,0,0)} !== {16'h7f29,16'h5c0f})
            $fatal(1,"1280x960 mode must say scaled down");
        scale_mode=1; frame();
        if ({dut.status_detail_code(14,dut.scale_q,0,0),
             dut.status_detail_code(15,dut.scale_q,0,0)} !== {16'h653e,16'h5927})
            $fatal(1,"320x240 mode must say enlarged");
        scale_mode=3; frame();
        if ({dut.status_detail_code(14,dut.scale_q,0,0),
             dut.status_detail_code(15,dut.scale_q,0,0)} !== {16'h62c9,16'h4f38})
            $fatal(1,"320x180 mode must say stretched");
        for (mode_idx=0; mode_idx<3; mode_idx=mode_idx+1)
            for (scale_idx=0; scale_idx<4; scale_idx=scale_idx+1)
                for (transition_idx=0; transition_idx<4; transition_idx=transition_idx+1)
                    for (slot_idx=0; slot_idx<31; slot_idx=slot_idx+1) begin
                        code_at=dut.status_detail_code(slot_idx[4:0],scale_idx[1:0],
                                                       transition_idx[1:0],mode_idx[2:0]);
                        if (code_at!=16'h0020) begin
                            glyph_union=16'd0;
                            for (row_idx=0; row_idx<16; row_idx=row_idx+1)
                                glyph_union=glyph_union |
                                    dut.status_font_rom[{dut.status_glyph_index(code_at),row_idx[3:0]}];
                            if (glyph_union==16'd0)
                                $fatal(1,"detail row has a missing Chinese glyph: %h",code_at);
                        end
                    end
        for (slot_idx=0; slot_idx<27; slot_idx=slot_idx+1) begin
            code_at=dut.status_main_code(slot_idx[4:0],2'd3,2'd3,3'd4,3'd4,1'b0);
            if (code_at!=16'h0020) begin
                glyph_union=16'd0;
                for (row_idx=0; row_idx<16; row_idx=row_idx+1)
                    glyph_union=glyph_union |
                        dut.status_font_rom[{dut.status_glyph_index(code_at),row_idx[3:0]}];
                if (glyph_union==16'd0)
                    $fatal(1,"main row has a missing Chinese glyph: %h",code_at);
            end
        end
        browse_mode=0; image_index=2'd1; scale_mode=2'd0;
        brightness_level=3'd3; contrast_level=3'd4; transition_kind=2'd1;
        auto_enabled=1; demo_mode=0; edit_mode=0; alpha=2'd2;
        frame();
        browse_mode=1; browse_index=2'd2; browse_scale_mode=2'd1;
        frame();
        if (dut.image_q !== 2'd2 || dut.scale_q !== 2'd1 ||
            dut.status_detail_code(14,dut.scale_q,dut.transition_q,dut.edit_q) !== 16'h653e)
            $fatal(1,"browse image, source size and display mode must match focus");
        image_index=2'd0; scale_mode=2'd3;
        browse_index=2'd3; browse_scale_mode=2'd2;
        brightness_level=3'd0; contrast_level=3'd1; transition_kind=2'd3;
        auto_enabled=0; demo_mode=1; edit_mode=2; alpha=2'd0;
        frame();
        if (dut.image_q !== 2'd3 || dut.scale_q !== 2'd2 ||
            dut.status_detail_code(14,dut.scale_q,dut.transition_q,dut.edit_q) !== 16'h7f29)
            $fatal(1,"KEY2 must update selected source size and display mode");
        if (dut.brightness_q !== 3'd3 || dut.contrast_q !== 3'd4 ||
            dut.transition_q !== 2'd1 || dut.auto_q !== 1'b1 ||
            dut.demo_q !== 1'b0 || dut.edit_q !== 3'd0)
            $fatal(1,"other top status fields must hold while browsing");
        subtitle_enable=1; status_enable=1; alpha=2'd3; frame();
        x=12'd15; y=12'd13; #1;
        if (!dut.status_q || !dut.subtitle_q || dut.alpha_q !== 2'd3 ||
            rgb_out !== 24'hf7f9f8)
            $fatal(1,"top text must stay fully clear in browse mode");
        alpha=2'd1; frame();
        if (dut.alpha_q !== 2'd1 || rgb_out !== 24'hf7f9f8)
            $fatal(1,"bottom subtitle clarity must not dim top letters");
        x=12'd11; y=12'd44; #1;
        if (rgb_out !== 24'hf7f9f8)
            $fatal(1,"top detail letters must stay fully clear");
        x=12'd15; y=12'd13; #1;
        alpha=2'd0; subtitle_enable=0; frame();
        if (dut.alpha_q !== 2'd0 || dut.subtitle_q || rgb_out !== 24'hf7f9f8)
            $fatal(1,"zero bottom subtitle clarity must leave top letters clear");
        status_enable=0; frame();
        if (dut.status_q || rgb_out !== rgb_in)
            $fatal(1,"browse SW2 must hide top status without exiting browse");
        status_enable=1; subtitle_enable=1; alpha=2'd2; frame();
        if (!dut.status_q || !dut.subtitle_q || dut.alpha_q !== 2'd2)
            $fatal(1,"browse switches must restore status and subtitle immediately");
        browse_mode=0; frame();
        if (dut.image_q !== image_index || dut.scale_q !== scale_mode ||
            dut.brightness_q !== brightness_level ||
            dut.contrast_q !== contrast_level || dut.transition_q !== transition_kind)
            $fatal(1,"leaving browse must restore live top status");
        alpha=2'd0; subtitle_enable=0; frame();
        if (rgb_out !== 24'hf7f9f8)
            $fatal(1,"top text clarity must also stay fixed outside browse mode");
        $display("ALL PASSED: video OSD overlay");
        $finish;
    end
endmodule

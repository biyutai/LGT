`timescale 1ns/1ps
module tb_osd_subtitle_full;
    reg clk=0, rst=1, frame_start=0;
    always #5 clk=~clk;
    reg [11:0] x=8, y=440;
    wire [23:0] rgb_out;
    wire [5:0] sub_char;
    wire sub_lang;
    wire [15:0] sub_code = sub_lang ? 16'h0042 : 16'h0041;
    localparam [23:0] PHOTO=24'h204060;

    video_osd_overlay dut (
        .clk(clk), .rst(rst), .frame_start(frame_start), .de(1'b1),
        .x(x), .y(y), .rgb_in(PHOTO), .rgb_out(rgb_out),
        .subtitle_enable(1'b1), .status_enable(1'b0), .alpha(2'd3),
        .info_page(1'b0), .cover_active(1'b0), .standby_mode(1'b0),
        .selfcheck_page(1'b0), .selfcheck_ok(7'd0), .img_found(3'd4),
        .playlist_entries(5'd4), .playlist_errors(4'd0),
        .playlist_subtitle(1'b1), .playlist_sub_code(sub_code),
        .playlist_sub_char(sub_char), .playlist_sub_lang(sub_lang),
        .log_page(1'b0), .log_view(252'd0), .log_any_valid(1'b0),
        .guide_page(1'b0), .av_err_01ms(10'd0),
        .image_index(2'd0), .browse_mode(1'b0), .browse_index(2'd0),
        .browse_scale_mode(2'd0), .auto_enabled(1'b1), .demo_mode(1'b0),
        .brightness_level(3'd2), .contrast_level(3'd2), .volume_level(3'd4),
        .edit_mode(3'd0), .transition_kind(2'd0), .scale_mode(2'd0),
        .source_large_1024(1'b0), .timestamp(24'd0),
        .effect_level(4'd0), .audio_effect_level(3'd0),
        .health(4'd0), .fps(8'd60), .load_seconds(8'd0),
        .cache_hits(8'd0), .underrun_count(8'd0), .diag_view(1'b0)
    );

    task sample;
        input integer sx, sy;
        begin
            @(negedge clk); x=sx; y=sy;
            repeat(5) @(posedge clk);
            #1;
        end
    endtask

    integer i, hits;
    initial begin
        repeat(3) @(negedge clk); rst=0;
        @(negedge clk); frame_start=1;
        @(negedge clk); frame_start=0;
        hits=0;
        for (i=0;i<16;i=i+1) begin
            sample(600+i,440);
            if (rgb_out==24'hf7f9f8) hits=hits+1;
        end
        if (hits<2 || sub_lang) $fatal(1,"Chinese row must span the right side");
        hits=0;
        for (i=0;i<16;i=i+1) begin
            sample(600+i,464);
            if (rgb_out==24'hf7f9f8) hits=hits+1;
        end
        if (hits<2 || !sub_lang) $fatal(1,"English row must span the right side");
        sample(616,464);
        if (sub_char!=6'd38) $fatal(1,"full-width final cell address=%0d",sub_char);
        sample(200,448);
        if (rgb_out!=PHOTO) $fatal(1,"gap must preserve photo pixels");
        sample(8,432);
        if (rgb_out!=PHOTO) $fatal(1,"blank glyph pixel must preserve photo, not a band");
        $display("ALL PASSED: full-width two-line subtitle without background");
        $finish;
    end
endmodule

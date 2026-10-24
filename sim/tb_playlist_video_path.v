`timescale 1ns/1ps
module tb_playlist_video_path;
    reg sd_clk=0, video_clk=0, rst=1;
    always #10 sd_clk=~sd_clk;
    always #20 video_clk=~video_clk;
    reg start=0, byte_valid=0, eof=0, frame_start=0;
    reg [7:0] byte_data=0;
    reg [11:0] x=8, y=440;
    wire [5:0] sub_char;
    wire sub_lang;
    wire [15:0] sub_code;
    wire [23:0] rgb_out;
    wire [4:0] entry_count;

    playlist_parse parser (
        .clk(sd_clk), .rst(rst), .start(start), .byte_valid(byte_valid),
        .byte_data(byte_data), .eof(eof), .entry_count(entry_count),
        .error_count(), .present(), .done(),
        .rd_entry(4'd0), .rd_img_index(), .rd_seconds(), .rd_transition(),
        .rd_sub_entry(4'd0), .rd_sub_lang(sub_lang), .rd_sub_char(sub_char),
        .rd_sub_clk(video_clk), .rd_sub_code(sub_code)
    );
    video_osd_overlay osd (
        .clk(video_clk), .rst(rst), .frame_start(frame_start),
        .de(1'b1), .x(x), .y(y), .rgb_in(24'h204060), .rgb_out(rgb_out),
        .subtitle_enable(1'b1), .status_enable(1'b0), .alpha(2'd3),
        .info_page(1'b0), .cover_active(1'b0), .standby_mode(1'b0),
        .selfcheck_page(1'b0), .selfcheck_ok(7'd0), .img_found(3'd1),
        .playlist_entries(entry_count), .playlist_errors(4'd0),
        .playlist_subtitle(1'b1), .playlist_sub_code(sub_code),
        .playlist_sub_char(sub_char), .playlist_sub_lang(sub_lang),
        .log_page(1'b0), .log_view(252'd0), .log_any_valid(1'b0),
        .guide_page(1'b0), .av_err_01ms(10'd0),
        .image_index(2'd0), .browse_mode(1'b0), .browse_index(2'd0),
        .browse_scale_mode(2'd0), .auto_enabled(1'b1), .demo_mode(1'b0),
        .brightness_level(3'd2), .contrast_level(3'd2), .volume_level(3'd4),
        .edit_mode(3'd0), .transition_kind(2'd0), .scale_mode(2'd0),
        .source_large_1024(1'b0), .timestamp(24'd0),
        .effect_level(4'd0), .audio_effect_level(3'd0), .health(4'd0),
        .fps(8'd60), .load_seconds(8'd0), .cache_hits(8'd0),
        .underrun_count(8'd0), .diag_view(1'b0)
    );

    task send;
        input [7:0] value;
        begin
            @(negedge sd_clk); byte_data=value; byte_valid=1;
            @(negedge sd_clk); byte_valid=0;
        end
    endtask
    task sample;
        input integer sx, sy;
        begin
            @(negedge video_clk); x=sx; y=sy;
            repeat (6) @(posedge video_clk);
            #1;
        end
    endtask

    integer i, zh_hits, en_hits;
    initial begin
        repeat (4) @(negedge sd_clk); rst=0;
        @(negedge sd_clk); start=1;
        @(negedge sd_clk); start=0;
        send("1"); send(","); send("8"); send(","); send("0"); send(",");
        send("A"); send("B"); send("C"); send("|");
        send("H"); send("E"); send("L"); send("L"); send("O"); send(8'h0a);
        @(negedge sd_clk); eof=1;
        @(negedge sd_clk); eof=0;
        repeat (4) @(negedge sd_clk);
        @(negedge video_clk); frame_start=1;
        @(negedge video_clk); frame_start=0;
        sample(8,440);
        if (sub_code!==16'h0041 || sub_lang)
            $fatal(1,"first row code=%h lang=%b",sub_code,sub_lang);
        zh_hits=0;
        for (i=0;i<16;i=i+1) begin
            sample(8+i,440);
            if (rgb_out==24'hf7f9f8) zh_hits=zh_hits+1;
        end
        sample(8,464);
        if (sub_code!==16'h0048 || !sub_lang)
            $fatal(1,"English row code=%h lang=%b",sub_code,sub_lang);
        en_hits=0;
        for (i=0;i<16;i=i+1) begin
            sample(8+i,464);
            if (rgb_out==24'hf7f9f8) en_hits=en_hits+1;
        end
        if (zh_hits<2 || en_hits<2)
            $fatal(1,"bilingual screen pixels zh=%0d en=%0d",zh_hits,en_hits);
        $display("ALL PASSED: dual-clock playlist renders both language rows");
        $finish;
    end
endmodule

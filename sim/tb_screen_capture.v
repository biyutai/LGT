`timescale 1ns/1ps
module tb_screen_capture;
    reg clk = 0, rst = 1, frame_start = 0;
    always #5 clk = ~clk;
    reg [11:0] x = 0, y = 0;
    reg log_page = 0;
    reg selfcheck_mode = 0;
    reg [251:0] log_view = 0;
    wire [23:0] boot_rgb, rgb_out;
    integer fd, px, py;

    video_startup_screen cover (
        .clk(clk), .rst(rst), .frame_start(frame_start),
        .photo_valid(1'b0), .x(x), .y(y), .photo_rgb(24'd0),
        .rgb_out(boot_rgb), .cover_active()
    );
    video_osd_overlay osd (
        .clk(clk), .rst(rst), .frame_start(frame_start), .de(1'b1),
        .x(x), .y(y), .rgb_in(boot_rgb), .rgb_out(rgb_out),
        .subtitle_enable(1'b0), .status_enable(1'b0), .alpha(2'd3),
        .info_page(1'b0), .cover_active(1'b1), .standby_mode(1'b0),
        .selfcheck_page(selfcheck_mode), .selfcheck_ok(7'h7f), .img_found(3'd4),
        .playlist_entries(5'd0), .playlist_errors(4'd0),
        // Keep a nonblank playlist glyph active on LOG to expose footer leakage.
        .playlist_subtitle(log_page), .playlist_sub_code(16'h64ad),
        .playlist_sub_char(), .playlist_sub_lang(),
        .log_page(log_page), .log_view(log_view), .log_any_valid(1'b1),
        .guide_page(1'b0), .av_err_01ms(10'd0),
        .image_index(2'd0), .browse_mode(1'b0), .browse_index(2'd0),
        .browse_scale_mode(2'd0), .auto_enabled(1'b0), .demo_mode(1'b0),
        .brightness_level(3'd2), .contrast_level(3'd2), .volume_level(3'd4),
        .edit_mode(3'd0), .transition_kind(2'd0), .scale_mode(2'd0),
        .source_large_1024(1'b0), .timestamp(24'd0),
        .effect_level(4'd0), .audio_effect_level(3'd0), .health(4'd0),
        .fps(8'd60), .load_seconds(8'd0), .cache_hits(8'd0),
        .underrun_count(8'd0), .diag_view(1'b0)
    );

    task capture;
        input [8*96-1:0] path;
        begin
            fd = $fopen(path, "wb");
            if (!fd) $fatal(1, "cannot open capture output");
            $fwrite(fd, "P6\n640 480\n255\n");
            for (py = 0; py < 480; py = py + 1)
                for (px = 0; px < 640; px = px + 1) begin
                    @(negedge clk); x = px; y = py;
                    @(posedge clk); #1;
                    $fwrite(fd, "%c%c%c", rgb_out[23:16], rgb_out[15:8], rgb_out[7:0]);
                end
            $fclose(fd);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk); rst = 0;
        @(negedge clk); frame_start = 1;
        @(negedge clk); frame_start = 0;
        capture("../../build/preview_cover.ppm");
        log_view[0 +: 36] = {1'b1, 4'd0, 3'd0, 12'h123, 16'h0001};
        log_view[36 +: 36] = {1'b1, 4'd1, 3'd1, 12'h157, 16'h0002};
        log_view[72 +: 36] = {1'b1, 4'd2, 3'd2, 12'h204, 16'h0003};
        log_page = 1;
        capture("../../build/preview_log.ppm");
        log_page = 0;
        selfcheck_mode = 1;
        capture("../../build/preview_selfcheck.ppm");
        $display("ALL PASSED: cover, log and self-check captures written");
        $finish;
    end
endmodule

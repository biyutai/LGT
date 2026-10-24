`timescale 1ns/1ps
module tb_video_startup_screen;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, frame_start=0, photo_valid=0;
    reg [11:0] x=0, y=0;
    reg [23:0] photo_rgb=24'h123456;
    wire [23:0] rgb_out;

    video_startup_screen dut (
        .clk(clk), .rst(rst), .frame_start(frame_start),
        .photo_valid(photo_valid), .x(x), .y(y),
        .photo_rgb(photo_rgb), .rgb_out(rgb_out), .cover_active()
    );

    task frame;
        begin @(negedge clk); frame_start=1; @(negedge clk); frame_start=0; #1; end
    endtask

    initial begin
        repeat(3) @(negedge clk); rst=0;
        x=12'd10; y=12'd40; #1;
        if(rgb_out[23:16] < 8'hb0 || rgb_out[15:8] < 8'hb0)
            $fatal(1,"startup image must have a bright background");
        x=12'd40; y=12'd10; #1;
        if(rgb_out!==24'hdcebea) $fatal(1,"cover needs the original calm background");
        x=12'd174; y=12'd144; #1;
        if(rgb_out!==24'h008a9b)
            $fatal(1,"central LGT logo should be enlarged");
        x=12'd200; y=12'd10; #1;
        if(rgb_out!==24'hdcebea) $fatal(1,"cover should differ from the SW1 information page");
        x=12'd250; y=12'd200; #1;
        if(rgb_out===24'd0 || rgb_out===photo_rgb)
            $fatal(1,"startup image must contain visible central content");
        x=12'd174; y=12'd144; #1;
        if(rgb_out!==24'h008a9b)
            $fatal(1,"L must render clearly on the startup image");
        x=12'd308; #1;
        if(rgb_out!==24'h238b62)
            $fatal(1,"G must render on the startup image");
        x=12'd386; #1;
        if(rgb_out!==24'hc36246)
            $fatal(1,"T must render on the startup image");
        x=12'd500; #1;
        if(rgb_out!==24'heff7f4)
            $fatal(1,"old fourth letter must be absent");
        x=12'd230; y=12'd284; #1;
        if(rgb_out!==24'h00a9be)
            $fatal(1,"startup image must render its color strip");
        photo_valid=1; #1;
        if(rgb_out===photo_rgb)
            $fatal(1,"photo must not replace startup image mid-frame");
        frame();
        if(rgb_out!==photo_rgb)
            $fatal(1,"first complete photo must appear at a frame boundary");
        photo_valid=0; #1;
        if(rgb_out!==photo_rgb)
            $fatal(1,"card removal must not tear the current frame");
        frame();
        if(rgb_out===photo_rgb || rgb_out===24'd0)
            $fatal(1,"startup image must return at the next frame boundary");
        $display("ALL PASSED: startup image and frame-boundary handoff");
        $finish;
    end
endmodule

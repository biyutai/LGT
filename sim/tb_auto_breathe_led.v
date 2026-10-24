`timescale 1ns/1ps
module tb_auto_breathe_led;
    reg clk=0,rst=1,frame_start=0,photo_valid=1;
    reg auto_enabled=0,wav_ready=1,wav_played=0;
    reg browse_mode=0;
    reg [1:0] image_index=0;
    reg [20:0] segment_samples=21'd1024;
    wire [3:0] led;
    integer i,lit;
    always #5 clk=~clk;

    auto_breathe_led #(.PWM_PRESCALE(1)) dut (
        .clk(clk),.rst(rst),.frame_start(frame_start),
        .photo_valid(photo_valid),.auto_enabled(auto_enabled),
        .browse_mode(browse_mode),
        .wav_ready(wav_ready),.wav_played(wav_played),
        .segment_samples(segment_samples),.image_index(image_index),.led(led)
    );

    task play_samples;
        input integer count;
        integer k;
        begin
            for(k=0;k<count;k=k+1) begin
                @(negedge clk);wav_played=1;
                @(negedge clk);wav_played=0;
            end
        end
    endtask
    task frame;
        begin @(negedge clk);frame_start=1;@(negedge clk);frame_start=0; end
    endtask
    task count_light;
        output integer result;
        integer k;
        begin
            result=0;
            for(k=0;k<128;k=k+1) begin
                @(negedge clk);
                if(led!=={4{led[0]}})$fatal(1,"four green LEDs must share one PWM signal");
                if(led[0])result=result+1;
            end
        end
    endtask

    initial begin
        repeat(3) @(negedge clk);rst=0;
        if(led!==4'b0000)$fatal(1,"manual mode must keep LEDs off");
        auto_enabled=1;
        play_samples(256);
        count_light(lit);
        if(lit!==64)$fatal(1,"first quarter breath must be half bright, lit=%0d",lit);
        play_samples(256);
        count_light(lit);
        if(lit!==127)$fatal(1,"middle of interval must reach peak brightness, lit=%0d",lit);
        play_samples(256);
        count_light(lit);
        if(lit!==63)$fatal(1,"last quarter must fade, lit=%0d",lit);
        play_samples(256);
        count_light(lit);
        if(lit!==0)$fatal(1,"breath must finish dark and not repeat before next image");
        image_index=1;
        repeat(2) @(negedge clk);
        if(led!==4'b0000 || dut.breath_phase!==8'd0)
            $fatal(1,"new picture must restart the four-LED breath");
        auto_enabled=0;
        repeat(2) @(negedge clk);
        if(led!==4'b0000)$fatal(1,"LEDs must turn off when auto play stops");
        wav_ready=0;auto_enabled=1;
        repeat(30) frame();
        count_light(lit);
        if(lit<110 || lit>120)$fatal(1,"timer slideshow must reach one bright peak");
        repeat(30) frame();
        count_light(lit);
        if(lit!==0)$fatal(1,"timer slideshow breath must finish dark");
        browse_mode=1; photo_valid=0;
        repeat(128) begin
            @(negedge clk);
            if(led!==4'b1111)$fatal(1,"browse mode must keep all four LEDs on");
        end
        auto_enabled=0;
        repeat(128) begin
            @(negedge clk);
            if(led!==4'b1111)$fatal(1,"manual browse must keep all four LEDs on");
        end
        browse_mode=0;
        @(negedge clk);
        if(led!==4'b0000)$fatal(1,"LEDs must return to playback behavior after browse");
        $display("ALL PASSED: four-LED automatic slideshow breathing");
        $finish;
    end
endmodule

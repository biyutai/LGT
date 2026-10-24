`timescale 1ns/1ps
module tb_audio_visualizer;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, frame_start=0, de=1, pcm_valid=0, led_enable=1, video_enable=1;
    reg signed [15:0] pcm=0;
    reg [11:0] x=0,y=0;
    reg [23:0] rgb_in=24'h203040;
    wire [23:0] rgb_out;
    wire [7:0] led_red,led_green;
    integer i, lit_green, lit_red;
    real phase;
    reg signed [15:0] previous_slow;
    integer palette_before;
    audio_visualizer #(.DECIMATE(1)) dut (
        .clk(clk),.rst(rst),.frame_start(frame_start),.de(de),
        .x(x),.y(y),.rgb_in(rgb_in),.pcm_valid(pcm_valid),.pcm(pcm),
        .led_enable(led_enable), .video_enable(video_enable),
        .rgb_out(rgb_out),.led_red(led_red),.led_green(led_green)
    );
    task frame;
        begin @(negedge clk);frame_start=1;@(negedge clk);frame_start=0;#1;end
    endtask
    task check;
        input [23:0] expected;
        begin #1;if(rgb_out !== expected)begin
            $display("FAIL x=%0d y=%0d got=%h expected=%h",x,y,rgb_out,expected);
            $fatal(1);
        end end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        x=300;y=200;check(rgb_in);
        for(i=0;i<32;i=i+1)begin
            @(negedge clk);pcm_valid=1;pcm=(i[0] ? -16'sd24000 : 16'sd24000);
            @(negedge clk);pcm_valid=0;
        end
        frame();
        lit_green=0;lit_red=0;
        for(i=0;i<8;i=i+1)begin
            lit_green=lit_green+led_green[i];
            lit_red=lit_red+led_red[i];
        end
        while(dut.pwm_phase!==5'd0) @(negedge clk);
        #1;
        if(led_red[6]!==1'b1 || led_green[7]!==1'b1)
            $fatal(1,"high-band LED pair must include red and green colors");
        x=20;y=361;check(24'h53d8c5); // first waveform sample
        video_enable=0; check(rgb_in);
        video_enable=1; check(24'h53d8c5);
        x=600;y=390;
        if(rgb_out===rgb_in)$fatal(1,"high band must rise visibly above the bottom");
        x=300;y=200;check(rgb_in);
        de=0;x=20;y=361;check(rgb_in);
        de=1;
        for(i=0;i<800;i=i+1)begin
            @(negedge clk);pcm_valid=1;pcm=0;
            @(negedge clk);pcm_valid=0;
        end
        frame();
        for(i=0;i<800;i=i+1)begin
            @(negedge clk);pcm_valid=1;pcm=0;
            @(negedge clk);pcm_valid=0;
        end
        frame();
        if(led_red!==0 || led_green!==0)$fatal(1,"silence must clear LED levels");
        for(i=0;i<800;i=i+1)begin
            phase=6.28318530718*i/48000.0;
            @(negedge clk);pcm_valid=1;
            pcm=$rtoi(3500.0*$sin(100.0*phase)+3500.0*$sin(400.0*phase)+
                      3500.0*$sin(1000.0*phase)+3500.0*$sin(4000.0*phase));
            @(negedge clk);pcm_valid=0;
        end
        frame();
        if(dut.band_display[0]>=8'd200 || dut.band_display[1]>=8'd200)
            $fatal(1,"moderate music must not saturate all four bands");
        if(dut.chase_frames!==4'd8 || dut.chase_pos!==3'd0)
            $fatal(1,"beat must start an eight-position LED chase");
        if(led_red[0]!==1'b1)
            $fatal(1,"first beat highlight must start at LED 0");
        palette_before=dut.palette_phase;
        while(dut.pwm_phase!==5'd0) @(negedge clk);
        #1;
        lit_green=0;lit_red=0;
        for(i=0;i<8;i=i+1)begin
            lit_green=lit_green+led_green[i];
            lit_red=lit_red+led_red[i];
        end
        if(lit_green<4 || lit_red<4)
            $fatal(1,"moderate four-band music must animate most LED positions");
        x=516;y=402;#1;if(rgb_out===rgb_in)$fatal(1,"low band too short");
        x=544;y=398;#1;if(rgb_out===rgb_in)$fatal(1,"low-mid band too short");
        x=572;y=390;#1;if(rgb_out===rgb_in)$fatal(1,"high-mid band too short");
        x=600;y=390;#1;if(rgb_out===rgb_in)$fatal(1,"high band too short");
        x=520;y=420;check(24'hd6e9e8); // LO label
        x=548;y=420;check(24'hd6e9e8); // LM label
        x=576;y=420;check(24'hd6e9e8); // HM label
        x=604;y=420;check(24'hd6e9e8); // HI label
        frame();
        if(dut.chase_pos!==3'd1 || led_red[1]!==1'b1)
            $fatal(1,"beat highlight must move to LED 1");
        repeat(7) frame();
        if(dut.chase_frames!==4'd0)
            $fatal(1,"beat chase must end after eight frames");
        if(dut.palette_phase!==palette_before)
            $fatal(1,"palette must stay stable between beats");
        while(dut.pwm_phase!==5'd0) @(negedge clk);
        #1;
        if((led_red & led_green)===8'd0 ||
           (led_red & ~led_green)===8'd0 ||
           (led_green & ~led_red)===8'd0)
            $fatal(1,"LED palette needs mixed, red-only and green-only colors");
        while(dut.pwm_phase!==5'd31) @(negedge clk);
        #1;
        if(led_red!==8'd0 || led_green!==8'd0)
            $fatal(1,"PWM must include an off interval for brightness control");
        for(i=0;i<800;i=i+1)begin
            @(negedge clk);pcm_valid=1;pcm=0;
            @(negedge clk);pcm_valid=0;
        end
        frame();
        frame();
        for(i=0;i<800;i=i+1)begin
            phase=6.28318530718*i/48000.0;
            @(negedge clk);pcm_valid=1;
            pcm=$rtoi(3500.0*$sin(100.0*phase)+3500.0*$sin(400.0*phase)+
                      3500.0*$sin(1000.0*phase)+3500.0*$sin(4000.0*phase));
            @(negedge clk);pcm_valid=0;
        end
        frame();
        if(dut.palette_phase!==(palette_before+1)%4 || dut.chase_pos!==3'd0)
            $fatal(1,"next beat must rotate the palette and restart the chase");
        led_enable=0;
        repeat(40) @(negedge clk);
        if(dut.pwm_phase!==5'd0 || led_red!==8'd0 || led_green!==8'd0)
            $fatal(1,"disabled LED view must stop PWM and output activity");
        led_enable=1;
        rst=1;repeat(2) @(negedge clk);rst=0;
        for(i=0;i<64;i=i+1)begin
            @(negedge clk);pcm_valid=1;pcm=16'sd12000;
            @(negedge clk);pcm_valid=0;
        end
        previous_slow=dut.low_slow;
        @(negedge clk);pcm_valid=1;pcm=0;
        @(negedge clk);pcm_valid=0;
        if(dut.low_slow>=previous_slow)
            $fatal(1,"negative low-pass delta must decay toward silence");
        $display("ALL PASSED: PCM waveform, bands and LEDs");$finish;
    end
endmodule

`timescale 1ns/1ps
// 串口状态报文：4 行 x 64 字节（每行 62 个可见字符 + CR + LF），共 256 字节
module tb_uart_status;
    parameter integer SERIAL_CLK_HZ=1200;
    parameter integer SERIAL_BAUD=100;
    localparam integer CLKS_PER_BIT=(SERIAL_CLK_HZ+SERIAL_BAUD/2)/SERIAL_BAUD;
    localparam integer LINE_LEN=256;
    reg clk=0,rst=1,frame_start=0,photo_valid=0,auto_enabled=0,wav_ready=0,demo_mode=0;
    reg [1:0] image_index=0, subtitle_alpha=2;
    reg [2:0] image_count=0, brightness=2, contrast=2, volume_level=4;
    reg [3:0] health=0;
    reg [7:0] beat_count=0;
    reg [7:0] diag_cache_hits=0, diag_load_seconds=0;
    reg [3:0] diag_error_code=0;
    reg diag_load_busy=0;
    reg [15:0] key_mask=0;
    reg [4:0] playlist_entries=0;
    reg [3:0] playlist_errors=0;
    reg [2:0] playlist_pos=0;
    wire uart_tx;
    integer j;
    reg [7:0] received;
    reg [8*LINE_LEN-1:0] expected;
    always #5 clk=~clk;

    uart_status_reporter #(.CLK_HZ(SERIAL_CLK_HZ),.BAUD(SERIAL_BAUD),.FRAMES_PER_REPORT(4)) dut (
        .clk(clk),.rst(rst),.frame_start(frame_start),
        .photo_valid(photo_valid),.image_index(image_index),
        .image_count(image_count),
        .auto_enabled(auto_enabled),.demo_mode(demo_mode),
        .wav_ready(wav_ready),
        .brightness(brightness),.contrast(contrast),
        .subtitle_alpha(subtitle_alpha),
        .health(health),.beat_count(beat_count),
        .volume_level(volume_level),
        .diag_cache_hits(diag_cache_hits),.diag_load_seconds(diag_load_seconds),
        .diag_error_code(diag_error_code),.diag_load_busy(diag_load_busy),
        .key_mask(key_mask),
        .playlist_entries(playlist_entries),
        .playlist_errors(playlist_errors),
        .playlist_pos(playlist_pos),
        .uart_tx(uart_tx)
    );

    task frame;
        begin @(negedge clk);frame_start=1;@(negedge clk);frame_start=0; end
    endtask
    task recv_byte;
        output reg [7:0] value;
        integer bit_no;
        begin
            wait(uart_tx===1'b0);
            repeat(CLKS_PER_BIT/2) @(posedge clk);
            #1;
            if(uart_tx!==1'b0) $fatal(1,"UART start bit invalid");
            for(bit_no=0;bit_no<8;bit_no=bit_no+1) begin
                repeat(CLKS_PER_BIT) @(posedge clk);
                #1;value[bit_no]=uart_tx;
            end
            repeat(CLKS_PER_BIT) @(posedge clk);
            #1;
            if(uart_tx!==1'b1) $fatal(1,"UART stop bit invalid");
        end
    endtask
    task recv_line;
        input [8*LINE_LEN-1:0] line;
        reg [7:0] value;
        begin
            for(j=0;j<LINE_LEN;j=j+1) begin
                recv_byte(value);
                if(value!==line[(LINE_LEN-1-j)*8 +: 8])
                    $fatal(1,"UART byte %0d got=%h expected=%h",j,value,
                           line[(LINE_LEN-1-j)*8 +: 8]);
            end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        if(uart_tx!==1'b1)$fatal(1,"UART idle level must be high");
        frame();
        expected={
            "PHOTO 0/0   PLAY MANUAL  AUDIO TONE   VOLUME 100% PL  0/ 0 C 0",8'h0d,8'h0a,
            "BRIGHT 2/4  CONTRAST 2/4  SUBTITLE 70%   KEY none             ",8'h0d,8'h0a,
            "HEALTH VIDEO OK   AUDIO OK   SD CARD OK   LOAD idle 00s       ",8'h0d,8'h0a,
            "CACHE HITS 000  MUSIC BEATS 000  LAST ERROR none              ",8'h0d,8'h0a};
        recv_line(expected);
        photo_valid=1;image_index=1;image_count=4;auto_enabled=1;demo_mode=0;wav_ready=1;
        brightness=3;contrast=4;volume_level=1;subtitle_alpha=2;
        diag_cache_hits=12;diag_load_seconds=3;diag_error_code=0;diag_load_busy=1;
        beat_count=42;health=0;key_mask=16'h0004;
        playlist_entries=12;playlist_errors=3;playlist_pos=5;
        frame();
        expected={
            "PHOTO 2/4   PLAY AUTO    AUDIO WAV    VOLUME 35%  PL 12/ 3 C 5",8'h0d,8'h0a,
            "BRIGHT 3/4  CONTRAST 4/4  SUBTITLE 70%   KEY S3               ",8'h0d,8'h0a,
            "HEALTH VIDEO OK   AUDIO OK   SD CARD OK   LOAD busy 03s       ",8'h0d,8'h0a,
            "CACHE HITS 012  MUSIC BEATS 042  LAST ERROR none              ",8'h0d,8'h0a};
        recv_line(expected);
        image_index=0;auto_enabled=1;demo_mode=1;wav_ready=0;
        brightness=0;contrast=0;volume_level=0;subtitle_alpha=3;key_mask=16'h0182;
        health=4'b1101;diag_error_code=3;diag_cache_hits=255;beat_count=255;
        diag_load_seconds=0;diag_load_busy=0;
        playlist_entries=8;playlist_errors=15;playlist_pos=2;
        frame();
        expected={
            "PHOTO 1/4   PLAY DEMO    AUDIO TONE   VOLUME 0%   PL  8/15 C 2",8'h0d,8'h0a,
            "BRIGHT 0/4  CONTRAST 0/4  SUBTITLE 100%  KEY multi            ",8'h0d,8'h0a,
            "HEALTH VIDEO FAIL AUDIO FAIL SD CARD FAIL LOAD idle 00s       ",8'h0d,8'h0a,
            "CACHE HITS 255  MUSIC BEATS 255  LAST ERROR TIMEOUT           ",8'h0d,8'h0a};
        recv_line(expected);
        // 只动节目单一项：十位进位（10 → "10"）且应立刻补发一份报文
        playlist_errors=10;
        frame();
        expected={
            "PHOTO 1/4   PLAY DEMO    AUDIO TONE   VOLUME 0%   PL  8/10 C 2",8'h0d,8'h0a,
            "BRIGHT 0/4  CONTRAST 0/4  SUBTITLE 100%  KEY multi            ",8'h0d,8'h0a,
            "HEALTH VIDEO FAIL AUDIO FAIL SD CARD FAIL LOAD idle 00s       ",8'h0d,8'h0a,
            "CACHE HITS 255  MUSIC BEATS 255  LAST ERROR TIMEOUT           ",8'h0d,8'h0a};
        recv_line(expected);
        $display("ALL PASSED: human readable UART status, 4 lines (with playlist status)");
        $finish;
    end
    initial begin
        #5_000_000;
        $fatal(1,"UART status timeout");
    end
endmodule

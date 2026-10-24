`timescale 1ns/1ps
module tb_thumbnail_downsample_full;
    reg clk=0,rst=1,start=0,valid=0;
    reg [23:0] rgb=0;
    wire word_valid;
    wire [31:0] word_data;
    integer x,y,count=0,px,py;
    reg [31:0] expected;
    always #5 clk=~clk;
    thumbnail_downsample dut(.clk(clk),.rst(rst),.start(start),
        .in_valid(valid),.in_rgb(rgb),
        .word_valid(word_valid),.word_data(word_data));
    function [23:0] pixel(input integer xx,input integer yy);
        pixel={xx[7:0],yy[7:0],(xx+yy)&8'hff};
    endfunction
    function [15:0] pack(input [23:0] p);
        pack={p[23:19],p[15:10],p[7:3]};
    endfunction
    always @(negedge clk) if(word_valid) begin
        px=(count%160)*4;
        py=(count/160)*2;
        expected={pack(pixel(px,py)),pack(pixel(px+2,py))};
        if(word_data!==expected)
            $fatal(1,"preview word %0d at (%0d,%0d): got %h expected %h",
                   count,px,py,word_data,expected);
        count=count+1;
    end
    initial begin
        repeat(2) @(negedge clk);rst=0;start=1;
        @(negedge clk);start=0;
        for(y=0;y<480;y=y+1) begin
            for(x=0;x<640;x=x+1) begin
                valid=1;rgb=pixel(x,y);
                @(negedge clk);
            end
            valid=0;
            repeat(3) @(negedge clk);
        end
        repeat(3) @(negedge clk);
        if(count!=38400) $fatal(1,"expected 38400 preview words, got %0d",count);
        $display("ALL PASSED: full 640x480 to 320x240 RGB565 preview");$finish;
    end
endmodule

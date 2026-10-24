`timescale 1ns/1ps
module tb_thumbnail_stream_unpack;
    reg clk=0,rst=1,preview=1,base_en=0,x_bit=0;
    reg [31:0] word=32'd0;
    wire read_en;
    wire [23:0] rgb;
    integer i;
    always #5 clk=~clk;
    thumbnail_stream_unpack dut(.clk(clk),.rst(rst),.preview_mode(preview),
        .base_read_en(base_en),.x_parity(x_bit),.read_word(word),
        .read_en(read_en),.rgb(rgb));
    initial begin
        repeat(2) @(negedge clk);rst=0;
        for(i=0;i<19;i=i+1) begin x_bit=i[0];@(negedge clk);end
        word=32'hf800_07e0;
        base_en=1;
        x_bit=1;
        #1;
        if(!read_en) $fatal(1,"even pixel must pop one word");
        @(negedge clk);x_bit=0;#1;
        if(rgb!==24'hff0000) $fatal(1,"even RGB565 pixel %h",rgb);
        if(read_en) $fatal(1,"odd pixel must reuse word");
        @(negedge clk);#1;
        if(rgb!==24'h00ff00) $fatal(1,"odd RGB565 pixel %h",rgb);
        preview=0;word=32'h12345600;#1;
        if(rgb!==24'h123456 || !read_en) $fatal(1,"normal frame passthrough");
        $display("ALL PASSED: packed preview stream");$finish;
    end
endmodule

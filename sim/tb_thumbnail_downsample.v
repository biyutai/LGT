`timescale 1ns/1ps
module tb_thumbnail_downsample;
    reg clk=0, rst=1, start=0, valid=0;
    reg [23:0] rgb=0;
    wire word_valid;
    wire [31:0] word_data;
    integer x,y,n=0;
    reg [31:0] expected [0:3];
    always #5 clk=~clk;
    thumbnail_downsample #(.WIDTH(8),.HEIGHT(4)) dut(
        .clk(clk),.rst(rst),.start(start),.in_valid(valid),.in_rgb(rgb),
        .word_valid(word_valid),.word_data(word_data));
    always @(negedge clk) if(word_valid) begin
        if(word_data !== expected[n]) $fatal(1,"word %0d got %h expected %h",n,word_data,expected[n]);
        n=n+1;
    end
    initial begin
        expected[0]=32'hf800_07e0;
        expected[1]=32'h001f_ffff;
        expected[2]=32'h07e0_f800;
        expected[3]=32'hffff_001f;
        repeat(2) @(negedge clk);rst=0;
        start=1; @(negedge clk);start=0;
        for(y=0;y<4;y=y+1) for(x=0;x<8;x=x+1) begin
            valid=1;
            case ({y[1],x[2:1]})
                4'b0000:rgb=24'hff0000;
                4'b0001:rgb=24'h00ff00;
                4'b0010:rgb=24'h0000ff;
                4'b0011:rgb=24'hffffff;
                4'b0100:rgb=24'h00ff00;
                4'b0101:rgb=24'hff0000;
                4'b0110:rgb=24'hffffff;
                default:rgb=24'h0000ff;
            endcase
            @(negedge clk);
            if(x==3) begin valid=0; repeat(3) @(negedge clk); end
        end
        valid=0;repeat(3) @(negedge clk);
        if(n!=4) $fatal(1,"expected four packed words, got %0d",n);
        $display("ALL PASSED: 320x240 RGB565 preview packing");$finish;
    end
endmodule

`timescale 1ns/1ps
module tb_bmp_scale_2x;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1,start=0,mode_load=0,in_valid=0;
    reg [15:0] src_width=8,src_height=4;
    reg [23:0] in_data=0;
    wire out_valid,done;
    wire [23:0] out_data;
    integer x,y,n=0,cycles=0;
    reg wide_test=0;
    integer expected_y;
    bmp_scale_2x #(.FRAME_WIDTH(16),.FRAME_HEIGHT(8)) dut(
        .clk(clk),.rst(rst),.start(start),.mode_load(mode_load),.src_width(src_width),
        .src_height(src_height),.in_valid(in_valid),.in_data(in_data),
        .out_valid(out_valid),.out_data(out_data),.done(done)
    );
    always @(posedge clk) if(out_valid) begin
        expected_y = wide_test ? ((n/16)<2 ? 0 : (n/16)<5 ? 1 : 2) : n/32;
        if(out_data !== (expected_y*8+(n%16)/2+1)) begin
            $display("FAIL output %0d got %h",n,out_data);$fatal(1);
        end
        n=n+1;
    end
    initial begin
        repeat(2) @(negedge clk);rst=0;
        @(negedge clk);start=1;
        @(negedge clk);start=0;
        mode_load=1;
        @(negedge clk);mode_load=0;
        for(y=0;y<4;y=y+1)for(x=0;x<8;x=x+1)begin
            repeat(6) @(negedge clk);
            if(y==1 && x==4)begin src_width=16;src_height=8;end
            in_valid=1;in_data=y*8+x+1;
            @(negedge clk);in_valid=0;
            if(y==1 && x==4)begin src_width=8;src_height=4;end
        end
        while(!done && cycles<1000)begin @(negedge clk);cycles=cycles+1;end
        @(negedge clk);
        if(!done || n!=128)$fatal(1,"scaled frame incomplete: n=%0d",n);
        n=0;cycles=0;wide_test=1;src_height=3;
        @(negedge clk);start=1;
        @(negedge clk);start=0;mode_load=1;
        @(negedge clk);mode_load=0;
        for(y=0;y<3;y=y+1)for(x=0;x<8;x=x+1)begin
            repeat(6) @(negedge clk);
            in_valid=1;in_data=y*8+x+1;
            @(negedge clk);in_valid=0;
        end
        while(!done && cycles<1000)begin @(negedge clk);cycles=cycles+1;end
        @(negedge clk);
        if(!done || n!=128)$fatal(1,"wide frame incomplete: n=%0d",n);
        $display("ALL PASSED: 2x nearest-neighbor stream expansion");$finish;
    end
endmodule

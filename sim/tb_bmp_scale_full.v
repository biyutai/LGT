`timescale 1ns/1ps
module tb_bmp_scale_full;
    reg clk=0,rst=1,start=0,mode_load=0,in_valid=0;
    reg [15:0] src_width=16'd320,src_height=16'd240;
    reg [23:0] in_data=24'd0;
    wire out_valid,done;
    wire [23:0] out_data;
    integer n=0,case_height=240,source_x,source_y,expected_y,expected_x,wait_cycles;
    always #5 clk=~clk;

    bmp_scale_2x #(.FRAME_WIDTH(640),.FRAME_HEIGHT(480)) dut (
        .clk(clk),.rst(rst),.start(start),.mode_load(mode_load),
        .src_width(src_width),.src_height(src_height),
        .in_valid(in_valid),.in_data(in_data),
        .out_valid(out_valid),.out_data(out_data),.done(done)
    );

    function [23:0] pixel;
        input integer px,py;
        reg [7:0] xb,yb,mix;
        begin
            xb=px[7:0];yb=py[7:0];mix=xb^yb;
            pixel={yb,xb,mix};
        end
    endfunction

    always @(posedge clk) if (!rst && out_valid) begin
        expected_x=(n%640)/2;
        expected_y=(case_height==240) ? n/1280 : (((n/640)+1)*3-1)/8;
        if(n>=307200 || out_data!==pixel(expected_x,expected_y))
            $fatal(1,"full frame mismatch: h=%0d n=%0d got=%h expected=%h",
                   case_height,n,out_data,pixel(expected_x,expected_y));
        n=n+1;
    end

    task run_case;
        input integer height;
        begin
            case_height=height;n=0;src_height=height;
            @(negedge clk);start=1;
            @(negedge clk);start=0;mode_load=1;
            @(negedge clk);mode_load=0;
            for(source_y=0;source_y<height;source_y=source_y+1)
                for(source_x=0;source_x<320;source_x=source_x+1) begin
                    repeat(9) @(negedge clk);
                    in_valid=1;in_data=pixel(source_x,source_y);
                    @(negedge clk);in_valid=0;
                end
            wait_cycles=0;
            while(!done && wait_cycles<100000) begin
                @(negedge clk);wait_cycles=wait_cycles+1;
            end
            repeat(3) @(negedge clk);
            if(!done || n!=307200)
                $fatal(1,"full frame incomplete: h=%0d pixels=%0d",height,n);
        end
    endtask

    initial begin
        repeat(3) @(negedge clk);rst=0;
        run_case(240);
        run_case(180);
        $display("ALL PASSED: full 640x480 scaling, 320x240 and 320x180");
        $finish;
    end
endmodule

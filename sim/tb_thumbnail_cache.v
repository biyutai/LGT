`timescale 1ns/1ps
module tb_thumbnail_cache;
    reg thumb_mode=1;
    reg focus_enable=1;
    reg [1:0] focus=0;
    reg [3:0] valid_mask=0;
    reg [23:0] full_rgb=24'h123456;
    reg [11:0] x=0,y=0;
    wire [23:0] rgb;
    wire active;
    thumbnail_cache dut(.thumb_mode(thumb_mode),.focus_index(focus),
        .focus_enable(focus_enable),
        .full_rgb(full_rgb),.full_valid_mask(valid_mask),
        .x(x),.y(y),.rgb(rgb),.active(active));
    initial begin
        x=100;y=100;focus=3;#1;
        if(!active || rgb!==24'h101820) $fatal(1,"incomplete preview must be blank");
        valid_mask=4'b0001;#1;
        if(rgb!==full_rgb) $fatal(1,"completed preview must use full-resolution pixel");
        x=319;y=239;#1;
        if(rgb!==full_rgb) $fatal(1,"bank zero final pixel");
        x=320;#1;
        if(rgb!==24'h101820) $fatal(1,"bank one still incomplete");
        valid_mask=4'b1111;focus=1;#1;
        if(rgb!==24'h00e5ff) $fatal(1,"selected bank border");
        focus_enable=0;#1;
        if(rgb!==full_rgb) $fatal(1,"disabled focus must not draw the border");
        focus_enable=1;#1;
        if(rgb!==24'h00e5ff) $fatal(1,"focus border must come back");
        x=330;y=100;#1;
        if(rgb!==full_rgb) $fatal(1,"bank one interior");
        x=0;y=240;focus=3;#1;
        if(rgb!==full_rgb) $fatal(1,"bank two first pixel");
        x=639;y=479;#1;
        if(rgb!==24'h00e5ff) $fatal(1,"bank three border");
        thumb_mode=0;#1;
        if(active || rgb!==24'd0) $fatal(1,"preview disabled");
        $display("ALL PASSED: four full-resolution preview cells");$finish;
    end
endmodule

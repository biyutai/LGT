`timescale 1ns/1ps
module tb_thumbnail_buttons;
    reg clk=0, rst=1, key2=1, key3=1, confirm_toggle=0, confirm_long_toggle=0;
    wire thumb_mode, select_toggle, mode_short_toggle;
    wire [1:0] focus_index, select_index;
    always #5 clk=~clk;
    thumbnail_button_control #(.CLK_HZ(100)) dut (
        .clk(clk), .rst(rst), .key1(1'b1), .key2(key2), .key3(key3),
        .confirm_toggle(confirm_toggle), .confirm_long_toggle(confirm_long_toggle),
        .thumb_mode(thumb_mode),
        .focus_index(focus_index), .select_toggle(select_toggle),
        .select_index(select_index), .mode_short_toggle(mode_short_toggle)
    );
    task cycles(input integer n);
        integer i;
        begin for(i=0;i<n;i=i+1) @(negedge clk); end
    endtask
    initial begin
        cycles(4); rst=0;
        key3=0; cycles(12);
        if (mode_short_toggle || thumb_mode) $fatal(1,"KEY3 press must not act before release");
        key3=1; cycles(8);
        if (!mode_short_toggle || thumb_mode) $fatal(1,"short KEY3 must only change edit mode");
        key3=0; cycles(110);
        if (!thumb_mode || mode_short_toggle !== 1'b1)
            $fatal(1,"long KEY3 must enter browse without short event");
        key3=1; cycles(8);
        if (!thumb_mode || mode_short_toggle !== 1'b1)
            $fatal(1,"long KEY3 release must not add a short event");
        key2=0; cycles(5); key2=1; cycles(5);
        if (focus_index != 2'd1) $fatal(1,"KEY2 must move browse focus");
        confirm_toggle=1; cycles(4);
        if (thumb_mode || !select_toggle || select_index != 2'd1)
            $fatal(1,"short KEY1 must confirm focused image");
        // 再进一次缩略图，用长按退出：不应改变选中图片，也不改变显示缓冲
        confirm_toggle=0; cycles(4);
        key3=0; cycles(110); key3=1; cycles(8);
        if (!thumb_mode) $fatal(1,"long KEY3 must re-enter browse");
        key2=0; cycles(5); key2=1; cycles(5);
        if (focus_index != 2'd2) $fatal(1,"KEY2 must move browse focus again");
        confirm_long_toggle=1; cycles(4);
        if (thumb_mode) $fatal(1,"long KEY1 in browse must exit the grid");
        if (select_index != 2'd1 || select_toggle !== 1'b1)
            $fatal(1,"browse exit must not re-select a picture");
        $display("ALL PASSED: thumbnail button short/long separation");
        $finish;
    end
endmodule

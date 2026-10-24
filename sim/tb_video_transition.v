`timescale 1ns/1ps
module tb_video_transition;
    reg clk=0, rst=1, frame_start=0, de=1, active=1;
    always #5 clk=~clk;
    reg manual_press=0, manual_prev_press=0;
    reg browse_mode=0, browse_select_pulse=0;
    reg [1:0] buffer_index=0, effect_kind=0;
    reg [11:0] x=100, y=240;
    reg [23:0] rgb_in=24'h804020;
    wire [23:0] rgb_out;
    wire switch_toggle, prev_toggle, busy;
    video_transition #(.FADE_FRAMES(4),.WAIT_FRAMES(5)) dut (
        .clk(clk),.rst(rst),.frame_start(frame_start),.de(de),
        .active(active),.manual_press(manual_press),
        .manual_prev_press(manual_prev_press),.browse_mode(browse_mode),
        .browse_select_pulse(browse_select_pulse),.prefetch_enabled(1'b1),
        .next_ready(1'b0),.buffer_index(buffer_index),.effect_kind(effect_kind),
        .x(x),.y(y),.rgb_in(rgb_in),.rgb_out(rgb_out),
        .switch_toggle(switch_toggle),.prev_toggle(prev_toggle),
        .prev_in_progress(),.busy(busy)
    );
    task frame;
        begin @(negedge clk); frame_start=1; @(negedge clk); frame_start=0; #1; end
    endtask
    task check;
        input [23:0] expected;
        begin #1; if (rgb_out!==expected) $fatal(1,"x=%0d y=%0d got=%h want=%h",x,y,rgb_out,expected); end
    endtask
    integer i;
    initial begin
        repeat(3) @(negedge clk); rst=0;
        frame(); check(rgb_in);
        @(negedge clk); manual_press=1;
        @(negedge clk); manual_press=0;
        repeat(3) @(negedge clk);
        if (!switch_toggle || !busy) $fatal(1,"manual request not sent");
        repeat(8) begin frame(); check(rgb_in); end
        buffer_index=1; repeat(2) @(negedge clk);
        frame(); check(24'h201008);
        frame(); check(24'h402010);
        frame(); check(24'h603018);
        frame(); check(rgb_in);
        frame(); if (busy) $fatal(1,"manual fade-in not finished");

        effect_kind=1; buffer_index=0; repeat(2) @(negedge clk);
        check(rgb_in);
        frame(); x=100; check(rgb_in); x=300; check(24'h000000);
        repeat(4) frame(); x=639; check(rgb_in);
        frame(); if (busy) $fatal(1,"left reveal not finished");

        effect_kind=2; buffer_index=1; repeat(2) @(negedge clk);
        frame(); x=100; check(24'h000000); x=600; check(rgb_in);
        repeat(5) frame(); if (busy) $fatal(1,"right reveal not finished");

        effect_kind=3; buffer_index=0; repeat(2) @(negedge clk);
        frame(); x=320; y=240; check(rgb_in);
        x=0; y=0; check(24'h000000);
        repeat(24) frame(); check(rgb_in);
        if (busy) $fatal(1,"diamond dissolve not finished");

        browse_mode=1; frame();
        buffer_index=1; frame();
        if (busy || rgb_out!==rgb_in) $fatal(1,"thumbnail grid must stay unanimated");
        browse_select_pulse=1; @(negedge clk);
        browse_select_pulse=0; browse_mode=0;
        buffer_index=0; frame();
        if (busy || rgb_out!==rgb_in) $fatal(1,"thumbnail confirmation must show selected frame");

        rst=1; buffer_index=0; effect_kind=0; browse_mode=0;
        repeat(2) @(negedge clk); rst=0;
        frame();
        @(negedge clk); manual_prev_press=1;
        @(negedge clk); manual_prev_press=0;
        repeat(3) @(negedge clk);
        if (!prev_toggle || switch_toggle || !busy) $fatal(1,"previous request not sent");
        for (i=0;i<8;i=i+1) begin frame(); check(rgb_in); end
        $display("ALL PASSED: manual hold and automatic reveal effects");
        $finish;
    end
endmodule

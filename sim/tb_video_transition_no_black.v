`timescale 1ns/1ps
module tb_video_transition_no_black;
    reg clk=0, rst=1, frame_start=0, de=1, active=1;
    always #5 clk=~clk;
    reg manual_press=0, manual_prev_press=0;
    reg [1:0] buffer_index=0, effect_kind=0;
    reg [23:0] rgb_in=24'h3579bd;
    wire [23:0] rgb_out;
    wire switch_toggle, prev_toggle, busy;
    video_transition #(.FADE_FRAMES(4),.WAIT_FRAMES(5)) dut (
        .clk(clk),.rst(rst),.frame_start(frame_start),.de(de),
        .active(active),.manual_press(manual_press),
        .manual_prev_press(manual_prev_press),.browse_mode(1'b0),
        .browse_select_pulse(1'b0),.prefetch_enabled(1'b1),
        .next_ready(1'b0),.buffer_index(buffer_index),.effect_kind(effect_kind),
        .x(12'd240),.y(12'd200),.rgb_in(rgb_in),.rgb_out(rgb_out),
        .switch_toggle(switch_toggle),.prev_toggle(prev_toggle),
        .prev_in_progress(),.busy(busy)
    );
    task frame;
        begin @(negedge clk); frame_start=1; @(negedge clk); frame_start=0; #1; end
    endtask
    integer i;
    initial begin
        repeat(3) @(negedge clk); rst=0;
        frame();
        @(negedge clk); manual_press=1;
        @(negedge clk); manual_press=0;
        repeat(3) @(negedge clk);
        if (!switch_toggle || !busy) $fatal(1,"manual request must start loading immediately");
        for (i=0;i<12;i=i+1) begin
            frame();
            if (rgb_out!==rgb_in) $fatal(1,"old image hidden while next image loads: %h",rgb_out);
        end
        buffer_index=1;
        repeat(3) @(negedge clk);
        frame();
        repeat(5) frame();
        if (busy || rgb_out!==rgb_in) $fatal(1,"new image transition did not finish");

        @(negedge clk); manual_prev_press=1;
        @(negedge clk); manual_prev_press=0;
        repeat(3) @(negedge clk);
        if (!prev_toggle || !busy) $fatal(1,"previous request must start loading immediately");
        for (i=0;i<12;i=i+1) begin
            frame();
            if (rgb_out!==rgb_in) $fatal(1,"old image hidden during previous-image load");
        end
        if (busy) $fatal(1,"failed image load must release manual transition for retry");
        $display("ALL PASSED: manual switches keep old image until new frame commits");
        $finish;
    end
endmodule

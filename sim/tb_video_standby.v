`timescale 1ns/1ps

module tb_video_standby;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg tick_1s = 0;
    reg activity = 0;
    reg card_change = 0;
    reg manual_mode = 0;
    wire standby;
    wire default_standby;

    video_standby #(.IDLE_SECONDS(5)) dut (
        .clk(clk), .rst(rst), .tick_1s(tick_1s),
        .activity(activity), .card_change(card_change),
        .manual_mode(manual_mode), .standby(standby)
    );
    video_standby dut_default (
        .clk(clk), .rst(rst), .tick_1s(tick_1s),
        .activity(activity), .card_change(card_change),
        .manual_mode(manual_mode), .standby(default_standby)
    );

    task tick; begin @(negedge clk); tick_1s = 1; @(negedge clk); tick_1s = 0; end endtask
    integer i;

    initial begin
        repeat(3) @(negedge clk); rst = 0;
        for (i = 0; i < 65; i = i + 1) tick();
        if (standby || default_standby) $fatal(1, "automatic mode must not enter standby");
        @(negedge clk); manual_mode = 1;
        for (i = 0; i < 4; i = i + 1) tick();
        if (standby) $fatal(1, "standby too early");
        tick();
        if (!standby) $fatal(1, "standby must assert after idle window");

        @(negedge clk); activity = 1;
        @(negedge clk); activity = 0;
        if (standby) $fatal(1, "activity must wake");
        for (i = 0; i < 4; i = i + 1) tick();
        if (standby) $fatal(1, "timer must restart after activity");
        tick();
        if (!standby) $fatal(1, "standby must assert again");

        @(negedge clk); manual_mode = 0;
        @(negedge clk);
        if (standby) $fatal(1, "leaving manual mode must clear standby");
        for (i = 0; i < 65; i = i + 1) tick();
        if (standby || default_standby) $fatal(1, "automatic mode must keep timers at zero");
        @(negedge clk); manual_mode = 1;
        for (i = 0; i < 4; i = i + 1) tick();
        if (standby || default_standby) $fatal(1, "returning to manual mode restarts timers");
        tick();
        if (!standby) $fatal(1, "manual mode starts a fresh standby interval");

        @(negedge clk); card_change = 1;
        @(negedge clk); card_change = 0;
        if (standby) $fatal(1, "card change must wake");
        for (i = 0; i < 59; i = i + 1) tick();
        if (default_standby) $fatal(1,"default standby must wait one minute");
        tick();
        if (!default_standby) $fatal(1,"default standby must assert at 60 seconds");
        $display("ALL PASSED: standby timer");
        $finish;
    end
endmodule

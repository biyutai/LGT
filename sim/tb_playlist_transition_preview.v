`timescale 1ns/1ps
module tb_playlist_transition_preview;
    reg clk=0, rst=1;
    always #5 clk=~clk;
    reg playlist_active=1, manual_select=0, restore_select=0, busy=0;
    reg [1:0] playlist_kind=1, manual_kind=3;
    wire [1:0] effective_kind;
    playlist_transition_preview dut (
        .clk(clk), .rst(rst), .playlist_active(playlist_active),
        .playlist_kind(playlist_kind), .manual_kind(manual_kind),
        .manual_select(manual_select), .restore_select(restore_select),
        .transition_busy(busy),
        .effective_kind(effective_kind)
    );
    task tick; begin @(negedge clk); #1; end endtask
    initial begin
        repeat(3) tick(); rst=0; tick();
        if (effective_kind!=1) $fatal(1,"playlist transition must be the default");
        manual_select=1; tick(); manual_select=0;
        if (effective_kind!=3) $fatal(1,"manual transition must override the playlist");
        busy=1; tick();
        if (effective_kind!=3) $fatal(1,"manual transition must survive the next image switch");
        busy=0; tick();
        playlist_kind=2; busy=1; tick();
        if (effective_kind!=3) $fatal(1,"manual transition must survive playlist changes");
        busy=0; tick();
        playlist_active=0; tick();
        if (effective_kind!=3) $fatal(1,"without a playlist, manual selection remains active");
        rst=1; tick(); rst=0; playlist_active=1; tick();
        if (effective_kind!=2) $fatal(1,"reset returns to authored playlist effect");
        restore_select=1; tick(); restore_select=0; tick();
        if (effective_kind!=3) $fatal(1,"restored flash setting must override playlist effects");
        $display("ALL PASSED: persistent manual transition selection");
        $finish;
    end
endmodule

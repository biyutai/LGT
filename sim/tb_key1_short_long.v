`timescale 1ns/1ps
module tb_key1_short_long;
    reg clk = 0;
    always #5 clk = ~clk;
    reg key_n = 1;
    reg pll_locked = 1;
    reg browse_mode = 0;
    wire rst, reset_n, short_toggle, browse_short_toggle, long_toggle, browse_long_toggle;
    key1_short_long #(.DEBOUNCE_CYCLES(3), .LONG_CYCLES(12)) dut (
        .clk(clk), .key_n(key_n), .system_rst(rst), .browse_mode(browse_mode),
        .reset_n(reset_n), .short_toggle(short_toggle),
        .browse_short_toggle(browse_short_toggle), .long_toggle(long_toggle),
        .browse_long_toggle(browse_long_toggle)
    );
    sys_reset #(.HOLD_CYCLES(4)) u_reset (
        .clk(clk), .rst_n(reset_n), .pll_locked(pll_locked), .rst(rst)
    );
    task cycles;
        input integer n;
        integer i;
        begin for (i=0; i<n; i=i+1) @(negedge clk); #1; end
    endtask
    initial begin
        cycles(9);
        if (rst || !reset_n || short_toggle) $fatal(1,"power-on reset must release");
        key_n=0; cycles(1); key_n=1; cycles(7);
        if (!reset_n || short_toggle) $fatal(1,"bounce must be ignored");
        key_n=0; cycles(7); key_n=1; cycles(7);
        if (!reset_n || !short_toggle || rst) $fatal(1,"short KEY1 must change effect once");
        key_n=0; cycles(7); key_n=1; cycles(7);
        if (!reset_n || short_toggle || rst) $fatal(1,"second short KEY1 must change effect once");
        key_n=0; cycles(23);
        if (!reset_n || rst || short_toggle || !long_toggle) $fatal(1,"long KEY1 must select next track without reset");
        key_n=1; cycles(12);
        if (!reset_n || rst || short_toggle || !long_toggle) $fatal(1,"long release must not reset or add a second pulse");
        key_n=0; cycles(7); key_n=1; cycles(7);
        if (!reset_n || rst || !short_toggle) $fatal(1,"short KEY1 must work after a reset");
        browse_mode=1;
        key_n=0; cycles(7); key_n=1; cycles(7);
        if (short_toggle !== 1'b1 || browse_short_toggle !== 1'b1)
            $fatal(1,"browse KEY1 must confirm without changing effect");
        key_n=0; cycles(23); key_n=1; cycles(12);
        if (browse_short_toggle !== 1'b1 || short_toggle !== 1'b1 ||
            long_toggle !== 1'b1 || browse_long_toggle !== 1'b1)
            $fatal(1,"browse long KEY1 must exit browse without advancing playlist");
        browse_mode=0;
        key_n=0; cycles(23); key_n=1; cycles(12);
        if (long_toggle !== 1'b0 || browse_long_toggle !== 1'b1)
            $fatal(1,"normal long KEY1 must still advance the playlist");
        $display("ALL PASSED: KEY1 short effect and long playlist-next");
        $finish;
    end
endmodule

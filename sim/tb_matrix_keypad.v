`timescale 1ns/1ps

module tb_matrix_keypad;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg [15:0] switches = 16'd0;
    wire [3:0] row_drive_low;
    wire [3:0] col_n;
    wire [15:0] keys_down, press_pulse, release_pulse;
    reg [15:0] seen_press = 16'd0;
    reg [15:0] seen_release = 16'd0;
    integer i;

    always #5 clk = ~clk;

    genvar col;
    generate
        for (col = 0; col < 4; col = col + 1) begin: g_cols
            assign col_n[col] = ~((switches[col] && row_drive_low[0]) ||
                                  (switches[col+4] && row_drive_low[1]) ||
                                  (switches[col+8] && row_drive_low[2]) ||
                                  (switches[col+12] && row_drive_low[3]));
        end
    endgenerate

    matrix_keypad #(.CLK_HZ(1000), .ROW_HZ(100), .DEBOUNCE_SCANS(3)) dut (
        .clk(clk), .rst(rst), .col_n(col_n), .row_drive_low(row_drive_low),
        .keys_down(keys_down), .press_pulse(press_pulse),
        .release_pulse(release_pulse)
    );

    always @(posedge clk) begin
        if (!rst) begin
            if (row_drive_low != 4'b0001 && row_drive_low != 4'b0010 &&
                row_drive_low != 4'b0100 && row_drive_low != 4'b1000)
                $fatal(1, "row drive must select exactly one row");
            seen_press <= seen_press | press_pulse;
            seen_release <= seen_release | release_pulse;
        end
    end

    task settle;
        begin
            repeat (170) @(negedge clk);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        settle();
        if (keys_down !== 16'd0) $fatal(1, "idle state must be empty");

        switches[0] = 1'b1;
        repeat (25) @(negedge clk);
        switches[0] = 1'b0;
        settle();
        if (keys_down !== 16'd0) $fatal(1, "short bounce was accepted");

        for (i = 0; i < 16; i = i + 1) begin
            switches[i] = 1'b1;
            settle();
            if (keys_down !== (16'h0001 << i))
                $fatal(1, "S%0d press mapped to %h", i+1, keys_down);
            switches[i] = 1'b0;
            settle();
            if (keys_down !== 16'd0)
                $fatal(1, "S%0d release left %h", i+1, keys_down);
        end
        if (seen_press !== 16'hffff || seen_release !== 16'hffff)
            $fatal(1, "missing press/release events %h/%h", seen_press, seen_release);

        switches[0] = 1'b1;
        switches[4] = 1'b1;
        settle();
        if (keys_down !== 16'h0011)
            $fatal(1, "same-column simultaneous press failed: %h", keys_down);
        switches = 16'd0;
        settle();
        if (keys_down !== 16'd0) $fatal(1, "simultaneous release failed");
        $display("ALL PASSED: 16 keys, debounce, pulses, and simultaneous keys");
        $finish;
    end
endmodule

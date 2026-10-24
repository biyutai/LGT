// 复位与同步模块的自检仿真：sys_reset + rst_sync + sync_2ff
// 运行：sim/run.sh tb_reset
`timescale 1ns / 1ps

module tb_reset;

localparam integer HOLD = 20;      // 仿真里把 20ms 缩成 20 个周期

reg  clk   = 1'b0;                 // 50MHz
reg  clk_v = 1'b0;                 // 25MHz，模拟另一个时钟域
reg  rst_n = 1'b1;
reg  pll_locked = 1'b0;
reg  d = 1'b0;

wire rst_sys;
wire rst_v;
wire q;

always #10 clk   = ~clk;
always #20 clk_v = ~clk_v;

sys_reset #(.HOLD_CYCLES(HOLD)) dut_por (
    .clk        (clk),
    .rst_n      (rst_n),
    .pll_locked (pll_locked),
    .rst        (rst_sys)
);

rst_sync dut_rs (
    .clk  (clk_v),
    .arst (rst_sys),
    .srst (rst_v)
);

sync_2ff dut_s2 (
    .clk (clk_v),
    .rst (rst_v),
    .d   (d),
    .q   (q)
);

integer errors = 0;
integer n;

task check(input cond, input [8*64-1:0] msg);
    begin
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s  (t=%0t)", msg, $time); errors = errors + 1; end
    end
endtask

// 统计 rst_sys 在 pll_locked 之后多少个 clk 周期释放
task count_release(output integer cycles);
    begin
        cycles = 0;
        while (rst_sys && cycles < 10 * HOLD) begin
            @(posedge clk); cycles = cycles + 1;
        end
    end
endtask

initial begin
    $display("== 1. power-up: hold reset while PLLs unlocked");
    #1;
    check(rst_sys === 1'b1, "rst_sys = 1 at power-up");
    check(rst_v   === 1'b1, "rst_v = 1 at power-up");
    repeat (5 * HOLD) @(posedge clk);
    check(rst_sys === 1'b1, "still in reset after 5*HOLD without lock");

    $display("== 2. release HOLD cycles after lock");
    @(negedge clk) pll_locked = 1'b1;
    count_release(n);
    $display("        released %0d clk cycles after lock", n);
    check(n >= HOLD && n <= HOLD + 2, "release time = HOLD (+2)");

    $display("== 3. rst_sync: deassert on 3rd edge of local clock");
    check(rst_v === 1'b1, "rst_v still 1 right after rst_sys falls");
    repeat (2) @(posedge clk_v); #1;
    check(rst_v === 1'b1, "rst_v still 1 after 2nd clk_v edge");
    @(posedge clk_v); #1;
    check(rst_v === 1'b0, "rst_v = 0 after 3rd clk_v edge");

    $display("== 4. lock glitch after release is ignored");
    @(negedge clk) pll_locked = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk) pll_locked = 1'b1;
    repeat (5) @(posedge clk); #1;
    check(rst_sys === 1'b0, "rst_sys stays 0 after lock glitch");

    $display("== 5. sync_2ff: 2-cycle latency");
    @(negedge clk_v) d = 1'b1;
    @(posedge clk_v); #1;
    check(q === 1'b0, "q still 0 after 1 cycle");
    @(posedge clk_v); #1;
    check(q === 1'b1, "q = 1 after 2 cycles");
    @(negedge clk_v) d = 1'b0;
    repeat (2) @(posedge clk_v); #1;
    check(q === 1'b0, "q = 0 two cycles after d falls");

    $display("== 6. KEY1 press: reset now, recount after release");
    @(negedge clk) rst_n = 1'b0;
    repeat (3) @(posedge clk); #1;
    check(rst_sys === 1'b1, "rst_sys = 1 within 3 cycles of press");
    check(rst_v   === 1'b1, "rst_v follows immediately (async assert)");
    repeat (10 * HOLD) @(posedge clk);
    check(rst_sys === 1'b1, "stays in reset while held");
    @(negedge clk) rst_n = 1'b1;
    count_release(n);
    $display("        released %0d clk cycles after key release", n);
    check(n >= HOLD + 2 && n <= HOLD + 4, "release time = 2 sync + HOLD (+2)");

    $display("== 7. lock lost while counting: counter restarts");
    @(negedge clk) rst_n = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk) rst_n = 1'b1;
    repeat (HOLD / 2) @(posedge clk);
    @(negedge clk) pll_locked = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk) pll_locked = 1'b1;
    count_release(n);
    $display("        released %0d clk cycles after re-lock", n);
    check(n >= HOLD && n <= HOLD + 2, "full HOLD recounted after lock loss");

    $display("");
    if (errors == 0) $display("== ALL PASSED");
    else             $display("== %0d FAILED", errors);
    $finish;
end

initial begin
    #1_000_000;
    $display("== TIMEOUT");
    $finish;
end

endmodule

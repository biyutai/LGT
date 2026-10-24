// wav_player 自检：正常播放、读空计数、active 之前不计
// 用一个数组模拟音频 FIFO（pop 后下一拍出数据，与 rfifo_32_32_512 非预读模式相同）
// 运行：sim/run.sh tb_wav_player
`timescale 1ns / 1ps

module tb_wav_player;

reg clk = 1'b0;
reg rst = 1'b1;
always #20 clk = ~clk;                       // 25MHz

reg  tick = 1'b0;
reg  active = 1'b0;
wire pop;
reg  [31:0] fifo [0:1023];
integer     rd = 0, wr = 0;
reg  [31:0] data = 32'd0;
wire        empty = (rd == wr);
wire        valid;
wire [23:0] left, right;
wire [7:0]  underrun_cnt;

wav_player dut (
    .clk (clk), .rst (rst), .sample_tick (tick), .active (active),
    .pop (pop), .data (data), .empty (empty),
    .audio_valid (valid), .audio_left (left), .audio_right (right),
    .underrun_cnt (underrun_cnt)
);

always @(posedge clk) if (pop) begin data <= fifo[rd]; rd = rd + 1; end

integer errors = 0;
task check(input cond, input [8*64-1:0] msg);
    begin
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s  (t=%0t)", msg, $time); errors = errors + 1; end
    end
endtask

// 推 n 个平滑样本：左声道从 v 起每个 +100，右声道从 r 起每个 -200
task push_smooth(input integer n, input integer v, input integer r);
    integer i;
    begin
        for (i = 0; i < n; i = i + 1) begin
            fifo[wr] = {v[15:0] + i[15:0] * 16'd100, r[15:0] - i[15:0] * 16'd200};
            wr = wr + 1;
        end
    end
endtask

task ticks(input integer n);
    integer i;
    begin
        for (i = 0; i < n; i = i + 1) begin
            @(posedge clk) tick <= 1'b1;
            @(posedge clk) tick <= 1'b0;
            repeat (8) @(posedge clk);
        end
    end
endtask

integer outs = 0;
reg [23:0] last_left = 24'd0;
always @(posedge clk) if (valid) begin outs = outs + 1; last_left = left; end

initial begin
    repeat (5) @(posedge clk);
    rst <= 1'b0;

    $display("== 1. before active: underruns are not counted");
    ticks(5);                                         // FIFO 空
    check(underrun_cnt == 0, "counter stays 0 while active = 0");

    $display("== 2. smooth playback after active");
    active = 1'b1;
    push_smooth(50, 1000, 0);                         // 最后一个：左 5900，右 -9800
    ticks(50);
    check(underrun_cnt == 0, "50 smooth samples: no underrun");
    check(last_left == {16'd1000 + 16'd4900, 8'd0}, "last output = sample 49 << 8");

    $display("== 3. FIFO runs dry for 3 ticks");
    ticks(3);
    check(underrun_cnt == 3, "underrun_cnt = 3");
    check(left == 24'd0 && right == 24'd0, "silence output while empty");

    $display("== 4. active drops: counter keeps value, restart after re-arm");
    active = 1'b0;
    ticks(4);
    check(underrun_cnt == 3, "counter frozen while inactive");

    $display("");
    if (errors == 0) $display("== ALL PASSED");
    else             $display("== %0d FAILED", errors);
    $finish;
end

endmodule

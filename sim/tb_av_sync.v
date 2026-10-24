// av_sync 单元测试：节拍位置、每轮节拍数、读空不计数、不提前的情况、误差测量的符号与大小、超时
// 运行：sim/run.sh tb_av_sync
`timescale 1ns / 1ps

module tb_av_sync;

reg clk = 1'b0;
always #20 clk = ~clk;
reg rst = 1'b1;

reg         active = 1'b0;
reg  [20:0] words = 21'd0;
reg  [2:0]  img_count = 3'd0;
reg         played = 1'b0;
reg         sof = 1'b0;
reg  [1:0]  frame_buf = 2'd0;
wire        beat_toggle;
wire [20:0] segment_samples;
wire [7:0]  beat_cnt, meas_cnt;
wire signed [23:0] err_last;
wire [23:0] err_max_abs;

localparam integer LEAD = 50;

av_sync #(.LEAD_SAMPLES(LEAD), .MEAS_TIMEOUT(5000)) dut (
    .clk (clk), .rst (rst), .active (active), .words (words), .img_count (img_count), .played (played),
    .beat_toggle (beat_toggle), .beat_cnt (beat_cnt),
    .segment_samples(segment_samples),
    .sof (sof), .frame_buf (frame_buf), .err_last (err_last), .err_max_abs (err_max_abs), .meas_cnt (meas_cnt)
);

integer errors = 0;
task check(input cond, input [8*72-1:0] msg);
    begin
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s  (t=%0t)", msg, $time); errors = errors + 1; end
    end
endtask

// 记录每个节拍发生时正在送出的样本位置
integer fire_pos [0:63];
integer n_fire = 0;
integer pos_model = 0;                 // 测试平台自己数的播放位置
integer pos_model_at_play = 0;         // 最近一个送出样本的位置
reg     p_tgl = 1'b0;
always @(posedge clk) begin
    if (beat_toggle != p_tgl) begin
        if (n_fire < 64) fire_pos[n_fire] = pos_model_at_play;
        n_fire = n_fire + 1;
    end
    p_tgl = beat_toggle;
end

// 送出一个样本（played 一拍），位置 +1，循环
task play_one;
    begin
        @(posedge clk) begin played <= 1'b1; end
        pos_model_at_play = pos_model;
        @(posedge clk) played <= 1'b0;
        pos_model = (pos_model + 1) % words;
        repeat (3) @(posedge clk);
    end
endtask

task start(input integer w, input integer n);
    begin
        @(posedge clk) active <= 1'b0;
        repeat (5) @(posedge clk);
        words = w; img_count = n;
        n_fire = 0; pos_model = 0;
        @(posedge clk) active <= 1'b1;
        repeat (30) @(posedge clk);           // 等除法算完（21 拍）
    end
endtask

task play(input integer n);
    integer i;
    begin for (i = 0; i < n; i = i + 1) play_one; end
endtask

// 期望的触发位置：对齐点 SEG..(N-1)SEG 和 words，减 lead，words 处的取模 0
function integer exp_trig(input integer w, input integer n, input integer lead, input integer k);  // k = 1..n
    integer seg, b;
    begin
        seg = w / n;
        b = (k == n) ? w : k * seg;
        exp_trig = (b - lead) % w;
    end
endfunction

task check_fires(input integer w, input integer n, input integer lead, input integer loops, input [8*48-1:0] name);
    integer i, bad;
    begin
        bad = 0;
        for (i = 0; i < n * loops && i < 64; i = i + 1)
            if (fire_pos[i] != exp_trig(w, n, lead, (i % n) + 1)) begin
                if (bad < 3) $display("        beat %0d at pos %0d, expected %0d", i, fire_pos[i], exp_trig(w, n, lead, (i % n) + 1));
                bad = bad + 1;
            end
        check(n_fire == n * loops && bad == 0, name);
    end
endtask

initial begin
    repeat (5) @(posedge clk);
    rst <= 1'b0;

    $display("== 1. words 1000, 3 images: SEG 333, beats at 283 / 616 / 950 each loop");
    start(1000, 3);
    check(dut.seg == 333 && segment_samples == 333 && dut.lead == LEAD,
          "SEG = 333 exported to LED breath, lead = 50");
    play(3000);
    $display("        beats: %0d at %0d %0d %0d %0d ...", n_fire, fire_pos[0], fire_pos[1], fire_pos[2], fire_pos[3]);
    check_fires(1000, 3, LEAD, 3, "9 beats in 3 loops, all at the right positions");

    $display("== 2. words 1024, 4 images: SEG 256");
    start(1024, 4);
    play(2048);
    check_fires(1024, 4, LEAD, 2, "8 beats in 2 loops at 206 / 462 / 718 / 974");

    $display("== 3. words 600, 2 images: SEG 300");
    start(600, 2);
    play(1800);
    check_fires(600, 2, LEAD, 3, "6 beats in 3 loops at 250 / 550");

    $display("== 4. short segments (SEG <= 2*lead): no lead, beats exactly on boundaries, loop boundary at 0");
    start(300, 4);                            // SEG 75 <= 100
    check(dut.lead == 0, "lead = 0");
    play(601);                                // 第 2 轮结尾那个节拍在下一轮的第 0 个样本
    check_fires(300, 4, 0, 2, "8 beats at 75 / 150 / 225 / 0");

    $display("== 5. one image: no beats");
    start(1000, 1);
    play(2000);
    check(n_fire == 0, "no beat with 1 image");

    $display("== 6. underrun: tick without a sample does not advance position");
    start(1000, 3);
    play(200);
    repeat (5000) @(posedge clk);             // 很久没有 played
    play(100);                                // 位置 300，越过 283
    check(n_fire == 1 && fire_pos[0] == 283, "first beat still at sample 283");

    $display("== 7. measurement: video switch 1234 cycles after the boundary sample");
    start(1000, 3);
    frame_buf = 2'd0;
    @(posedge clk) sof <= 1'b1; @(posedge clk) sof <= 1'b0;     // 先让它记下当前缓冲
    play(283);                                // 送到 282
    play_one;                                 // 283：节拍
    begin : m7
        integer k, t_bnd;
        for (k = 284; k < 333; k = k + 1) play_one;     // 送到 332
        @(posedge clk) played <= 1'b1;        // 333：对齐点样本
        pos_model_at_play = pos_model;
        @(posedge clk) played <= 1'b0;
        pos_model = pos_model + 1;
        t_bnd = $time;
        repeat (1233) @(posedge clk);
        frame_buf = 2'd1;
        sof <= 1'b1; @(posedge clk) sof <= 1'b0;
        repeat (10) @(posedge clk);
    end
    $display("        err_last = %0d, max = %0d, meas_cnt = %0d", err_last, err_max_abs, meas_cnt);
    check(err_last == 1234 && err_max_abs == 1234 && meas_cnt == 1, "err = +1234 cycles (video late)");

    $display("== 8. video switch before the boundary sample: negative error");
    begin : m8
        integer k;
        for (k = 334; k < 616; k = k + 1) play_one;     // 送到 615
        play_one;                             // 616：节拍
        repeat (10) @(posedge clk);
        frame_buf = 2'd0;
        sof <= 1'b1; @(posedge clk) sof <= 1'b0;        // 画面先换
        repeat (100) @(posedge clk);
        for (k = 617; k < 667; k = k + 1) play_one;     // 送过对齐点 666
    end
    $display("        err_last = %0d, max = %0d, meas_cnt = %0d", err_last, err_max_abs, meas_cnt);
    check(err_last < 0 && meas_cnt == 2, "err < 0 (video early)");
    check(err_max_abs == 1234 || err_max_abs == -err_last, "max |err| tracks the larger one");

    $display("== 9. no video switch: measurement times out, nothing recorded");
    begin : m9
        integer k;
        for (k = 667; k < 1000; k = k + 1) play_one;   // 节拍 950，对齐点 0（下一轮开头）
        play(10);
        repeat (6000) @(posedge clk);
    end
    check(meas_cnt == 2 && !dut.armed, "timed out, meas_cnt still 2");

    $display("== 10. active low: everything resets");
    @(posedge clk) active <= 1'b0;
    repeat (5) @(posedge clk);
    check(meas_cnt == 0 && err_max_abs == 0 && beat_cnt == 0 && dut.pos == 0, "counters cleared");

    $display("");
    if (errors == 0) $display("== ALL PASSED");
    else             $display("== %0d FAILED", errors);
    $finish;
end

endmodule

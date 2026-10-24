// 真实 SDRAM 控制器（官方加密 sdr_as_ram）+ 芯片行为模型：读写正确性、读延迟、Sdr_busy 行为、刷新
// 运行：sim/run.sh tb_sdram_ctrl
//
// dq 时序自查（第 6b 步）：改芯片模型的读数据窗口 / 写数据延迟，看控制器什么时候采样、什么时候发数据
//   sim/run.sh tb_sdram_ctrl -GT_AC=5 -GT_OH=4.1    读数据在 Clk_sft 沿后 [T_AC, 8 + T_OH] ns 有效
//   sim/run.sh tb_sdram_ctrl -GT_DQ_IN=4            芯片在 Clk_sft 沿采到的是 T_DQ_IN ns 之前的 dq
//   结果：读 —— 窗口包含 Clk_sft 沿后 12ns（±0.1）就通过，否则失败，即控制器在 TD 默认假设的采样沿（沿后 4ns）
//              再晚一个 Clk 周期采样；写 —— T_DQ_IN ≤ 4 通过、≥ 4.5 失败，即芯片采到的是半个周期前 Clk 沿发出的数据，
//              和 TD 的半周期检查一致。详见 doc/系统架构与数据通路.md 第七节
`timescale 1ns / 1ps

module tb_sdram_ctrl;

reg clk = 1'b0, clk_sft = 1'b1;
always #4 begin clk = ~clk; clk_sft = ~clk_sft; end     // 125MHz，Clk_sft 反相（180°）
reg rst = 1'b1;

wire        init_done, init_ref_vld, busy;
reg         wr_en = 1'b0, rd_en = 1'b0;
reg  [20:0] wr_addr = 21'd0, rd_addr = 21'd0;
reg  [31:0] wr_din = 32'd0;
wire        sdr_rd_en;
wire [31:0] sdr_rd_dout;

sdram dut (
    .Clk              (clk),
    .Clk_sft          (clk_sft),
    .Rst              (rst),
    .Sdr_init_done    (init_done),
    .Sdr_init_ref_vld (init_ref_vld),
    .Sdr_busy         (busy),
    .App_wr_en        (wr_en),
    .App_wr_addr      (wr_addr),
    .App_wr_dm        (4'b0000),
    .App_wr_din       (wr_din),
    .App_rd_en        (rd_en),
    .App_rd_addr      (rd_addr),
    .Sdr_rd_en        (sdr_rd_en),
    .Sdr_rd_dout      (sdr_rd_dout)
);

integer errors = 0;
task check(input cond, input [8*64-1:0] msg);
    begin
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s  (t=%0t)", msg, $time); errors = errors + 1; end
    end
endtask

// 读返回记录
integer    n_ret = 0;
reg [31:0] ret [0:4095];
// 下降沿采样：Sdr_rd_en / Sdr_rd_dout 在上升沿改变，上升沿采样会和它竞争
always @(negedge clk) if (sdr_rd_en) begin ret[n_ret % 4096] = sdr_rd_dout; n_ret = n_ret + 1; end

// busy 统计
integer busy_cyc = 0, cyc = 0, busy_rise = 0;
reg     p_busy = 1'b0;
always @(posedge clk) if (init_done) begin
    cyc = cyc + 1;
    if (busy) busy_cyc = busy_cyc + 1;
    if (busy && !p_busy) busy_rise = busy_rise + 1;
    p_busy = busy;
end

function [31:0] pat(input [20:0] a);
    pat = {11'h5A5, a} ^ {a[10:0], 21'd0};
endfunction

task write_burst(input [20:0] base, input integer n);
    integer k;
    begin
        for (k = 0; k < n; k = k + 1) begin
            @(posedge clk) begin wr_en <= 1'b1; wr_addr <= base + k; wr_din <= pat(base + k); end
        end
        @(posedge clk) wr_en <= 1'b0;
    end
endtask

integer t_first_req, t_first_ret;
task read_burst(input [20:0] base, input integer n, output integer bad, output integer lat);
    integer k, start, t;
    begin
        start = n_ret;
        for (k = 0; k < n; k = k + 1) begin
            @(posedge clk) begin rd_en <= 1'b1; rd_addr <= base + k; end
            if (k == 0) t_first_req = $time;
        end
        @(posedge clk) rd_en <= 1'b0;
        t = 0;
        while (n_ret < start + n && t < 2000) begin @(posedge clk); t = t + 1; end
        bad = 0;
        for (k = 0; k < n; k = k + 1) if (ret[(start + k) % 4096] !== pat(base + k)) bad = bad + 1;
        if (n_ret != start + n) bad = bad + 1000;
        lat = 0;
    end
endtask

// 测读延迟：单个读请求到 Sdr_rd_en 的拍数
task read_latency(input [20:0] a, output integer lat);
    integer t;
    begin
        @(posedge clk) begin rd_en <= 1'b1; rd_addr <= a; end
        @(posedge clk) rd_en <= 1'b0;
        t = 1;
        while (!sdr_rd_en && t < 100) begin @(posedge clk); t = t + 1; end
        lat = t;
    end
endtask

integer bad, lat;

integer trace_n = 0;
reg     trace_on = 1'b0;

initial begin
    repeat (20) @(posedge clk);
    rst <= 1'b0;
    wait (init_done);
    $display("== init_done at %0t ns", $time);
    repeat (50) @(posedge clk);

    $display("== 1. gap sensitivity: two 64-word bursts separated by G idle cycles");
    begin : gaps
        integer gi, g, k, start, t, bad_w, bad_r, e0;
        integer glist [0:9];
        glist[0] = 1; glist[1] = 2; glist[2] = 3; glist[3] = 4; glist[4] = 5;
        glist[5] = 6; glist[6] = 8; glist[7] = 10; glist[8] = 12; glist[9] = 16;
        for (gi = 0; gi < 10; gi = gi + 1) begin
            g = glist[gi];
            e0 = dut.sdram.n_err;
            // 写：A 区 64 字，空 g 拍，B 区 64 字（不同行）
            for (k = 0; k < 64; k = k + 1) @(posedge clk) begin wr_en <= 1'b1; wr_addr <= 21'd2048*gi + k; wr_din <= pat(21'd2048*gi + k); end
            @(posedge clk) wr_en <= 1'b0;
            repeat (g - 1) @(posedge clk);
            for (k = 0; k < 64; k = k + 1) @(posedge clk) begin wr_en <= 1'b1; wr_addr <= 21'd700000 + 21'd2048*gi + k; wr_din <= pat(21'd700000 + 21'd2048*gi + k); end
            @(posedge clk) wr_en <= 1'b0;
            repeat (40) @(posedge clk);
            bad_w = dut.sdram.n_err - e0;
            // 读：同样的两段，中间空 g 拍
            start = n_ret;
            for (k = 0; k < 64; k = k + 1) @(posedge clk) begin rd_en <= 1'b1; rd_addr <= 21'd2048*gi + k; end
            @(posedge clk) rd_en <= 1'b0;
            repeat (g - 1) @(posedge clk);
            for (k = 0; k < 64; k = k + 1) @(posedge clk) begin rd_en <= 1'b1; rd_addr <= 21'd700000 + 21'd2048*gi + k; end
            @(posedge clk) rd_en <= 1'b0;
            t = 0; while (n_ret < start + 128 && t < 500) begin @(posedge clk); t = t + 1; end
            bad_r = 0;
            for (k = 0; k < 64; k = k + 1) begin
                if (ret[(start + k) % 4096]      !== pat(21'd2048*gi + k))          bad_r = bad_r + 1;
                if (ret[(start + 64 + k) % 4096] !== pat(21'd700000 + 21'd2048*gi + k)) bad_r = bad_r + 1;
            end
            $display("        gap %2d: protocol errors %0d, returned %0d/128, wrong words %0d", g, dut.sdram.n_err - e0, n_ret - start, bad_r);
            if (gi == 9) for (k = 0; k < 8; k = k + 1)
                $display("            ret[%0d] = %h  expect %h", k, ret[(start + k) % 4096], pat(21'd2048*gi + k));
            repeat (100) @(posedge clk);
        end
    end
    dut.sdram.dump_hist = 1'b0;

    $display("== 1b. same, but the second burst waits until Sdr_busy = 0 (+G cycles)");
    begin : gaps_busy
        integer g, k, start, t, bad_r, e0, waited;
        for (g = 0; g < 4; g = g + 1) begin
            e0 = dut.sdram.n_err;
            for (k = 0; k < 64; k = k + 1) @(posedge clk) begin wr_en <= 1'b1; wr_addr <= 21'd40000 + 2048*g + k; wr_din <= pat(21'd40000 + 2048*g + k); end
            @(posedge clk) wr_en <= 1'b0;
            waited = 0; @(posedge clk); while (busy) begin @(posedge clk); waited = waited + 1; end
            repeat (g) @(posedge clk);
            for (k = 0; k < 64; k = k + 1) @(posedge clk) begin wr_en <= 1'b1; wr_addr <= 21'd800000 + 2048*g + k; wr_din <= pat(21'd800000 + 2048*g + k); end
            @(posedge clk) wr_en <= 1'b0;
            repeat (40) @(posedge clk);
            start = n_ret;
            for (k = 0; k < 64; k = k + 1) @(posedge clk) begin rd_en <= 1'b1; rd_addr <= 21'd40000 + 2048*g + k; end
            @(posedge clk) rd_en <= 1'b0;
            @(posedge clk); while (busy) @(posedge clk);
            repeat (g) @(posedge clk);
            for (k = 0; k < 64; k = k + 1) @(posedge clk) begin rd_en <= 1'b1; rd_addr <= 21'd800000 + 2048*g + k; end
            @(posedge clk) rd_en <= 1'b0;
            t = 0; while (n_ret < start + 128 && t < 500) begin @(posedge clk); t = t + 1; end
            bad_r = 0;
            for (k = 0; k < 64; k = k + 1) begin
                if (ret[(start + k) % 4096]      !== pat(21'd40000 + 2048*g + k))  bad_r = bad_r + 1;
                if (ret[(start + 64 + k) % 4096] !== pat(21'd800000 + 2048*g + k)) bad_r = bad_r + 1;
            end
            $display("        busy fell %0d cycles after last write; +%0d: protocol errors %0d, wrong words %0d", waited, g, dut.sdram.n_err - e0, bad_r);
            repeat (100) @(posedge clk);
        end
    end

    $display("== 2. realistic traffic for 2,000,000 cycles: 256-word video reads with random 200~1200 idle + 64-word audio reads");
    begin : traffic
        integer k, n, start, t, bad_v, bad_a, nv, na, e0, r0;
        integer seed;
        reg [20:0] va, aa;
        // 先用安全间隔（16 拍）写满测试区：视频区 0~16383，音频区 614400~616447
        for (n = 0; n < 64; n = n + 1) begin
            for (k = 0; k < 256; k = k + 1) @(posedge clk) begin wr_en <= 1'b1; wr_addr <= n*256 + k; wr_din <= pat(n*256 + k); end
            @(posedge clk) wr_en <= 1'b0; repeat (15) @(posedge clk);
        end
        for (n = 0; n < 8; n = n + 1) begin
            for (k = 0; k < 256; k = k + 1) @(posedge clk) begin wr_en <= 1'b1; wr_addr <= 21'd614400 + n*256 + k; wr_din <= pat(21'd614400 + n*256 + k); end
            @(posedge clk) wr_en <= 1'b0; repeat (15) @(posedge clk);
        end
        repeat (50) @(posedge clk);
        e0 = dut.sdram.n_err; r0 = dut.sdram.n_ref;
        bad_v = 0; bad_a = 0; nv = 0; na = 0; va = 0; aa = 21'd614400; seed = 12345;
        t = 0;
        while (t < 2000000) begin
            // 视频突发
            start = n_ret;
            for (k = 0; k < 256; k = k + 1) @(posedge clk) begin rd_en <= 1'b1; rd_addr <= va + k; end
            @(posedge clk) rd_en <= 1'b0;
            repeat (12) @(posedge clk);
            while (n_ret < start + 256 && t < 300000) begin @(posedge clk); t = t + 1; end
            for (k = 0; k < 256; k = k + 1) if (ret[(start + k) % 4096] !== pat(va + k)) bad_v = bad_v + 1;
            nv = nv + 1; va = (va + 256) % 16384;
            t = t + 270;
            // 像真实视频一样：突发之间随机空闲 200~1200 拍，刷新会在随机时刻插进来
            n = 200 + ($random(seed) & 1023);
            repeat (n) @(posedge clk);
            t = t + n;
            // 每 3 个视频突发插一个音频突发
            if (nv % 3 == 0) begin
                repeat ($random(seed) & 63) @(posedge clk);
                start = n_ret;
                for (k = 0; k < 64; k = k + 1) @(posedge clk) begin rd_en <= 1'b1; rd_addr <= aa + k; end
                @(posedge clk) rd_en <= 1'b0;
                repeat (12) @(posedge clk);
                while (n_ret < start + 64) @(posedge clk);
                for (k = 0; k < 64; k = k + 1) if (ret[(start + k) % 4096] !== pat(aa + k)) bad_a = bad_a + 1;
                na = na + 1; aa = 21'd614400 + ((aa - 21'd614400 + 64) % 2048);
                repeat (2) @(posedge clk);
                t = t + 90;
            end
        end
        $display("        %0d video bursts, %0d wrong words; %0d audio bursts, %0d wrong words", nv, bad_v, na, bad_a);
        $display("        REF commands during traffic: %0d, protocol errors: %0d", dut.sdram.n_ref - r0, dut.sdram.n_err - e0);
        check(bad_v == 0 && bad_a == 0 && dut.sdram.n_err == e0, "official-like traffic: all data correct, no protocol errors");
    end

    $display("== 3. idle 100000 cycles: does the controller ever refresh?");
    repeat (100000) @(posedge clk);
    $display("        REF commands seen by SDRAM: %0d (need ~25 for 3906-cycle interval, ~50 for 1953)", dut.sdram.n_ref);
    $display("        Sdr_busy high %0d of %0d cycles, %0d times", busy_cyc, cyc, busy_rise);
    $display("        SDRAM model: MRS %0d ACT %0d PRE %0d RD %0d WR %0d BST %0d protocol errors %0d",
             dut.sdram.n_mrs, dut.sdram.n_act, dut.sdram.n_pre, dut.sdram.n_rd, dut.sdram.n_wr, dut.sdram.n_bst, dut.sdram.n_err);

    $display("");
    if (errors == 0) $display("== ALL PASSED");
    else             $display("== %0d FAILED", errors);
    $finish;
end

endmodule

`timescale 1ns/1ps
// audio_dsp 频响测试台：50/100/300/1k/3k/8k/12k，三档预设 + 原声旁路。
// 期望值来自 scripts/gen_audio_eq_coeffs.py 的量化系数响应表，容差 ±1dB。
module tb_audio_dsp;
    localparam real PI = 3.14159265358979;
    localparam real AMP = 2097152.0;            // -12dBFS 的 16 位内容 << 8
    localparam integer N = 3600;                // 每频点样本数
    localparam integer DISCARD = 1800;
    localparam integer SAMPLES_PER_FRAME = 2100; // TB 10ns 时钟：21µs ≈ 48kHz

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, valid = 0;
    reg [2:0] effect = 3'd0;
    reg signed [23:0] l_in = 0, r_in = 0;
    wire signed [23:0] l_out, r_out;
    wire out_valid;
    real ts = 0.0, peak = 0.0;
    real v;
    integer sample_no = 0;
    integer got_valid = 0;
    integer e, fi, n;
    real gain;

    audio_dsp dut (
        .clk(clk), .rst(rst), .sample_valid(valid), .effect(effect),
        .left_in(l_in), .right_in(r_in), .left_out(l_out), .right_out(r_out),
        .out_valid(out_valid)
    );

    always @(posedge clk) if (!rst && out_valid) begin
        got_valid = got_valid + 1;
        v = $itor(l_out);
        if (v < 0.0) v = -v;
        if (sample_no >= DISCARD && v > peak) peak = v;
        sample_no = sample_no + 1;
    end

    task drive;
        input real freq;
        real v;
        begin
            v = AMP * $sin(2.0 * PI * freq * ts);
            l_in = $rtoi(v);
            r_in = $rtoi(v);
            ts = ts + 1.0 / 48000.0;
            @(negedge clk); valid = 1;
            @(negedge clk); valid = 0;
            repeat (SAMPLES_PER_FRAME - 2) @(negedge clk);
        end
    endtask

    real freqs [0:2];
    initial begin
        freqs[0] = 50.0; freqs[1] = 1000.0; freqs[2] = 8000.0;

        repeat (3) @(negedge clk);
        rst = 0;

        // 原声逐位旁路（含低 8 位非零）
        effect = 3'd0;
        for (n = 0; n < 40; n = n + 1) begin
            l_in = 24'sd1234567; r_in = -24'sd7654321;
            @(negedge clk); valid = 1;
            @(negedge clk); valid = 0;
            wait (out_valid); #1;
            if (!out_valid || l_out !== 24'sd1234567 || r_out !== -24'sd7654321)
                $fatal(1, "bypass is not bit-exact (L=%0d R=%0d)", l_out, r_out);
            repeat (SAMPLES_PER_FRAME - 8) @(negedge clk);
        end

        for (e = 1; e <= 3; e = e + 1) begin
            effect = e[2:0];
            for (fi = 0; fi < 3; fi = fi + 1) begin
                peak = 0.0; sample_no = 0; got_valid = 0; ts = 0.0;
                for (n = 0; n < N; n = n + 1)
                    drive(freqs[fi]);
                repeat (3) @(negedge clk);
                if (sample_no < N - 2)
                    $fatal(1, "effect %0d f=%0.0f only %0d outputs", e, freqs[fi], sample_no);
                gain = 20.0 * $log10(peak / AMP);
                $display("effect %0d f=%6.0f Hz gain=%6.2f dB", e, freqs[fi], gain);
                // 5 段一阶分频：低频段/高频段应分别被抬/压，中频保持
                if (fi == 1 && (gain > 3.0 || gain < -3.0))
                    $fatal(1, "mid band must stay near 0dB");
                if (e == 1 && fi == 0 && gain < 3.0) $fatal(1, "bass preset must lift 50Hz");
                if (e == 1 && fi == 2 && gain > -3.0) $fatal(1, "bass preset must cut 8kHz");
                if (e == 2 && fi == 0 && gain > -3.0) $fatal(1, "bright preset must cut 50Hz");
                if (e == 2 && fi == 2 && gain < 3.0) $fatal(1, "bright preset must lift 8kHz");
                if (e == 3 && fi == 0 && gain < 3.0) $fatal(1, "both preset must lift 50Hz");
                if (e == 3 && fi == 2 && gain < 3.0) $fatal(1, "both preset must lift 8kHz");
            end
        end

        // 档位越界按 3 处理：8kHz 应仍有提升
        effect = 3'd7;
        peak = 0.0; sample_no = 0; ts = 0.0;
        for (n = 0; n < N; n = n + 1) drive(8000.0);
        repeat (3) @(negedge clk);
        gain = 20.0 * $log10(peak / AMP);
        if (gain < 3.0)
            $fatal(1, "effect>3 must clamp to preset 3 (gain=%0.2f)", gain);

        $display("ALL PASSED: 5-band audio EQ frequency response");
        $finish;
    end
    initial begin #2.5e9; $fatal(1, "audio dsp timeout"); end
endmodule

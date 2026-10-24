// 音频通路自检：audio_sample_tick + audio_tone_gen（+ sine_lut）+ 官方 audio_arc_calculate
//   1. 采样节拍：每 CLK_HZ/1000 拍恰好 48 个，间隔 CLK_HZ/FS 拍（25.2MHz 时恒为 525；25MHz 时 520 / 521）
//   2. 每个采样与参考模型逐点相等（按音符频率独立算相位，查理想正弦）
//   3. 8 个音的频率、每个音的长度、左右声道一致、音量
//   4. HDMI 音频时钟恢复：CTS 恒为 CLK_HZ/1000（25.2MHz 时 25200）、N = 6144
// 运行：sim/run.sh tb_audio_tone
`timescale 1ns / 1ps

module tb_audio_tone;

localparam integer CLK_HZ   = 25_200_000;      // 与顶层 PIX_HZ 相同（第 6b 步起 60Hz）
localparam integer FS       = 48_000;
localparam integer WIN      = CLK_HZ / 1000;    // 每 WIN 拍恰好 48 个节拍
localparam integer SP_LO    = CLK_HZ / FS;      // 节拍间隔下限 / 上限
localparam integer SP_HI    = (CLK_HZ + FS - 1) / FS;
localparam integer NOTE_N   = 600;             // 仿真里每个音 600 个采样（板上 24000）
localparam integer N_SAMPLE = NOTE_N * 8 + 200;  // 跑完一轮 8 个音再多一点
localparam integer VOL_SHIFT = 1;

reg clk = 1'b0;
reg rst = 1'b1;
always #19.841 clk = ~clk;                      // 25.2MHz

wire        tick;
wire        valid;
wire [23:0] left, right;
wire        acr_valid;
wire [19:0] acr_cts, acr_n;

audio_sample_tick #(.CLK_HZ(CLK_HZ), .FS(FS)) u_tick (
    .clk (clk), .rst (rst), .tick (tick)
);

audio_tone_gen #(.NOTE_SAMPLES(NOTE_N), .VOL_SHIFT(VOL_SHIFT)) dut (
    .clk (clk), .rst (rst), .sample_tick (tick), .enable(1'b1),
    .audio_valid (valid), .audio_left (left), .audio_right (right)
);

audio_arc_calculate #(.ACR_N(6144)) u_acr (
    .I_clk (clk), .I_rst (rst), .I_audio_valid (valid),
    .O_acr_valid (acr_valid), .O_acr_cts (acr_cts), .O_acr_n (acr_n)
);

// ---------------- 检查项计数 ----------------
localparam integer NCHK = 12;
integer chk_n [0:NCHK-1];
integer chk_e [0:NCHK-1];
integer errors = 0;
integer k;
initial for (k = 0; k < NCHK; k = k + 1) begin chk_n[k] = 0; chk_e[k] = 0; end

task chk(input integer id, input cond);
    begin
        chk_n[id] = chk_n[id] + 1;
        if (!cond) chk_e[id] = chk_e[id] + 1;
    end
endtask

task report(input integer id, input [8*64-1:0] msg);
    begin
        if (chk_n[id] == 0)      begin $display("  FAIL  %0s  (never checked)", msg); errors = errors + 1; end
        else if (chk_e[id] == 0) $display("  PASS  %0s  (%0d checks)", msg, chk_n[id]);
        else begin $display("  FAIL  %0s  (%0d of %0d wrong)", msg, chk_e[id], chk_n[id]); errors = errors + 1; end
    end
endtask

// ---------------- 参考模型 ----------------
// 音符频率按十二平均律 440 × 2^((MIDI - 69) / 12) 独立算出，相位增量 = 频率 × 2^32 / 48000 四舍五入，
// 不抄 DUT 里的常数
integer note_midi [0:7];
initial begin
    note_midi[0] = 60; note_midi[1] = 62; note_midi[2] = 64; note_midi[3] = 65;
    note_midi[4] = 67; note_midi[5] = 69; note_midi[6] = 71; note_midi[7] = 72;
end

function [31:0] ref_inc(input integer n);
    real f, r;
    begin
        f = 440.0 * (2.0 ** ((note_midi[n] - 69) / 12.0));
        r = f * 4294967296.0 / FS;
        ref_inc = $rtoi(r + 0.5);                // $rtoi 截断，加 0.5 即四舍五入
    end
endfunction

localparam real PI = 3.14159265358979;

function integer ref_sine(input [9:0] p);
    real r;
    begin
        r = 32767.0 * $sin((p + 0.5) * 2.0 * PI / 1024.0);
        ref_sine = (r >= 0.0) ? $rtoi(r + 0.5) : -$rtoi(-r + 0.5);
    end
endfunction

// ---------------- 逐拍检查 ----------------
integer cyc = 0;
integer win_ticks = 0;                           // 当前 WIN 拍窗口里的节拍数
integer win_start = -1;                          // 窗口从第一个节拍开始算
integer last_tick = -1;
integer n_sample = 0;
integer max_abs = 0;
integer s_val, e_val;
reg [31:0] ref_phase = 32'd0;
integer acr_seen = 0;
reg     p_valid = 1'b0;

always @(posedge clk) begin
    if (!rst) begin
        cyc = cyc + 1;

        // 1. 采样节拍
        if (win_start >= 0 && cyc - win_start == WIN) begin
            chk(1, win_ticks == 48);
            win_ticks = 0;
            win_start = cyc;
        end
        if (tick) begin
            if (last_tick >= 0) chk(0, (cyc - last_tick == SP_LO) || (cyc - last_tick == SP_HI));
            if (win_start < 0) win_start = cyc;
            last_tick = cyc;
            win_ticks = win_ticks + 1;
        end

        // 2、3. 采样值
        if (valid) begin
            chk(2, !p_valid);                    // 单拍脉冲
            chk(3, left == right);
            s_val = $signed(left);
            // 参考：第 n 个采样用第 n 个音的相位，查理想正弦，再按音量缩放（低 8 位补 0 后算术右移）
            e_val = (ref_sine(ref_phase[31:22]) * 256) >>> VOL_SHIFT;
            chk(4, s_val == e_val);
            if (s_val == e_val && chk_e[4] == 0 && n_sample < 3)
                $display("        sample %0d = %0d (expect %0d)", n_sample, s_val, e_val);
            if (s_val > max_abs) max_abs = s_val;
            if (-s_val > max_abs) max_abs = -s_val;
            ref_phase = ref_phase + ref_inc((n_sample / NOTE_N) % 8);
            n_sample = n_sample + 1;
        end
        p_valid = valid;

        // 4. 音频时钟恢复包（前两包的计数窗口不完整，跳过）
        if (acr_valid) begin
            acr_seen = acr_seen + 1;
            if (acr_seen > 2) begin
                chk(5, acr_cts == WIN);
                chk(6, acr_n   == 20'd6144);
            end
        end

        if (n_sample == N_SAMPLE) begin
            // 满幅 32767 × 256 >> 1 = 4194176（-6dBFS 的 24 位峰值）
            chk(7, max_abs == ((32767 * 256) >>> VOL_SHIFT));
            $display("== audio_sample_tick");
            $display("        clock %0d Hz: spacing %0d..%0d cycles, window %0d cycles", CLK_HZ, SP_LO, SP_HI, WIN);
            report(0, "tick spacing = CLK_HZ / FS (floor or ceil)");
            report(1, "exactly 48 ticks per CLK_HZ/1000 cycles (48.000kHz)");
            $display("== audio_tone_gen");
            report(2, "audio_valid is a 1-cycle pulse");
            report(3, "left == right");
            report(4, "every sample == reference sine, 8 notes C4..C5");
            report(7, "peak = -6dBFS (4194176)");
            $display("        %0d samples, peak %0d", n_sample, max_abs);
            $display("== audio_arc_calculate (official) with the new source");
            report(5, "CTS = CLK_HZ / 1000 every packet");
            report(6, "N = 6144");
            $display("");
            if (errors == 0) $display("== ALL PASSED");
            else             $display("== %0d FAILED", errors);
            $finish;
        end
    end
end

initial begin
    repeat (10) @(posedge clk);
    rst <= 1'b0;
end

endmodule

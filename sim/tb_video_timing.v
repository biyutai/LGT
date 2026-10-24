// 视频时序发生器自检：video_timing_gen（新）对比官方 color_bar + video_timing_data（旧）
//   A. 新旧两个模块同时跑，逐拍比对输出
//   B. 单独检查新模块的 640×480@60 时序参数和像素坐标
// 运行：sim/run.sh tb_video_timing
`timescale 1ns / 1ps

module tb_video_timing;

localparam integer H_ACTIVE = 640, H_FP = 16, H_SYNC = 96, H_BP = 48;
localparam integer V_ACTIVE = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33;
localparam integer H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 800
localparam integer V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 525
localparam integer FRAME    = H_TOTAL * V_TOTAL;                 // 420000
localparam integer N_FRAMES = 4;

reg clk = 1'b0;
reg rst = 1'b1;
always #20 clk = ~clk;                        // 25MHz

// 两边各接一个相同的应答模型：请求 4 拍后应答，模拟 frame_fifo_read + 跨域同步
wire       n_hs, n_vs, n_de, n_req;
wire [11:0] n_x, n_y;
reg  [3:0] n_ack_sr = 4'd0;
wire       o_hs, o_vs, o_de, o_req;
reg  [3:0] o_ack_sr = 4'd0;

always @(posedge clk) begin
    n_ack_sr <= {n_ack_sr[2:0], n_req};
    o_ack_sr <= {o_ack_sr[2:0], o_req};
end

video_timing_gen dut (
    .clk          (clk),
    .rst          (rst),
    .hs           (n_hs),
    .vs           (n_vs),
    .de           (n_de),
    .x            (n_x),
    .y            (n_y),
    .read_req     (n_req),
    .read_req_ack (n_ack_sr[3])
);

video_timing_data ref_old (
    .video_clk    (clk),
    .rst          (rst),
    .read_req     (o_req),
    .read_req_ack (o_ack_sr[3]),
    .hs           (o_hs),
    .vs           (o_vs),
    .de           (o_de)
);

// ---------------- 检查项计数 ----------------
integer cyc = -1;                              // 复位撤销后的第几拍
integer errors = 0;
localparam integer NCHK = 20;
integer chk_n [0:NCHK-1];
integer chk_e [0:NCHK-1];
integer k;
initial for (k = 0; k < NCHK; k = k + 1) begin chk_n[k] = 0; chk_e[k] = 0; end

task chk(input integer id, input cond);
    begin
        chk_n[id] = chk_n[id] + 1;
        if (!cond) begin
            if (chk_e[id] < 3) $display("        mismatch #%0d at cycle %0d (check %0d)", chk_e[id] + 1, cyc, id);
            chk_e[id] = chk_e[id] + 1;
        end
    end
endtask

task report(input integer id, input [8*64-1:0] msg);
    begin
        if (chk_n[id] == 0)      begin $display("  FAIL  %0s  (never checked)", msg); errors = errors + 1; end
        else if (chk_e[id] == 0) $display("  PASS  %0s  (%0d checks)", msg, chk_n[id]);
        else begin $display("  FAIL  %0s  (%0d of %0d wrong)", msg, chk_e[id], chk_n[id]); errors = errors + 1; end
    end
endtask

// ---------------- 逐拍检查 ----------------
integer f1_sync_diff = 0;                      // 第 1 帧 hs / vs / read_req 与官方不同的拍数（预期非 0）

// 新模块的边沿记录
reg     p_hs = 1'b1, p_vs = 1'b1, p_de = 1'b0, p_req = 1'b0;
integer hs_start = -1, hs_end = -1, de_start = -1, de_end = -1, vs_start = -1, req_rise = -1;
integer de_lines = 0, exp_x = 0, exp_y = 0, line_y = 0;
reg     first_de_after_vs = 1'b0;

wire hs_act = (n_hs == 1'b0);                  // 负极性
wire vs_act = (n_vs == 1'b0);

always @(posedge clk) begin
    if (!rst) begin
        cyc = cyc + 1;

        // ===== A. 与官方逐拍比对 =====
        if (cyc >= 2) chk(0, n_de === o_de);   // 官方模块的输出寄存器复位后一拍才有确定值
        if (cyc >= FRAME) begin
            chk(1, n_hs  === o_hs);
            chk(2, n_vs  === o_vs);
            chk(3, n_req === o_req);
        end else if (cyc >= 2) begin
            if (n_hs !== o_hs || n_vs !== o_vs || n_req !== o_req) f1_sync_diff = f1_sync_diff + 1;
        end

        // ===== B. 新模块单独检查（第 2 帧起，跳过复位后的不完整帧）=====
        if (cyc >= FRAME) begin
            // 行同步
            if (hs_act && !(p_hs == 1'b0)) begin
                if (hs_start >= 0) chk(4, cyc - hs_start == H_TOTAL);
                if (de_end >= 0 && cyc - de_end < H_TOTAL) chk(5, cyc - de_end == H_FP);
                hs_start = cyc;
            end
            if (!hs_act && (p_hs == 1'b0) && hs_start >= 0) begin
                chk(6, cyc - hs_start == H_SYNC);
                hs_end = cyc;
            end

            // 数据有效 + 坐标
            if (n_de && !p_de) begin
                if (hs_end >= 0 && cyc - hs_end < H_TOTAL) chk(7, cyc - hs_end == H_BP);
                if (first_de_after_vs) begin
                    if (chk_n[8] == 0) $display("        vsync -> first de = %0d cycles", cyc - vs_start);
                    // 场同步在第 490 行的行同步处开始，490~491 同步、492~524 后沿，
                    // 第 0 行的行同步在 35 行之后，再过 行同步 + 行后沿 才是第一个像素
                    chk(8, cyc - vs_start == (V_SYNC + V_BP) * H_TOTAL + H_SYNC + H_BP);
                    first_de_after_vs = 1'b0;
                    line_y = 0;
                end
                exp_x = 0;
                exp_y = line_y;
                de_start = cyc;
            end
            if (n_de) begin
                chk(9,  n_x == exp_x);
                chk(10, n_y == exp_y);
                exp_x = exp_x + 1;
            end
            if (!n_de && p_de && de_start >= 0) begin
                chk(11, cyc - de_start == H_ACTIVE);
                de_end   = cyc;
                de_lines = de_lines + 1;
                line_y   = line_y + 1;
            end

            // 场同步
            if (vs_act && !(p_vs == 1'b0)) begin
                chk(12, hs_act && !(p_hs == 1'b0));                      // 与行同步前沿对齐
                if (vs_start >= 0) chk(13, cyc - vs_start == FRAME);
                if (de_end >= 0 && chk_n[14] == 0) $display("        last de -> vsync = %0d cycles", cyc - de_end);
                // 最后一行（479）有效区结束后，过行前沿到第 480 行的行同步；480~489 是 10 行场前沿
                if (de_end >= 0)   chk(14, cyc - de_end == H_FP + V_FP * H_TOTAL);
                if (vs_start >= 0) chk(15, de_lines == V_ACTIVE);
                chk(16, req_rise == cyc - 1);                             // read_req 比 vs 早一拍
                de_lines = 0;
                vs_start = cyc;
                first_de_after_vs = 1'b1;
            end
            if (!vs_act && (p_vs == 1'b0) && vs_start >= 0)
                chk(17, cyc - vs_start == V_SYNC * H_TOTAL);

            if (n_req && !p_req) req_rise = cyc;
        end

        p_hs  = n_hs;
        p_vs  = n_vs;
        p_de  = n_de;
        p_req = n_req;

        if (cyc == N_FRAMES * FRAME) begin
            $display("== A. new video_timing_gen vs official color_bar + video_timing_data, cycle by cycle");
            report(0, "de identical from reset");
            report(1, "hs identical from frame 2");
            report(2, "vs identical from frame 2");
            report(3, "read_req identical from frame 2");
            $display("        frame 1: %0d cycles where hs/vs/read_req differ (official sync starts active)", f1_sync_diff);
            $display("== B. new module timing, frames 2-%0d", N_FRAMES);
            report(4,  "line period = 800");
            report(6,  "hsync width = 96");
            report(5,  "front porch: de end -> hsync = 16");
            report(7,  "back porch: hsync end -> de = 48");
            report(11, "de width = 640");
            report(15, "480 active lines per frame");
            report(13, "frame period = 420000 (800 x 525)");
            report(17, "vsync width = 2 lines");
            report(12, "vsync starts on an hsync leading edge");
            report(14, "last de -> vsync = H_FP + 10 lines = 8016");
            report(8,  "vsync -> first de = 35 lines + H_SYNC + H_BP = 28144");
            report(16, "read_req rises 1 cycle before vsync");
            report(9,  "x = 0..639 within each line");
            report(10, "y = 0..479, one per line");
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

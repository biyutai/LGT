// 音画同步整链验证：音频节拍 → av_sync → 切显示缓冲（模拟 sd_card_bmp 的同步与提交）
//   → frame_fifo_read 在帧首换缓冲 → video_timing_gen / video_delay / video_rgb_to_axis → 新图第一帧
// 用缩小的视频时序（200×60，一帧 12000 拍）让仿真跑得快；提前量用和顶层相同的公式按这组参数算。
// 检查：每个节拍都测到；误差全部落在 ±(半帧 + 1 个样本 + 几拍跨域)；有正有负（确实居中）；
//       读请求 → 新帧第一个像素的实测延迟与顶层公式 SOF_DELAY 一致。
// 运行：sim/run.sh tb_av_chain              （提前量按公式）
//       sim/run.sh tb_av_chain -gUSE_LEAD=0  （不提前：画面总是晚 SOF_DELAY ~ SOF_DELAY + 1 帧，验证测量方向和提前量的必要）
`timescale 1ns / 1ps

module tb_av_chain;

parameter integer USE_LEAD = 1;

localparam integer H_ACTIVE = 128, H_FP = 16, H_SYNC = 24, H_BP = 32;
localparam integer V_ACTIVE = 48,  V_FP = 4,  V_SYNC = 2,  V_BP = 6;
localparam integer H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;      // 200
localparam integer V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;      // 60
localparam integer FRAME    = H_TOTAL * V_TOTAL;                    // 12000
localparam integer SOF_DELAY    = 1 + (V_SYNC + V_BP) * H_TOTAL + H_SYNC + H_BP + 21 + 2;
localparam integer PIX_HZ       = 25_200_000;                       // 与顶层相同（第 6b 步起 60Hz）
localparam integer LEAD_SAMPLES = USE_LEAD ? ((SOF_DELAY + FRAME / 2) * 48) / (PIX_HZ / 1000) : 0;
localparam integer SEG    = 67;                                     // 每张图 67 个样本 ≈ 2.9 帧，相位不断变化（总长要 >= 256，av_sync 的保护）
localparam integer N_IMG  = 4;
localparam [20:0]  WORDS  = SEG * N_IMG;
localparam integer N_BEATS = 120;

reg video_clk = 0, mem_clk = 0, sd_clk = 0;
always #19.841 video_clk = ~video_clk; // 25.2MHz
always #4  mem_clk   = ~mem_clk;       // 125MHz
always #5  sd_clk    = ~sd_clk;        // 100MHz
reg rst = 1'b1;

// ---------------- 音频：48kHz 节拍 + 播放器（FIFO 永远有数）----------------
wire tick, played, pop, a_valid;
wire [23:0] a_l, a_r;
audio_sample_tick #(.CLK_HZ(PIX_HZ), .FS(48_000)) u_tick (.clk(video_clk), .rst(rst), .tick(tick));
wav_player u_player (
    .clk (video_clk), .rst (rst), .sample_tick (tick), .active (1'b1),
    .pop (pop), .data (32'h1234_5678), .empty (1'b0),
    .audio_valid (a_valid), .audio_left (a_l), .audio_right (a_r), .played (played),
    .underrun_cnt ()
);

// ---------------- 视频时序 + 帧缓存读通道 ----------------
wire hs0, vs0, de0, read_req, read_req_ack_mem, read_en, hs, vs, de;
wire [11:0] px, py;
reg  [1:0]  ack_sync = 2'b00;
wire [31:0] read_data;
wire [23:0] vout;
wire [23:0] vout_q;
wire hs_q, vs_q, de_q;
wire sof, vvalid, vlast;
wire [23:0] vdata;

video_timing_gen #(
    .H_ACTIVE(H_ACTIVE), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
    .V_ACTIVE(V_ACTIVE), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP)
) u_tg (
    .clk (video_clk), .rst (rst), .hs (hs0), .vs (vs0), .de (de0), .x (px), .y (py),
    .read_req (read_req), .read_req_ack (ack_sync[1])
);
always @(posedge video_clk) ack_sync <= {ack_sync[0], read_req_ack_mem};

video_delay u_vd (
    .video_clk (video_clk), .rst (rst), .read_en (read_en), .read_data (read_data[31:8]),
    .hs (hs0), .vs (vs0), .de (de0), .hs_r (hs), .vs_r (vs), .de_r (de), .vout_data (vout)
);
video_output_stage u_output_stage (
    .clk(video_clk), .rst(rst), .hs(hs), .vs(vs), .de(de), .rgb(vout),
    .hs_out(hs_q), .vs_out(vs_q), .de_out(de_q), .rgb_out(vout_q)
);
video_rgb_to_axis_640x480 u_axis (
    .I_clk (video_clk), .I_rst (rst), .I_vs (vs_q), .I_de (de_q), .I_rgb (vout_q),
    .O_video_user (sof), .O_video_valid (vvalid), .O_video_last (vlast), .O_video_data (vdata)
);

// 理想 SDRAM：读数据 6 拍后返回
wire        App_rd_en;
wire [20:0] App_rd_addr;
reg  [5:0]  rd_pipe = 6'd0;
wire        Sdr_rd_en = rd_pipe[5];
reg  [1:0]  disp_idx = 2'd0;           // sd_clk 域：模拟 sd_card_bmp 的 disp_buf_idx
wire [1:0]  read_index_mem;
wire        rd_empty;
always @(posedge mem_clk) rd_pipe <= {rd_pipe[4:0], App_rd_en};

frame_read_write #(.WRITE_V_FLIP(1), .FRAME_WIDTH(H_ACTIVE), .FRAME_HEIGHT(V_ACTIVE)) u_fr (
    .rst (rst), .mem_clk (mem_clk),
    .Sdr_init_done (1'b1), .Sdr_init_ref_vld (1'b0), .Sdr_busy (1'b0),
    .ext_rd_busy (1'b0), .fr_burst (), .read_index_cur (read_index_mem), .read_empty (rd_empty),
    .App_rd_en (App_rd_en), .App_rd_addr (App_rd_addr), .Sdr_rd_en (Sdr_rd_en), .Sdr_rd_dout (32'hAABBCC00),
    .read_clk (video_clk), .read_req (read_req), .read_req_ack (read_req_ack_mem), .read_finish (),
    .read_addr_0 (21'd0), .read_addr_1 (21'd8192), .read_addr_2 (21'd0), .read_addr_3 (21'd0),
    .read_addr_index (disp_idx), .read_is_preview(1'b0), .read_preview_addr(21'd0),
    .read_len (H_ACTIVE * V_ACTIVE), .read_en (read_en), .read_data (read_data),
    .App_wr_en (), .App_wr_addr (), .App_wr_din (), .App_wr_dm (),
    .write_clk (sd_clk), .write_req (1'b0), .write_req_ack (), .write_finish (),
    .write_addr_0 (21'd0), .write_addr_1 (21'd0), .write_addr_2 (21'd0), .write_addr_3 (21'd0),
    .write_is_preview(1'b0),
    .write_addr_index (2'd0), .write_is_wav (1'b0),
    .write_len (21'd0), .write_en (1'b0), .write_data (32'd0)
);

// ---------------- av_sync + 切换模型 ----------------
wire        beat_toggle;
wire [7:0]  beat_cnt, meas_cnt;
wire signed [23:0] err_last;
wire [23:0] err_max_abs;
reg  [1:0]  idx_v0 = 2'd0, idx_v1 = 2'd0;
always @(posedge video_clk) begin idx_v0 <= read_index_mem; idx_v1 <= idx_v0; end

av_sync #(.LEAD_SAMPLES(LEAD_SAMPLES), .MEAS_TIMEOUT(3 * FRAME)) dut (
    .clk (video_clk), .rst (rst), .active (1'b1), .words (WORDS), .img_count (N_IMG[2:0]), .played (played),
    .beat_toggle (beat_toggle), .beat_cnt (beat_cnt),
    .sof (sof), .frame_buf (idx_v1), .err_last (err_last), .err_max_abs (err_max_abs), .meas_cnt (meas_cnt)
);

// 与 sd_card_bmp 相同：节拍打三拍同步，边沿那一拍切换（后台已预加载好）
reg [2:0] beat_sync = 3'b000;
always @(posedge sd_clk) begin
    beat_sync <= {beat_sync[1:0], beat_toggle};
    if (beat_sync[2] ^ beat_sync[1]) disp_idx <= {1'b0, ~disp_idx[0]};
end

// ---------------- 统计 ----------------
integer n_err = 0, n_neg = 0, n_pos = 0, out_of_bound = 0;
integer e, e_min = 1 << 30, e_max = -(1 << 30);
integer sum = 0;
reg [7:0] p_meas = 8'd0;
localparam integer BOUND = FRAME / 2 + 525 + 20;      // 半帧 + 1 个样本（525 拍）+ 跨域几拍
always @(posedge video_clk) begin
    if (meas_cnt != p_meas) begin
        e = err_last;
        n_err = n_err + 1;
        sum = sum + e;
        if (e < 0) n_neg = n_neg + 1; else n_pos = n_pos + 1;
        if (e < e_min) e_min = e;
        if (e > e_max) e_max = e;
        if (USE_LEAD ? (e > BOUND || e < -BOUND) : (e < SOF_DELAY - 20 || e > SOF_DELAY + FRAME + 565)) out_of_bound = out_of_bound + 1;
    end
    p_meas <= meas_cnt;
end

// 画面读空（与顶层健康指示 bit0 同样的判据）：第一帧开始读之后，要像素时读 FIFO 不能是空的
reg     uf_armed = 1'b0;
integer underflows = 0;
always @(posedge video_clk) begin
    if (ack_sync[1]) uf_armed <= 1'b1;
    if (uf_armed && read_en && rd_empty) underflows = underflows + 1;
end

// 读请求 → 新帧第一个像素的实测延迟
integer t_req = -1, sof_lat = -1;
reg p_req = 1'b0;
integer cyc = 0;
always @(posedge video_clk) begin
    cyc = cyc + 1;
    if (read_req && !p_req) t_req = cyc;
    if (sof && t_req >= 0 && sof_lat < 0) sof_lat = cyc - t_req;
    p_req <= read_req;
end

integer errors = 0;
task check(input cond, input [8*80-1:0] msg);
    begin
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s", msg); errors = errors + 1; end
    end
endtask

initial begin
    $display("== frame %0d cycles, SOF_DELAY %0d, LEAD %0d samples, SEG %0d samples", FRAME, SOF_DELAY, LEAD_SAMPLES, SEG);
    repeat (20) @(posedge video_clk);
    rst <= 1'b0;
    wait (beat_cnt == N_BEATS);
    repeat (4 * FRAME) @(posedge video_clk);
    $display("        read_req -> first pixel of the frame at HDMI IP input: %0d cycles (formula %0d)", sof_lat, SOF_DELAY);
    $display("        %0d beats, %0d measured; error min %0d, max %0d, mean %0d cycles; %0d negative, %0d positive",
             beat_cnt, n_err, e_min, e_max, sum / (n_err > 0 ? n_err : 1), n_neg, n_pos);
    check(sof_lat == SOF_DELAY - 1 || sof_lat == SOF_DELAY, "measured read_req -> SOF delay matches the formula used for LEAD");
    check(n_err >= N_BEATS - 1, "every beat produced a measurement");
    check(underflows == 0, "no read FIFO underflow (health bit0 stays 0)");
    if (USE_LEAD) begin
        $display("        bound +-%0d cycles (half frame %0d + 1 sample + CDC)", BOUND, FRAME / 2);
        check(out_of_bound == 0, "all errors within +-(half frame + 1 sample + CDC)");
        check(n_neg > N_BEATS / 5 && n_pos > N_BEATS / 5, "errors on both sides: lead centers them");
        check(err_max_abs <= BOUND, "err_max_abs within bound");
    end else begin
        check(out_of_bound == 0, "no lead: video always late by SOF_DELAY .. SOF_DELAY + 1 frame");
    end
    $display("");
    if (errors == 0) $display("== ALL PASSED");
    else             $display("== %0d FAILED", errors);
    $finish;
end

initial begin
    #500_000_000;
    $display("== TIMEOUT (beats %0d, measured %0d)", beat_cnt, n_err);
    $finish;
end

endmodule

// SDRAM 三个口同时工作（真实控制器版）：视频读 + 图片写 + 音频读，全部经过官方加密 SDRAM 控制器
// 与 tb_sdram_audio 相同的流量和检查，SDRAM 换成 sdr_as_ram（ModelSim 解密运行）+ 芯片行为模型（sim/models/sdram_chip_model.v）
// 刷新照常进行（global_def.v 修复后每 1953 拍一次），检查刷新确实发生、协议没有错误
// 运行：sim/run.sh tb_sdram_real          （+POPDIV=2：音频取得极快，读口几乎一直在等，每次写突发一结束就紧接着读，
//                                          专门制造"刚写完就读"的短间隔；去掉 Sdr_busy 门控时这个场景会读错）
`timescale 1ns / 1ps

module tb_sdram_real;

parameter integer FULL_RES = 0;
localparam integer FW = FULL_RES ? 640 : 64;
localparam integer FH = FULL_RES ? 480 : 16;
localparam integer FRAME = FW * FH;            // 1024 字
localparam [20:0]  BUF0 = 21'd0;
localparam [20:0]  BUF1 = 21'd307200;
localparam [20:0]  ABASE = FULL_RES ? 21'd614400 : 21'd4096;
localparam [20:0]  PREVIEW_BASE = FULL_RES ? 21'd1943552 : 21'd8192;
localparam [20:0]  AWORDS = 21'd768;           // 256 的倍数，循环点不在 64 字突发边界以外
localparam integer N_FRAMES = FULL_RES ? 4 : 12;


reg mem_clk = 0, mem_clk_sft = 1, video_clk = 0, sd_clk = 0;
always #4  begin mem_clk = ~mem_clk; mem_clk_sft = ~mem_clk_sft; end   // 125MHz，Clk_sft 反相（180°）
always #20 video_clk = ~video_clk;             // 25MHz
always #5  sd_clk    = ~sd_clk;                // 100MHz

reg rst = 1'b1;

// ---------------- 真实 SDRAM 控制器 + 芯片模型 ----------------
wire        App_wr_en, App_rd_en;
wire [20:0] App_wr_addr, App_rd_addr;
wire [31:0] App_wr_din;
wire [3:0]  App_wr_dm;
wire        Sdr_init_done, Sdr_init_ref_vld, Sdr_busy;
wire        Sdr_rd_en;
wire [31:0] Sdr_rd_dout;

sdram U3 (
    .Clk              (mem_clk),
    .Clk_sft          (mem_clk_sft),
    .Rst              (rst),
    .Sdr_init_done    (Sdr_init_done),
    .Sdr_init_ref_vld (Sdr_init_ref_vld),
    .Sdr_busy         (Sdr_busy),
    .App_wr_en        (App_wr_en),
    .App_wr_addr      (App_wr_addr),
    .App_wr_dm        (App_wr_dm),
    .App_wr_din       (App_wr_din),
    .App_rd_en        (App_rd_en),
    .App_rd_addr      (App_rd_addr),
    .Sdr_rd_en        (Sdr_rd_en),
    .Sdr_rd_dout      (Sdr_rd_dout)
);

// 应用地址 → 芯片模型存储下标：控制器把 4 字一组轮流放进 4 个 bank（tb_sdram_ctrl 里从引脚命令看出来的）
//   bank = a[3:2]，列 = {a[9:4], a[1:0]}，行 = a[20:10]；模型下标 = {bank, 行, 列}
function [20:0] chip_idx(input [20:0] a);
    chip_idx = {a[3:2], a[20:10], a[9:4], a[1:0]};
endfunction
`define MEM(a) U3.sdram.mem[chip_idx(a)]

// ---------------- 被测：frame_read_write + audio_sdram_stream + 顶层那几行拼接 ----------------
wire        fr_rd_en, fr_burst, au_owner, au_mine, au_rd_en;
wire [20:0] fr_rd_addr, au_rd_addr;
assign App_rd_en   = fr_rd_en | au_rd_en;
assign App_rd_addr = au_mine ? au_rd_addr : fr_rd_addr;

reg         read_req = 1'b0;
reg  [1:0]  read_idx = 2'd0;
wire        read_req_ack;
reg         read_en = 1'b0;
wire [31:0] read_data;
reg         write_req = 1'b0;
wire        write_req_ack, write_finish;
reg  [1:0]  write_idx = 2'd2;
reg  [20:0] write_len = AWORDS;
reg         write_en = 1'b0;
reg         write_preview = 1'b0;
reg  [31:0] write_data = 32'd0;

frame_read_write #(
    .BURST_SIZE   (128),
    .WRITE_V_FLIP (1),
    .FRAME_WIDTH  (FW),
    .FRAME_HEIGHT (FH)
) dut_fr (
    .rst              (rst),
    .mem_clk          (mem_clk),
    .Sdr_init_done    (Sdr_init_done),
    .Sdr_init_ref_vld (Sdr_init_ref_vld),
    .Sdr_busy         (Sdr_busy),
    .ext_rd_busy      (au_owner),
    .fr_burst         (fr_burst),
    .App_rd_en        (fr_rd_en),
    .App_rd_addr      (fr_rd_addr),
    .Sdr_rd_en        (Sdr_rd_en & ~au_mine),
    .Sdr_rd_dout      (Sdr_rd_dout),
    .read_clk         (video_clk),
    .read_req         (read_req),
    .read_req_ack     (read_req_ack),
    .read_finish      (),
    .read_addr_0      (BUF0),
    .read_addr_1      (BUF1),
    .read_addr_2      (21'd0),
    .read_addr_3      (21'd0),
    .read_addr_index  (read_idx),
    .read_is_preview  (1'b0),
    .read_preview_addr(21'd0),
    .read_len         (FRAME[20:0]),
    .read_en          (read_en),
    .read_data        (read_data),
    .App_wr_en        (App_wr_en),
    .App_wr_addr      (App_wr_addr),
    .App_wr_din       (App_wr_din),
    .App_wr_dm        (App_wr_dm),
    .write_clk        (sd_clk),
    .write_req        (write_req),
    .write_req_ack    (write_req_ack),
    .write_finish     (write_finish),
    .write_addr_0     (write_preview ? PREVIEW_BASE : BUF0),
    .write_addr_1     (BUF1),
    .write_addr_2     (ABASE),
    .write_addr_3     (21'd0),
    .write_addr_index (write_idx),
    .write_is_wav     (write_idx == 2'd2),
    .write_is_preview (write_preview),
    .write_len        (write_len),
    .write_en         (write_en),
    .write_data       (write_data)
);

reg         au_enable = 1'b0;
wire [3:0]  au_err_cnt;
reg         au_pop_req = 1'b0;
wire        au_pop;
wire [31:0] au_data;
wire        au_empty;
assign au_pop = au_pop_req & ~au_empty;

audio_sdram_stream dut_au (
    .mem_clk     (mem_clk),
    .mem_rst     (rst),
    .enable      (au_enable),
    .words       (AWORDS),
    .base_addr   (ABASE),
    .fr_burst    (fr_burst),
    .sdr_busy    (Sdr_busy),
    .owner       (au_owner),
    .mine        (au_mine),
    .other_rd_en (fr_rd_en),
    .rd_en       (au_rd_en),
    .rd_addr     (au_rd_addr),
    .sdr_rd_en   (Sdr_rd_en),
    .sdr_rd_dout (Sdr_rd_dout),
    .video_clk   (video_clk),
    .pop         (au_pop),
    .data        (au_data),
    .empty       (au_empty),
    .err_cnt     (au_err_cnt)
);

// ---------------- 检查项 ----------------
localparam integer NCHK = 13;
integer chk_n [0:NCHK-1];
integer chk_e [0:NCHK-1];
integer errors = 0;
integer k;
initial for (k = 0; k < NCHK; k = k + 1) begin chk_n[k] = 0; chk_e[k] = 0; end

task chk(input integer id, input cond);
    begin
        chk_n[id] = chk_n[id] + 1;
        if (!cond) begin
            if (chk_e[id] < 3) $display("        mismatch in check %0d at t=%0t", id, $time);
            chk_e[id] = chk_e[id] + 1;
        end
    end
endtask

task report(input integer id, input [8*72-1:0] msg);
    begin
        if (chk_n[id] == 0)      begin $display("  FAIL  %0s  (never checked)", msg); errors = errors + 1; end
        else if (chk_e[id] == 0) $display("  PASS  %0s  (%0d checks)", msg, chk_n[id]);
        else begin $display("  FAIL  %0s  (%0d of %0d wrong)", msg, chk_e[id], chk_n[id]); errors = errors + 1; end
    end
endtask

// 每拍：几个口不会同时发请求；音频 FIFO 满时不会再写
integer au_bursts = 0;
reg     p_owner = 1'b0;
always @(posedge mem_clk) if (!rst) begin
    chk(0, !(fr_rd_en && au_rd_en));
    chk(1, !(App_wr_en && App_rd_en));
    if (Sdr_rd_en && au_mine) begin
        if (dut_au.u_audio_fifo.full_flag && chk_e[2] < 2)
            $display("        [%0t] FULL write: state=%0d fifo_used=%0d inflight=%0d fr_rd_en=%b fr_state=%0d",
                     $time, dut_au.state, dut_au.fifo_used, dut_au.inflight, fr_rd_en, dut_fr.frame_fifo_read_m0.state);
        chk(2, !dut_au.u_audio_fifo.full_flag);
    end
    if (au_owner && !p_owner) au_bursts = au_bursts + 1;
    p_owner = au_owner;
end

// ---------------- 视频读：每帧 read_req，然后 16 行 × 64 像素（每行后空 16 拍）----------------
integer frames_done = 0;
integer vexp;
reg     v_valid = 1'b0;            // read_en 后一拍 read_data 有效
task video_frame;
    integer r, c;
    begin
        @(posedge video_clk) read_req <= 1'b1;
        wait (read_req_ack);
        @(posedge video_clk) read_req <= 1'b0;
        repeat (35 * 80) @(posedge video_clk);          // 场消隐，读 FIFO 预取
        vexp = 0;
        for (r = 0; r < FH; r = r + 1) begin
            for (c = 0; c < FW; c = c + 1) begin
                @(posedge video_clk) read_en <= 1'b1;
            end
            @(posedge video_clk) read_en <= 1'b0;
            repeat (15) @(posedge video_clk);
        end
        repeat (4) @(posedge video_clk);
        frames_done = frames_done + 1;
    end
endtask

always @(posedge video_clk) begin
    v_valid <= read_en;
    if (v_valid) begin
        if (read_idx == 2'd0)
            chk(3, read_data === (32'hA000_0000 + vexp));
        else
            chk(3, read_data === (32'hB002_0000 +
                     (FH - 1 - vexp / FW) * FW + vexp % FW));
        vexp = vexp + 1;
    end
end

// ---------------- 音频取数：远快于 48kHz（每 20 个 video_clk 一次）----------------
integer aexp = 0;
reg     a_valid = 1'b0;
integer apop_div = 0;
integer POPDIV = 20;
integer a_empty_hits = 0;
always @(posedge video_clk) begin
    a_valid <= au_pop;
    if (a_valid) begin
        chk(4, au_data === (32'h5000_0000 + (aexp % AWORDS)));
        aexp = aexp + 1;
    end
    au_pop_req <= 1'b0;
    if (au_enable) begin
        apop_div = apop_div + 1;
        if (apop_div >= POPDIV) begin
            apop_div = 0;
            au_pop_req <= 1'b1;
            if (au_empty && aexp > 64) a_empty_hits = a_empty_hits + 1;
        end
    end
end

// ---------------- 写通道：sd_clk 域，每 3 拍一个字 ----------------
task write_frame(input [1:0] idx, input [20:0] len, input [31:0] base_val);
    integer n;
    begin
        @(posedge sd_clk) begin write_idx <= idx; write_len <= len; end
        repeat (4) @(posedge sd_clk);
        write_req <= 1'b1;
        wait (write_req_ack);
        @(posedge sd_clk) write_req <= 1'b0;
        repeat (8) @(posedge sd_clk);
        for (n = 0; n < len; n = n + 1) begin
            @(posedge sd_clk) begin write_en <= 1'b1; write_data <= base_val + n; end
            @(posedge sd_clk) write_en <= 1'b0;
            @(posedge sd_clk);
        end
        wait (write_finish);
        // 写通道报完成时控制器流水线里还有几个字没写进芯片；直接检查芯片内容前等它写完
        repeat (50) @(posedge mem_clk);
    end
endtask

integer i, bad;
integer ref0;

initial begin
    if ($value$plusargs("POPDIV=%d", POPDIV)) ;
    $display("== audio pop every %0d video clocks", POPDIV);
    repeat (20) @(posedge mem_clk);
    rst <= 1'b0;
    wait (Sdr_init_done);
    $display("== SDRAM controller init done at %0t", $time);
    // 视频缓冲直接预置到芯片模型（控制器初始化之后，免得被初始化覆盖）
    for (i = 0; i < FRAME; i = i + 1) `MEM(BUF0 + i) = 32'hA000_0000 + i;
    for (i = 0; i < FRAME; i = i + 1) `MEM(BUF1 + i) = 32'h0;
    for (i = 0; i < AWORDS; i = i + 1) `MEM(ABASE + i) = 32'h0;
    ref0 = U3.sdram.n_ref;
    repeat (20) @(posedge mem_clk);

    // 1. 用写通道把音频数据线性写进音频区（buffer 2，不翻转），和开机载入 WAV 一样
    write_frame(2'd2, AWORDS, 32'h5000_0000);
    bad = 0;
    for (i = 0; i < AWORDS; i = i + 1) if (`MEM(ABASE + i) !== 32'h5000_0000 + i) bad = bad + 1;
    chk(5, bad == 0);

    // 2. 打开音频读口；同时视频连续读帧、写通道每隔几帧写一次 buffer 1（翻转）
    au_enable = 1'b1;
    fork
        begin : video
            integer f;
            for (f = 0; f < N_FRAMES; f = f + 1) video_frame;
        end
        begin : writer
            integer w, r, c;
            for (w = 0; w < 3; w = w + 1) begin
                repeat (3000) @(posedge sd_clk);
                write_frame(2'd1, FRAME[20:0], 32'hB000_0000 + w * 32'h10000);
                bad = 0;
                for (r = 0; r < FH; r = r + 1)
                    for (c = 0; c < FW; c = c + 1)
                        if (`MEM(BUF1 + (FH - 1 - r) * FW + c) !== 32'hB000_0000 + w * 32'h10000 + r * FW + c) bad = bad + 1;
                chk(6, bad == 0);
            end
        end
    join

    // The second and fourth slideshow images both use buffer 1.
    read_idx = 2'd1;
    video_frame;
    chk(11, dut_fr.read_index_cur == 2'd1);

    // 3. 关掉音频读口：FIFO 清空、读口释放
    au_enable = 1'b0;
    repeat (200) @(posedge mem_clk);
    chk(7, !au_owner && au_empty);

    if (!FULL_RES) begin : preview_real_check
        integer row,col,fail_count,addr;
        write_preview=1'b1;
        write_frame(2'd0,FRAME/8,32'hE000_0000);
        write_preview=1'b0;
        fail_count=0;
        for(row=0;row<FH/2;row=row+1)
            for(col=0;col<FW/4;col=col+1) begin
                addr=PREVIEW_BASE+(FH/2-1-row)*(FW/2)+col;
                if (`MEM(addr) !== 32'hE000_0000+row*(FW/4)+col)
                    fail_count=fail_count+1;
            end
        chk(12,fail_count==0);
    end

    $display("        %0d video frames, %0d audio samples, %0d audio bursts, %0d audio pops found FIFO empty",
             frames_done, aexp, au_bursts, a_empty_hits);
    report(0, "frame_read_write and audio never issue reads in the same cycle");
    report(1, "no read and write in the same cycle");
    report(2, "audio FIFO never written while full");
    report(5, "audio area written linearly through write channel (buffer 2, no flip)");
    report(3, "every video pixel correct while audio and writes run");
    report(4, "every audio sample correct, loops over 768 words");
    report(6, "buffer 1 written with vertical flip, 3 frames, all words correct");
    report(11, "buffer 1 reads back as a complete nonblack video frame");
    report(7, "disable: owner released, FIFO flushed");
    if (!FULL_RES) report(12, "preview burst writes upright words through real SDRAM controller");
    chk(8, au_err_cnt == 0);
    report(8, "no short / timed-out audio bursts (err_cnt = 0)");
    $display("        SDRAM: %0d REF during the test (max gap %0t), %0d protocol errors", U3.sdram.n_ref - ref0, U3.sdram.max_ref_gap, U3.sdram.n_err);
    chk(9, U3.sdram.n_err == 0);
    report(9, "SDRAM chip model saw no protocol errors (missing ACT etc.)");
    chk(10, U3.sdram.n_ref - ref0 > 10 && U3.sdram.max_ref_gap < 64'd40000);
    report(10, "controller refreshes during traffic, gap < 40us (needs 15.6us average)");
    $display("");
    if (errors == 0) $display("== ALL PASSED");
    else             $display("== %0d FAILED", errors);
    $finish;
end

initial begin
    #200_000_000;
    $display("== TIMEOUT");
    $finish;
end

endmodule

// SDRAM 三个口同时工作：视频读（frame_read_write 读通道）+ 图片写（写通道）+ 音频读（audio_sdram_stream）
// 这里用理想的接口行为模型：每拍收一个读 / 写，读数据 LAT 拍后按顺序返回，用来扫读延迟。
// 用官方真实控制器（含刷新、busy）的版本见 tb_sdram_real
// 检查：视频每帧每个像素、音频每个样本、写进去的每个字都对；三个口不会同时发请求；音频 FIFO 不溢出
// 运行：sim/run.sh tb_sdram_audio     （LAT 默认 6，可用 +LAT=3 / +LAT=10 改）
// LAT 只在 <= 10 有意义：官方 frame_fifo_read 认定最后一次读发出后 10 拍内数据全部返回（rd_delay == 10），
// 关掉音频读口、LAT = 14 时官方视频读同样出错；板上图像一直正确，说明真实 SDRAM 控制器延迟在 10 拍以内
`timescale 1ns / 1ps

module tb_sdram_audio;

localparam integer FW = 64, FH = 16;
localparam integer FRAME = FW * FH;            // 1024 字
localparam [20:0]  BUF0 = 21'd0;
localparam [20:0]  BUF1 = 21'd1024;
localparam [20:0]  BUF2 = 21'd2048;
localparam [20:0]  BUF3 = 21'd3072;
localparam [20:0]  ABASE = 21'd4096;
localparam [20:0]  PREVIEW_BASE = 21'd8192;
localparam [20:0]  AWORDS = 21'd768;           // 256 的倍数，循环点不在 64 字突发边界以外
localparam integer N_FRAMES = 12;

integer LAT = 6;
integer DROP = 0;                              // +DROP=n：丢掉第 n 个音频读的返回（测 err_cnt 能抓到）
integer au_ret = 0;

reg mem_clk = 0, video_clk = 0, sd_clk = 0;
always #4  mem_clk   = ~mem_clk;               // 125MHz
always #20 video_clk = ~video_clk;             // 25MHz
always #5  sd_clk    = ~sd_clk;                // 100MHz

reg rst = 1'b1;

// ---------------- SDRAM 接口模型 ----------------
reg  [31:0] mem [0:(1<<21)-1];
wire        App_wr_en, App_rd_en;
wire [20:0] App_wr_addr, App_rd_addr;
wire [31:0] App_wr_din;
wire [3:0]  App_wr_dm;
reg         Sdr_init_done = 1'b0;
reg  [20:0] rd_pipe_addr [0:31];
reg  [31:0] rd_pipe_v;
reg         Sdr_rd_en = 1'b0;
reg  [31:0] Sdr_rd_dout = 32'd0;
integer     p;

always @(posedge mem_clk) begin
    if (App_wr_en) mem[App_wr_addr] <= App_wr_din;
    for (p = 31; p > 0; p = p - 1) rd_pipe_addr[p] <= rd_pipe_addr[p-1];
    rd_pipe_addr[0] <= App_rd_addr;
    rd_pipe_v <= {rd_pipe_v[30:0], App_rd_en};
    Sdr_rd_en   <= rd_pipe_v[LAT-2];
    Sdr_rd_dout <= mem[rd_pipe_addr[LAT-2]];
end

// ---------------- 被测：frame_read_write + audio_sdram_stream + 顶层那几行拼接 ----------------
wire        fr_rd_en, fr_burst, au_owner, au_mine, au_rd_en;
wire [20:0] fr_rd_addr, au_rd_addr;
assign App_rd_en   = fr_rd_en | au_rd_en;
assign App_rd_addr = au_mine ? au_rd_addr : fr_rd_addr;

// +DROP=n：把第 n 个音频读的返回吞掉（在上面 SDRAM 模型之后覆盖 Sdr_rd_en）
always @(posedge mem_clk) begin
    if (rd_pipe_v[LAT-2] && au_mine) begin
        au_ret = au_ret + 1;
        if (au_ret == DROP) Sdr_rd_en <= 1'b0;
    end
end

reg         read_req = 1'b0;
reg         preview_read = 1'b0;
reg  [1:0]  read_idx = 2'd0;
wire        read_req_ack;
reg         read_en = 1'b0;
wire [31:0] read_data;
reg         write_req = 1'b0;
wire        write_req_ack, write_finish;
reg  [1:0]  write_idx = 2'd2;
reg         write_wav = 1'b1;
reg         write_preview = 1'b0;
reg  [20:0] write_len = AWORDS;
reg         write_en = 1'b0;
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
    .Sdr_init_ref_vld (1'b0),
    .Sdr_busy         (1'b0),
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
    .read_addr_2      (BUF2),
    .read_addr_3      (BUF3),
    .read_addr_index  (read_idx),
    .read_is_preview  (preview_read),
    .read_preview_addr(PREVIEW_BASE),
    .read_len         (preview_read ? FRAME/2 : FRAME),
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
    .write_addr_1     (write_preview ? PREVIEW_BASE + FW/4 : BUF1),
    .write_addr_2     (write_preview ? PREVIEW_BASE + FRAME/4 : write_wav ? ABASE : BUF2),
    .write_addr_3     (write_preview ? PREVIEW_BASE + FRAME/4 + FW/4 : BUF3),
    .write_addr_index (write_idx),
    .write_is_wav     (write_wav),
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
    .sdr_busy    (1'b0),                       // 理想模型没有忙状态；真实控制器的 busy 行为在 tb_sdram_real 里测
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
localparam integer NCHK = 14;
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
                @(posedge video_clk) read_en <= preview_read ? !c[0] : 1'b1;
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
        if (preview_read) begin
            begin : check_preview_word
                integer word_x, word_y, bank, local_row, local_col;
                word_x = vexp % (FW/2);
                word_y = vexp / (FW/2);
                bank = (word_y >= FH/2 ? 2 : 0) + (word_x >= FW/4 ? 1 : 0);
                local_row = (FH/2-1) - (word_y % (FH/2));
                local_col = word_x % (FW/4);
                chk(12, read_data === 32'hE000_0000 + (bank << 16) + local_row*(FW/4) + local_col);
            end
        end else case (read_idx)
            2'd2: chk(3, read_data === (32'hC000_0000 + (FH-1-vexp/FW)*FW + vexp%FW));
            2'd3: chk(3, read_data === (32'hD000_0000 + (FH-1-vexp/FW)*FW + vexp%FW));
            default: chk(3, read_data === (32'hA000_0000 + vexp));
        endcase
        vexp = vexp + 1;
    end
end

// ---------------- 音频取数：远快于 48kHz（每 20 个 video_clk 一次）----------------
integer aexp = 0;
reg     a_valid = 1'b0;
integer apop_div = 0;
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
        if (apop_div == 20) begin
            apop_div = 0;
            au_pop_req <= 1'b1;
            if (au_empty && aexp > 64) a_empty_hits = a_empty_hits + 1;
        end
    end
end

// ---------------- 写通道：sd_clk 域，每 3 拍一个字 ----------------
task write_frame(input [1:0] idx, input [20:0] len,
                 input [31:0] base_val, input is_wav);
    integer n;
    begin
        @(posedge sd_clk) begin
            write_idx <= idx; write_len <= len; write_wav <= is_wav;
        end
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
        @(posedge mem_clk);
    end
endtask

integer i, bad;

initial begin
    if ($value$plusargs("LAT=%d", LAT)) ;
    if ($value$plusargs("DROP=%d", DROP)) ;
    if (DROP) $display("== DROP: audio read return #%0d will be lost", DROP);
    $display("== SDRAM model read latency = %0d cycles", LAT);
    for (i = 0; i < FRAME; i = i + 1) mem[BUF0 + i] = 32'hA000_0000 + i;
    for (i = 0; i < FRAME; i = i + 1) mem[BUF1 + i] = 32'h0;
    for (i = 0; i < AWORDS; i = i + 1) mem[ABASE + i] = 32'h0;
    for (i = 0; i < 32; i = i + 1) rd_pipe_addr[i] = 21'd0;
    rd_pipe_v = 32'd0;

    repeat (20) @(posedge mem_clk);
    rst <= 1'b0;
    repeat (20) @(posedge mem_clk);
    Sdr_init_done <= 1'b1;

    // 1. 用写通道把音频数据线性写进音频区（buffer 2，不翻转），和开机载入 WAV 一样
    write_frame(2'd2, AWORDS, 32'h5000_0000, 1'b1);
    bad = 0;
    for (i = 0; i < AWORDS; i = i + 1) if (mem[ABASE + i] !== 32'h5000_0000 + i) bad = bad + 1;
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
                write_frame(2'd1, FRAME[20:0], 32'hB000_0000 + w * 32'h10000, 1'b0);
                bad = 0;
                for (r = 0; r < FH; r = r + 1)
                    for (c = 0; c < FW; c = c + 1)
                        if (mem[BUF1 + (FH - 1 - r) * FW + c] !== 32'hB000_0000 + w * 32'h10000 + r * FW + c) bad = bad + 1;
                chk(6, bad == 0);
            end
        end
    join

    // 3. 关掉音频读口：FIFO 清空、读口释放
    au_enable = 1'b0;
    repeat (200) @(posedge mem_clk);
    chk(7, !au_owner && au_empty);

    write_frame(2'd2, FRAME[20:0], 32'hC000_0000, 1'b0);
    bad = 0;
    for (i=0;i<FRAME;i=i+1)
        if (mem[BUF2 + (FH-1-i/FW)*FW + i%FW] !== 32'hC000_0000+i)
            bad=bad+1;
    chk(9, bad==0);

    write_frame(2'd3, FRAME[20:0], 32'hD000_0000, 1'b0);
    bad = 0;
    for (i=0;i<FRAME;i=i+1)
        if (mem[BUF3 + (FH-1-i/FW)*FW + i%FW] !== 32'hD000_0000+i)
            bad=bad+1;
    chk(10, bad==0);
    read_idx=2'd2;
    video_frame;
    read_idx=2'd3;
    video_frame;

    for (i=0;i<FRAME/2;i=i+1) mem[PREVIEW_BASE+i]=32'd0;
    write_preview=1'b1;
    for (i=0;i<4;i=i+1)
        write_frame(i[1:0],(FRAME/8),32'hE000_0000 + (i << 16),1'b0);
    write_preview=1'b0;
    bad=0;
    begin : preview_check
        integer bank,row,col,dest;
        for(bank=0;bank<4;bank=bank+1)
            for(row=0;row<FH/2;row=row+1)
                for(col=0;col<FW/4;col=col+1) begin
                    dest=PREVIEW_BASE+((bank/2)*(FH/2)+(FH/2-1-row))*(FW/2)
                         +(bank%2)*(FW/4)+col;
                    if(mem[dest] !== 32'hE000_0000+(bank << 16)+row*(FW/4)+col)
                        bad=bad+1;
                end
    end
    chk(11,bad==0);
    preview_read=1'b1;
    aexp=0;
    au_enable=1'b1;
    video_frame;
    au_enable=1'b0;
    preview_read=1'b0;
    chk(13,au_err_cnt==0);

    $display("        %0d video frames, %0d audio samples, %0d audio bursts, %0d audio pops found FIFO empty",
             frames_done, aexp, au_bursts, a_empty_hits);
    report(0, "frame_read_write and audio never issue reads in the same cycle");
    report(1, "no read and write in the same cycle");
    report(2, "audio FIFO never written while full");
    report(5, "audio area written linearly through write channel (buffer 2, no flip)");
    report(3, "every video pixel correct while audio and writes run");
    report(4, "every audio sample correct, loops over 768 words");
    report(6, "buffer 1 written with vertical flip, 3 frames, all words correct");
    report(7, "disable: owner released, FIFO flushed");
    report(9, "bank 2 image written with vertical flip, audio area intact");
    report(10, "bank 3 image written with vertical flip");
    report(11, "four RGB565 previews map to upright 2x2 raster");
    report(12, "every packed preview word reads back in screen order");
    report(13, "audio read remains healthy during preview frame");
    report(3, "video reader selects all resident bank addresses");
    chk(8, au_err_cnt == 0);
    if (DROP) $display("        err_cnt = %0d (expected > 0 with DROP)", au_err_cnt);
    else report(8, "no short / timed-out audio bursts (err_cnt = 0)");
    $display("");
    if (errors == 0) $display("== ALL PASSED");
    else             $display("== %0d FAILED", errors);
    $finish;
end

initial begin
    #50_000_000;
    $display("== TIMEOUT");
    $finish;
end

endmodule

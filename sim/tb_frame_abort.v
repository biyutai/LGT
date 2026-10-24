// 复现"读卡中拔卡"后的帧写通道状态：一帧写到一半中断，再完整写下一帧，
// 检查写完成信号与 SDRAM 内容是否正常（用真实加密 SDRAM 控制器 + 芯片模型）。
// 运行：sim/run.sh tb_frame_abort
`timescale 1ns / 1ps

module tb_frame_abort;

localparam integer FW = 64;
localparam integer FH = 16;
localparam integer FRAME = FW * FH;
localparam [20:0] BUF0 = 21'd0;

reg mem_clk = 0, mem_clk_sft = 1, video_clk = 0, sd_clk = 0;
always #4  begin mem_clk = ~mem_clk; mem_clk_sft = ~mem_clk_sft; end
always #20 video_clk = ~video_clk;
always #10 sd_clk    = ~sd_clk;                 // 50MHz，与板上 SD 域一致

reg rst = 1'b1;

wire App_wr_en, App_rd_en;
wire [20:0] App_wr_addr, App_rd_addr;
wire [31:0] App_wr_din;
wire [3:0]  App_wr_dm;
wire Sdr_init_done, Sdr_init_ref_vld, Sdr_busy;
wire Sdr_rd_en;
wire [31:0] Sdr_rd_dout;

sdram U3 (
    .Clk(mem_clk), .Clk_sft(mem_clk_sft), .Rst(rst),
    .Sdr_init_done(Sdr_init_done), .Sdr_init_ref_vld(Sdr_init_ref_vld),
    .Sdr_busy(Sdr_busy),
    .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr),
    .App_wr_dm(App_wr_dm), .App_wr_din(App_wr_din),
    .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr),
    .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout)
);

function [20:0] chip_idx(input [20:0] a);
    chip_idx = {a[3:2], a[20:10], a[9:4], a[1:0]};
endfunction
`define MEM(a) U3.sdram.mem[chip_idx(a)]

wire fr_burst, read_empty;
reg  read_req = 1'b0;
wire read_req_ack, read_finish;
reg  read_en = 1'b0;
wire [31:0] read_data;
reg  write_req = 1'b0;
wire write_req_ack, write_finish;
reg  [1:0]  write_idx = 2'd0;
reg  [20:0] write_len = FRAME[20:0];
reg         write_en = 1'b0;
reg  [31:0] write_data = 32'd0;

frame_read_write #(
    .BURST_SIZE(128), .WRITE_V_FLIP(1),
    .FRAME_WIDTH(FW), .FRAME_HEIGHT(FH)
) dut (
    .rst(rst), .mem_clk(mem_clk),
    .Sdr_init_done(Sdr_init_done), .Sdr_init_ref_vld(Sdr_init_ref_vld),
    .Sdr_busy(Sdr_busy), .ext_rd_busy(1'b0), .fr_burst(fr_burst),
    .read_index_cur(), .read_empty(read_empty),
    .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr),
    .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout),
    .read_clk(video_clk), .read_req(read_req), .read_req_ack(read_req_ack),
    .read_finish(read_finish),
    .read_addr_0(BUF0), .read_addr_1(21'd1024),
    .read_addr_2(21'd0), .read_addr_3(21'd0),
    .read_addr_index(2'd0), .read_is_preview(1'b0), .read_preview_addr(21'd0),
    .read_len(FRAME[20:0]), .read_en(read_en), .read_data(read_data),
    .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr),
    .App_wr_din(App_wr_din), .App_wr_dm(App_wr_dm),
    .write_clk(sd_clk), .write_req(write_req),
    .write_req_ack(write_req_ack), .write_finish(write_finish),
    .write_addr_0(BUF0), .write_addr_1(21'd1024),
    .write_addr_2(21'd0), .write_addr_3(21'd0),
    .write_addr_index(write_idx), .write_is_wav(1'b0),
    .write_is_preview(1'b0), .write_len(write_len),
    .write_en(write_en), .write_data(write_data)
);

integer errors = 0;
task check(input cond, input [8*64-1:0] msg);
    begin
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s (t=%0t)", msg, $time); errors = errors + 1; end
    end
endtask

// 发起一次写请求，返回是否在超时内收到应答
task start_write(output reg ack);
    integer t;
    begin
        @(posedge sd_clk) write_idx <= 2'd0;
        repeat (4) @(posedge sd_clk);
        write_req <= 1'b1;
        t = 0; ack = 1'b0;
        while (!ack && t < 100_000) begin
            @(posedge sd_clk); t = t + 1;
            if (write_req_ack) ack = 1'b1;
        end
        @(posedge sd_clk) write_req <= 1'b0;
        // FIFO 异步清还在 write_req_d2 撤销前保持几拍，等它释放后再送数据
        repeat (8) @(posedge sd_clk);
    end
endtask

task feed(input integer n, input [31:0] base);
    integer k;
    begin
        for (k = 0; k < n; k = k + 1) begin
            @(posedge sd_clk) begin write_en <= 1'b1; write_data <= base + k; end
            @(posedge sd_clk) write_en <= 1'b0;
            @(posedge sd_clk);
        end
    end
endtask

reg ack;
reg seen_finish = 1'b0;
// write_finish 是 mem_clk 域的一拍脉冲（125MHz，8ns），必须在 mem_clk 采样
always @(posedge mem_clk) if (write_finish) seen_finish <= 1'b1;
integer t, bad, r, c;
initial begin
    repeat (20) @(posedge mem_clk);
    rst <= 1'b0;
    wait (Sdr_init_done);
    repeat (50) @(posedge mem_clk);

    if ($test$plusargs("CLEAN")) begin
        $display("== 0. clean full frame");
        start_write(ack);
        feed(FRAME, 32'h3000_0000);
        t = 0;
        while (!seen_finish && t < 1_000_000) begin @(posedge sd_clk); t = t + 1; end
        check(seen_finish, "clean frame reaches write_finish");
        seen_finish = 1'b0;
        repeat (200) @(posedge mem_clk);
    end

    $display("== 1. write 100 words of a frame, then abort (card pulled)");
    start_write(ack);
    check(ack, "first write request acked");
    feed(100, 32'h1000_0000);
    // 拔卡：源端不再送数据，写请求也早已撤销；等 FIFO/状态机自己停下
    repeat (2000) @(posedge sd_clk);

    $display("== 2. write the next full frame after re-mount");
    start_write(ack);
    check(ack, "second write request acked after abort");
    feed(FRAME, 32'h2000_0000);
    t = 0;
    while (!seen_finish && t < 1_000_000) begin @(posedge sd_clk); t = t + 1; end
    check(seen_finish, "second frame reaches write_finish after an aborted frame");
    $display("        seen_finish=%b state=%0d waited=%0d", seen_finish,
             dut.frame_fifo_write_m0.state, t);
    $display("        words_remaining=%0d rdusedw=%0d fifo_ready_q=%b write_cnt=%0d write_len_latch=%0d App_rd_busy=%b Sdr_busy=%b",
             dut.frame_fifo_write_m0.words_remaining, dut.frame_fifo_write_m0.rdusedw,
             dut.frame_fifo_write_m0.fifo_ready_q, dut.frame_fifo_write_m0.write_cnt,
             dut.frame_fifo_write_m0.write_len_latch, dut.frame_fifo_write_m0.App_rd_busy,
             Sdr_busy);
    repeat (200) @(posedge mem_clk);

    bad = 0;
    for (r = 0; r < FH; r = r + 1)
        for (c = 0; c < FW; c = c + 1)
            if (`MEM(BUF0 + (FH - 1 - r) * FW + c) !== 32'h2000_0000 + r * FW + c)
                bad = bad + 1;
    check(bad == 0, "SDRAM holds the complete second frame after the abort");

    if (errors == 0) $display("== ALL PASSED");
    else             $display("== %0d FAILED", errors);
    $finish;
end

endmodule

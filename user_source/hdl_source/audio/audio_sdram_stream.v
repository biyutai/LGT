// 从 SDRAM 音频区循环读出 WAV 样本，经异步 FIFO 交给像素时钟域播放
//
// mem_clk 侧（125MHz）：作为 SDRAM 的第三个读口，优先级最低，两步占用：
//   1. FIFO 不够满时拉高 owner。owner 一拉高，frame_read_write 的读、写通道都不再开始新的突发
//      （owner 接到它的 ext_rd_busy）。
//   2. 再等它手上可能正在进行的那一次突发结束（fr_burst 寄存一拍后为 0，且至少等过 1 拍）、
//      所有已发出的读都已返回、并且 SDRAM 控制器空闲（Sdr_busy = 0），才开始连续读 BURST 个字；
//      读完、等全部数据返回后释放 owner。
//      Sdr_busy 必须等：官方控制器在上一次操作收尾前（约 11 拍）收到新突发会漏发 ACT、读错数据，
//      刚写完图片紧接着读音频就会碰上（第 5b 步用真实控制器仿真查出）。
//   开始读之前所有在途读数归零，读完也等归零才释放，所以 S_ISSUE / S_DRAIN 期间返回的数据都是本模块的：
//   mine 为 1 时数据进音频 FIFO，顶层用它把 Sdr_rd_en 从 frame_read_write 那里屏蔽掉。
//   注意不能用 owner 判断：S_WAIT 期间 owner 已经为 1，但返回的还是视频的数据。
//   在途读数按全部读口统计（自己的 + frame_read_write 的），不依赖 SDRAM 读延迟是多少拍。
// video_clk 侧（25MHz）：pop 一拍，下一拍 data 有效（FIFO 非预读模式）。
//
// 地址在 [base_addr, base_addr + words) 里循环。enable 撤销时清空 FIFO、指针回到开头。
// words 来自 SD 卡时钟域，在 enable 拉高之前就已稳定；enable 为 0 期间每拍把最后一个地址算好寄存，
// enable 为 1 之后不再采样（SDC 里对这条路径设了 false path）。
module audio_sdram_stream #(
    parameter integer BURST     = 64,                 // 每次突发读的字数
    parameter [8:0]   FIFO_LOW  = 9'd432              // FIFO 写侧计数低于它就再读一包（512 - 64 - 16，保证不溢出）
)(
    // ---------------- mem_clk 域 ----------------
    input  wire        mem_clk,
    input  wire        mem_rst,          // 高电平有效，与 mem_clk 同步撤销
    input  wire        enable,           // 已同步到 mem_clk：WAV 已在音频区
    input  wire [20:0] words,            // 音频区有效字数（来自 SD 卡时钟域，enable 之前已稳定）
    input  wire [20:0] base_addr,

    input  wire        fr_burst,         // frame_read_write：读或写通道正在突发（状态译码）
    input  wire        sdr_busy,         // SDRAM 控制器 Sdr_busy
    output reg         owner,            // 本模块占用 SDRAM 读口（frame_read_write 不再开始新突发）
    output wire        mine,             // 现在 SDRAM 返回的数据属于本模块

    input  wire        other_rd_en,      // frame_read_write 发给 SDRAM 的读请求（统计在途读数）
    output reg         rd_en,            // 本模块发给 SDRAM 的读请求
    output reg  [20:0] rd_addr,
    input  wire        sdr_rd_en,        // SDRAM 返回数据有效（所有读口共用）
    input  wire [31:0] sdr_rd_dout,

    // ---------------- video_clk 域 ----------------
    input  wire        video_clk,
    input  wire        pop,              // 取一个字（FIFO 空时不取）
    output wire [31:0] data,             // pop 之后下一拍有效
    output wire        empty,

    // 错误计数（mem_clk 域）：一次突发收到的数据不是 BURST 个、或等返回超时的次数，饱和不回绕
    output reg  [3:0]  err_cnt
);

localparam [1:0] S_IDLE  = 2'd0;
localparam [1:0] S_WAIT  = 2'd1;
localparam [1:0] S_ISSUE = 2'd2;
localparam [1:0] S_DRAIN = 2'd3;

reg  [1:0]  state;
reg  [7:0]  issue_cnt;
reg  [9:0]  inflight;          // 所有读口已发出、还没返回的读
reg  [8:0]  wait_cnt;          // S_WAIT / S_DRAIN 已等的拍数，S_DRAIN 用它防止 SDRAM 少回数据时卡死
reg  [20:0] ptr;               // 下一个要读的地址
reg  [20:0] last_addr;         // 音频区最后一个地址
reg  [7:0]  rx_cnt;            // 本次突发已收到的字数
reg         fr_burst_q;
reg         fifo_rst;

wire [8:0]  fifo_used;         // 写侧计数（偏大，只会更保守）

assign mine = (state == S_ISSUE) || (state == S_DRAIN);

always @(posedge mem_clk or posedge mem_rst) begin
    if (mem_rst) begin
        inflight   <= 10'd0;
        fr_burst_q <= 1'b0;
        last_addr  <= 21'd0;
    end else begin
        fr_burst_q <= fr_burst;
        if (!enable)
            last_addr <= base_addr + words - 21'd1;
        if (state == S_DRAIN && wait_cnt == 9'd511)
            inflight <= 10'd0;                               // 超时：重新对齐计数
        else
            inflight <= inflight + {9'd0, rd_en | other_rd_en} - {9'd0, sdr_rd_en};
    end
end

always @(posedge mem_clk or posedge mem_rst) begin
    if (mem_rst) begin
        state     <= S_IDLE;
        owner     <= 1'b0;
        rd_en     <= 1'b0;
        rd_addr   <= 21'd0;
        ptr       <= 21'd0;
        issue_cnt <= 8'd0;
        wait_cnt  <= 9'd0;
        fifo_rst  <= 1'b1;
        rx_cnt    <= 8'd0;
        err_cnt   <= 4'd0;
    end else begin
        if (sdr_rd_en && mine)
            rx_cnt <= rx_cnt + 8'd1;
        fifo_rst <= ~enable;
        rd_en    <= 1'b0;

        case (state)
            S_IDLE: begin
                if (!enable)
                    ptr <= base_addr;
                else if ((fifo_used < FIFO_LOW) && !fifo_rst) begin
                    owner    <= 1'b1;             // 从下一拍起 frame_read_write 不再开始新突发
                    wait_cnt <= 9'd0;
                    state    <= S_WAIT;
                end
            end

            S_WAIT: begin
                // 第 0 拍的 fr_burst_q 还是拉 owner 之前的值，不可信；从第 1 拍起它只会从 1 变 0
                wait_cnt <= wait_cnt + 9'd1;
                if (!enable) begin
                    owner <= 1'b0;
                    state <= S_IDLE;
                end else if ((wait_cnt != 9'd0) && !fr_burst_q && (inflight == 10'd0) && !sdr_busy) begin
                    issue_cnt <= 8'd0;
                    rx_cnt    <= 8'd0;
                    state     <= S_ISSUE;
                end
            end

            S_ISSUE: begin
                rd_en     <= 1'b1;
                rd_addr   <= ptr;
                ptr       <= (ptr == last_addr) ? base_addr : ptr + 21'd1;
                issue_cnt <= issue_cnt + 8'd1;
                if (issue_cnt == BURST - 1) begin
                    wait_cnt <= 9'd0;
                    state    <= S_DRAIN;
                end
            end

            S_DRAIN: begin
                // 最后一个读请求在进入本状态这一拍发出，之后等在途读数归零
                wait_cnt <= wait_cnt + 9'd1;
                if (((inflight == 10'd0) && !rd_en) || wait_cnt == 9'd511) begin
                    owner <= 1'b0;
                    state <= S_IDLE;
                    if (((wait_cnt == 9'd511) || (rx_cnt + {7'd0, sdr_rd_en} != BURST)) && err_cnt != 4'hF)
                        err_cnt <= err_cnt + 4'd1;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

// 与 frame_read_write 里的读 FIFO 同一个 IP：32 位 × 512，非预读，pop 后下一拍出数据
rfifo_32_32_512 u_audio_fifo (
    .rst        (fifo_rst | mem_rst),
    .clkw       (mem_clk),
    .clkr       (video_clk),
    .we         (sdr_rd_en & mine),
    .di         (sdr_rd_dout),
    .re         (pop),
    .dout       (data),
    .valid      (),
    .full_flag  (),
    .empty_flag (empty),
    .afull      (),
    .aempty     (),
    .wrusedw    (fifo_used),
    .rdusedw    ()
);

endmodule

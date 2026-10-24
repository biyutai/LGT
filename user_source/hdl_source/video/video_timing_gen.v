// 视频时序发生器
//
// 产生行同步 hs、场同步 vs、数据有效 de，以及有效区内的像素坐标 x / y；
// 每帧场同步开始时向帧缓存发一次读请求 read_req（保持到 read_req_ack）。
// 时序参数可配置，默认 640×480@60（800×525，行场同步均负极性）。
//
// 一行（一帧同理）按 有效 → 前沿 → 同步 → 后沿 排列，计数器 0 就是第一个有效像素，
// 所以有效区内 x = h_cnt、y = v_cnt，不需要再做减法。
// 场计数在行同步开始时 +1，场同步沿与行同步前沿对齐。
//
// 复位后从行、场前沿开始计数（先输出消隐），所有输出比计数器晚 OUT_LATENCY 拍。
// 这两点让本模块与替换掉的官方 color_bar + video_timing_data 逐拍对齐（de / x / y 从复位起一致，
// hs / vs / read_req 从第 2 帧起一致；官方第 1 帧的同步信号从复位起就处于有效电平，这里改为正常的无效电平），
// 后级 video_delay 的 21 拍对齐和 HDMI 发射 IP 收到的视频流都不受影响。
module video_timing_gen #(
    parameter integer H_ACTIVE = 640,
    parameter integer H_FP     = 16,
    parameter integer H_SYNC   = 96,
    parameter integer H_BP     = 48,
    parameter integer V_ACTIVE = 480,
    parameter integer V_FP     = 10,
    parameter integer V_SYNC   = 2,
    parameter integer V_BP     = 33,
    parameter         HS_POL   = 1'b0,      // 同步有效电平：1 正极性，0 负极性
    parameter         VS_POL   = 1'b0,
    parameter integer OUT_LATENCY = 3       // 输出相对计数器的拍数，>= 2
)(
    input  wire        clk,                 // 像素时钟
    input  wire        rst,                 // 高电平有效，与 clk 同步撤销

    output wire        hs,
    output wire        vs,
    output wire        de,
    output wire [11:0] x,                   // de = 1 时有效：0 ~ H_ACTIVE-1
    output wire [11:0] y,                   // de = 1 时有效：0 ~ V_ACTIVE-1

    output reg         read_req,            // 每帧一次的帧缓存读请求
    input  wire        read_req_ack
);

localparam integer H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
localparam integer V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

localparam integer H_SYNC_BEGIN = H_ACTIVE + H_FP;          // 行同步第一个像素
localparam integer H_SYNC_END   = H_ACTIVE + H_FP + H_SYNC; // 行同步之后第一个像素
localparam integer V_SYNC_BEGIN = V_ACTIVE + V_FP;
localparam integer V_SYNC_END   = V_ACTIVE + V_FP + V_SYNC;

// ---------------- 行、场计数器 ----------------
reg [11:0] h_cnt;
reg [11:0] v_cnt;

always @(posedge clk or posedge rst) begin
    if (rst)
        h_cnt <= H_ACTIVE[11:0];
    else if (h_cnt == H_TOTAL - 1)
        h_cnt <= 12'd0;
    else
        h_cnt <= h_cnt + 12'd1;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        v_cnt <= V_ACTIVE[11:0];
    else if (h_cnt == H_SYNC_BEGIN - 1) begin
        if (v_cnt == V_TOTAL - 1)
            v_cnt <= 12'd0;
        else
            v_cnt <= v_cnt + 12'd1;
    end
end

// ---------------- 译码 + 输出流水 ----------------
// 按当前计数组合译码，再经 OUT_LATENCY 级移位寄存器输出。
// 移位寄存器里第 k 级（k = 1 ~ OUT_LATENCY）是 k 拍之前的译码结果
wire        hs_act_c = (h_cnt >= H_SYNC_BEGIN) && (h_cnt < H_SYNC_END);
wire        vs_act_c = (v_cnt >= V_SYNC_BEGIN) && (v_cnt < V_SYNC_END);
wire        de_c     = (h_cnt <  H_ACTIVE)     && (v_cnt <  V_ACTIVE);

localparam integer N = OUT_LATENCY;

reg [N-1:0]    hs_act_sr;          // [0] 是第 1 级
reg [N-1:0]    vs_act_sr;
reg [N-1:0]    de_sr;
reg [12*N-1:0] x_sr;               // [11:0] 是第 1 级
reg [12*N-1:0] y_sr;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        hs_act_sr <= {N{1'b0}};
        vs_act_sr <= {N{1'b0}};
        de_sr     <= {N{1'b0}};
        x_sr      <= {12*N{1'b0}};
        y_sr      <= {12*N{1'b0}};
    end else begin
        hs_act_sr <= {hs_act_sr[N-2:0], hs_act_c};
        vs_act_sr <= {vs_act_sr[N-2:0], vs_act_c};
        de_sr     <= {de_sr[N-2:0],     de_c};
        x_sr      <= {x_sr[12*(N-1)-1:0], (de_c ? h_cnt : 12'd0)};
        y_sr      <= {y_sr[12*(N-1)-1:0], (de_c ? v_cnt : 12'd0)};
    end
end

assign hs = hs_act_sr[N-1] ? HS_POL : ~HS_POL;
assign vs = vs_act_sr[N-1] ? VS_POL : ~VS_POL;
assign de = de_sr[N-1];
assign x  = x_sr[12*N-1 -: 12];
assign y  = y_sr[12*N-1 -: 12];

// ---------------- 帧缓存读请求 ----------------
// 场同步开始后第 2 拍拉高（默认 3 拍延迟下比 vs 输出早一拍，与官方 video_timing_data 相同），
// 场同步加后沿共 35 行消隐，读 FIFO 有足够时间预取第一行
wire vs_start = vs_act_sr[0] & ~vs_act_sr[1];

always @(posedge clk or posedge rst) begin
    if (rst)
        read_req <= 1'b0;
    else if (vs_start)
        read_req <= 1'b1;
    else if (read_req_ack)
        read_req <= 1'b0;
end

endmodule

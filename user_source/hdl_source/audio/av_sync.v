// 音画同步（第 5c 步）：按 WAV 播放位置产生切图节拍，并测量音画同步误差
//
// 【节拍】每张图的时长 SEG = WAV 字数 / 图片张数（WAV 开始播放时用移位相减除法算一次）。
// 对齐点在播放位置 SEG、2·SEG、……、(N-1)·SEG 和循环回到 0 处：一轮正好 N 个，每轮位置相同。
// 计数的是播放器实际送出的样本（FIFO 读空时不计），所以对齐点始终跟着音乐内容走。
// 音频节拍和像素时钟出自同一个 25MHz，两者之间没有长期漂移。
//
// 【提前量】切图链路：节拍 → sd_card_bmp 切显示缓冲（几十 ns）→ 下一帧场同步时 frame_fifo_read 换缓冲
//   → 再过 D（场同步 + 场后沿 + 行同步 + 行后沿 + 对齐流水）新图第一个像素进 HDMI IP。
// 换缓冲只能在帧首，所以画面相对节拍会晚 0 ~ 1 帧不定。节拍提前 LEAD 个样本发出，
// LEAD ≈ (D + 半帧) 换算成样本数，误差就落在 ±半帧（约 ±8.4ms）之内。顶层按时序参数算好传进来。
// SEG 太短（≤ 2·LEAD）时不提前，避免节拍跑到上一段里去。
//
// 【测量】节拍发出后，记下"对齐点那个样本送进 HDMI IP"和"显示缓冲换掉后第一帧的第一个像素送进 HDMI IP"
// 两个时刻，相减得到误差（像素时钟数，正 = 画面晚于声音）。两者都在 HDMI 发射 IP 的输入端测，
// 不含 IP 内部的音频打包缓冲和显示器自己的处理延迟。3 帧内没测到两个事件就放弃这一次（例如这次没切成）。
module av_sync #(
    parameter integer LEAD_SAMPLES = 453,           // 25.2MHz、640×480@60Hz 下的值，由 top_tf_hdmi_audio.v 按公式传入
    parameter integer MEAS_TIMEOUT = 1_260_000      // 3 帧
)(
    input  wire        clk,                 // video_clk
    input  wire        rst,                 // 高电平有效，与 clk 同步撤销
    input  wire        active,              // WAV 正在播放（wav_ready 已同步到 clk）；为 0 时全部复位
    input  wire [20:0] words,               // WAV 字数：来自 SD 卡时钟域，active 之前已稳定
    input  wire [2:0]  img_count,           // 图片张数：同上
    input  wire        played,              // 本拍有一个 WAV 样本送进 HDMI IP（与 audio_valid 同拍）

    output reg         beat_toggle,         // 每个节拍翻转一次，送 sd_card_bmp
    output reg  [7:0]  beat_cnt,
    output wire [20:0] segment_samples,     // 每张图对应的 WAV 样本数，供呼吸灯使用

    input  wire        sof,                 // 一帧的第一个像素送进 HDMI IP
    input  wire [1:0]  frame_buf,           // 当前帧显示的缓冲编号（已同步，整帧不变）
    output reg  signed [23:0] err_last,     // 最近一次误差，像素时钟数
    output reg  [23:0] err_max_abs,         // 播放以来误差绝对值的最大值
    output reg  [7:0]  meas_cnt             // 测到的次数
);

// ---------------- 配置：SEG = words / img_count ----------------
localparam [1:0] C_IDLE = 2'd0;
localparam [1:0] C_DIV  = 2'd1;
localparam [1:0] C_SET  = 2'd2;
localparam [1:0] C_RUN  = 2'd3;

reg [1:0]  cfg;
reg [20:0] words_q;
reg [2:0]  n_q;
reg [4:0]  div_cnt;
reg [20:0] div_q;
reg [20:0] div_r;
reg [20:0] seg;
reg [20:0] lead;
reg        en;                          // 已算好，开始出节拍
assign segment_samples = en ? seg : 21'd0;

wire [21:0] r_sh = {div_r, div_q[20]};
wire        r_ge = (r_sh >= {19'd0, n_q});

// ---------------- 节拍 ----------------
reg  [20:0] pos;                        // 当前送出的样本在 WAV 里的位置
reg  [20:0] bnd;                        // 下一个对齐点（SEG 的倍数，或 words 表示回到开头）
wire [20:0] trig     = (bnd - lead == words_q) ? 21'd0 : (bnd - lead);
wire [20:0] bnd_pos  = (bnd == words_q) ? 21'd0 : bnd;
wire [20:0] bnd_next = (bnd == words_q)                 ? seg :
                       (bnd + seg + seg > words_q)      ? words_q :
                                                          bnd + seg;
wire        fire     = active && en && played && (pos == trig);

// ---------------- 测量 ----------------
reg  [31:0] tcnt;
reg         armed, a_done, v_done;
reg  [20:0] meas_pos;
reg  [31:0] t_a, t_v;
reg  [20:0] meas_age;
reg  [1:0]  last_buf;
reg         last_buf_v;
wire [31:0] diff     = t_v - t_a;
wire signed [23:0] err_now = diff[23:0];
wire [23:0] err_abs  = err_now[23] ? -err_now : err_now;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        cfg         <= C_IDLE;
        words_q     <= 21'd0;
        n_q         <= 3'd0;
        div_cnt     <= 5'd0;
        div_q       <= 21'd0;
        div_r       <= 21'd0;
        seg         <= 21'd0;
        lead        <= 21'd0;
        en          <= 1'b0;
        pos         <= 21'd0;
        bnd         <= 21'd0;
        beat_toggle <= 1'b0;
        beat_cnt    <= 8'd0;
    end else if (!active) begin
        cfg      <= C_IDLE;
        en       <= 1'b0;
        pos      <= 21'd0;
        beat_cnt <= 8'd0;
    end else begin
        // 配置
        case (cfg)
            C_IDLE: begin
                words_q <= words;
                n_q     <= img_count;
                div_q   <= words;
                div_r   <= 21'd0;
                div_cnt <= 5'd21;
                cfg     <= (img_count >= 3'd2 && words >= 21'd256) ? C_DIV : C_RUN;   // 1 张图不切换
            end
            C_DIV: begin
                // 移位相减（恢复余数）除法，每拍出一位商
                div_r   <= r_ge ? (r_sh[20:0] - {18'd0, n_q}) : r_sh[20:0];
                div_q   <= {div_q[19:0], r_ge};
                div_cnt <= div_cnt - 5'd1;
                if (div_cnt == 5'd1) begin
                    seg <= {div_q[19:0], r_ge};
                    cfg <= C_SET;
                end
            end
            C_SET: begin
                lead <= (seg > 2 * LEAD_SAMPLES) ? LEAD_SAMPLES[20:0] : 21'd0;
                bnd  <= seg;
                en   <= 1'b1;
                cfg  <= C_RUN;
            end
            default: ;
        endcase

        // 节拍：本拍送出的样本位置正好是触发点
        if (fire) begin
            beat_toggle <= ~beat_toggle;
            beat_cnt    <= beat_cnt + 8'd1;
            bnd         <= bnd_next;
        end

        // 播放位置
        if (played)
            pos <= (pos == words_q - 21'd1) ? 21'd0 : pos + 21'd1;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        tcnt        <= 32'd0;
        armed       <= 1'b0;
        a_done      <= 1'b0;
        v_done      <= 1'b0;
        meas_pos    <= 21'd0;
        t_a         <= 32'd0;
        t_v         <= 32'd0;
        meas_age    <= 21'd0;
        last_buf    <= 2'd0;
        last_buf_v  <= 1'b0;
        err_last    <= 24'sd0;
        err_max_abs <= 24'd0;
        meas_cnt    <= 8'd0;
    end else begin
        tcnt <= tcnt + 32'd1;

        // 每帧记下显示的是哪块缓冲，换了就是"新图第一帧"
        if (sof) begin
            last_buf   <= frame_buf;
            last_buf_v <= 1'b1;
        end

        if (!active) begin
            armed       <= 1'b0;
            err_last    <= 24'sd0;
            err_max_abs <= 24'd0;
            meas_cnt    <= 8'd0;
        end else if (fire) begin
            armed    <= 1'b1;
            v_done   <= 1'b0;
            meas_pos <= bnd_pos;
            meas_age <= 21'd0;
            // 不提前（lead = 0）时，节拍这一拍送出的就是对齐点样本
            a_done   <= (pos == bnd_pos);
            t_a      <= tcnt;
        end else if (armed) begin
            meas_age <= meas_age + 21'd1;
            if (played && pos == meas_pos && !a_done) begin
                t_a    <= tcnt;
                a_done <= 1'b1;
            end
            if (sof && last_buf_v && frame_buf != last_buf && !v_done) begin
                t_v    <= tcnt;
                v_done <= 1'b1;
            end
            if (a_done && v_done) begin
                armed    <= 1'b0;
                err_last <= err_now;
                if (err_abs > err_max_abs)
                    err_max_abs <= err_abs;
                if (meas_cnt != 8'hFF)
                    meas_cnt <= meas_cnt + 8'd1;
            end else if (meas_age == MEAS_TIMEOUT - 1) begin
                armed <= 1'b0;
            end
        end
    end
end

endmodule

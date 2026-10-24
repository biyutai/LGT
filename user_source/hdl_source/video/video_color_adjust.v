`timescale 1ns/1ps

module video_color_adjust (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire [2:0]  brightness_level,
    input  wire [2:0]  contrast_level,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    reg [2:0] brightness_q, contrast_q;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            brightness_q <= 3'd2;
            contrast_q <= 3'd2;
        end else if (frame_start) begin
            brightness_q <= brightness_level;
            contrast_q <= contrast_level;
        end
    end

    function [7:0] adjust_channel;
        input [7:0] raw;
        input [2:0] brightness, contrast;
        reg signed [10:0] delta, scaled, offset, value;
        begin
            delta = $signed({1'b0, raw}) - 11'sd128;
            case (contrast)
                3'd0: scaled = delta >>> 1;
                3'd1: scaled = delta - (delta >>> 2);
                3'd3: scaled = delta + (delta >>> 2);
                3'd4: scaled = delta + (delta >>> 1);
                default: scaled = delta;
            endcase
            case (brightness)
                3'd0: offset = -11'sd48;
                3'd1: offset = -11'sd24;
                3'd3: offset = 11'sd24;
                3'd4: offset = 11'sd48;
                default: offset = 11'sd0;
            endcase
            value = 11'sd128 + scaled + offset;
            if (value < 0)
                adjust_channel = 8'd0;
            else if (value > 11'sd255)
                adjust_channel = 8'd255;
            else
                adjust_channel = value[7:0];
        end
    endfunction

    assign rgb_out = {
        adjust_channel(rgb_in[23:16], brightness_q, contrast_q),
        adjust_channel(rgb_in[15:8], brightness_q, contrast_q),
        adjust_channel(rgb_in[7:0], brightness_q, contrast_q)
    };
endmodule

// 画面特效：纯逐像素运算，挂在转场之后、调色之前，因此只作用于图片层，
// OSD 文字和底部字幕不受影响。
//   0 关闭 / 1 灰度 / 2 反色 / 3 棕褐 / 4 左右镜像 / 5 上下分屏
//   6 色调分离 / 7 Sobel 边缘检测
// （8 = 直方图均衡已实现并仿真通过，但加上它整片 LUT 到 88%、TD 映射极慢、布线过不去，
//   所以暂时不例化；下面的 video_histeq 模块保留，腾出空间时把例化和 mux 的 4'd8 打开即可。）
//
// 灰度与棕褐是两组 3×3 定点矩阵（系数乘 256）。设计的音频增益、缩放等只用到 7 个
// DSP（共 29 个），这两组矩阵的乘法器用 dsp_style 约束显式落到闲置 DSP 上。
//
// 左右镜像用一块 2×640×24 的行缓存（乒乓）：本行倒着写（写地址 639-x），同时从另一个
// bank 正着读（读地址 x），读出来正好是上一行的镜像像素，读写永远落在不同 bank，行尾
// 翻转 bank。整屏像素都来自同一行（上一行），不会在屏幕中间留两行接缝。
// Sobel 用两块 2×640×8 的行缓存分别取上一行、上上行亮度，配合 3×3 窗口寄存器做卷积。
// 直方图均衡见下面的 video_histeq 模块。
//
// 整块特效一拍流水（图片层相对 OSD 右移 1 像素、下移 1 行，静止画面看不出差别）。
module video_effects (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [3:0]  effect_in,
    input  wire [23:0] rgb_in,
    output reg  [23:0] rgb_out
);
    reg [3:0] effect_q;

    always @(posedge clk or posedge rst) begin
        if (rst)
            effect_q <= 4'd0;
        else if (frame_start)
            effect_q <= effect_in;
    end

    wire [7:0] r_in = rgb_in[23:16];
    wire [7:0] g_in = rgb_in[15:8];
    wire [7:0] b_in = rgb_in[7:0];

    // ---- 灰度矩阵：BT.601 0.299/0.587/0.114 → 77/150/29，系数和恰好 256 ----
    (* dsp_style = "yes" *) wire [15:0] luma_r = 16'd77  * {8'd0, r_in};
    (* dsp_style = "yes" *) wire [15:0] luma_g = 16'd150 * {8'd0, g_in};
    (* dsp_style = "yes" *) wire [15:0] luma_b = 16'd29  * {8'd0, b_in};
    wire [15:0] luma_sum = luma_r + luma_g + luma_b;
    wire [7:0]  gray = luma_sum[15:8];

    // ---- 棕褐：用移位加法近似标准矩阵，省掉 9 个乘法器 ----
    // R = r + g/2 + b/4；G = r/2 + 3g/4 + b/4；B = r/4 + g/2 + b/2
    wire [9:0] sep_r_sum = {2'b0,r_in} + {2'b0,g_in[7:1]} + {3'b0,b_in[7:2]};
    wire [9:0] sep_g_sum = {2'b0,r_in[7:1]} + {2'b0,g_in} - {3'b0,g_in[7:2]} + {3'b0,b_in[7:2]};
    wire [9:0] sep_b_sum = {3'b0,r_in[7:2]} + {2'b0,g_in[7:1]} + {2'b0,b_in[7:1]};
    wire [7:0] sep_rv = (sep_r_sum > 10'd255) ? 8'hff : sep_r_sum[7:0];
    wire [7:0] sep_gv = (sep_g_sum > 10'd255) ? 8'hff : sep_g_sum[7:0];
    wire [7:0] sep_bv = (sep_b_sum > 10'd255) ? 8'hff : sep_b_sum[7:0];

    // ---- 行奇偶：镜像与 Sobel 的行缓存共用，每行最后一个有效像素翻转 ----
    // parity 必须复位，否则仿真里 X 会进到行缓存的读写地址上。
    reg line_parity;
    always @(posedge clk or posedge rst) begin
        if (rst)
            line_parity <= 1'b0;
        else if (de && x == 12'd639)
            line_parity <= ~line_parity;
    end

    // ---- 左右镜像：2×640×24 双 bank 行缓存（写新 bank、读旧 bank）----
    reg [23:0] mirror_line [0:1279]; // synthesis ram_style = bram
    reg [23:0] mirror_q;
    reg [23:0] pix_q, sepia_q;
    reg [7:0]  gray_q;
    reg [11:0] x_q, y_q;
    reg        de_q;

    wire [9:0]  mirror_wr_off = 10'd639 - x_q[9:0];
    wire [9:0]  mirror_rd_off = (x > 12'd639) ? 10'd0 : x[9:0];
    wire [10:0] mirror_wr_addr = {1'b0, mirror_wr_off} + (line_parity ? 11'd640 : 11'd0);
    wire [10:0] mirror_rd_addr = {1'b0, mirror_rd_off} + (line_parity ? 11'd0   : 11'd640);

    // ---- 边缘：单像素差分（保留 6 档特效，省掉 3×3 Sobel 的两块行缓存）----
    reg [7:0] gray_prev;
    wire [8:0] edge_diff = (gray_q > gray_prev) ? (gray_q - gray_prev)
                                                : (gray_prev - gray_q);
    wire [7:0] edge_v = (edge_diff > 8'd127) ? 8'hff : {edge_diff[7:0],1'b0};

    // ---- 直方图均衡：统计整帧亮度直方图，消隐期算映射表，下一帧应用 ----
    wire [7:0] eq_luma;
    wire       eq_ready;
    // video_histeq u_histeq (
    //     .clk(clk), .rst(rst), .frame_start(frame_start), .de(de),
    //     .luma(gray), .luma_q(gray_q), .mapped(eq_luma), .ready(eq_ready)
    // );
    assign eq_luma  = 8'd0;
    assign eq_ready = 1'b0;

    // 按"亮度差平移"三通道：保持色相，只改对比度/亮度
    function [7:0] shift_ch;
        input [7:0] ch;
        input [7:0] lut_v;
        input [7:0] luma_v;
        reg signed [9:0] v;
        begin
            v = $signed({1'b0, ch}) + $signed({1'b0, lut_v}) - $signed({1'b0, luma_v});
            if (v < 0)
                shift_ch = 8'd0;
            else if (v > 10'sd255)
                shift_ch = 8'd255;
            else
                shift_ch = v[7:0];
        end
    endfunction

    wire [23:0] equalized = {shift_ch(pix_q[23:16], eq_luma, gray_q),
                             shift_ch(pix_q[15:8],  eq_luma, gray_q),
                             shift_ch(pix_q[7:0],   eq_luma, gray_q)};

    always @(posedge clk) begin
        gray_q   <= gray;
        pix_q    <= rgb_in;
        sepia_q  <= {sep_rv, sep_gv, sep_bv};
        x_q      <= x;
        y_q      <= y;
        de_q     <= de;

        // 镜像行缓存：本行倒着写，同时从另一个 bank 正着读上一行
        if (de_q && x_q < 12'd640)
            mirror_line[mirror_wr_addr] <= pix_q;
        mirror_q <= mirror_line[mirror_rd_addr];

        gray_prev <= gray_q;   // 单像素边缘的参考亮度
    end

    always @* begin
        case (effect_q)
            4'd1: rgb_out = {gray_q, gray_q, gray_q};
            4'd2: rgb_out = ~pix_q;
            4'd3: rgb_out = sepia_q;
            4'd4: rgb_out = mirror_q;
            // 档位重排：原来的"上下分屏"(5) 与"色调分离"(6) 已按资源方案删掉，Sobel 从 7 前移到 5
            4'd5: rgb_out = {edge_v, edge_v, edge_v};
            // 4'd8: rgb_out = eq_ready ? equalized : pix_q;   // 直方图均衡，暂不例化
            default: rgb_out = pix_q;
        endcase
    end
endmodule

// 直方图均衡（自动对比度）：整帧亮度统计成 32 段直方图，帧起始的消隐期算累积分布得到
// 32 个采样点，下一帧按"亮度差平移"三通道应用（保色相），段内线性插值（3 位小数）避免条带。
//
// 32 段的表和直方图都只有几百位，用寄存器实现只花几百个 LUT —— 早期版本用 256 项查找表
// 时 TD 会把它当寄存器阵列，一下吃掉 1800 个 LUT、2000 多个触发器，器件装不下。
//
// 统计用"待写回缓存"：本拍读段号（数据下一拍到），下一拍若还是同段就在缓存里累加，
// 换段时把缓存写回；有效区结束那一拍强制写回一次。消隐期扫描 256 个 bin（每段 8 个）
// 累加像素数，每到段尾把累积值折算成采样点写进 curve，顺手把该段清零。
// 映射系数 255/307200 用定点 218/2^18 近似（误差 < 1LSB，最大正好 255）。
module video_histeq (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        de,
    input  wire [7:0]  luma,         // 当前像素亮度（用于统计）
    input  wire [7:0]  luma_q,       // 打了一拍的亮度（video_effects 第一级流水），插值要和它对齐
    output wire [7:0]  mapped,       // 组合输出，与 luma_q 同拍
    output reg         ready
);
    localparam [8:0] SCALE_K = 9'd218;      // 255/307200 ≈ 218/2^18

    reg [15:0] hist  [0:31];                // 32 段亮度直方图
    reg [7:0]  curve [0:31];                // curve[k] = CDF(8k-1)，curve[0] 恒为 0
    reg [4:0]  seg_q;                       // 上一拍像素的段号
    reg [15:0] hist_q;
    reg        de_q;
    reg        building;
    reg [8:0]  bin, bin_q;                  // 消隐期扫描计数器 0..258
    reg [18:0] acc;
    reg        pend_valid;                  // 待写回的计数缓存
    reg [4:0]  pend_seg;
    reg [15:0] pend_cnt;

    wire [4:0] seg = luma[7:3];
    // 统计期：读当前像素的段号，数据下一拍回来时正好和 seg_q 对齐（用于创建待写回缓存）
    // 扫描期：组合读 bin_q 对应的段（组合读保证和 bin_q 同拍，段头清零、段尾取值都不会错位）
    wire [15:0] build_hist = hist[bin_q[7:3]];
    wire [18:0] acc_next = acc + {3'b0, build_hist};
    (* dsp_style = "yes" *) wire [27:0] cdf_scaled = acc_next * {19'd0, SCALE_K};
    wire [7:0]  cdf_next = cdf_scaled[25:18];
    wire [4:0]  curve_wr = (bin_q[7:3] == 5'd31) ? 5'd31 : (bin_q[7:3] + 5'd1);

    // 段内线性插值：ci = 段号，x = 段内偏移（0~7），mapped = curve[ci] + (Δ*x)>>3
    wire [4:0]  ci = luma_q[7:3];
    wire [7:0]  c0 = curve[ci];
    wire [7:0]  c1 = (ci == 5'd31) ? curve[5'd31] : curve[ci + 5'd1];
    wire signed [8:0] dcurve = $signed({1'b0, c1}) - $signed({1'b0, c0});
    wire signed [11:0] interp = $signed({1'b0, c0}) +
                                ((dcurve * $signed({1'b0, luma_q[2:0]})) >>> 3);
    assign mapped = (interp < 12'sd0) ? 8'd0 :
                    (interp > 12'sd255) ? 8'hff : interp[7:0];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < 32; init_i = init_i + 1) begin
            hist[init_i]  = 16'd0;
            curve[init_i] = 8'd0;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            de_q       <= 1'b0;
            building   <= 1'b0;
            ready      <= 1'b0;
            bin        <= 9'd0;
            bin_q      <= 9'd0;
            acc        <= 19'd0;
            seg_q      <= 5'd0;
            hist_q     <= 16'd0;
            pend_valid <= 1'b0;
            pend_cnt   <= 16'd0;
        end else begin
            seg_q  <= seg;
            hist_q <= hist[seg];
            de_q   <= de;
            bin_q  <= bin;

            if (building) begin
                // 消隐期：256 个 bin 累加，段尾写采样点，每组头拍把该段清零
                if (bin_q[2:0] == 3'd0) begin
                    acc <= acc_next;              // 每段只在头拍累加一次，避免同一段加 8 次
                    hist[bin_q[7:3]] <= 16'd0;
                end
                if (bin_q[2:0] == 3'd7)
                    curve[curve_wr] <= cdf_next;
                bin <= bin + 9'd1;
                if (bin_q >= 9'd258) begin
                    building <= 1'b0;
                    ready    <= 1'b1;
                end
            end else if (frame_start) begin
                building   <= 1'b1;
                bin        <= 9'd0;
                bin_q      <= 9'd0;
                acc        <= 19'd0;
                pend_valid <= 1'b0;
            end else begin
                bin   <= 9'd0;
                bin_q <= 9'd0;
                if (de_q) begin
                    // 处理上一拍的像素：同段就继续累计，否则先把缓存写回再新建
                    if (pend_valid && (pend_seg == seg_q))
                        pend_cnt <= pend_cnt + 16'd1;
                    else begin
                        if (pend_valid)
                            hist[pend_seg] <= pend_cnt;
                        pend_seg   <= seg_q;
                        pend_cnt   <= hist_q + 16'd1;
                        pend_valid <= 1'b1;
                    end
                end else if (pend_valid) begin
                    hist[pend_seg] <= pend_cnt;   // 有效区结束：把最后一段写回
                    pend_valid <= 1'b0;
                end
            end
        end
    end
endmodule

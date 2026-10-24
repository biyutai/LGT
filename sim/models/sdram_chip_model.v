// EG4S20 片内合封 SDRAM（2M×32：4 bank × 2048 行 × 256 列）的行为模型，仅用于仿真
// TD 自带的 sim_release/eg4/eg_phy_sdram_2m_32.v 只有端口没有行为，这里替代它（模块名相同）
//
// 解析标准 SDR SDRAM 命令（时钟上升沿、cs_n = 0）：
//   {ras,cas,we} = 000 MRS / 001 REF / 010 PRE / 011 ACT / 100 WRITE / 101 READ / 110 BST / 111 NOP
// 从模式寄存器取 CAS 延迟和突发长度（1 / 2 / 4 / 8 / 整页 256），支持 A10 自动预充电、新读写打断旧突发、DM 屏蔽
// DM 只在明确为 1 时屏蔽：官方控制器的 DM 输出寄存器没有复位，仿真里第一次写是 X（真实芯片上电是确定值）
// 统计（testbench 读取）：各命令次数、两次 REF 的最大间隔、协议错误（读写未激活的行、重复激活）
`timescale 1ns / 1ps

module EG_PHY_SDRAM_2M_32 #(
    // 下面三个参数用来扫控制器的 dq 采样 / 发送时刻（第 6b 步自查，见 sim/tb_sdram_ctrl.v 开头），默认值即原来的行为
    // T_AC 必须小于时钟周期 8ns：输出用 always 块里的延时实现，延时跨过下一个时钟沿会漏掉那个沿
    parameter real T_AC = 5.0,      // 时钟沿 → 读数据出现（ns）
    parameter real T_OH = 5.0,      // 下一个时钟沿之后读数据还保持多久（ns）；T_OH < T_AC 时中间输出 X
    parameter real T_DQ_IN = 1.0    // 写数据进芯片的延迟（ns）：芯片在自己的时钟沿采到的是 T_DQ_IN 之前的 dq
)(
    input         clk,
    input         ras_n,
    input         cas_n,
    input         we_n,
    input  [10:0] addr,
    input  [1:0]  ba,
    inout  [31:0] dq,
    input         cs_n,
    input         dm0,
    input         dm1,
    input         dm2,
    input         dm3,
    input         cke
);

// 输入经 1ns 延迟后采样，模拟芯片的保持时间：控制器的命令可能在芯片时钟同一个沿上改变，
// 零延迟仿真里不加延迟就会时而采到旧值、时而采到新值（漏命令）
wire        #1 ras_n_s = ras_n;
wire        #1 cas_n_s = cas_n;
wire        #1 we_n_s  = we_n;
wire [10:0] #1 addr_s  = addr;
wire [1:0]  #1 ba_s    = ba;
wire        #1 cs_n_s  = cs_n;
wire        #1 dm0_s   = dm0;
wire        #1 dm1_s   = dm1;
wire        #1 dm2_s   = dm2;
wire        #1 dm3_s   = dm3;
wire        #1 cke_s   = cke;
wire [31:0] #(T_DQ_IN) dq_in = dq;

reg [31:0] mem [0:(1<<21)-1];

// 模式寄存器
integer cl  = 3;
integer bl  = 1;                   // 读突发长度
integer wbl = 1;                   // 写突发长度（模式寄存器 A9 = 1 时为单次写）

// 每个 bank 的打开行
reg        open_v [0:3];
reg [10:0] open_r [0:3];

// 当前读 / 写突发
reg        rd_act = 1'b0, wr_act = 1'b0;
reg [1:0]  bst_ba;
reg [10:0] bst_row;
reg [7:0]  bst_col;
integer    bst_left = 0;
reg        bst_ap = 1'b0;          // 突发结束后自动预充电

// 读数据输出流水：在命令后第 cl 个上升沿之后驱动
reg [31:0] out_q  [0:15];
reg        out_v  [0:15];
reg [31:0] dq_out = 32'd0;
reg        dq_oe  = 1'b0;
assign dq = dq_oe ? dq_out : 32'bz;

// 统计
integer n_mrs = 0, n_ref = 0, n_pre = 0, n_act = 0, n_wr = 0, n_rd = 0, n_bst = 0;
integer n_err = 0;
time    last_ref = 0, max_ref_gap = 0, first_ref = 0;

integer i;
initial begin
    for (i = 0; i < 4; i = i + 1) begin open_v[i] = 1'b0; open_r[i] = 11'd0; end
    for (i = 0; i < 16; i = i + 1) begin out_v[i] = 1'b0; out_q[i] = 32'd0; end
end

wire [2:0]  cmd = {ras_n_s, cas_n_s, we_n_s};
wire [3:0]  dm  = {dm3_s, dm2_s, dm1_s, dm0_s};
// 存储地址直接用寄存器拼：不能用连续赋值的 wire，它要等 always 块挂起才更新，突发第一拍会用到旧地址

// 最近 8 条命令，出错时打印（排查用）
reg [2:0]  h_cmd [0:7];
reg [1:0]  h_ba  [0:7];
reg [10:0] h_ad  [0:7];
time       h_t   [0:7];
integer    h_n = 0;
reg        dump_hist = 1'b1;

task err(input [8*48-1:0] msg);
    integer j, k;
    begin
        if (n_err < 5) begin
            $display("        [sdram %0t] %0s  (ba_s=%0d addr_s=%h)", $time, msg, ba_s, addr_s);
            if (dump_hist && n_err == 0)
                for (j = 8; j >= 1; j = j - 1) if (h_n >= j) begin
                    k = (h_n - j) % 8;
                    $display("            prev cmd %0t: cmd=%b ba_s=%0d addr_s=%h", h_t[k], h_cmd[k], h_ba[k], h_ad[k]);
                end
        end
        n_err = n_err + 1;
    end
endtask

task close_burst_if_bank(input [1:0] b);
    begin
        if ((rd_act || wr_act) && bst_ba == b) begin rd_act = 1'b0; wr_act = 1'b0; bst_left = 0; end
    end
endtask

always @(posedge clk) begin
    // ---------- 输出流水前移，按 CL 驱动 dq ----------
    for (i = 15; i > 0; i = i - 1) begin out_q[i] = out_q[i-1]; out_v[i] = out_v[i-1]; end
    out_q[0] = 32'd0; out_v[0] = 1'b0;

    // ---------- 进行中的突发（本拍是后续节拍；本拍有新的读 / 写 / BST / 同 bank 预充电则被打断）----------
    if ((rd_act || wr_act) &&
        !(cke_s && !cs_n_s && (cmd == 3'b100 || cmd == 3'b101 || cmd == 3'b110 ||
                           (cmd == 3'b010 && (addr_s[10] || ba_s == bst_ba))))) begin
        if (bst_left > 0) begin
            if (wr_act) begin
                if (dm[0] !== 1'b1) mem[{bst_ba, bst_row, bst_col}][7:0]   = dq_in[7:0];
                if (dm[1] !== 1'b1) mem[{bst_ba, bst_row, bst_col}][15:8]  = dq_in[15:8];
                if (dm[2] !== 1'b1) mem[{bst_ba, bst_row, bst_col}][23:16] = dq_in[23:16];
                if (dm[3] !== 1'b1) mem[{bst_ba, bst_row, bst_col}][31:24] = dq_in[31:24];
            end else begin
                out_q[0] = mem[{bst_ba, bst_row, bst_col}]; out_v[0] = 1'b1;
            end
            bst_col  = bst_col + 8'd1;
            bst_left = bst_left - 1;
        end
        if (bst_left == 0) begin
            if (bst_ap) open_v[bst_ba] = 1'b0;
            rd_act = 1'b0; wr_act = 1'b0;
        end
    end

    // ---------- 本拍命令 ----------
    if (cke_s && !cs_n_s) case (cmd)
        3'b000: begin                                   // MRS
            n_mrs = n_mrs + 1;
            cl = addr_s[6:4];
            case (addr_s[2:0])
                3'd0: bl = 1; 3'd1: bl = 2; 3'd2: bl = 4; 3'd3: bl = 8; 3'd7: bl = 256;
                default: begin bl = 1; err("MRS: reserved burst length"); end
            endcase
            wbl = addr_s[9] ? 1 : bl;
            $display("        [sdram %0t] MRS: CL=%0d BL=%0d write BL=%0d", $time, cl, bl, wbl);
        end
        3'b001: begin                                   // REF
            n_ref = n_ref + 1;
            for (i = 0; i < 4; i = i + 1) if (open_v[i]) err("REF with a bank open");
            if (n_ref == 1) first_ref = $time;
            else if ($time - last_ref > max_ref_gap) max_ref_gap = $time - last_ref;
            last_ref = $time;
        end
        3'b010: begin                                   // PRE
            n_pre = n_pre + 1;
            if (addr_s[10]) begin
                for (i = 0; i < 4; i = i + 1) open_v[i] = 1'b0;
                rd_act = 1'b0; wr_act = 1'b0; bst_left = 0;
            end else begin
                open_v[ba_s] = 1'b0;
                close_burst_if_bank(ba_s);
            end
        end
        3'b011: begin                                   // ACT
            n_act = n_act + 1;
            if (open_v[ba_s]) err("ACT on an already open bank");
            open_v[ba_s] = 1'b1; open_r[ba_s] = addr_s;
        end
        3'b100, 3'b101: begin                           // WRITE / READ（打断进行中的突发）
            if (!open_v[ba_s]) err(cmd[0] ? "READ to a closed bank" : "WRITE to a closed bank");
            rd_act   = cmd[0];
            wr_act   = ~cmd[0];
            bst_ba   = ba_s;
            bst_row  = open_r[ba_s];
            bst_col  = addr_s[7:0];
            bst_ap   = addr_s[10];
            bst_left = cmd[0] ? bl : wbl;
            if (cmd[0]) n_rd = n_rd + 1; else n_wr = n_wr + 1;
            // 第一个节拍就在本拍
            if (wr_act) begin
                if (dm[0] !== 1'b1) mem[{bst_ba, bst_row, bst_col}][7:0]   = dq_in[7:0];
                if (dm[1] !== 1'b1) mem[{bst_ba, bst_row, bst_col}][15:8]  = dq_in[15:8];
                if (dm[2] !== 1'b1) mem[{bst_ba, bst_row, bst_col}][23:16] = dq_in[23:16];
                if (dm[3] !== 1'b1) mem[{bst_ba, bst_row, bst_col}][31:24] = dq_in[31:24];
            end else begin
                out_q[0] = mem[{bst_ba, bst_row, bst_col}]; out_v[0] = 1'b1;
            end
            bst_col  = bst_col + 8'd1;
            bst_left = bst_left - 1;
            if (bst_left == 0) begin
                if (bst_ap) open_v[bst_ba] = 1'b0;
                rd_act = 1'b0; wr_act = 1'b0;
            end
        end
        3'b110: begin                                   // BST
            n_bst = n_bst + 1;
            rd_act = 1'b0; wr_act = 1'b0; bst_left = 0;
        end
        default: ;                                      // NOP
    endcase

    if (cke_s && !cs_n_s && cmd != 3'b111) begin
        h_cmd[h_n % 8] = cmd; h_ba[h_n % 8] = ba_s; h_ad[h_n % 8] = addr_s; h_t[h_n % 8] = $time;
        h_n = h_n + 1;
    end

    // 读数据在命令后第 cl-1 个上升沿之后 5ns（tAC）出现、保持到下一个沿后 5ns（out_q[cl-1] 是 cl-1 拍之前装入的）。
    // 5ns 取自 TD 时序报告里合封 SDRAM 的输出延迟（input (hard ip) 5.000ns）；控制器在自己的时钟沿采样，
    // 比芯片时钟晚半拍，按这个延迟定的采样点，延迟取 1ns 会让控制器把下一个字当成这一个字
    if (T_OH < T_AC) begin
        #(T_OH);
        if (dq_oe) dq_out = 32'hxxxx_xxxx;
        #(T_AC - T_OH);
    end else
        #(T_AC);
    dq_oe  = out_v[cl-1];
    dq_out = out_q[cl-1];
end

endmodule

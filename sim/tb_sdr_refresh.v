// 检查官方 SDRAM 控制器的自刷新：sdr_init_ref 是否按 64ms / 4096 次（每 1953 拍）发出刷新请求
// 官方原版 global_def.v 的宏缺括号，间隔算成 0，一次请求都没有（第 5b 步修复）
// sdr_init_ref.enc.v 的计数器部分是明文，末尾加密块 ModelSim 能解密运行
// 运行：sim/run.sh tb_sdr_refresh
`timescale 1ns / 1ps

module tb_sdr_refresh;

reg clk = 1'b0;
reg rst = 1'b1;
always #4 clk = ~clk;                  // 125MHz

wire init_done, ref_req, init_ref_vld;
reg  ref_ack = 1'b0;

sdr_init_ref #(.self_refresh_open(1)) dut (
    .Sdr_clk          (clk),
    .Rst              (rst),
    .Sdr_init_req     (1'b0),
    .Sdr_init_mode    (4'd0),
    .Sdr_init_done    (init_done),
    .App_ref_req      (1'b0),
    .Sdr_ref_req      (ref_req),
    .Sdr_ref_ack      (ref_ack),
    .Sdr_rw_vld       (1'b0),
    .Sdr_init_ref_vld (init_ref_vld),
    .Sdr_init_ref_ras (),
    .Sdr_init_ref_cas (),
    .Sdr_init_ref_we  (),
    .Sdr_init_ref_ba  (),
    .Sdr_init_ref_addr()
);

// 收到请求 3 拍后应答一拍，模拟 sdr_wrrd 空闲时的行为
reg [2:0] req_sr = 3'd0;
always @(posedge clk) begin
    req_sr  <= {req_sr[1:0], ref_req};
    ref_ack <= req_sr[2];
end

integer n_req = 0;
integer first = -1, last = -1, cyc = 0;
always @(posedge clk) if (init_done) begin
    cyc = cyc + 1;
    if (ref_req) begin
        n_req = n_req + 1;
        if (first < 0) first = cyc;
        last = cyc;
    end
end

initial begin
    repeat (10) @(posedge clk);
    rst <= 1'b0;
    wait (init_done);
    $display("== init_done at %0t ns; SELF_REFRESH_INTERVAL macro = %0d", $time, `SELF_REFRESH_INTERVAL);
    repeat (40000) @(posedge clk);
    $display("        init_cnt now = %0d", dut.init_cnt);
    $display("        refresh requests in 40000 cycles: %0d (expected about 20 for one per 1953)", n_req);
    if (n_req >= 2) $display("        period = %0d cycles", (last - first) / (n_req - 1));
    if (n_req >= 18 && (last - first) / (n_req - 1) <= 1960) $display("== ALL PASSED");
    else                                                      $display("== FAILED: no / too slow self refresh");
    $finish;
end

endmodule

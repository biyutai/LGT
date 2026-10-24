// 复位同步器：异步置位、同步释放
//
// arst 一拉高，srst 立即拉高；arst 撤销后，srst 在 clk 的第 STAGES 个上升沿才撤销。
// 这样每个时钟域里所有寄存器在同一个时钟沿退出复位，复位撤销的时序也能被正常分析。
module rst_sync #(
    parameter integer STAGES = 3
)(
    input  wire clk,
    input  wire arst,    // 高电平有效，可来自任意时钟域
    output wire srst     // 高电平有效，与 clk 同步撤销
);

reg [STAGES-1:0] sync_r = {STAGES{1'b1}};

always @(posedge clk or posedge arst) begin
    if (arst)
        sync_r <= {STAGES{1'b1}};
    else
        sync_r <= {sync_r[STAGES-2:0], 1'b0};
end

assign srst = sync_r[STAGES-1];

endmodule

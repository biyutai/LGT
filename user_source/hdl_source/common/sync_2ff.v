// 单比特电平同步器（两级触发器）
//
// 用于把另一个时钟域的慢变化电平信号（如握手应答）同步到 clk 域，输出延迟 2 拍。
// 只适用于单比特、且每次变化后至少保持 2 个目标时钟周期的信号；多比特数据请用异步 FIFO。
module sync_2ff (
    input  wire clk,
    input  wire rst,     // 高电平有效，与 clk 同步撤销
    input  wire d,       // 来自其他时钟域，必须是寄存器输出
    output wire q
);

reg [1:0] sync_r;

always @(posedge clk or posedge rst) begin
    if (rst)
        sync_r <= 2'b00;
    else
        sync_r <= {sync_r[0], d};
end

assign q = sync_r[1];

endmodule

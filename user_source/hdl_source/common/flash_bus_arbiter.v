`timescale 1ns/1ps

// W25Q64 记录 store 的客户端仲裁：参数日志（优先）与事件日志共用一个 store 实例。
//
// 为什么不是"两份 store + 切 SPI 引脚"：一份 w25q64_record_store 的时序状态机约 410 LUT，
// 两份就把器件撑爆（实测 mslice 4,962 > 4,900）。这里只切 4 根客户端线
// （start / op_write / address / write_data），busy/done/error/read_data 广播；
// SPI 引脚只由那一份 store 驱动。
//
// 规则：
//   1. 参数日志优先。它的 load/save 请求是单拍脉冲，先闩住、拿到所有权再发单拍 start；
//      parameter_persistence 会一直等 done，所以"晚一点发起点"是安全的。
//   2. 事件日志只在参数日志空闲、且没有待发请求时拿所有权；拿到后整笔操作期间不收回
//      （事件日志自己保证 grant 连续两拍才开新操作）。
//   3. 两侧都空闲才切 owner，切换后 3 拍内不再切：busy 有 1~2 拍的建立延迟。
module flash_bus_arbiter (
    input  wire clk,
    input  wire rst,
    // 参数日志侧
    input  wire journal_load_req,
    input  wire journal_save_req,
    input  wire journal_busy,
    input  wire journal_st_start,
    input  wire journal_st_op_write,
    input  wire [23:0] journal_st_address,
    input  wire [95:0] journal_st_write_data,
    output reg  journal_load_start,
    output reg  journal_save_start,
    // 事件日志侧
    input  wire log_req,
    input  wire log_busy,
    input  wire log_st_start,
    input  wire log_st_op_write,
    input  wire [23:0] log_st_address,
    input  wire [95:0] log_st_write_data,
    output wire log_grant,
    // 唯一 store
    output wire store_start,
    output wire store_op_write,
    output wire [23:0] store_address,
    output wire [95:0] store_write_data
);
    reg       owner;              // 0 = 参数日志，1 = 事件日志
    reg       load_hold, save_hold;
    reg [2:0] settle;

    assign log_grant        = owner;
    assign store_start      = owner ? log_st_start      : journal_st_start;
    assign store_op_write   = owner ? log_st_op_write   : journal_st_op_write;
    assign store_address    = owner ? log_st_address    : journal_st_address;
    assign store_write_data = owner ? log_st_write_data : journal_st_write_data;

    wire journal_wants = journal_load_req || journal_save_req || load_hold || save_hold;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            owner              <= 1'b0;
            load_hold          <= 1'b0;
            save_hold          <= 1'b0;
            journal_load_start <= 1'b0;
            journal_save_start <= 1'b0;
            settle             <= 3'd0;
        end else begin
            journal_load_start <= 1'b0;
            journal_save_start <= 1'b0;
            if (settle != 3'd0)
                settle <= settle - 1'b1;

            if (journal_load_req) load_hold <= 1'b1;
            if (journal_save_req) save_hold <= 1'b1;

            if (owner == 1'b0) begin
                if (!journal_busy) begin
                    if (load_hold) begin
                        load_hold          <= 1'b0;
                        journal_load_start <= 1'b1;
                        settle             <= 3'd3;
                    end else if (save_hold) begin
                        save_hold          <= 1'b0;
                        journal_save_start <= 1'b1;
                        settle             <= 3'd3;
                    end
                end
                if (settle == 3'd0 && !journal_busy && !journal_wants && log_req) begin
                    owner  <= 1'b1;
                    settle <= 3'd3;
                end
            end else begin
                if (settle == 3'd0 && !log_busy &&
                    (journal_wants || !log_req)) begin
                    owner  <= 1'b0;
                    settle <= 3'd3;
                end
            end
        end
    end
endmodule

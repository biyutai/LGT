`timescale 1ns/1ps

// 双槽参数日志（12 字节记录：version 4 + period 4 + volume 1 + mode 1 + crc 2 + marker 由上层管）。
//
// 面积瘦身（2026-10-16）：CRC 从"两份逐位 40 比特展开"换成"一份按字节查表时分复用"：
//   * crc16_byte 只有一份，槽0 / 槽1 / 保存记录三个任务共用（120 + 60 LUT 那一刀）；
//   * 载荷按 MSB-first 逐字节喂入，每字节间隔两拍等流水回灌，第 0 字节用初值 16'hffff；
//     算法不变 → 12 字节记录格式、坏槽回退、TB 里的 CRC 值全部不变（两个 TB 一行不改即等价性证明）。
//   * record_version/period/volume/mode 直接由输入端口给出（不再闩一份 80 位副本），
//     record_crc 仍需寄存器：它要在整个 Flash 写（擦+写+回读）期间保持有效。
//
// 减寄存器的前提（调用方保证，见 config_flash_journal 的 FSM）：
//   1) load_start 到 load_done 之间 slot0_*/slot1_* 不变 —— 载荷与最终选择直接用输入端口；
//   2) save_start 到写完成之间 save_* 不变（wrapper 把它们闩在 save_*_latched 上）——
//      record_* 因此可以是组合输出；
//   3) load 与 save 不会同时开始（wrapper 单 FSM），所以三个 CRC 任务可以串行共用一份算力。
module config_journal (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load_start,
    input  wire        slot0_present,
    input  wire [31:0] slot0_version,
    input  wire [31:0] slot0_period,
    input  wire [7:0]  slot0_volume,
    input  wire [7:0]  slot0_mode,
    input  wire [15:0] slot0_crc,
    input  wire        slot1_present,
    input  wire [31:0] slot1_version,
    input  wire [31:0] slot1_period,
    input  wire [7:0]  slot1_volume,
    input  wire [7:0]  slot1_mode,
    input  wire [15:0] slot1_crc,
    output reg         load_done,
    output reg         config_valid,
    output reg  [31:0] active_version,
    output reg  [31:0] active_period,
    output reg  [7:0]  active_volume,
    output reg  [7:0]  active_mode,
    output reg         active_slot,
    input  wire        save_start,
    input  wire [31:0] save_period,
    input  wire [7:0]  save_volume,
    input  wire [7:0]  save_mode,
    output reg         record_ready,
    output reg         target_slot,
    output wire [31:0] record_version,
    output wire [31:0] record_period,
    output wire [7:0]  record_volume,
    output wire [7:0]  record_mode,
    output reg  [15:0] record_crc
);
    function version_newer;
        input [31:0] candidate;
        input [31:0] reference;
        reg [31:0] delta;
        begin
            delta = candidate - reference;
            version_newer = (candidate != reference) && !delta[31];
        end
    endfunction

    localparam [15:0] CRC_SEED = 16'hffff;
    // 80 位载荷 = 10 字节；每字节两拍（第一拍喂、下一拍等流水），喂完第 10 字节再等 2 拍取结果
    localparam [4:0]  CRC_TICKS = 5'd20;

    localparam [1:0] JOB_SLOT0 = 2'd0;
    localparam [1:0] JOB_SLOT1 = 2'd1;
    localparam [1:0] JOB_SAVE  = 2'd2;

    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_LOAD0_W = 3'd1;
    localparam [2:0] ST_LOAD1_W = 3'd2;
    localparam [2:0] ST_SAVE_W  = 3'd3;

    // ---- 记录字段：只有 CRC 需要闩，其余由输入端口组合给出 ----
    wire [31:0] next_version = active_version + 32'd1;
    assign record_version = next_version;
    assign record_period  = save_period;
    assign record_volume  = save_volume;
    assign record_mode    = save_mode;

    // ---- 按字节 CRC 引擎（一份 crc16_byte，三个任务时分复用）----
    reg  [1:0]  crc_job;
    reg  [4:0]  crc_tick;
    reg         crc_busy;
    reg         crc_req;      // 建表未完成时先把请求寄存下来
    reg  [15:0] crc_value;    // 最近一个任务的 CRC 结果
    reg         crc_done;
    wire [7:0]  crc_byte;
    wire [15:0] crc_next;
    wire        crc_table_ready;

    wire [79:0] crc_payload = (crc_job == JOB_SLOT0) ? {slot0_version,slot0_period,slot0_volume,slot0_mode} :
                              (crc_job == JOB_SLOT1) ? {slot1_version,slot1_period,slot1_volume,slot1_mode} :
                                                       {next_version,save_period,save_volume,save_mode};
    wire        crc_feed = crc_busy && !crc_tick[0] && (crc_tick != CRC_TICKS);

    function [7:0] payload_byte;              // 按字节序号取载荷（MSB first）
        input [79:0] payload;
        input [3:0]  index;
        begin
            case (index)
                4'd0: payload_byte = payload[79:72];
                4'd1: payload_byte = payload[71:64];
                4'd2: payload_byte = payload[63:56];
                4'd3: payload_byte = payload[55:48];
                4'd4: payload_byte = payload[47:40];
                4'd5: payload_byte = payload[39:32];
                4'd6: payload_byte = payload[31:24];
                4'd7: payload_byte = payload[23:16];
                4'd8: payload_byte = payload[15:8];
                default: payload_byte = payload[7:0];
            endcase
        end
    endfunction

    assign crc_byte = payload_byte(crc_payload, crc_tick[4:1]);

    crc16_byte u_crc16_byte (
        .clk(clk), .rst(~rst_n),
        .crc_in((crc_tick == 5'd0) ? CRC_SEED : crc_next),
        .byte_in(crc_byte),
        .crc_out(crc_next), .table_ready(crc_table_ready)
    );

    reg [2:0] state;
    reg       slot0_good_q;

    // 一次任务的启动脉冲与任务号（FSM 组合产生，引擎寄存）
    wire crc_start_1 = (state == ST_LOAD0_W) && crc_done;
    wire crc_start_s = (state == ST_IDLE) && save_start && !load_start;
    wire crc_start   = ((state == ST_IDLE) && load_start) || crc_start_1 || crc_start_s;
    wire [1:0] crc_job_next = crc_start_1 ? JOB_SLOT1 : (crc_start_s ? JOB_SAVE : JOB_SLOT0);

    wire slot1_good_now = slot1_present && (slot1_crc == crc_value);
    wire prefer_slot0   = slot0_good_q && (!slot1_good_now || !version_newer(slot1_version, slot0_version));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc_job   <= JOB_SLOT0;
            crc_tick  <= 5'd0;
            crc_busy  <= 1'b0;
            crc_req   <= 1'b0;
            crc_value <= 16'd0;
            crc_done  <= 1'b0;
        end else begin
            crc_done <= 1'b0;
            if (crc_start) begin
                crc_req <= 1'b1;
                crc_job <= crc_job_next;
            end
            if (!crc_busy) begin
                if (crc_req && crc_table_ready) begin
                    crc_req  <= 1'b0;
                    crc_busy <= 1'b1;
                    crc_tick <= 5'd0;
                end
            end else begin
                if (crc_tick == CRC_TICKS) begin
                    crc_busy  <= 1'b0;
                    crc_value <= crc_next;      // 第 10 字节喂完的第 2 拍，结果在 crc_next 上
                    crc_done  <= 1'b1;
                end
                crc_tick <= crc_tick + 5'd1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_done<=0; config_valid<=0; active_version<=0; active_period<=0;
            active_volume<=0; active_mode<=0; active_slot<=0;
            record_ready<=0; target_slot<=0;
            record_crc<=0;
            state<=ST_IDLE; slot0_good_q<=0;
        end else begin
            load_done<=0;
            record_ready<=0;
            case (state)
                ST_IDLE: begin
                    if (load_start)
                        state <= ST_LOAD0_W;
                    else if (save_start) begin
                        target_slot <= config_valid ? ~active_slot : 1'b0;
                        state <= ST_SAVE_W;
                    end
                end
                ST_LOAD0_W: if (crc_done) begin
                    slot0_good_q <= slot0_present && (slot0_crc == crc_value);
                    state <= ST_LOAD1_W;
                end
                ST_LOAD1_W: if (crc_done) begin
                    load_done <= 1'b1;
                    state <= ST_IDLE;
                    if (prefer_slot0) begin
                        config_valid<=1; active_version<=slot0_version; active_period<=slot0_period;
                        active_volume<=slot0_volume; active_mode<=slot0_mode; active_slot<=1'b0;
                    end else if (slot1_good_now) begin
                        config_valid<=1; active_version<=slot1_version; active_period<=slot1_period;
                        active_volume<=slot1_volume; active_mode<=slot1_mode; active_slot<=1'b1;
                    end else begin
                        config_valid<=0; active_version<=0; active_period<=0;
                        active_volume<=0; active_mode<=0; active_slot<=1'b0;
                    end
                end
                ST_SAVE_W: if (crc_done) begin
                    record_crc   <= crc_value;
                    record_ready <= 1'b1;
                    state        <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

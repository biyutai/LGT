// SD 卡 SPI 模式行为模型（仅用于仿真）
//
// 支持 CMD0 / CMD8 / CMD55 / ACMD41 / CMD16 / CMD17（单块读），SDHC 块地址。
// 与本工程 bug 相关的真实卡行为：
//   - 上电后只认 CMD0（进入 SPI 模式），其余命令不应答
//   - 发送数据块期间忽略一切命令，直到整块（令牌 + 512 字节 + CRC）发完
//   - CS 拉高时暂停，不丢弃尚未发完的数据
//   - 已初始化（非 idle）时收到 CMD8 返回非法命令 0x04，CMD55 返回 0x00
// SPI 模式 3：上升沿采样 MOSI，下降沿输出 MISO。
// 扇区内容：sector < DISK_SECTORS 时取 disk[]（testbench 可直接写），否则按 pattern() 生成。
`timescale 1ns / 1ps

module sd_card_model #(
    parameter integer DISK_SECTORS = 64,
    parameter integer ACMD41_BUSY  = 2      // ACMD41 前几次返回"仍在初始化"
)(
    input  wire cs_n,
    input  wire sclk,
    input  wire mosi,
    output reg  miso
);

reg [7:0] disk [0:DISK_SECTORS*512-1];

reg        present  = 1'b1;     // testbench 置 0 模拟拔卡
reg        spi_mode = 1'b0;
reg        idle     = 1'b1;
reg        app_cmd  = 1'b0;
integer    acmd41_cnt = 0;

// 输出字节队列
reg [7:0]  q [0:1023];
integer    q_rd = 0, q_wr = 0;
integer    data_left = 0;       // 队列里还剩多少字节属于数据块（>0 时忽略命令）
reg [7:0]  cur = 8'hff;
integer    obit = 7;

// 命令接收
reg        rx_active = 1'b0;
integer    rx_cnt = 0;
reg [47:0] rx_sr;

// 统计（testbench 读取）
integer    cmd_count = 0;
integer    cmd0_count = 0;
reg        trace = 1'b0;            // testbench 置 1 打印每条收到的命令

initial miso = 1'b1;

function [7:0] pattern(input [31:0] sector, input integer i);
    // 大量 0x01：模拟深色图像像素，最容易让主机把数据误认成 R1 应答
    pattern = (i % 3 == 0) ? 8'h01 : (sector[7:0] + i[7:0]);
endfunction

function [7:0] content(input [31:0] sector, input integer i);
    if (sector < DISK_SECTORS) content = disk[sector*512 + i];
    else                       content = pattern(sector, i);
endfunction

task push(input [7:0] b);
    begin q[q_wr % 1024] = b; q_wr = q_wr + 1; end
endtask

task r1(input [7:0] v);
    begin push(8'hff); push(v); end      // Ncr = 1 字节
endtask

task do_cmd(input [47:0] c);
    reg [5:0]  idx;
    reg [31:0] arg;
    integer    i;
    begin
        idx = c[45:40];
        arg = c[39:8];
        cmd_count = cmd_count + 1;
        if (trace)
            $display("        [card %0t] CMD%0d arg=%h  spi_mode=%0d idle=%0d app=%0d", $time, idx, arg, spi_mode, idle, app_cmd);
        // 命令应答从下一个整字节开始
        obit = 7;
        if (!spi_mode) begin
            if (idx == 6'd0) begin
                spi_mode = 1'b1; idle = 1'b1; app_cmd = 1'b0; acmd41_cnt = 0;
                cmd0_count = cmd0_count + 1;
                r1(8'h01);
            end
        end else if (app_cmd && idx == 6'd41) begin
            app_cmd = 1'b0;
            if (idle) begin
                acmd41_cnt = acmd41_cnt + 1;
                if (acmd41_cnt > ACMD41_BUSY) idle = 1'b0;
            end
            r1(idle ? 8'h01 : 8'h00);
        end else begin
            app_cmd = 1'b0;
            case (idx)
                6'd0:  begin idle = 1'b1; acmd41_cnt = 0; cmd0_count = cmd0_count + 1; r1(8'h01); end
                6'd8:  if (idle) begin r1(8'h01); push(8'h00); push(8'h00); push(8'h01); push(8'haa); end
                       else r1(8'h04);
                6'd55: begin app_cmd = 1'b1; r1(idle ? 8'h01 : 8'h00); end
                6'd16: r1(idle ? 8'h01 : 8'h00);
                6'd17: if (idle) r1(8'h05);
                       else begin
                           r1(8'h00);
                           push(8'hff); push(8'hff); push(8'hff);   // 读取延迟
                           push(8'hfe);                             // 数据令牌
                           for (i = 0; i < 512; i = i + 1) push(content(arg, i));
                           push(8'h12); push(8'h34);                // CRC（主机不校验）
                           data_left = 2 + 3 + 1 + 512 + 2;
                       end
                default: r1(idle ? 8'h05 : 8'h04);
            endcase
        end
    end
endtask

// 拔卡：清空一切；插回：相当于重新上电
task remove;
    begin
        present = 1'b0;
        q_rd = 0; q_wr = 0; data_left = 0; cur = 8'hff; obit = 7;
        rx_active = 1'b0; spi_mode = 1'b0; idle = 1'b1; app_cmd = 1'b0;
        miso = 1'b1;
    end
endtask

task insert;
    begin present = 1'b1; end
endtask

always @(negedge sclk) begin
    if (present && !cs_n) begin
        if (obit == 7) begin
            if (q_rd != q_wr) begin
                cur  = q[q_rd % 1024];
                q_rd = q_rd + 1;
                if (data_left > 0) data_left = data_left - 1;
            end else
                cur = 8'hff;
        end
        miso = cur[obit];
        obit = (obit == 0) ? 7 : obit - 1;
    end else if (!present)
        miso = 1'b1;
end

always @(posedge sclk) begin
    if (present && !cs_n && data_left == 0) begin
        if (!rx_active) begin
            if (mosi == 1'b0) begin           // 起始位
                rx_active = 1'b1;
                rx_cnt    = 1;
                rx_sr     = 48'd0;
            end
        end else begin
            rx_sr  = {rx_sr[46:0], mosi};
            rx_cnt = rx_cnt + 1;
            if (rx_cnt == 48) begin
                rx_active = 1'b0;
                if (rx_sr[46] == 1'b1 && rx_sr[0] == 1'b1)   // 传输位 = 1、结束位 = 1
                    do_cmd({1'b0, rx_sr[46:0]});
            end
        end
    end
end

endmodule

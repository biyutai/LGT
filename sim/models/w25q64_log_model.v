`timescale 1ns/1ps

// 事件日志用的最小 mode-0 SPI 模型：SLOTS 个扇区，每扇区前 RECORD 字节有效。
// 编程按字节立即落盘（比真芯片更苛刻：断电时会留下"半条记录"），擦除只清本扇区。
module w25q64_log_model #(
    parameter [23:0] BASE = 24'h700000,
    parameter integer SLOTS = 16,
    parameter integer RECORD = 12,
    parameter integer CONFIG_SLOT = 0,
    parameter [23:0] CONFIG_ADDRESS = 24'h7fe000
) (
    input wire cs_n,
    input wire sclk,
    input wire mosi,
    output wire miso
);
    reg [7:0] bytes [0:(SLOTS+CONFIG_SLOT)*RECORD-1];
    reg [7:0] cmd, rx_shift, tx_shift;
    reg [23:0] address;
    reg [2:0] bit_index;
    reg [2:0] phase;
    reg wel;
    integer busy_polls;
    integer offset;
    integer erase_slot;
    integer i;

    assign miso = tx_shift[7];

    function integer byte_offset;
        input [23:0] addr;
        integer s;
        begin
            s = (addr - BASE) >> 12;
            byte_offset = -1;
            if (addr >= BASE && s >= 0 && s < SLOTS && addr[11:0] < RECORD)
                byte_offset = s*RECORD + addr[11:0];
            else if (CONFIG_SLOT && addr >= CONFIG_ADDRESS &&
                     addr < CONFIG_ADDRESS + RECORD)
                byte_offset = SLOTS*RECORD + (addr - CONFIG_ADDRESS);
        end
    endfunction

    initial begin
        cmd=0; rx_shift=0; tx_shift=8'hff; address=0;
        bit_index=0; phase=0; wel=0; busy_polls=0;
        for (i=0;i<(SLOTS+CONFIG_SLOT)*RECORD;i=i+1) bytes[i]=8'hff;
    end

    always @(posedge sclk or posedge cs_n) begin
        if (cs_n) begin
            if (cmd == 8'h20 && wel && busy_polls == 0) begin
                erase_slot = (address - BASE) >> 12;
                if (CONFIG_SLOT && address == CONFIG_ADDRESS)
                    for (i=0;i<RECORD;i=i+1)
                        bytes[SLOTS*RECORD+i] <= 8'hff;
                else if (erase_slot >= 0 && erase_slot < SLOTS)
                    for (i=0;i<RECORD;i=i+1)
                        bytes[erase_slot*RECORD+i] <= 8'hff;
                wel <= 0;
                busy_polls <= 2;
            end else if (cmd == 8'h02 && wel) begin
                wel <= 0;
                busy_polls <= 2;
            end else if (cmd == 8'h06 && busy_polls == 0)
                wel <= 1;
            phase <= 0;
            bit_index <= 0;
            tx_shift <= 8'hff;
        end else begin
            rx_shift <= {rx_shift[6:0],mosi};
            if (bit_index == 3'd7) begin
                bit_index <= 0;
                case (phase)
                    0: begin
                        cmd <= {rx_shift[6:0],mosi};
                        address <= 0;
                        if ({rx_shift[6:0],mosi} == 8'h05) begin
                            phase <= 5;
                            tx_shift <= {6'd0,wel,(busy_polls != 0)};
                            if (busy_polls != 0) busy_polls <= busy_polls - 1;
                        end else if ({rx_shift[6:0],mosi} == 8'h03 ||
                                     {rx_shift[6:0],mosi} == 8'h02 ||
                                     {rx_shift[6:0],mosi} == 8'h20)
                            phase <= 1;
                    end
                    1,2,3: begin
                        address <= {address[15:0],rx_shift[6:0],mosi};
                        if (phase == 3) begin
                            phase <= 4;
                            offset = byte_offset({address[15:0],rx_shift[6:0],mosi});
                            tx_shift <= offset >= 0 ? bytes[offset] : 8'hff;
                        end else
                            phase <= phase + 1'b1;
                    end
                    4: begin
                        offset = byte_offset(address);
                        if (cmd == 8'h02 && wel && offset >= 0)
                            bytes[offset] <= bytes[offset] & {rx_shift[6:0],mosi};
                        address <= address + 1'b1;
                        offset = byte_offset(address + 1'b1);
                        tx_shift <= offset >= 0 ? bytes[offset] : 8'hff;
                    end
                    5: tx_shift <= {6'd0,wel,(busy_polls != 0)};
                endcase
            end else begin
                bit_index <= bit_index + 1'b1;
                tx_shift <= {tx_shift[6:0],1'b0};
            end
        end
    end
endmodule

`timescale 1ns/1ps

// Minimal mode-0 SPI model for the two protected parameter sectors.
module w25q64_config_model (
    input wire cs_n,
    input wire sclk,
    input wire mosi,
    output wire miso
);
    reg [7:0] bytes [0:23];
    reg [7:0] cmd, rx_shift, tx_shift;
    reg [23:0] address;
    reg [2:0] bit_index;
    reg [2:0] phase;
    reg wel;
    integer busy_polls;
    integer offset;
    integer i;

    assign miso = tx_shift[7];

    function integer byte_offset;
        input [23:0] addr;
        begin
            if (addr >= 24'h7fe000 && addr < 24'h7fe00c)
                byte_offset = addr - 24'h7fe000;
            else if (addr >= 24'h7ff000 && addr < 24'h7ff00c)
                byte_offset = 12 + addr - 24'h7ff000;
            else
                byte_offset = -1;
        end
    endfunction

    initial begin
        cmd=0; rx_shift=0; tx_shift=8'hff; address=0;
        bit_index=0; phase=0; wel=0; busy_polls=0;
        for (i=0;i<24;i=i+1) bytes[i]=8'hff;
    end

    always @(posedge sclk or posedge cs_n) begin
        if (cs_n) begin
            if (cmd == 8'h20 && wel && busy_polls == 0) begin
                if (address == 24'h7fe000)
                    for (i=0;i<12;i=i+1) bytes[i] <= 8'hff;
                else if (address == 24'h7ff000)
                    for (i=12;i<24;i=i+1) bytes[i] <= 8'hff;
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

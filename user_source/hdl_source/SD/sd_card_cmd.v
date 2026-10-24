
module sd_card_cmd#(
	// 复位后先把卡里没发完的数据读干净再初始化（见 S_FLUSH）
	// 连续收到 FLUSH_FF_BYTES 个 0xFF 才算干净：单块读最多剩 514 字节，读延迟规范上限 100ms ≈ 2500 字节 @ 200kHz
	// MISO 没有上拉、卡不驱动时可能永远收不到 0xFF，所以最多读 FLUSH_MAX_BYTES 个就继续
	parameter [15:0] FLUSH_FF_BYTES  = 16'd2600,
	parameter [15:0] FLUSH_MAX_BYTES = 16'd6000,
	// 命令发完后等应答的最多字节数（规范 NCR 最多 8 字节）
	parameter [15:0] RESP_TIMEOUT    = 16'd64
)(
	input                       sys_clk,
	input                       rst,
	input[15:0]                 spi_clk_div,                  //SPI module clock division parameter
	input                       cmd_req,                      //SD card command request
	output                      cmd_req_ack,                  //SD card command request response
	output reg                  cmd_req_error,                //SD card command request error
	input[47:0]                 cmd,                          //SD card command
	input[7:0]                  cmd_r1,                       //SD card expect response
	input[15:0]                 cmd_data_len,                 //SD card command read data length
	input                       block_read_req,               //SD card sector data read request
	output reg                  block_read_valid,             //SD card sector data read data valid
	output reg[7:0]             block_read_data,              //SD card sector data read data
	output                      block_read_req_ack,           //SD card sector data read response
	input                       block_write_req,              //SD card sector data write request
	input[7:0]                  block_write_data,             //SD card sector data write data next clock is valid
	output                      block_write_data_rd,          //SD card sector data write data
	output                      block_write_req_ack,          //SD card sector data write response
	output                      nCS_ctrl,                     //SPI module chip select control
	output reg[15:0]            clk_div,
	output reg                  spi_wr_req,                   //SPI module data sending request
	input                       spi_wr_ack,                   //SPI module data request response
	output[7:0]                 spi_data_in,                  //SPI module send data
	input[7:0]                  spi_data_out                  //SPI module data returned
);
localparam S_IDLE         = 0;
localparam S_WAIT         = 1;
localparam S_INIT         = 2;
localparam S_CMD_PRE      = 3;
localparam S_CMD          = 4;
localparam S_CMD_DATA     = 5;
localparam S_READ_WAIT    = 6;
localparam S_READ         = 7;
localparam S_READ_ACK     = 8;
localparam S_WRITE_TOKEN  = 9;
localparam S_WRITE_DATA_0 = 10;
localparam S_WRITE_DATA_1 = 11;
localparam S_WRITE_CRC    = 12;
localparam S_WRITE_SUC    = 13;
localparam S_WRITE_BUSY   = 14;
localparam S_WRITE_ACK    = 15;
localparam S_ERR          = 16;
localparam S_END          = 17;
localparam S_FLUSH        = 18;

reg[4:0]                      state;
reg                           CS_reg;
reg[15:0]                     byte_cnt;
reg[7:0]                      send_data;
wire[7:0]                     data_recv;
reg[9:0]                      wr_data_cnt;
reg[15:0]                     ff_cnt;               //S_FLUSH: consecutive 0xFF bytes received
reg                           preflight_done;

assign cmd_req_ack = (state == S_END);
assign block_read_req_ack = (state == S_READ_ACK);
assign block_write_req_ack= (state == S_WRITE_ACK);
assign block_write_data_rd = (state == S_WRITE_DATA_0);
assign spi_data_in = send_data;
assign data_recv = spi_data_out;
assign nCS_ctrl = CS_reg;
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		CS_reg <= 1'b1;
		spi_wr_req <= 1'b0;
		byte_cnt <= 16'd0;
		clk_div <= 16'd0;
		send_data <= 8'hff;
		state <= S_IDLE;
		cmd_req_error <= 1'b0;
		wr_data_cnt <= 10'd0;
		ff_cnt <= 16'd0;
		preflight_done <= 1'b0;
	end
	else
		case(state)
			S_IDLE:
			begin
				state <= S_INIT;
				clk_div <= spi_clk_div;
				CS_reg <= 1'b1;
				byte_cnt <= 16'd0;
				ff_cnt <= 16'd0;
				preflight_done <= 1'b0;
			end
			S_FLUSH:
			begin
				//CS low, clock out whatever the card is still sending (e.g. a data block
				//interrupted by a reset), until FLUSH_FF_BYTES consecutive 0xFF are seen.
				//Without this, leftover data bytes can be mistaken for a command response.
				if(spi_wr_ack == 1'b1)
				begin
					ff_cnt <= (data_recv == 8'hff) ? ff_cnt + 16'd1 : 16'd0;
					byte_cnt <= byte_cnt + 16'd1;
					if((data_recv == 8'hff && ff_cnt >= FLUSH_FF_BYTES - 16'd1) || byte_cnt >= FLUSH_MAX_BYTES - 16'd1)
					begin
						byte_cnt <= 16'd0;
						spi_wr_req <= 1'b0;
						CS_reg <= 1'b1;
						preflight_done <= 1'b1;
						state <= S_INIT;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_INIT:
			begin
				// Keep CS high for 64 bytes before CMD0, including warm FPGA reconfiguration.
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt >= 16'd63)
					begin
						byte_cnt <= 16'd0;
						spi_wr_req <= 1'b0;
						state <= preflight_done ? S_WAIT : S_FLUSH;
						CS_reg <= preflight_done ? 1'b1 : 1'b0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WAIT:
			begin
				cmd_req_error <= 1'b0;
				wr_data_cnt <= 10'd0;
				//wait for  instruction
				if(cmd_req == 1'b1)
					state <= S_CMD_PRE;
				else if(block_read_req == 1'b1)
					state <= S_READ_WAIT;
				else if(block_write_req == 1'b1)
					state <= S_WRITE_TOKEN;
				clk_div <= spi_clk_div;
			end
			S_CMD_PRE:
			begin
				//before sending a command, send an byte 'ff',provide some clocks
				if(spi_wr_ack == 1'b1)
				begin
					state <= S_CMD;
					spi_wr_req <= 1'b0;
					byte_cnt <= 16'd0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					CS_reg <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_CMD:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					//bytes 0..5 are the command itself; what comes back meanwhile is not a response
					if(byte_cnt < 16'd6)
						byte_cnt <= byte_cnt + 16'd1;
					else if((byte_cnt >= RESP_TIMEOUT) || (data_recv != cmd_r1 && data_recv[7] == 1'b0))
					begin
						state <= S_ERR;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else if(data_recv == cmd_r1)
					begin
						spi_wr_req <= 1'b0;
						if(cmd_data_len != 16'd0)
						begin
							state <= S_CMD_DATA;
							byte_cnt <= 16'd0;
						end
						else
						begin
							state <= S_END;
							byte_cnt <= 16'd0;
						end
					end
					else
						byte_cnt <=  byte_cnt + 16'd1;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					CS_reg <= 1'b0;
					if(byte_cnt == 16'd0)
						send_data <= (cmd[47:40] | 8'h40);
					else if(byte_cnt == 16'd1)
						send_data <= cmd[39:32];
					else if(byte_cnt == 16'd2)
						send_data <= cmd[31:24];
					else if(byte_cnt == 16'd3)
						send_data <= cmd[23:16];
					else if(byte_cnt == 16'd4)
						send_data <= cmd[15:8];
					else if(byte_cnt == 16'd5)
						send_data <= cmd[7:0];
					else
						send_data <= 8'hff;
				end
			end
			S_CMD_DATA:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == cmd_data_len - 16'd1)
					begin
						state <= S_END;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_READ_WAIT:
			begin
				if(spi_wr_ack == 1'b1 && data_recv == 8'hfe)
				begin
					spi_wr_req <= 1'b0;
					state <= S_READ;
					byte_cnt <= 16'd0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_READ:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == 16'd513)
					begin
						state <= S_READ_ACK;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_TOKEN:
				if(spi_wr_ack == 1'b1)
				begin
					state <= S_WRITE_DATA_0;
					spi_wr_req <= 1'b0;
					byte_cnt <= 16'd0;  
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hfe;
				end
			S_WRITE_DATA_0:
			begin
				state <= S_WRITE_DATA_1;
				wr_data_cnt <= wr_data_cnt + 10'd1;
			end
			S_WRITE_DATA_1:
			begin
				if(spi_wr_ack == 1'b1 && wr_data_cnt == 10'd512)
				begin
					state <= S_WRITE_CRC;
					spi_wr_req <= 1'b0;
				end
				else if(spi_wr_ack == 1'b1)
				begin
					state <= S_WRITE_DATA_0;
					spi_wr_req <= 1'b0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= block_write_data;
				end
			end
			S_WRITE_CRC:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == 16'd1)
					begin
						state <= S_WRITE_SUC;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_SUC :
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(data_recv[4:0] == 5'b00101)
					begin
						state <= S_WRITE_BUSY;
						spi_wr_req <= 1'b0;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_BUSY :
			begin
				if(spi_wr_ack == 1'b1)
				begin
					if(data_recv == 8'hff)
					begin
						state <= S_WRITE_ACK;
						spi_wr_req <= 1'b0;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_ERR:
			begin
				state <= S_END;
				cmd_req_error <= 1'b1;
			end
			S_READ_ACK,S_WRITE_ACK,S_END:
			begin
				state <= S_WAIT;
			end
			default:
				state <= S_IDLE;
		endcase
end
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		block_read_valid <= 1'b0;
	else if(state == S_READ && byte_cnt < 16'd512)
		block_read_valid <= spi_wr_ack;
	else
		block_read_valid <= 1'b0;
end

always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		block_read_data <= 8'd0;
	else if(state == S_READ && spi_wr_ack == 1'b1)
		block_read_data <= data_recv;
end

endmodule

`timescale 1ns/1ps

// 串口只发状态行：逐字节比对 190 字节固定报文。
// 事件日志不再导出，但仍验证 log_view 快照能在刷新后更新（供 OSD LOG 页）。
module tb_uart_slim_reporter;
    localparam integer CPB = 10;          // CLK_HZ/BAUD
    localparam integer STATUS_LEN = 190;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg frame_start = 0;
    reg log_refresh = 0;
    wire uart_tx;
    reg [7:0] rx_bytes [0:399];
    integer   rx_count = 0;

    wire        log_rd_start;
    wire [3:0]  log_rd_slot;
    reg         log_rd_done = 0;
    reg         log_rd_valid = 0;
    reg [95:0]  log_rd_data = 0;
    reg [15:0]  seq7 = 16'h0007;
    reg [31:0]  uptime7 = 32'h00001234;
    wire [251:0] log_view;
    wire        log_any_valid;

    uart_slim_reporter #(
        .CLK_HZ(1_000_000), .BAUD(100_000), .FRAMES_PER_REPORT(2)
    ) dut (
        .clk(clk), .rst(rst), .frame_start(frame_start),
        .brightness(3'd2), .contrast(3'd2), .transition(2'd0),
        .volume(3'd4), .image_index(2'd1), .image_count(3'd4),
        .uptime_bcd(24'h010203), .auto_mode(1'b1), .tf_mounted(1'b1),
        .wav_ready(1'b1), .health(4'd0), .load_stage(4'd9),
        .playlist_errors(4'd0),
        .log_refresh(log_refresh), .log_newest_slot(4'd7),
        .log_rd_start(log_rd_start), .log_rd_slot(log_rd_slot),
        .log_rd_done(log_rd_done), .log_rd_valid(log_rd_valid),
        .log_rd_data(log_rd_data), .log_view(log_view),
        .log_any_valid(log_any_valid), .uart_tx(uart_tx)
    );

    // 假的“最近 7 条”：slot 7 最新，slot 5 人为标成无效槽。
    always @(posedge clk) begin
        log_rd_done <= 1'b0;
        if (log_rd_start) begin
            log_rd_done <= 1'b1;
            case (log_rd_slot)
                4'd7: begin log_rd_data <= {8'h5A,8'h01,8'h02,8'h5A,seq7,uptime7,16'h0000};
                            log_rd_valid <= 1'b1; end
                4'd6: begin log_rd_data <= {8'h5A,8'h00,8'h00,8'h00,16'h0006,32'h00001111,16'h0000};
                            log_rd_valid <= 1'b1; end
                4'd5: begin log_rd_data <= {8'h5A,8'h03,8'h01,8'h07,16'h0005,32'h00001000,16'h0000};
                            log_rd_valid <= 1'b0; end
                4'd4: begin log_rd_data <= {8'h5A,8'h01,8'h03,8'h00,16'h0004,32'h00000E10,16'h0000};
                            log_rd_valid <= 1'b1; end
                4'd3: begin log_rd_data <= {8'h5A,8'h00,8'h01,8'h10,16'h0003,32'h00000258,16'h0000};
                            log_rd_valid <= 1'b1; end
                4'd2: begin log_rd_data <= {8'h5A,8'h02,8'h02,8'h03,16'h0002,32'h000000B4,16'h0000};
                            log_rd_valid <= 1'b1; end
                4'd1: begin log_rd_data <= {8'h5A,8'h00,8'h03,8'h00,16'h0001,32'h0000003C,16'h0000};
                            log_rd_valid <= 1'b1; end
                default: begin log_rd_data <= {8'h5A,8'h01,8'h00,8'h00,16'h0010,32'h00000001,16'h0000};
                            log_rd_valid <= 1'b1; end
            endcase
        end
    end

    // 采样式 UART 接收
    integer bit_i;
    reg [7:0] sh;
    initial begin
        forever begin
            @(negedge uart_tx);
            #(CPB*10*3/2);                 // 1.5 bit 到第 0 位中间
            for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin
                sh[bit_i] = uart_tx;
                #(CPB*10);
            end
            if (uart_tx !== 1'b1) $fatal(1,"stop bit low");
            rx_bytes[rx_count] = sh;
            rx_count = rx_count + 1;
        end
    end

    task pulse_frame; begin @(negedge clk); frame_start=1; @(negedge clk); frame_start=0; end endtask

    reg [7:0] want [0:199];
    integer want_n = 0;
    integer k;
    task add_line;
        input [8*200-1:0] s;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                want[want_n] = s[8*(n-1-i) +: 8];
                want_n = want_n + 1;
            end
        end
    endtask
    task add_crlf;
        begin
            want[want_n] = 8'h0d; want_n = want_n + 1;
            want[want_n] = 8'h0a; want_n = want_n + 1;
        end
    endtask

    initial begin
        add_line("UPTIME=01:02:03 IMAGE=2/4 AUTO_MODE=ON  TF_CARD=READY  WAV_AUDIO=READY  BRIGHTNESS_LEVEL=2 CONTRAST_LEVEL=2 VOLUME_LEVEL=4 TRANSITION=FADE    PLAYLIST_ERRORS=0 LOAD_PHASE=READY    HEALTH=0", 188); add_crlf;
        if (want_n != STATUS_LEN)
            $fatal(1,"expected length %0d",want_n);

        repeat(3) @(negedge clk);
        rst = 0;
        repeat(3) @(negedge clk);

        // 第 1 行状态：复位后每 2 帧一行
        pulse_frame(); pulse_frame();
        wait (rx_count == STATUS_LEN);
        for (k = 0; k < want_n; k = k + 1)
            if (rx_bytes[k] !== want[k])
                $fatal(1,"status byte %0d got %h want %h",k,rx_bytes[k],want[k]);

        // 日志快照只服务 OSD：刷新后 7 行应更新，第 2 行保持无效
        @(negedge clk); log_refresh = 1;
        @(negedge clk); log_refresh = 0;
        wait (log_view[15:0] === 16'h0007);
        repeat (1200) @(negedge clk);
        if (!log_any_valid || log_view[35] !== 1'b1 || log_view[2*36+35] !== 1'b0)
            $fatal(1,"log view valid flags wrong");

        // 运行中刷新：最新槽 seq/BCD 应更新
        seq7 = 16'h0008;
        uptime7 = 32'h00002000;
        @(negedge clk); log_refresh = 1;
        @(negedge clk); log_refresh = 0;
        wait (log_view[15:0] === 16'h0008);
        repeat (1200) @(negedge clk);
        if (log_view[27:16] !== 12'h192)
            $fatal(1,"live log view bcd=%h", log_view[27:16]);

        // 第 2 行状态
        pulse_frame(); pulse_frame();
        wait (rx_count == 2*STATUS_LEN);
        for (k = 0; k < want_n; k = k + 1)
            if (rx_bytes[STATUS_LEN + k] !== want[k])
                $fatal(1,"second status byte %0d got %h want %h", k,
                       rx_bytes[STATUS_LEN + k], want[k]);

        $display("ALL PASSED: status line only + log view refresh (%0d bytes)", 2*STATUS_LEN);
        $finish;
    end
    initial begin
        #200_000_000;
        $fatal(1,"slim reporter timeout (got %0d bytes)",rx_count);
    end
endmodule

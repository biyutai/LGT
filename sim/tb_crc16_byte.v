`timescale 1ns/1ps
// crc16_byte 等价性：与"逐位 0x1021"参考实现（本文件内自带）逐值比对。
// 参考实现独立写一遍（不调用被改模块的任何函数），避免自证。
module tb_crc16_byte;
    reg clk = 0;
    always #5 clk = ~clk;

    reg         rst = 1;
    reg  [15:0] crc_in = 16'd0;
    reg  [7:0]  byte_in = 8'd0;
    wire [15:0] crc_out;
    wire        table_ready;

    crc16_byte dut (
        .clk(clk), .rst(rst),
        .crc_in(crc_in), .byte_in(byte_in),
        .crc_out(crc_out), .table_ready(table_ready)
    );

    function [15:0] ref_step_byte;      // 逐位参考：与 RTL 里的 POLY 一致
        input [15:0] crc_in;
        input [7:0]  byte_in;
        integer i;
        reg [15:0] c;
        begin
            c = crc_in ^ {byte_in, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                c = c[15] ? ({c[14:0], 1'b0} ^ 16'h1021) : {c[14:0], 1'b0};
            ref_step_byte = c;
        end
    endfunction

    function [15:0] ref_crc40;          // 40 比特（5 字节）整段
        input [39:0] payload;
        input [15:0] crc_in;
        reg [15:0] c;
        begin
            c = ref_step_byte(crc_in, payload[39:32]);
            c = ref_step_byte(c, payload[31:24]);
            c = ref_step_byte(c, payload[23:16]);
            c = ref_step_byte(c, payload[15:8]);
            c = ref_step_byte(c, payload[7:0]);
            ref_crc40 = c;
        end
    endfunction

    // 单字节一步：与参考比对（把"表"与"串联"分开测）
    task dut_step;
        input  [15:0] c_in;
        input  [7:0]  b_in;
        output [15:0] c_out;
        begin
            crc_in  = c_in;
            byte_in = b_in;
            @(negedge clk); @(negedge clk);   // 两拍流水
            c_out = crc_out;
        end
    endtask

    integer n, k;
    reg [39:0] payload;
    reg [15:0] want, got, acc;
    reg [15:0] step_v;
    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        while (!table_ready) @(negedge clk);
        @(negedge clk);
        $display("table ready at %0t", $time);

        // 1) 单字节一步：随机 (crc, byte) 各测一遍
        for (n = 0; n < 32; n = n + 1) begin
            want = ref_step_byte(n[15:0], (n * 37 + 11));
            dut_step(n[15:0], (n * 37 + 11), got);
            if (got !== want)
                $fatal(1, "byte step mismatch n=%0d crc=%h byte=%h got=%h want=%h",
                       n, n[15:0], (n * 37 + 11), got, want);
        end

        // 2) 40 比特整段：五字节串起来
        for (n = 0; n < 40; n = n + 1) begin
            payload = {$random(n * 7 + 1), $random(n * 13 + 5)};
            want = ref_crc40(payload, 16'd0);
            acc  = 16'd0;
            for (k = 0; k < 5; k = k + 1) begin
                dut_step(acc, payload[39 - k*8 -: 8], step_v);
                acc = step_v;
            end
            got = acc;
            if (got !== want)
                $fatal(1, "crc40 mismatch n=%0d payload=%h got=%h want=%h",
                       n, payload, got, want);
        end

        // 3) 边界：全 0 与全 1
        payload = 40'd0;          want = ref_crc40(payload, 16'd0);
        acc = 16'd0; for (k = 0; k < 5; k = k + 1) begin dut_step(acc, payload[39 - k*8 -: 8], step_v); acc = step_v; end
        if (acc !== want) $fatal(1, "crc40 all-zero mismatch");
        payload = 40'hffffffffff;  want = ref_crc40(payload, 16'd0);
        acc = 16'd0; for (k = 0; k < 5; k = k + 1) begin dut_step(acc, payload[39 - k*8 -: 8], step_v); acc = step_v; end
        if (acc !== want) $fatal(1, "crc40 all-one mismatch");

        $display("ALL PASSED: crc16_byte matches bit-serial reference");
        $finish;
    end
    initial begin
        #2_000_000;
        $fatal(1, "crc16_byte timeout");
    end
endmodule

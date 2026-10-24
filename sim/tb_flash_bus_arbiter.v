`timescale 1ns/1ps

// 客户端仲裁定向用例（共享一份 store）：
//   1) 参数日志与事件日志同时要总线 → 参数日志先服务；
//   2) 事件日志占用期间来的 save 请求被闩住、不丢，等日志整笔做完再发；
//   3) 任何时刻只有 owner 能发 store 操作（另一侧 busy 时 owner 不会切过去）。
module tb_flash_bus_arbiter;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg j_load_req = 0, j_save_req = 0, log_req = 0;
    wire j_load_start, j_save_start, log_grant;
    wire st_start, st_op_write;
    wire [23:0] st_address;
    wire [95:0] st_write_data;

    // 参数日志桩：收到 start 后忙 24 拍，并发一次 store 操作
    reg j_busy = 0, j_st_start = 0;
    reg [7:0] j_cnt = 0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            j_busy <= 0; j_st_start <= 0; j_cnt <= 0;
        end else begin
            j_st_start <= 1'b0;
            if ((j_load_start || j_save_start) && !j_busy) begin
                j_busy <= 1; j_cnt <= 8'd24; j_st_start <= 1'b1;
            end else if (j_busy) begin
                if (j_cnt == 0) j_busy <= 0; else j_cnt <= j_cnt - 1'b1;
            end
        end
    end

    // 事件日志桩：grant 且有待办时忙 36 拍
    reg l_busy = 0, l_st_start = 0;
    reg [7:0] l_cnt = 0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            l_busy <= 0; l_st_start <= 0; l_cnt <= 0;
        end else begin
            l_st_start <= 1'b0;
            if (log_grant && log_req && !l_busy) begin
                l_busy <= 1; l_cnt <= 8'd36; l_st_start <= 1'b1; log_req <= 1'b0;
            end else if (l_busy) begin
                if (l_cnt == 0) l_busy <= 0; else l_cnt <= l_cnt - 1'b1;
            end
        end
    end

    // store 桩：任一操作忙 20 拍
    reg st_busy = 0;
    reg [7:0] st_cnt = 0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st_busy <= 0; st_cnt <= 0;
        end else if (st_start && !st_busy) begin
            st_busy <= 1; st_cnt <= 8'd20;
        end else if (st_busy) begin
            if (st_cnt == 0) st_busy <= 0; else st_cnt <= st_cnt - 1'b1;
        end
    end

    flash_bus_arbiter dut (
        .clk(clk), .rst(rst),
        .journal_load_req(j_load_req), .journal_save_req(j_save_req),
        .journal_busy(j_busy), .journal_st_start(j_st_start),
        .journal_st_op_write(1'b0), .journal_st_address(24'h7fe000),
        .journal_st_write_data(96'd0),
        .journal_load_start(j_load_start), .journal_save_start(j_save_start),
        .log_req(log_req), .log_busy(l_busy), .log_st_start(l_st_start),
        .log_st_op_write(1'b1), .log_st_address(24'h700000),
        .log_st_write_data(96'd0), .log_grant(log_grant),
        .store_start(st_start), .store_op_write(st_op_write),
        .store_address(st_address), .store_write_data(st_write_data)
    );

    reg saw_load = 0, saw_save = 0, saw_log = 0;
    reg load_ok = 0, save_ok = 0;
    always @(posedge clk) if (!rst) begin
        if (j_st_start && dut.owner)
            $fatal(1,"journal issued a store op while the log owned it (%0t)",$time);
        if (l_st_start && !dut.owner)
            $fatal(1,"log issued a store op while the journal owned it (%0t)",$time);
        if (st_start && st_busy)
            $fatal(1,"store start while busy (%0t)",$time);
        if (j_load_start) begin
            if (l_busy) $fatal(1,"load start overlapped the log (%0t)",$time);
            saw_load <= 1'b1;
            if (!saw_log) load_ok <= 1'b1;
        end
        if (j_save_start) begin
            if (l_busy) $fatal(1,"save start overlapped the log (%0t)",$time);
            saw_save <= 1'b1;
            if (saw_log) save_ok <= 1'b1;
        end
        if (l_busy && !saw_log) saw_log <= 1'b1;
    end

    task tick;
        begin @(negedge clk); #1; end
    endtask

    initial begin
        repeat(3) tick();
        rst = 0; tick();

        @(negedge clk);
        j_load_req = 1; log_req = 1;
        @(negedge clk);
        j_load_req = 0;
        repeat(200) tick();
        if (!saw_load || !saw_log) $fatal(1,"both requests must be served");
        if (!load_ok) $fatal(1,"journal load must be served before the log");

        log_req = 1;
        wait(log_grant); tick();
        wait(l_busy);
        @(negedge clk); j_save_req = 1;
        @(negedge clk); j_save_req = 0;
        repeat(400) tick();
        if (!saw_save) $fatal(1,"save request was lost while the log owned the bus");
        if (!save_ok) $fatal(1,"save must be issued after the log finished");

        $display("ALL PASSED: journal priority, log grant, save deferred but not lost (shared store)");
        $finish;
    end
    initial begin
        #2_000_000;
        $fatal(1,"arbiter timeout");
    end
endmodule

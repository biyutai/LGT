// 系统复位发生器（板载 50MHz 时钟域）
//
// 上电或按下复位键时输出高电平复位；等所有 PLL 锁定、并连续稳定 HOLD_CYCLES 个周期后才释放。
// 一旦释放，PLL 锁定信号的短暂抖动不再引起复位（防止运行中随机复位），只有复位键能再次复位。
// 输出是 clk 域的同步信号，各时钟域还需经 rst_sync 再同步一次。
module sys_reset #(
    parameter integer HOLD_CYCLES = 1_000_000   // 20ms @ 50MHz
)(
    input  wire clk,          // 板载晶振，PLL 锁定前就已稳定
    input  wire rst_n,        // 复位键，低电平有效，异步
    input  wire pll_locked,   // 所有 PLL 锁定信号相与
    output reg  rst           // 高电平有效
);

reg  [1:0]  rst_n_sync = 2'b00;
reg  [23:0] hold_cnt   = 24'd0;

initial rst = 1'b1;

// 按键是异步输入，先打两拍
always @(posedge clk)
    rst_n_sync <= {rst_n_sync[0], rst_n};

always @(posedge clk) begin
    if (!rst_n_sync[1]) begin
        hold_cnt <= 24'd0;
        rst      <= 1'b1;
    end else if (!rst) begin
        rst      <= 1'b0;
    end else if (pll_locked) begin
        if (hold_cnt == HOLD_CYCLES - 1)
            rst      <= 1'b0;
        else
            hold_cnt <= hold_cnt + 24'd1;
    end else begin
        hold_cnt <= 24'd0;
    end
end

endmodule

// KEY1 short/long detector.  The board reset input remains independent.
// 缩略图浏览时：短按选中焦点图片，长按退出缩略图（不选图）；
// 正常播放时：短按切换转场，长按切换下一首。
module key1_short_long #(
    parameter integer DEBOUNCE_CYCLES = 1_000_000,
    parameter integer LONG_CYCLES = 40_000_000
)(
    input  wire clk,
    input  wire key_n,
    input  wire system_rst,
    input  wire browse_mode,
    output reg  reset_n = 1'b1,
    output reg  short_toggle = 1'b0,
    output reg  browse_short_toggle = 1'b0,
    output reg  long_toggle = 1'b0,
    output reg  browse_long_toggle = 1'b0
);
    localparam integer DB_BITS = (DEBOUNCE_CYCLES > 1) ? $clog2(DEBOUNCE_CYCLES) : 1;
    localparam integer LONG_BITS = (LONG_CYCLES > 1) ? $clog2(LONG_CYCLES) : 1;
    reg [1:0] key_sync = 2'b11;
    reg stable_n = 1'b1;
    reg [DB_BITS-1:0] db_count = 0;
    reg [LONG_BITS-1:0] held_count = 0;
    reg long_seen = 1'b0;
    reg browse_on_press = 1'b0;
    wire changed = key_sync[1] != stable_n && db_count == DEBOUNCE_CYCLES - 1;
    wire released = changed && key_sync[1];
    wire pressed = changed && !key_sync[1];

    always @(posedge clk) begin
        key_sync <= {key_sync[0],key_n};
        if (key_sync[1] == stable_n || changed)
            db_count <= 0;
        else
            db_count <= db_count + 1'b1;
        if (changed)
            stable_n <= key_sync[1];

        if (pressed) begin
            held_count <= 0;
            browse_on_press <= browse_mode;
        end
        else if (released) begin
            held_count <= 0;
            reset_n <= 1'b1;
            long_seen <= 1'b0;
            if (!long_seen && !system_rst) begin
                if (browse_on_press)
                    browse_short_toggle <= ~browse_short_toggle;
                else
                    short_toggle <= ~short_toggle;
            end
        end else if (!stable_n && !long_seen) begin
            if (held_count == LONG_CYCLES - 1) begin
                long_seen <= 1'b1;
                if (browse_on_press)
                    browse_long_toggle <= ~browse_long_toggle;
                else
                    long_toggle <= ~long_toggle;
            end else
                held_count <= held_count + 1'b1;
        end
        if (system_rst)
            short_toggle <= 1'b0;
    end
endmodule

`timescale 1ns/1ps
// 复现：SW1 信息页把 key_next/key_prev 强行拉 0，消抖器把它当成按下，
// 20 ms 后产生 manual_prev_press / manual_next_press，后台切到上一张。
// 修复后：raw 直连 + .info_page(info_page)，同一激励下计数必须为 0。
module tb_sw1_info_gate;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg sw2 = 0;
    reg sw4 = 0;
    reg [3:0] subtitle_select = 0;
    reg key_mode = 1;
    reg key_next_raw = 1;
    reg key_prev_raw = 1;
    reg info_page = 0;
    wire key_next = key_next_raw;
    wire key_prev = key_prev_raw;
    reg [3:0] effect_select = 0;
    reg demo_frame_step = 0;
    reg browse_mode = 0;
    reg prev_available = 1;
    reg persist_ready = 1, persist_apply = 0;
    reg [2:0] persisted_brightness = 2, persisted_contrast = 2;
    reg [1:0] persisted_transition = 0;

    wire subtitle_enable, status_enable;
    wire [1:0] alpha;
    wire [2:0] edit_mode;
    wire [2:0] brightness_level, contrast_level;
    wire [3:0] effect_level;
    wire [2:0] audio_effect_level;
    wire demo_mode;
    wire sd_key_next;
    wire manual_next_press, manual_prev_press;
    wire [1:0] transition_kind;

    integer manual_count = 0;
    integer prev_count = 0;
    always @(posedge clk) if (!rst) begin
        if (manual_next_press) manual_count <= manual_count + 1;
        if (manual_prev_press) prev_count <= prev_count + 1;
    end

    osd_controls #(.CLK_FREQ_HZ(1000)) dut (
        .clk(clk), .rst(rst),
        .sw2(sw2), .sw4(sw4), .subtitle_select(subtitle_select),
        .key_mode(key_mode), .key_mode_pulse(1'b0),
        .key_next(key_next), .key_prev(key_prev),
        .browse_mode(browse_mode),
        .info_page(info_page),
        .prev_available(prev_available),
        .effect_select(effect_select),
        .demo_frame_step(demo_frame_step), .demo_mode(demo_mode),
        .persist_ready(persist_ready), .persist_apply(persist_apply),
        .persist_brightness(persisted_brightness),
        .persist_contrast(persisted_contrast),
        .persist_transition(persisted_transition),
        .sd_key_next(sd_key_next),
        .manual_next_press(manual_next_press), .manual_prev_press(manual_prev_press),
        .transition_kind(transition_kind),
        .edit_mode(edit_mode), .brightness_level(brightness_level),
        .contrast_level(contrast_level),
        .effect_level(effect_level), .audio_effect_level(audio_effect_level),
        .subtitle_enable(subtitle_enable), .status_enable(status_enable),
        .alpha(alpha));

    task tick;
        begin @(negedge clk); #1; end
    endtask

    initial begin
        repeat (2) tick();
        rst = 0;
        repeat (3) tick();

        // 进入信息页：两个按键都未按（raw=1），旧顶层把它们拉成 0
        info_page = 1;
        repeat (60) tick();
        if (manual_count != 0 || prev_count != 0) begin
            $display("FAIL: info-page entry generated false key pulse (next=%0d prev=%0d)",
                     manual_count, prev_count);
            $fatal(1);
        end

        // 退出信息页：raw 仍为 1，不应产生新的按键脉冲
        info_page = 0;
        repeat (60) tick();
        if (manual_count != 0 || prev_count != 0) begin
            $display("FAIL: info-page exit generated false key pulse (next=%0d prev=%0d)",
                     manual_count, prev_count);
            $fatal(1);
        end

        // 退出后真实按一次 KEY4，应只产生一次 prev
        key_prev_raw = 0;
        repeat (40) tick();
        key_prev_raw = 1;
        repeat (40) tick();
        if (prev_count != 1 || manual_count != 0) begin
            $display("FAIL: real KEY4 after info page not detected (next=%0d prev=%0d)",
                     manual_count, prev_count);
            $fatal(1);
        end

        $display("ALL PASSED: SW1 info page does not generate key pulses");
        $finish;
    end
endmodule

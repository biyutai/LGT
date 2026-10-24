`timescale 1ns/1ps
module tb_osd_controls;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg sw2 = 0;
    reg sw4 = 0;
    reg [3:0] subtitle_select = 0;
    reg key_mode = 1, key_next = 1, key_prev = 1;
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
    always @(posedge clk) if (!rst && manual_next_press) manual_count = manual_count + 1;
    integer prev_count = 0;
    always @(posedge clk) if (!rst && manual_prev_press) prev_count = prev_count + 1;
    osd_controls #(.CLK_FREQ_HZ(1000)) dut (.clk(clk), .rst(rst),
        .sw2(sw2), .sw4(sw4), .subtitle_select(subtitle_select),
        .key_mode(key_mode), .key_mode_pulse(1'b0),
        .key_next(key_next), .key_prev(key_prev),
        .browse_mode(browse_mode),
        .info_page(1'b0),
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
    task press_mode;
        begin key_mode = 0; repeat (25) tick(); key_mode = 1; repeat (25) tick(); end
    endtask
    task press_next;
        begin key_next = 0; repeat (25) tick(); key_next = 1; repeat (25) tick(); end
    endtask
    task press_prev;
        begin key_prev = 0; repeat (25) tick(); key_prev = 1; repeat (25) tick(); end
    endtask
    task select_subtitle;
        input integer index;
        begin subtitle_select[index] = 1'b1; tick(); subtitle_select = 0; tick(); end
    endtask
    // 矩阵键 S9~S12 直接选转场
    task select_effect;
        input integer index;
        begin
            effect_select = 4'd1 << index; tick();
            effect_select = 4'd0; tick();
        end
    endtask
    task check;
        input condition;
        input [8*64-1:0] message;
        begin if (!condition) begin $display("FAIL: %0s", message); $fatal(1); end end
    endtask
    initial begin
        repeat (2) tick(); rst = 0;
        repeat (3) tick();
        check(subtitle_enable && !status_enable && alpha == 2'd1,
              "default screen is clean: subtitle at 35 percent, no status bar");
        select_subtitle(0);
        check(!subtitle_enable && alpha == 2'd0, "S5 hides subtitle");
        select_subtitle(1);
        check(subtitle_enable && alpha == 2'd1, "S6 selects 35 percent");
        select_subtitle(2);
        check(subtitle_enable && alpha == 2'd2, "S7 selects 70 percent");
        select_subtitle(3);
        check(subtitle_enable && alpha == 2'd3, "S8 selects 100 percent");
        sw2 = 1; repeat (3) tick();
        check(status_enable && subtitle_enable && alpha == 2'd3,
              "SW2 up shows the status bar without changing subtitle");
        sw2 = 0; repeat (3) tick();
        check(edit_mode == 0 && brightness_level == 2 && contrast_level == 2,
              "normal mode starts with neutral image");
        key_next = 0; tick();
        check(sd_key_next == 0, "normal KEY2 reaches the slide player");
        key_next = 1; repeat (25) tick();
        press_mode();
        check(edit_mode == 1 && sd_key_next && !manual_prev_press,
              "KEY3 enters brightness mode and blocks playback keys");
        press_next(); check(brightness_level == 3, "KEY2 raises brightness");
        browse_mode = 1;
        press_next();
        check(brightness_level == 3 && sd_key_next && manual_count == 0,
              "browse KEY2 only moves thumbnail focus");
        select_subtitle(0);
        check(!status_enable && !subtitle_enable && alpha == 2'd0,
              "S5 hides subtitle while browsing");
        select_subtitle(3);
        check(!status_enable && subtitle_enable && alpha == 2'd3,
              "S8 restores full subtitle while browsing");
        sw2 = 1; repeat (3) tick();
        check(status_enable && subtitle_enable,
              "SW2 up shows status while browsing");
        sw2 = 0; repeat (3) tick();
        browse_mode = 0;
        press_next(); press_next(); check(brightness_level == 4, "brightness saturates at maximum");
        press_prev(); check(brightness_level == 3, "KEY4 lowers brightness");
        press_mode(); check(edit_mode == 2, "KEY3 selects contrast");
        press_prev(); press_prev(); press_prev();
        check(contrast_level == 0, "contrast saturates at minimum");
        press_next(); check(contrast_level == 1, "KEY2 raises contrast");
        key_next = 0;
        press_mode(); press_mode(); press_mode();   // 编辑链：正常→亮度→对比度→特效→音效→正常
        check(edit_mode == 0 && sd_key_next,
              "exiting edit mode keeps a held KEY2 away from the slide player");
        key_next = 1; repeat (3) tick();
        key_next = 0; tick();
        check(sd_key_next == 0, "KEY2 resumes after release");
        key_next = 1; repeat (25) tick();
        prev_available=0;
        press_prev();
        check(prev_count == 0, "KEY4 does not fade when only one photo exists");
        prev_available=1;
        press_prev();
        check(prev_count == 1, "normal KEY4 requests previous photo once");
        press_next();
        check(manual_count == 1, "normal KEY2 produces one transition request");
        press_mode();
        press_next();
        check(manual_count == 1, "brightness KEY2 does not start a transition");
        press_mode(); check(edit_mode == 2, "KEY3 selects contrast");
        press_mode(); check(edit_mode == 3, "KEY3 selects the picture-effect level");
        if (effect_level != 4'd0) $fatal(1, "effect level must start at 0");
        press_next(); press_next(); press_next();
        check(effect_level == 4'd3, "KEY2 raises the effect level");
        press_prev(); check(effect_level == 4'd2, "KEY4 lowers the effect level");
        press_next(); press_next(); press_next();
        press_next(); press_next(); press_next();
        check(effect_level == 4'd5, "effect level saturates at 5 (split/posterize removed)");
        press_next(); check(effect_level == 4'd5, "effect level stays at 5");
        while (effect_level != 4'd0) press_prev();
        check(effect_level == 4'd0, "effect level returns to 0");
        // 第 5 档：音频音效 0~5
        press_mode(); check(edit_mode == 4, "KEY3 selects the audio-effect level");
        if (audio_effect_level != 3'd0) $fatal(1, "audio effect level must start at 0");
        press_next(); press_next();
        check(audio_effect_level == 3'd2, "KEY2 raises the audio effect level");
        press_prev(); check(audio_effect_level == 3'd1, "KEY4 lowers the audio effect level");
        press_next(); press_next();
        check(audio_effect_level == 3'd3, "audio effect level saturates at 3");
        press_next(); check(audio_effect_level == 3'd3, "audio effect level stays at 3");
        while (audio_effect_level != 3'd0) press_prev();
        check(audio_effect_level == 3'd0, "audio effect level returns to 0");
        press_mode(); check(edit_mode == 0,
                            "KEY3 returns to playback after the audio-effect mode");
        select_effect(2); check(transition_kind == 2, "S11 selects right reveal directly");
        select_effect(1); check(transition_kind == 1, "S10 selects left reveal directly");
        select_effect(3); check(transition_kind == 3, "S12 selects diamond dissolve");
        select_effect(0); check(transition_kind == 0, "S9 selects fade directly");
        select_effect(3); check(transition_kind == 3, "S12 reselects diamond dissolve");
        browse_mode = 1;
        select_effect(1);
        check(transition_kind == 3, "browse mode ignores the transition keys");
        browse_mode = 0;
        select_effect(0); check(transition_kind == 0, "S9 returns to fade");
        select_subtitle(0); repeat (3) tick();
        check(!status_enable && !subtitle_enable && edit_mode == 0,
              "subtitle keys remain independent of edit mode");
        check(transition_kind == 0 && brightness_level == 4 && contrast_level == 1,
              "settings before demo are the ones to restore");
        sw4 = 1; repeat (3) tick();
        check(demo_mode && sd_key_next,
              "SW4 up enters demo and blocks the slide keys");
        press_next(); press_prev();
        check(manual_count == 1 && prev_count == 1,
              "demo ignores KEY2 and KEY4");
        browse_mode = 1;
        demo_frame_step = 1; tick(); demo_frame_step = 0; repeat (2) tick();
        check(transition_kind == 0 && brightness_level == 4 && contrast_level == 1,
              "demo settings hold while browsing");
        browse_mode = 0;
        demo_frame_step = 1; tick(); demo_frame_step = 0; repeat (2) tick();
        check(transition_kind == 1 && brightness_level == 0 && contrast_level == 2,
              "demo frame advances transition and color levels");
        sw4 = 0; repeat (3) tick();
        check(!demo_mode && transition_kind == 0 && brightness_level == 4 && contrast_level == 1,
              "SW4 down restores user settings");
        persist_ready = 0; key_next = 0; tick();
        check(sd_key_next && !manual_prev_press,
              "playback keys must stay blocked while Flash settings load");
        persisted_brightness = 4; persisted_contrast = 1; persisted_transition = 3;
        persist_apply = 1; persist_ready = 1; tick(); persist_apply = 0; tick();
        check(brightness_level == 4 && contrast_level == 1 && transition_kind == 3,
              "loaded Flash settings must override defaults");
        key_next = 1; repeat (3) tick();
        $display("ALL PASSED: OSD controls"); $finish;
    end
endmodule

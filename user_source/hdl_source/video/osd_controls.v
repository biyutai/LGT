`timescale 1ns/1ps

module osd_controls #(
    parameter integer CLK_FREQ_HZ = 25_200_000
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       key_mode,
    input  wire       key_mode_pulse,
    input  wire       key_next,
    input  wire       key_prev,
    input  wire       browse_mode,
    input  wire       info_page,          // SW1 信息页：屏蔽消抖后的播放/编辑键，但不要把输入拉 0
    input  wire       prev_available,
    // 矩阵键 S9~S12 直接选择转场（one-hot）
    input  wire [3:0] effect_select,
    input  wire       demo_frame_step,
    input  wire       persist_ready,
    input  wire       persist_apply,
    input  wire [2:0] persist_brightness,
    input  wire [2:0] persist_contrast,
    input  wire [1:0] persist_transition,
    input  wire       sw2,
    input  wire       sw4,
    input  wire [3:0] subtitle_select,
    output wire       sd_key_next,
    output wire       manual_next_press,
    output wire       manual_prev_press,
    output reg  [1:0] transition_kind,
    output reg  [2:0] edit_mode,
    output reg  [2:0] brightness_level,
    output reg  [2:0] contrast_level,
    output reg  [3:0] effect_level,
    output reg  [2:0] audio_effect_level,
    output reg        demo_mode,
    output wire       subtitle_enable,
    output wire       status_enable,
    output reg  [1:0] alpha
);
    reg sw_meta, sw_sync;
    reg sw4_meta, sw4_sync;
    reg playback_armed;
    reg [1:0] saved_transition;
    reg [2:0] saved_brightness, saved_contrast;
    wire mode_press, next_press, prev_press;
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_mode_key (
        .clk(clk), .rst(rst), .button_in(key_mode), .press_pulse(mode_press)
    );
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_next_key (
        .clk(clk), .rst(rst), .button_in(key_next), .press_pulse(next_press)
    );
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_prev_key (
        .clk(clk), .rst(rst), .button_in(key_prev), .press_pulse(prev_press)
    );

    // 信息页只屏蔽消抖后的按键动作，消抖器始终看真实按键电平。
    // 旧实现把 key_* 强制拉 0，消抖器会把整段信息页误判成一次按下，
    // SW1 拨下时就会看到后台已经切到上一张/下一张。
    wire next_press_eff = next_press & ~info_page;
    wire prev_press_eff = prev_press & ~info_page;
    wire mode_press_eff = mode_press & ~info_page;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sw_meta <= 1'b0;
            sw_sync <= 1'b0;
            sw4_meta <= 1'b0;
            sw4_sync <= 1'b0;
            alpha <= 2'd1;                     // 产品化：默认 35% 的低存在感品牌字幕
            edit_mode <= 2'd0;
            brightness_level <= 3'd2;
            contrast_level <= 3'd2;
            effect_level <= 4'd0;
            audio_effect_level <= 3'd0;
            transition_kind <= 2'd0;
            demo_mode <= 1'b0;
            saved_transition <= 2'd0;
            saved_brightness <= 3'd2;
            saved_contrast <= 3'd2;
            playback_armed <= 1'b1;
        end else begin
            sw_meta <= sw2;
            sw_sync <= sw_meta;
            sw4_meta <= sw4;
            sw4_sync <= sw4_meta;
            if (subtitle_select[0])
                alpha <= 2'd0;
            else if (subtitle_select[1])
                alpha <= 2'd1;
            else if (subtitle_select[2])
                alpha <= 2'd2;
            else if (subtitle_select[3])
                alpha <= 2'd3;
            if (persist_apply) begin
                brightness_level <= persist_brightness;
                contrast_level <= persist_contrast;
                transition_kind <= persist_transition;
                edit_mode <= 3'd0;
                demo_mode <= 1'b0;
            end else if (!persist_ready) begin
                edit_mode <= 3'd0;
                demo_mode <= 1'b0;
            end else if (sw4_sync && !demo_mode) begin
                // SW4 up: demo runs and the user's picture settings are kept aside
                saved_transition <= transition_kind;
                saved_brightness <= brightness_level;
                saved_contrast <= contrast_level;
                edit_mode <= 3'd0;
                playback_armed <= 1'b1;
                demo_mode <= 1'b1;
            end else if (!sw4_sync && demo_mode) begin
                transition_kind <= saved_transition;
                brightness_level <= saved_brightness;
                contrast_level <= saved_contrast;
                edit_mode <= 3'd0;
                playback_armed <= 1'b1;
                demo_mode <= 1'b0;
            end else begin
                if (!demo_mode) begin
                    if (effect_select != 4'd0 && !browse_mode) begin
                        // 直接选：S9 淡入 / S10 左揭示 / S11 右揭示 / S12 菱形溶解
                        if (effect_select[0])
                            transition_kind <= 2'd0;
                        else if (effect_select[1])
                            transition_kind <= 2'd1;
                        else if (effect_select[2])
                            transition_kind <= 2'd2;
                        else
                            transition_kind <= 2'd3;
                    end
                    if ((mode_press_eff || (key_mode_pulse & ~info_page)) && !browse_mode) begin
                        // 编辑链：正常 → 亮度 → 对比度 → 特效 → 音效 → 正常
                        edit_mode <= (edit_mode == 3'd4) ? 3'd0 : edit_mode + 3'd1;
                        playback_armed <= 1'b0;
                    end else if (edit_mode == 2'd0 && !playback_armed && !info_page && key_next && key_prev)
                        playback_armed <= 1'b1;
                    else if (edit_mode == 2'd1 && !browse_mode) begin
                        if (next_press_eff && brightness_level < 3'd4)
                            brightness_level <= brightness_level + 3'd1;
                        else if (prev_press_eff && brightness_level > 3'd0)
                            brightness_level <= brightness_level - 3'd1;
                    end else if (edit_mode == 2'd2 && !browse_mode) begin
                        if (next_press_eff && contrast_level < 3'd4)
                            contrast_level <= contrast_level + 3'd1;
                        else if (prev_press_eff && contrast_level > 3'd0)
                            contrast_level <= contrast_level - 3'd1;
                    end else if (edit_mode == 2'd3 && !browse_mode) begin
                        // 第 4 档：画面特效，0~7 档
                        if (next_press_eff && effect_level < 4'd5)
                            effect_level <= effect_level + 4'd1;
                        else if (prev_press_eff && effect_level > 4'd0)
                            effect_level <= effect_level - 4'd1;
                    end else if (edit_mode == 3'd4 && !browse_mode) begin
                        // 第 5 档：音频音效，0~3 档（原声/低音/明亮/低音+明亮）
                        if (next_press_eff && audio_effect_level < 3'd3)
                            audio_effect_level <= audio_effect_level + 3'd1;
                        else if (prev_press_eff && audio_effect_level > 3'd0)
                            audio_effect_level <= audio_effect_level - 3'd1;
                    end
                end else if (demo_frame_step && !browse_mode) begin
                    transition_kind <= transition_kind + 2'd1;
                    brightness_level <= brightness_level == 3'd4 ? 3'd0 : brightness_level + 3'd1;
                    contrast_level <= contrast_level == 3'd4 ? 3'd0 : contrast_level + 3'd1;
                end
            end
        end
    end

    assign sd_key_next = (persist_ready && !browse_mode && edit_mode == 2'd0 && playback_armed && !demo_mode && !info_page) ? key_next : 1'b1;
    assign manual_next_press = (persist_ready && !browse_mode && edit_mode == 2'd0 && playback_armed && !demo_mode) && next_press_eff;
    assign manual_prev_press = (persist_ready && prev_available && !browse_mode && edit_mode == 2'd0 && playback_armed && !demo_mode) && prev_press_eff;

    // Board manual: switch up is 1. Both layers start visible with switches down.
    // 产品化：拨下 = 默认干净（不显示状态栏），拨上 = 状态栏常显（评委看参数与自检行）
    assign status_enable = sw_sync;
    assign subtitle_enable = alpha != 2'd0;
endmodule

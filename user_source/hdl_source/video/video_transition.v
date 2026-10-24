`timescale 1ns/1ps

module video_transition #(
    parameter integer FADE_FRAMES = 16,
    parameter integer H_ACTIVE = 640,
    parameter integer V_ACTIVE = 480,
    parameter integer WAIT_FRAMES = 240
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        de,
    input  wire        active,
    input  wire        manual_press,
    input  wire        manual_prev_press,
    input  wire        browse_mode,
    input  wire        browse_select_pulse,
    input  wire        prefetch_enabled,
    input  wire        next_ready,
    input  wire [1:0]  buffer_index,
    input  wire [1:0]  effect_kind,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [23:0] rgb_in,
    output reg  [23:0] rgb_out,
    output reg         switch_toggle,
    output reg         prev_toggle,
    output wire        prev_in_progress,
    output wire        busy
);
    localparam [1:0] IDLE = 2'd0, OUT = 2'd1, WAIT_SWITCH = 2'd2, IN = 2'd3;
    localparam [4:0] DIAMOND_FRAMES = 5'd24;
    localparam [11:0] CENTER_X = H_ACTIVE / 2, CENTER_Y = V_ACTIVE / 2;
    localparam integer SHIFT = $clog2(FADE_FRAMES);
    reg [1:0] state, kind_q, buffer_prev;
    reg [4:0] progress;
    reg new_frame_pending;
    reg pending_prev;
    reg active_seen;
    reg [8:0] wait_frames;
    reg suppress_next_switch;
    wire buffer_changed = buffer_index != buffer_prev;
    wire [11:0] boundary = progress * (H_ACTIVE / FADE_FRAMES);
    wire [11:0] diamond_dx = x >= CENTER_X ? x - CENTER_X : CENTER_X - 12'd1 - x;
    wire [11:0] diamond_dy = y >= CENTER_Y ? y - CENTER_Y : CENTER_Y - 12'd1 - y;
    wire [12:0] diamond_distance = {1'b0,diamond_dx} + {1'b0,diamond_dy};
    wire [12:0] diamond_radius = ({8'd0,progress} << 4) + ({8'd0,progress} << 3);
    wire [12:0] edge_distance = diamond_distance - diamond_radius;
    wire [4:0] dissolve_limit = dissolve_threshold(x[1:0],y[1:0]);

    assign busy = state != IDLE;
    assign prev_in_progress = pending_prev && state != IDLE;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            kind_q <= 2'd0;
            buffer_prev <= 2'd0;
            progress <= 5'd0;
            new_frame_pending <= 1'b0;
            pending_prev <= 1'b0;
            active_seen <= 1'b0;
            wait_frames <= 9'd0;
            suppress_next_switch <= 1'b0;
            switch_toggle <= 1'b0;
            prev_toggle <= 1'b0;
        end else begin
            buffer_prev <= buffer_index;
            if (browse_select_pulse && !buffer_changed)
                suppress_next_switch <= 1'b1;
            else if (buffer_changed && suppress_next_switch)
                suppress_next_switch <= 1'b0;
            if (buffer_changed && !browse_mode && !suppress_next_switch &&
                !browse_select_pulse)
                new_frame_pending <= 1'b1;
            if (frame_start)
                active_seen <= 1'b0;
            else if (de)
                active_seen <= 1'b1;
            if (browse_mode) begin
                state <= IDLE;
                new_frame_pending <= 1'b0;
                progress <= 5'd0;
            end else case (state)
                IDLE: begin
                    if ((frame_start || (!de && !active_seen)) && new_frame_pending && active) begin
                        state <= IN;
                        progress <= 5'd1;
                        kind_q <= effect_kind;
                        new_frame_pending <= 1'b0;
                    end else if ((manual_prev_press || manual_press) && active &&
                                 !new_frame_pending && !buffer_changed) begin
                        state <= WAIT_SWITCH;
                        wait_frames <= 9'd0;
                        kind_q <= effect_kind;
                        pending_prev <= manual_prev_press;
                        if (manual_prev_press)
                            prev_toggle <= ~prev_toggle;
                        else
                            switch_toggle <= ~switch_toggle;
                    end
                end
                WAIT_SWITCH: begin
                    if (!active)
                        state <= IDLE;
                    else if ((frame_start || (!de && !active_seen)) && new_frame_pending) begin
                        state <= IN;
                        progress <= 5'd1;
                        new_frame_pending <= 1'b0;
                        pending_prev <= 1'b0;
                    end else if (frame_start) begin
                        if (wait_frames == WAIT_FRAMES - 1) begin
                            state <= IDLE;
                            pending_prev <= 1'b0;
                        end else
                            wait_frames <= wait_frames + 9'd1;
                    end
                end
                IN: begin
                    if (buffer_changed) begin
                        progress <= 5'd0;
                        kind_q <= effect_kind;
                        new_frame_pending <= 1'b0;
                    end else if (frame_start) begin
                        if (progress == ((kind_q == 2'd3) ? DIAMOND_FRAMES : FADE_FRAMES[4:0]))
                            state <= IDLE;
                        else
                            progress <= progress + 5'd1;
                    end
                end
            endcase
        end
    end

    function [7:0] fade_channel;
        input [7:0] color;
        input [4:0] amount;
        reg [12:0] product;
        begin
            product = color * amount;
            fade_channel = product >> SHIFT;
        end
    endfunction

    function [4:0] dissolve_threshold;
        input [1:0] px, py;
        reg [3:0] rank;
        begin
            case ({py,px})
                4'h0: rank=4'd0;  4'h1: rank=4'd8;  4'h2: rank=4'd2;  4'h3: rank=4'd10;
                4'h4: rank=4'd12; 4'h5: rank=4'd4;  4'h6: rank=4'd14; 4'h7: rank=4'd6;
                4'h8: rank=4'd3;  4'h9: rank=4'd11; 4'ha: rank=4'd1;  4'hb: rank=4'd9;
                4'hc: rank=4'd15; 4'hd: rank=4'd7;  4'he: rank=4'd13; 4'hf: rank=4'd5;
            endcase
            dissolve_threshold = {rank,1'b1};
        end
    endfunction

    always @* begin
        rgb_out = rgb_in;
        if (browse_mode)
            rgb_out = rgb_in;
        else if (state == IN && kind_q == 2'd0)
            rgb_out = {
                fade_channel(rgb_in[23:16], progress),
                fade_channel(rgb_in[15:8], progress),
                fade_channel(rgb_in[7:0], progress)
            };
        else if (state == IN && kind_q == 2'd1 && x >= boundary)
            rgb_out = 24'd0;
        else if (state == IN && kind_q == 2'd2 && x < H_ACTIVE - boundary)
            rgb_out = 24'd0;
        else if (state == IN && kind_q == 2'd3 && diamond_distance > diamond_radius &&
                 (edge_distance > 13'd31 || edge_distance > {8'd0,dissolve_limit}))
            rgb_out = 24'd0;
    end
endmodule

module playlist_transition_preview (
    input  wire clk,
    input  wire rst,
    input  wire playlist_active,
    input  wire [1:0] playlist_kind,
    input  wire [1:0] manual_kind,
    input  wire manual_select,
    input  wire restore_select,
    input  wire transition_busy,
    output wire [1:0] effective_kind
);
    reg manual_override;
    assign effective_kind = playlist_active && !manual_override ? playlist_kind : manual_kind;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            manual_override <= 1'b0;
        end else begin
            if (manual_select || restore_select)
                manual_override <= 1'b1;
        end
    end
endmodule

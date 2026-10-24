`timescale 1ns/1ps

module thumbnail_stream_unpack (
    input  wire        clk,
    input  wire        rst,
    input  wire        preview_mode,
    input  wire        base_read_en,
    input  wire        x_parity,
    input  wire [31:0] read_word,
    output wire        read_en,
    output wire [23:0] rgb
);
    reg [19:0] x_parity_pipe;
    wire [15:0] pixel565 = x_parity_pipe[19] ? read_word[15:0] : read_word[31:16];
    always @(posedge clk or posedge rst) begin
        if (rst)
            x_parity_pipe <= 20'd0;
        else
            x_parity_pipe <= {x_parity_pipe[18:0], x_parity};
    end
    assign read_en = base_read_en && (!preview_mode || !x_parity_pipe[18]);
    assign rgb = preview_mode ?
        {pixel565[15:11],pixel565[15:13],pixel565[10:5],pixel565[10:9],
         pixel565[4:0],pixel565[4:2]} : read_word[31:8];
endmodule

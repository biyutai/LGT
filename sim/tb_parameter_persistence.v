`timescale 1ns/1ps

module tb_parameter_persistence;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg [2:0] current_brightness = 2, current_contrast = 2;
    reg [1:0] current_transition = 0;
    reg [2:0] current_volume = 4;
    wire [2:0] loaded_brightness, loaded_contrast;
    wire [1:0] loaded_transition;
    wire [2:0] loaded_volume;
    wire apply_pulse, ready, flash_load_start, flash_save_start, flash_error;
    reg flash_load_done = 0, flash_config_valid = 0;
    reg [31:0] flash_period = 0;
    reg [7:0] flash_volume = 0, flash_mode = 0;
    reg flash_save_done = 0;
    reg flash_operation_error = 0, save_enable = 1;
    wire [31:0] flash_save_period;
    wire [7:0] flash_save_volume, flash_save_mode;

    parameter_persistence #(.CLK_FREQ_HZ(1000), .SAVE_DELAY_CYCLES(4)) dut (
        .clk(clk), .rst(rst),
        .current_brightness(current_brightness),
        .current_contrast(current_contrast), .current_transition(current_transition),
        .current_volume(current_volume), .loaded_volume(loaded_volume),
        .loaded_brightness(loaded_brightness), .loaded_contrast(loaded_contrast),
        .loaded_transition(loaded_transition), .apply_pulse(apply_pulse),
        .ready(ready), .flash_load_start(flash_load_start),
        .flash_load_done(flash_load_done), .flash_config_valid(flash_config_valid),
        .flash_period(flash_period), .flash_volume(flash_volume),
        .flash_mode(flash_mode), .flash_save_start(flash_save_start),
        .flash_save_period(flash_save_period), .flash_save_volume(flash_save_volume),
        .flash_save_mode(flash_save_mode), .flash_save_done(flash_save_done),
        .flash_operation_error(flash_operation_error), .save_enable(save_enable),
        .flash_error(flash_error)
    );

    task tick;
        begin @(negedge clk); #1; end
    endtask
    task pulse_load_done;
        begin flash_load_done=1; tick(); flash_load_done=0; end
    endtask
    task pulse_save_done;
        begin flash_save_done=1; tick(); flash_save_done=0; end
    endtask

    initial begin
        repeat(2) tick(); rst=0; tick();
        if (!flash_load_start) $fatal(1,"manager must request a startup load");
        pulse_load_done();
        if (!ready || loaded_brightness != 2 || loaded_contrast != 2 ||
            loaded_transition != 0 || loaded_volume != 4 || !apply_pulse)
            $fatal(1,"blank flash must apply defaults");

        rst=1; tick(); rst=0;
        flash_config_valid=1; flash_volume=8'ha5;
        flash_period={26'd0,3'd4,3'd1}; flash_mode=8'd3;
        repeat(2) tick(); pulse_load_done();
        if (!ready || loaded_brightness != 4 || loaded_contrast != 1 ||
            loaded_transition != 3 || loaded_volume != 4)
            $fatal(1,"valid flash record must restore all parameters");

        rst=1; tick(); rst=0;
        flash_period={22'd0,4'd3,3'd4,3'd1};
        repeat(2) tick(); pulse_load_done();
        if (loaded_volume != 2 || loaded_brightness != 4 || loaded_contrast != 1)
            $fatal(1,"new record must restore volume alongside picture settings");

        rst=1; tick(); rst=0;
        flash_config_valid=1; flash_volume=8'ha5;
        flash_period={26'd0,3'd7,3'd1}; flash_mode=8'd3;
        repeat(2) tick(); pulse_load_done();
        if (loaded_brightness != 2 || loaded_contrast != 2 || loaded_transition != 0)
            $fatal(1,"out-of-range record must use defaults");

        current_brightness=3; current_contrast=4; current_transition=2; current_volume=2;
        repeat(3) tick();
        if (flash_save_start) $fatal(1,"save must wait for quiet delay");
        tick();
        if (!flash_save_start || flash_save_period != {22'd0,4'd3,3'd3,3'd4} ||
            flash_save_volume != 8'ha5 || flash_save_mode != 2)
            $fatal(1,"quiet save payload is wrong");
        pulse_save_done(); repeat(3) tick();
        if (flash_save_start) $fatal(1,"unchanged parameters must not rewrite flash");

        current_brightness=1; repeat(2) tick();
        current_brightness=4; repeat(2) tick();
        if (flash_save_start) $fatal(1,"quiet delay must restart on each edit");
        repeat(2) tick();
        if (!flash_save_start || flash_save_period != {22'd0,4'd3,3'd4,3'd4})
            $fatal(1,"latest stable values must be saved");
        flash_operation_error=1; pulse_save_done(); flash_operation_error=0;
        if (!flash_error) $fatal(1,"failed write must surface an error");
        save_enable=0; repeat(8) tick();
        if (flash_save_start) $fatal(1,"demo mode must not write Flash");
        $display("ALL PASSED: parameter defaults, restore, validation and delayed save");
        $finish;
    end
endmodule

// =============================================================================
// tb_blinky.v - Testbench for LED Blink Module
// =============================================================================

`timescale 1ns / 1ps

module tb_blinky;

    reg        clk;
    reg        rst_btn;
    reg        user_btn;
    wire [1:0] led;

    // Instantiate DUT
    blinky uut (
        .clk      (clk),
        .rst_btn  (rst_btn),
        .user_btn (user_btn),
        .led      (led)
    );

    // 50 MHz clock generation (20 ns period)
    initial clk = 0;
    always #10 clk = ~clk;

    // Test sequence
    initial begin
        $dumpfile("tb_blinky.vcd");
        $dumpvars(0, tb_blinky);

        // Initialize
        rst_btn  = 1;
        user_btn = 0;

        // Hold reset for 100 ns
        #100;
        rst_btn = 0;

        // Let it run for a while to see counter incrementing
        #2000;

        // Test user button
        user_btn = 1;
        #200;
        if (led != 2'b11)
            $display("FAIL: LEDs should be ON when button pressed");
        else
            $display("PASS: Button press turns on both LEDs");

        user_btn = 0;
        #200;

        $display("Blinky test complete.");
        $finish;
    end

endmodule

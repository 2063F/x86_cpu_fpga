// =============================================================================
// tb_soc_top.v - Testbench for soc_top running the LED demo
// =============================================================================
// Runs firmware/led_demo.hex with a shortened delay and checks the LED
// counter, the user button, the reset button and the FAULT indication.
// (The UART monitor is tested by tb_soc_monitor.v.)
//
// Run from the repository root:
//   iverilog -I src -o sim/tb_soc_top.out sim/tb_soc_top.v src/soc_top.v \
//            src/cpu_core.v src/alu.v src/register_file.v src/memory_controller.v \
//            src/uart.v src/debug_reporter.v
//   vvp sim/tb_soc_top.out
// =============================================================================

`timescale 1ns / 1ps

module tb_soc_top;

    localparam TIMEOUT = 20000;                 // clock cycles per LED step

    reg        clk      = 1'b0;
    reg        rst_btn  = 1'b0;
    reg        user_btn = 1'b0;
    wire [1:0] led;

    always #10 clk = ~clk;                      // 50 MHz

    soc_top #(
        .INIT_FILE ("firmware/led_demo.hex"),
        .BLINK_BIT (3)                          // fast FAULT blink for simulation
    ) dut (
        .clk      (clk),
        .rst_btn  (rst_btn),
        .user_btn (user_btn),
        .uart_rx  (1'b1),
        .uart_tx  (),
        .led      (led)
    );

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num   = 0;

    task check;
        input [31:0]     actual;
        input [31:0]     expected;
        input [8*40-1:0] name;
        begin
            test_num = test_num + 1;
            if (actual === expected) begin
                $display("PASS [%0d] %0s", test_num, name);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL [%0d] %0s: expected=%0d, got=%0d",
                         test_num, name, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Wait until the LEDs change; `cycles` is the time it took (0 = timeout)
    integer   cycles;
    reg [1:0] led_before;

    task wait_led_change;
        begin
            led_before = led;
            cycles     = 0;
            while (led === led_before && cycles < TIMEOUT) begin
                @(posedge clk);
                #1 cycles = cycles + 1;
            end
            if (led === led_before)
                cycles = 0;
        end
    endtask

    task press_reset;
        begin
            rst_btn = 1'b1;
            repeat (5) @(posedge clk);
            #1 rst_btn = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("tb_soc_top.vcd");
        $dumpvars(0, tb_soc_top);

        $display("=============================================================");
        $display("  SoC Top Testbench (firmware/led_demo.hex)");
        $display("=============================================================");

        // Shorten the firmware delay (first two words of the ROM):
        // delay_outer = 2, delay_inner = 3
        #1;
        dut.u_rom.mem[12'h000] = 8'd2;
        dut.u_rom.mem[12'h001] = 8'd0;
        dut.u_rom.mem[12'h002] = 8'd3;
        dut.u_rom.mem[12'h003] = 8'd0;

        // =====================================================================
        // Power-on reset, counting up
        // =====================================================================
        $display("\n--- Count up ---");
        repeat (10) @(posedge clk);
        #1;
        check({31'd0, dut.rst_n}, 0, "held in reset after power-on");
        check({30'd0, led}, 0, "LEDs off during reset");

        wait_led_change;
        check({30'd0, led}, 1, "LED 00 -> 01");
        wait_led_change;
        check({30'd0, led}, 2, "LED 01 -> 10");
        $display("  one step = %0d clock cycles (with the shortened delay)", cycles);
        wait_led_change;
        check({30'd0, led}, 3, "LED 10 -> 11");
        wait_led_change;
        check({30'd0, led}, 0, "LED 11 -> 00");

        // =====================================================================
        // User button: counting down
        // =====================================================================
        $display("\n--- Count down (user button held) ---");
        user_btn = 1'b1;
        wait_led_change;                        // step already in progress
        wait_led_change;
        led_before = led;
        wait_led_change;
        check({30'd0, led}, {30'd0, led_before - 2'd1}, "LED counts down (1)");
        led_before = led;
        wait_led_change;
        check({30'd0, led}, {30'd0, led_before - 2'd1}, "LED counts down (2)");
        user_btn = 1'b0;

        // =====================================================================
        // Reset button
        // =====================================================================
        $display("\n--- Reset button ---");
        press_reset;
        repeat (10) @(posedge clk);
        #1;
        check({30'd0, led}, 0, "LEDs off after reset button");
        wait_led_change;
        check({30'd0, led}, 1, "counter restarts: 00 -> 01");
        check({31'd0, dut.cpu_fault}, 0, "no FAULT while running");

        // =====================================================================
        // FAULT indication (unimplemented opcode 0F at the program start)
        // =====================================================================
        $display("\n--- FAULT indication ---");
        dut.u_rom.mem[12'h010] = 8'h0F;
        press_reset;
        cycles = 0;
        while (!dut.cpu_fault && cycles < TIMEOUT) begin
            @(posedge clk);
            #1 cycles = cycles + 1;
        end
        check({31'd0, dut.cpu_fault}, 1, "CPU stops in FAULT");
        check({31'd0, led[1] ^ led[0]}, 1, "LEDs show alternate pattern");
        wait_led_change;
        check({30'd0, led}, {30'd0, ~led_before}, "LEDs blink alternately");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n=============================================================");
        $display("  SoC Top Results: %0d PASSED, %0d FAILED (of %0d)",
                 pass_count, fail_count, test_num);
        $display("=============================================================");

        if (fail_count == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** SOME TESTS FAILED ***");

        $finish;
    end

endmodule

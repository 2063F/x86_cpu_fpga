// =============================================================================
// tb_soc_monitor.v - Testbench for soc_top running the UART monitor
// =============================================================================
// Talks to firmware/monitor.hex through a UART model: checks the monitor
// commands, loads and runs firmware/examples/hello.asm with the command file
// written by tools/upload.py, and checks the HALT / FAULT reports.
//
// Run from the repository root:
//   iverilog -I src -o sim/tb_soc_monitor.out sim/tb_soc_monitor.v src/soc_top.v \
//            src/cpu_core.v src/alu.v src/register_file.v src/memory_controller.v \
//            src/uart.v src/debug_reporter.v
//   vvp sim/tb_soc_monitor.out
//
// Plusargs:
//   +show   print everything the monitor sends
// =============================================================================

`timescale 1ns / 1ps

module tb_soc_monitor;

    // The simulation uses a fast baud rate (64 clock cycles per bit) to keep
    // the run short; tb_uart.v tests the real 115200 baud timing.
    // To run at the real baud rate (slow):
    //   iverilog -P tb_soc_monitor.BAUD=115200 ...
    parameter  BAUD     = 781250;
    localparam CLK_FREQ = 50000000;
    localparam DIV      = CLK_FREQ / BAUD;      // clock cycles per bit
    localparam BIT_NS   = DIV * 20;
    localparam TIMEOUT  = DIV * 6000;           // clock cycles to wait for a prompt
    localparam LOG_SIZE = 16384;

    reg        clk      = 1'b0;
    reg        rst_btn  = 1'b0;
    reg        uart_rx  = 1'b1;                 // testbench -> FPGA
    wire       uart_tx;                         // FPGA -> testbench
    wire [1:0] led;

    always #10 clk = ~clk;                      // 50 MHz

    soc_top #(
        .INIT_FILE ("firmware/monitor.hex"),
        .CLK_FREQ  (CLK_FREQ),
        .BAUD      (BAUD)
    ) dut (
        .clk      (clk),
        .rst_btn  (rst_btn),
        .user_btn (1'b0),
        .uart_rx  (uart_rx),
        .uart_tx  (uart_tx),
        .led      (led)
    );

    // -------------------------------------------------------------------------
    // UART model: receiver (logs everything the FPGA sends)
    // -------------------------------------------------------------------------
    reg [7:0] log [0:LOG_SIZE-1];
    integer   log_len = 0;
    integer   mark    = 0;          // searches start here
    reg       show;
    reg [7:0] rx_byte;
    integer   rb;

    always begin
        @(negedge uart_tx);
        #(BIT_NS * 1.5);
        for (rb = 0; rb < 8; rb = rb + 1) begin
            rx_byte[rb] = uart_tx;
            #(BIT_NS);
        end
        if (log_len < LOG_SIZE) begin
            log[log_len] = rx_byte;
            log_len = log_len + 1;
        end
        if (show)
            $write("%c", rx_byte);
    end

    // -------------------------------------------------------------------------
    // UART model: transmitter
    // -------------------------------------------------------------------------
    integer tb_bit;

    task uart_send;
        input [7:0] data;
        begin
            uart_rx = 1'b0;
            #(BIT_NS);
            for (tb_bit = 0; tb_bit < 8; tb_bit = tb_bit + 1) begin
                uart_rx = data[tb_bit];
                #(BIT_NS);
            end
            uart_rx = 1'b1;
            #(BIT_NS);
        end
    endtask

    // Wait until the monitor prints a new prompt ("> ")
    integer waited, wait_start;
    reg     got_prompt;

    task wait_prompt;
        begin
            waited     = 0;
            wait_start = log_len;
            got_prompt = 1'b0;
            while (!got_prompt && waited < TIMEOUT) begin
                @(posedge clk);
                waited = waited + 1;
                got_prompt = (log_len >= wait_start + 2) &&
                             (log[log_len-2] == ">") && (log[log_len-1] == " ");
            end
            // let the stop bit of the last character finish
            #(BIT_NS * 2);
        end
    endtask

    // Send text (up to 60 characters)
    integer si;

    task send_text;
        input [8*60-1:0] text;
        begin
            for (si = 59; si >= 0; si = si - 1)
                if (text[si*8 +: 8] != 8'h00)
                    uart_send(text[si*8 +: 8]);
        end
    endtask

    // Send a command line followed by CR, then wait for the next prompt.
    // The reply can then be searched with log_has().
    task send_line;
        input [8*60-1:0] line;
        begin
            mark = log_len;
            send_text(line);
            uart_send(8'h0D);
            wait_prompt;
        end
    endtask

    // 1 if the text received since `mark` contains `pattern`
    function log_has;
        input [8*40-1:0] pattern;
        integer len, p, j;
        reg     match;
        begin
            len = 0;
            for (j = 0; j < 40; j = j + 1)
                if (pattern[j*8 +: 8] != 8'h00)
                    len = j + 1;
            log_has = 1'b0;
            for (p = mark; p + len <= log_len; p = p + 1) begin
                match = 1'b1;
                for (j = 0; j < len; j = j + 1)
                    if (log[p + j] !== pattern[(len-1-j)*8 +: 8])
                        match = 1'b0;
                if (match)
                    log_has = 1'b1;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Checks
    // -------------------------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num   = 0;

    task check;
        input [31:0]     actual;
        input [31:0]     expected;
        input [8*44-1:0] name;
        begin
            test_num = test_num + 1;
            if (actual === expected) begin
                $display("PASS [%0d] %0s", test_num, name);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL [%0d] %0s: expected=0x%0h, got=0x%0h",
                         test_num, name, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task press_reset;
        begin
            rst_btn = 1'b1;
            repeat (5) @(posedge clk);
            #1 rst_btn = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    integer fd, ch;

    initial begin
        $dumpfile("tb_soc_monitor.vcd");
        $dumpvars(0, tb_soc_monitor);
        show = $test$plusargs("show");

        $display("=============================================================");
        $display("  SoC Monitor Testbench (firmware/monitor.hex)");
        $display("=============================================================");

        // =====================================================================
        // Start-up
        // =====================================================================
        $display("\n--- Start-up ---");
        wait_prompt;
        check({31'd0, got_prompt}, 1, "monitor prints a prompt");
        check({31'd0, log_has("x86_cpu_fpga monitor")}, 1, "banner");
        check({30'd0, led}, 1, "LED 0 on while the monitor runs");

        // =====================================================================
        // Commands
        // =====================================================================
        $display("\n--- Commands ---");
        send_line("w 0200 de ad BE EF");
        check({31'd0, log_has("?")}, 0, "w: accepted");
        check({dut.u_ram.mem[15'h0200], dut.u_ram.mem[15'h0201],
               dut.u_ram.mem[15'h0202], dut.u_ram.mem[15'h0203]},
              32'hDEAD_BEEF, "w: bytes are in RAM");

        send_line("d 200 4");
        check({31'd0, log_has("0200: DE AD BE EF")}, 1, "d: dump of the written bytes");

        send_line("w 3fe 11 22 33 44");
        send_line("d 3f0 12");
        check({31'd0, log_has("03F0: 00 00 00 00 00 00 00 00")}, 1, "d: first line");
        check({31'd0, log_has("00 00 11 22")}, 1, "d: 16 bytes per line");
        check({31'd0, log_has("0400: 33 44")}, 1, "d: second line");

        send_line("?");
        check({31'd0, log_has("d ADDR [LEN]")}, 1, "?: help text");

        send_line("x 1234");
        check({31'd0, log_has("?")}, 1, "unknown command is rejected");

        send_line("w 0200 zz");
        check({31'd0, log_has("?")}, 1, "bad number is rejected");
        check({24'd0, dut.u_ram.mem[15'h0200]}, 32'hDE, "rejected w leaves RAM unchanged");

        send_line("");
        check({31'd0, log_has("?")}, 0, "empty line gives a new prompt");

        // Backspace: "d 2x<BS>00 1" is the command "d 200 1"
        mark = log_len;
        send_text("d 2x");
        uart_send(8'h08);
        send_text("00 1");
        uart_send(8'h0D);
        wait_prompt;
        check({31'd0, log_has("0200: DE")}, 1, "backspace edits the line");

        check({24'd0, dut.u_rom.mem[12'hFF0]}, 32'hE9, "reset vector is in the ROM");

        // =====================================================================
        // Load and run a program (commands written by tools/upload.py)
        // =====================================================================
        $display("\n--- Program upload (sim/programs/hello_upload.txt) ---");
        fd = $fopen("sim/programs/hello_upload.txt", "r");
        check({31'd0, fd != 0}, 1, "command file opened");
        mark = log_len;
        if (fd != 0) begin
            ch = $fgetc(fd);
            while (ch != -1) begin
                if (ch == 10) begin             // end of line: send CR, wait
                    uart_send(8'h0D);
                    wait_prompt;
                end else if (ch != 13) begin
                    uart_send(ch[7:0]);
                end
                ch = $fgetc(fd);
            end
            $fclose(fd);
        end
        check({dut.u_ram.mem[15'h0100], dut.u_ram.mem[15'h0101]}, 32'hB002,
              "program is in RAM at 0100");
        check({31'd0, log_has("Hello from RAM!")}, 1, "program output");
        check({31'd0, log_has("x86_cpu_fpga monitor")}, 1, "program returns to the monitor");
        check({31'd0, dut.cpu_fault | dut.cpu_halted}, 0, "CPU still running");

        // =====================================================================
        // HALT / FAULT reports
        // =====================================================================
        $display("\n--- Stop reports ---");
        send_line("w 300 0f");                  // unimplemented opcode
        mark = log_len;
        send_text("g 300");                     // no prompt comes back
        uart_send(8'h0D);
        repeat (DIV * 600) @(posedge clk);
        check({31'd0, dut.cpu_fault}, 1, "g 300: CPU stops in FAULT");
        check({31'd0, log_has("*** FAULT IP=0300 OP=0F")}, 1, "FAULT report on the UART");
        check({31'd0, led[1] ^ led[0]}, 1, "FAULT blink pattern on the LEDs");

        press_reset;
        mark = log_len;
        wait_prompt;
        check({31'd0, log_has("x86_cpu_fpga monitor")}, 1, "reset button restarts the monitor");
        check({24'd0, dut.u_ram.mem[15'h0300]}, 32'h0F, "RAM keeps its contents over reset");

        send_line("w 310 90 f4");               // NOP, HLT
        mark = log_len;
        send_text("g 310");
        uart_send(8'h0D);
        repeat (DIV * 600) @(posedge clk);
        check({31'd0, dut.cpu_halted}, 1, "g 310: CPU stops in HALT");
        check({31'd0, log_has("*** HALT  IP=0311 OP=F4")}, 1, "HALT report on the UART");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n=============================================================");
        $display("  SoC Monitor Results: %0d PASSED, %0d FAILED (of %0d)",
                 pass_count, fail_count, test_num);
        $display("=============================================================");

        if (fail_count == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** SOME TESTS FAILED ***");

        $finish;
    end

endmodule

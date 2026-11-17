// =============================================================================
// tb_memory_controller.v - Testbench for Memory Controller
// =============================================================================
// Run from the repository root (the INIT_FILE test loads
// sim/programs/cpu_test.hex).
// =============================================================================

`timescale 1ns / 1ps
`include "x86_defines.vh"

module tb_memory_controller;

    reg         clk, rst_n;
    reg  [19:0] address;
    reg  [31:0] write_data;
    reg  [1:0]  access_size;
    reg         read_en;
    reg         write_en;
    wire [31:0] read_data;
    wire        ready;

    // Second instance: read-only use, initialized from a hex file
    reg  [19:0] rom_address;
    reg         rom_read_en;
    wire [31:0] rom_read_data;
    wire        rom_ready;

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num   = 0;

    reg [31:0] read_value;      // result of the last mem_read / rom_read
    integer    cycles;          // clock cycles taken by the last access

    memory_controller uut (
        .clk         (clk),
        .rst_n       (rst_n),
        .address     (address),
        .write_data  (write_data),
        .access_size (access_size),
        .read_en     (read_en),
        .write_en    (write_en),
        .read_data   (read_data),
        .ready       (ready)
    );

    memory_controller #(.INIT_FILE("sim/programs/cpu_test.hex")) rom (
        .clk         (clk),
        .rst_n       (rst_n),
        .address     (rom_address),
        .write_data  (32'd0),
        .access_size (`SIZE_16),
        .read_en     (rom_read_en),
        .write_en    (1'b0),
        .read_data   (rom_read_data),
        .ready       (rom_ready)
    );

    initial clk = 0;
    always #10 clk = ~clk;

    task check_value;
        input [31:0]  actual;
        input [31:0]  expected;
        input [255:0] test_name;
        begin
            test_num = test_num + 1;
            if (actual !== expected) begin
                $display("FAIL [%0d] %0s: expected=0x%08h, got=0x%08h",
                         test_num, test_name, expected, actual);
                fail_count = fail_count + 1;
            end else begin
                $display("PASS [%0d] %0s", test_num, test_name);
                pass_count = pass_count + 1;
            end
        end
    endtask

    task check_read;
        input [31:0]  expected;
        input [255:0] test_name;
        begin
            check_value(read_value, expected, test_name);
        end
    endtask

    // Hold the request until `ready` is 1, as the CPU does
    task mem_write;
        input [19:0] addr;
        input [31:0] data;
        input [1:0]  size;
        begin
            address     = addr;
            write_data  = data;
            access_size = size;
            write_en    = 1;
            read_en     = 0;
            cycles      = 1;
            #1;
            while (!ready) begin
                @(posedge clk);
                #1 cycles = cycles + 1;
            end
            @(posedge clk);
            #1;
            write_en = 0;
        end
    endtask

    task mem_read;
        input [19:0] addr;
        input [1:0]  size;
        begin
            address     = addr;
            access_size = size;
            write_en    = 0;
            read_en     = 1;
            cycles      = 1;
            #1;
            while (!ready) begin
                @(posedge clk);
                #1 cycles = cycles + 1;
            end
            read_value = read_data;
            @(posedge clk);
            #1;
            read_en = 0;
        end
    endtask

    task rom_read;              // 16-bit read from the INIT_FILE instance
        input [19:0] addr;
        begin
            rom_address = addr;
            rom_read_en = 1;
            #1;
            while (!rom_ready) begin
                @(posedge clk);
                #1;
            end
            read_value = rom_read_data;
            @(posedge clk);
            #1;
            rom_read_en = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_memory_controller.vcd");
        $dumpvars(0, tb_memory_controller);

        rst_n = 0; write_en = 0; read_en = 0;
        address = 0; write_data = 0; access_size = `SIZE_8;
        rom_address = 0; rom_read_en = 0;
        @(posedge clk); @(posedge clk);
        #1 rst_n = 1;
        @(posedge clk);
        #1;

        $display("==============================================");
        $display("  Memory Controller Test Suite");
        $display("==============================================");

        // =====================================================================
        // Byte access tests
        // =====================================================================
        $display("\n--- Byte Access Tests ---");

        mem_write(20'h00000, 32'h42, `SIZE_8);
        mem_read(20'h00000, `SIZE_8);
        check_read(32'h0000_0042, "Byte W/R @0");

        mem_write(20'h00001, 32'hAB, `SIZE_8);
        mem_read(20'h00001, `SIZE_8);
        check_read(32'h0000_00AB, "Byte W/R @1");

        mem_write(20'h00002, 32'hCD, `SIZE_8);
        mem_write(20'h00003, 32'hEF, `SIZE_8);

        // Read back all 4 bytes as a dword
        mem_read(20'h00000, `SIZE_32);
        check_read(32'hEFCD_AB42, "Dword read bytes");

        // A byte write must not touch the next byte
        mem_write(20'h00000, 32'hFFFF_FF11, `SIZE_8);
        mem_read(20'h00000, `SIZE_32);
        check_read(32'hEFCD_AB11, "Byte write keeps neighbors");

        // =====================================================================
        // Word access tests
        // =====================================================================
        $display("\n--- Word Access Tests ---");

        mem_write(20'h00100, 32'hBEEF, `SIZE_16);
        mem_read(20'h00100, `SIZE_16);
        check_read(32'h0000_BEEF, "Word W/R @100");

        mem_write(20'h00103, 32'h1234, `SIZE_16);
        mem_read(20'h00103, `SIZE_16);
        check_read(32'h0000_1234, "Word W/R @103 (unaligned)");
        mem_read(20'h00100, `SIZE_32);
        check_read(32'h3400_BEEF, "Unaligned word: low byte");
        mem_read(20'h00104, `SIZE_8);
        check_read(32'h0000_0012, "Unaligned word: high byte");

        // =====================================================================
        // Dword access test
        // =====================================================================
        $display("\n--- Dword Access Tests ---");

        mem_write(20'h00200, 32'hDEAD_BEEF, `SIZE_32);
        mem_read(20'h00200, `SIZE_32);
        check_read(32'hDEAD_BEEF, "Dword W/R @200");

        mem_write(20'h00301, 32'hCAFE_F00D, `SIZE_32);
        mem_read(20'h00301, `SIZE_32);
        check_read(32'hCAFE_F00D, "Dword W/R @301 (unaligned)");
        mem_read(20'h00303, `SIZE_16);
        check_read(32'h0000_CAFE, "Unaligned dword: high word");

        // =====================================================================
        // Different addresses
        // =====================================================================
        $display("\n--- Multi-Address Tests ---");

        mem_write(20'h00400, 32'h1111_1111, `SIZE_32);
        mem_write(20'h00404, 32'h2222_2222, `SIZE_32);
        mem_write(20'h00408, 32'h3333_3333, `SIZE_32);

        mem_read(20'h00400, `SIZE_32);
        check_read(32'h1111_1111, "Dword @400");

        mem_read(20'h00404, `SIZE_32);
        check_read(32'h2222_2222, "Dword @404");

        mem_read(20'h00408, `SIZE_32);
        check_read(32'h3333_3333, "Dword @408");

        // =====================================================================
        // Address mapping
        // =====================================================================
        $display("\n--- Address Mapping Tests ---");

        mem_write(20'hFFFF0, 32'h5AA5, `SIZE_16);
        mem_read(20'h01FF0, `SIZE_16);
        check_read(32'h0000_5AA5, "Boot vector FFFF0 = top of RAM");

        mem_read(20'h02400, `SIZE_32);
        check_read(32'h1111_1111, "Address wraps at 8KB");

        // =====================================================================
        // Access timing (clock cycles from request to ready)
        // =====================================================================
        $display("\n--- Timing Tests ---");

        mem_write(20'h00500, 32'h77, `SIZE_8);
        check_value(cycles, 1, "Byte write: 1 cycle");
        mem_write(20'h00500, 32'h7777, `SIZE_16);
        check_value(cycles, 1, "Word write: 1 cycle");
        mem_write(20'h00500, 32'h7777_7777, `SIZE_32);
        check_value(cycles, 2, "Dword write: 2 cycles");
        mem_read(20'h00500, `SIZE_8);
        check_value(cycles, 2, "Byte read: 2 cycles");
        mem_read(20'h00500, `SIZE_16);
        check_value(cycles, 2, "Word read: 2 cycles");
        mem_read(20'h00500, `SIZE_32);
        check_value(cycles, 3, "Dword read: 3 cycles");

        // Back-to-back reads of different addresses
        mem_read(20'h00400, `SIZE_16);
        check_read(32'h0000_1111, "Back-to-back read 1");
        mem_read(20'h00404, `SIZE_16);
        check_read(32'h0000_2222, "Back-to-back read 2");

        // =====================================================================
        // Initialization from a hex file (cpu_test.hex: JMP FAR at 1FF0)
        // =====================================================================
        $display("\n--- INIT_FILE Tests ---");

        rom_read(20'hFFFF0);
        check_read(32'h0000_00EA, "INIT_FILE: reset vector");
        rom_read(20'h01000);
        check_read(32'h0000_0000, "INIT_FILE: unused area is zero");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n==============================================");
        $display("  Memory Controller Results: %0d PASSED, %0d FAILED (of %0d)",
                 pass_count, fail_count, test_num);
        $display("==============================================");

        if (fail_count > 0)
            $display("*** SOME TESTS FAILED ***");
        else
            $display("*** ALL TESTS PASSED ***");

        $finish;
    end

endmodule

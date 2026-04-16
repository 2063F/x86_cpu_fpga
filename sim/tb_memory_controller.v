// =============================================================================
// tb_memory_controller.v - Testbench for Memory Controller
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

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num   = 0;

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

    initial clk = 0;
    always #10 clk = ~clk;

    task check_read;
        input [31:0]  expected;
        input [127:0] test_name;
        begin
            test_num = test_num + 1;
            #1;
            if (read_data !== expected) begin
                $display("FAIL [%0d] %0s: expected=0x%08h, got=0x%08h",
                         test_num, test_name, expected, read_data);
                fail_count = fail_count + 1;
            end else begin
                $display("PASS [%0d] %0s", test_num, test_name);
                pass_count = pass_count + 1;
            end
        end
    endtask

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
            @(posedge clk); // Wait for write to settle
            #1;
        end
    endtask

    initial begin
        $dumpfile("tb_memory_controller.vcd");
        $dumpvars(0, tb_memory_controller);

        rst_n = 0; write_en = 0; read_en = 0;
        address = 0; write_data = 0; access_size = `SIZE_8;
        @(posedge clk); @(posedge clk);
        rst_n = 1;
        @(posedge clk);

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

        // =====================================================================
        // Word access tests
        // =====================================================================
        $display("\n--- Word Access Tests ---");

        mem_write(20'h00100, 32'hBEEF, `SIZE_16);
        mem_read(20'h00100, `SIZE_16);
        check_read(32'h0000_BEEF, "Word W/R @100");

        // =====================================================================
        // Dword access test
        // =====================================================================
        $display("\n--- Dword Access Tests ---");

        mem_write(20'h00200, 32'hDEAD_BEEF, `SIZE_32);
        mem_read(20'h00200, `SIZE_32);
        check_read(32'hDEAD_BEEF, "Dword W/R @200");

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

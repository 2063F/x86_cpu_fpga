// =============================================================================
// tb_register_file.v - Testbench for x86 Register File
// =============================================================================
// Tests all register access patterns:
// - 32/16/8-bit read and write
// - High byte access (AH/BH/CH/DH)
// - Segment registers
// - EIP and EFLAGS
// - Reset state verification
// =============================================================================

`timescale 1ns / 1ps
`include "x86_defines.vh"

module tb_register_file;

    // =========================================================================
    // DUT Signals
    // =========================================================================
    reg         clk, rst_n;

    // Read Port A
    reg  [2:0]  rd_addr_a;
    reg  [1:0]  rd_size_a;
    reg         rd_high_a;
    wire [31:0] rd_data_a;

    // Read Port B
    reg  [2:0]  rd_addr_b;
    reg  [1:0]  rd_size_b;
    reg         rd_high_b;
    wire [31:0] rd_data_b;

    // Write Port
    reg  [2:0]  wr_addr;
    reg  [31:0] wr_data;
    reg  [1:0]  wr_size;
    reg         wr_high;
    reg         wr_en;

    // EIP
    reg  [31:0] eip_in;
    reg         eip_we;
    wire [31:0] eip_out;

    // EFLAGS
    reg  [31:0] eflags_in;
    reg         eflags_we;
    wire [31:0] eflags_out;

    // Segment registers
    reg  [2:0]  seg_rd_addr;
    wire [15:0] seg_rd_data;
    reg  [2:0]  seg_wr_addr;
    reg  [15:0] seg_wr_data;
    reg         seg_wr_en;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num   = 0;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    register_file uut (
        .clk         (clk),
        .rst_n       (rst_n),
        .rd_addr_a   (rd_addr_a),
        .rd_size_a   (rd_size_a),
        .rd_high_a   (rd_high_a),
        .rd_data_a   (rd_data_a),
        .rd_addr_b   (rd_addr_b),
        .rd_size_b   (rd_size_b),
        .rd_high_b   (rd_high_b),
        .rd_data_b   (rd_data_b),
        .wr_addr     (wr_addr),
        .wr_data     (wr_data),
        .wr_size     (wr_size),
        .wr_high     (wr_high),
        .wr_en       (wr_en),
        .eip_in      (eip_in),
        .eip_we      (eip_we),
        .eip_out     (eip_out),
        .eflags_in   (eflags_in),
        .eflags_we   (eflags_we),
        .eflags_out  (eflags_out),
        .seg_rd_addr (seg_rd_addr),
        .seg_rd_data (seg_rd_data),
        .seg_wr_addr (seg_wr_addr),
        .seg_wr_data (seg_wr_data),
        .seg_wr_en   (seg_wr_en)
    );

    // =========================================================================
    // Clock Generation
    // =========================================================================
    initial clk = 0;
    always #10 clk = ~clk;  // 50 MHz

    // =========================================================================
    // Helper Tasks
    // =========================================================================
    task check_value;
        input [31:0]  actual;
        input [31:0]  expected;
        input [127:0] test_name;
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

    task write_gpr;
        input [2:0]  addr;
        input [31:0] data;
        input [1:0]  size;
        input        high;
        begin
            wr_addr = addr;
            wr_data = data;
            wr_size = size;
            wr_high = high;
            wr_en   = 1;
            @(posedge clk);
            #1;
            wr_en   = 0;
        end
    endtask

    task read_gpr_a;
        input [2:0] addr;
        input [1:0] size;
        input       high;
        begin
            rd_addr_a = addr;
            rd_size_a = size;
            rd_high_a = high;
            #1;
        end
    endtask

    // =========================================================================
    // Test Execution
    // =========================================================================
    initial begin
        $dumpfile("tb_register_file.vcd");
        $dumpvars(0, tb_register_file);

        // Initialize inputs
        rd_addr_a = 0; rd_size_a = `SIZE_32; rd_high_a = 0;
        rd_addr_b = 0; rd_size_b = `SIZE_32; rd_high_b = 0;
        wr_addr = 0; wr_data = 0; wr_size = `SIZE_32; wr_high = 0; wr_en = 0;
        eip_in = 0; eip_we = 0;
        eflags_in = 0; eflags_we = 0;
        seg_rd_addr = 0; seg_wr_addr = 0; seg_wr_data = 0; seg_wr_en = 0;

        $display("==============================================");
        $display("  x86 Register File Test Suite");
        $display("==============================================");

        // =====================================================================
        // Reset test
        // =====================================================================
        $display("\n--- Reset State Verification ---");
        rst_n = 0;
        @(posedge clk); @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        #1;

        // Check EIP reset value
        check_value(eip_out, 32'h0000_FFF0, "EIP reset");

        // Check EFLAGS reset value (bit 1 always set)
        check_value(eflags_out, 32'h0000_0002, "EFLAGS reset");

        // Check CS reset value
        seg_rd_addr = `SEG_CS; #1;
        check_value({16'd0, seg_rd_data}, 32'h0000_F000, "CS reset");

        // Check GPRs are zero
        read_gpr_a(`REG_EAX, `SIZE_32, 0);
        check_value(rd_data_a, 32'h0, "EAX reset=0");

        // =====================================================================
        // 32-bit write/read test
        // =====================================================================
        $display("\n--- 32-bit Write/Read Tests ---");

        write_gpr(`REG_EAX, 32'hDEAD_BEEF, `SIZE_32, 0);
        read_gpr_a(`REG_EAX, `SIZE_32, 0);
        check_value(rd_data_a, 32'hDEAD_BEEF, "EAX=DEADBEEF");

        write_gpr(`REG_EBX, 32'h1234_5678, `SIZE_32, 0);
        read_gpr_a(`REG_EBX, `SIZE_32, 0);
        check_value(rd_data_a, 32'h1234_5678, "EBX=12345678");

        write_gpr(`REG_ESP, 32'h0000_FFFC, `SIZE_32, 0);
        read_gpr_a(`REG_ESP, `SIZE_32, 0);
        check_value(rd_data_a, 32'h0000_FFFC, "ESP=0000FFFC");

        // =====================================================================
        // 16-bit write test (preserves upper 16 bits)
        // =====================================================================
        $display("\n--- 16-bit Write Tests ---");

        // EAX is currently 0xDEAD_BEEF
        write_gpr(`REG_EAX, 32'h0000_CAFE, `SIZE_16, 0);
        read_gpr_a(`REG_EAX, `SIZE_32, 0);
        check_value(rd_data_a, 32'hDEAD_CAFE, "AX=CAFE keeps hi");

        read_gpr_a(`REG_EAX, `SIZE_16, 0);
        check_value(rd_data_a, 32'h0000_CAFE, "AX read=CAFE");

        // =====================================================================
        // 8-bit write tests
        // =====================================================================
        $display("\n--- 8-bit Write Tests ---");

        // Write AL
        write_gpr(`REG_EAX, 32'h0000_0042, `SIZE_8, 0);
        read_gpr_a(`REG_EAX, `SIZE_32, 0);
        check_value(rd_data_a, 32'hDEAD_CA42, "AL=42 keeps rest");

        read_gpr_a(`REG_EAX, `SIZE_8, 0);
        check_value(rd_data_a, 32'h0000_0042, "AL read=42");

        // Write AH
        write_gpr(`REG_EAX, 32'h0000_0099, `SIZE_8, 1);
        read_gpr_a(`REG_EAX, `SIZE_32, 0);
        check_value(rd_data_a, 32'hDEAD_9942, "AH=99 keeps rest");

        read_gpr_a(`REG_EAX, `SIZE_8, 1);
        check_value(rd_data_a, 32'h0000_0099, "AH read=99");

        // =====================================================================
        // Dual-port read test
        // =====================================================================
        $display("\n--- Dual Port Read ---");

        rd_addr_a = `REG_EAX; rd_size_a = `SIZE_32; rd_high_a = 0;
        rd_addr_b = `REG_EBX; rd_size_b = `SIZE_32; rd_high_b = 0;
        #1;
        check_value(rd_data_a, 32'hDEAD_9942, "Port A: EAX");
        check_value(rd_data_b, 32'h1234_5678, "Port B: EBX");

        // =====================================================================
        // EIP test
        // =====================================================================
        $display("\n--- EIP Tests ---");

        eip_in = 32'h0000_1000;
        eip_we = 1;
        @(posedge clk);
        eip_we = 0;
        #1;
        check_value(eip_out, 32'h0000_1000, "EIP=1000");

        // =====================================================================
        // EFLAGS test
        // =====================================================================
        $display("\n--- EFLAGS Tests ---");

        eflags_in = 32'h0000_0246; // ZF=1, PF=1, bit1=1
        eflags_we = 1;
        @(posedge clk);
        eflags_we = 0;
        #1;
        check_value(eflags_out, 32'h0000_0246, "EFLAGS=0246");

        // =====================================================================
        // Segment register test
        // =====================================================================
        $display("\n--- Segment Register Tests ---");

        seg_wr_addr = `SEG_DS;
        seg_wr_data = 16'h1234;
        seg_wr_en   = 1;
        @(posedge clk);
        seg_wr_en = 0;
        seg_rd_addr = `SEG_DS;
        #1;
        check_value({16'd0, seg_rd_data}, 32'h0000_1234, "DS=1234");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n==============================================");
        $display("  Register File Results: %0d PASSED, %0d FAILED (of %0d)",
                 pass_count, fail_count, test_num);
        $display("==============================================");

        if (fail_count > 0)
            $display("*** SOME TESTS FAILED ***");
        else
            $display("*** ALL TESTS PASSED ***");

        $finish;
    end

endmodule

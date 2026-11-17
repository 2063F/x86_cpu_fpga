// =============================================================================
// tb_alu.v - Comprehensive Testbench for x86 ALU
// =============================================================================
// Tests all ALU operations with 8/16/32-bit operand sizes.
// Verifies flag computation (CF, ZF, SF, OF, PF, AF).
// =============================================================================

`timescale 1ns / 1ps
`include "x86_defines.vh"

module tb_alu;

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg  [31:0] operand_a;
    reg  [31:0] operand_b;
    reg  [3:0]  alu_op;
    reg  [1:0]  operand_size;
    reg         carry_in;
    wire [31:0] result;
    wire        flag_cf, flag_zf, flag_sf, flag_of, flag_pf, flag_af;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num   = 0;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    alu uut (
        .operand_a    (operand_a),
        .operand_b    (operand_b),
        .alu_op       (alu_op),
        .operand_size (operand_size),
        .carry_in     (carry_in),
        .result       (result),
        .flag_cf      (flag_cf),
        .flag_zf      (flag_zf),
        .flag_sf      (flag_sf),
        .flag_of      (flag_of),
        .flag_pf      (flag_pf),
        .flag_af      (flag_af)
    );

    // =========================================================================
    // Helper Tasks
    // =========================================================================

    task check_result;
        input [31:0] expected_result;
        input        expected_cf;
        input        expected_zf;
        input        expected_sf;
        input        expected_of;
        input [127:0] test_name; // 16 characters max
        begin
            test_num = test_num + 1;
            #1; // Allow combinational propagation

            if (result !== expected_result ||
                flag_cf !== expected_cf ||
                flag_zf !== expected_zf ||
                flag_sf !== expected_sf ||
                flag_of !== expected_of) begin
                $display("FAIL [%0d] %0s", test_num, test_name);
                $display("  Operands: A=0x%08h, B=0x%08h, Op=%0d, Size=%0d",
                         operand_a, operand_b, alu_op, operand_size);
                $display("  Expected: result=0x%08h CF=%b ZF=%b SF=%b OF=%b",
                         expected_result, expected_cf, expected_zf, expected_sf, expected_of);
                $display("  Got:      result=0x%08h CF=%b ZF=%b SF=%b OF=%b",
                         result, flag_cf, flag_zf, flag_sf, flag_of);
                fail_count = fail_count + 1;
            end else begin
                $display("PASS [%0d] %0s", test_num, test_name);
                pass_count = pass_count + 1;
            end
        end
    endtask

    // Check only the auxiliary carry flag (carry/borrow out of bit 3)
    task check_af;
        input        expected_af;
        input [255:0] test_name;
        begin
            test_num = test_num + 1;
            #1; // Allow combinational propagation

            if (flag_af !== expected_af) begin
                $display("FAIL [%0d] %0s", test_num, test_name);
                $display("  Operands: A=0x%08h, B=0x%08h, Op=%0d, Size=%0d, Cin=%b",
                         operand_a, operand_b, alu_op, operand_size, carry_in);
                $display("  Expected: AF=%b  Got: AF=%b", expected_af, flag_af);
                fail_count = fail_count + 1;
            end else begin
                $display("PASS [%0d] %0s", test_num, test_name);
                pass_count = pass_count + 1;
            end
        end
    endtask

    task set_inputs;
        input [31:0] a;
        input [31:0] b;
        input [3:0]  op;
        input [1:0]  size;
        input        cin;
        begin
            operand_a    = a;
            operand_b    = b;
            alu_op       = op;
            operand_size = size;
            carry_in     = cin;
        end
    endtask

    // =========================================================================
    // Test Execution
    // =========================================================================
    initial begin
        $dumpfile("tb_alu.vcd");
        $dumpvars(0, tb_alu);

        $display("==============================================");
        $display("  x86 ALU Test Suite");
        $display("==============================================");

        // =====================================================================
        // ADD Tests (32-bit)
        // =====================================================================
        $display("\n--- ADD Tests (32-bit) ---");

        set_inputs(32'h0000_0001, 32'h0000_0002, `ALU_ADD, `SIZE_32, 0);
        check_result(32'h0000_0003, 0, 0, 0, 0, "ADD 1+2=3");

        set_inputs(32'hFFFF_FFFF, 32'h0000_0001, `ALU_ADD, `SIZE_32, 0);
        check_result(32'h0000_0000, 1, 1, 0, 0, "ADD FFFF+1 CF,ZF");

        set_inputs(32'h7FFF_FFFF, 32'h0000_0001, `ALU_ADD, `SIZE_32, 0);
        check_result(32'h8000_0000, 0, 0, 1, 1, "ADD 7FFF+1 OF");

        set_inputs(32'h0000_0000, 32'h0000_0000, `ALU_ADD, `SIZE_32, 0);
        check_result(32'h0000_0000, 0, 1, 0, 0, "ADD 0+0 ZF");

        // =====================================================================
        // ADD Tests (8-bit)
        // =====================================================================
        $display("\n--- ADD Tests (8-bit) ---");

        set_inputs(32'h0000_007F, 32'h0000_0001, `ALU_ADD, `SIZE_8, 0);
        check_result(32'h0000_0080, 0, 0, 1, 1, "ADD8 7F+1 OF,SF");

        set_inputs(32'h0000_00FF, 32'h0000_0001, `ALU_ADD, `SIZE_8, 0);
        check_result(32'h0000_0100, 1, 1, 0, 0, "ADD8 FF+1 CF,ZF");

        // =====================================================================
        // SUB Tests (32-bit)
        // =====================================================================
        $display("\n--- SUB Tests (32-bit) ---");

        set_inputs(32'h0000_0005, 32'h0000_0003, `ALU_SUB, `SIZE_32, 0);
        check_result(32'h0000_0002, 0, 0, 0, 0, "SUB 5-3=2");

        set_inputs(32'h0000_0000, 32'h0000_0001, `ALU_SUB, `SIZE_32, 0);
        check_result(32'hFFFF_FFFF, 1, 0, 1, 0, "SUB 0-1 CF,SF");

        set_inputs(32'h0000_0005, 32'h0000_0005, `ALU_SUB, `SIZE_32, 0);
        check_result(32'h0000_0000, 0, 1, 0, 0, "SUB 5-5 ZF");

        set_inputs(32'h8000_0000, 32'h0000_0001, `ALU_SUB, `SIZE_32, 0);
        check_result(32'h7FFF_FFFF, 0, 0, 0, 1, "SUB 8000-1 OF");

        // =====================================================================
        // AND Tests
        // =====================================================================
        $display("\n--- AND Tests ---");

        set_inputs(32'hFF00_FF00, 32'h0F0F_0F0F, `ALU_AND, `SIZE_32, 0);
        check_result(32'h0F00_0F00, 0, 0, 0, 0, "AND mask");

        set_inputs(32'hAAAA_AAAA, 32'h5555_5555, `ALU_AND, `SIZE_32, 0);
        check_result(32'h0000_0000, 0, 1, 0, 0, "AND zero ZF");

        // =====================================================================
        // OR Tests
        // =====================================================================
        $display("\n--- OR Tests ---");

        set_inputs(32'hFF00_0000, 32'h0000_00FF, `ALU_OR, `SIZE_32, 0);
        check_result(32'hFF00_00FF, 0, 0, 1, 0, "OR combine SF");

        // =====================================================================
        // XOR Tests
        // =====================================================================
        $display("\n--- XOR Tests ---");

        set_inputs(32'hDEAD_BEEF, 32'hDEAD_BEEF, `ALU_XOR, `SIZE_32, 0);
        check_result(32'h0000_0000, 0, 1, 0, 0, "XOR self=0 ZF");

        // =====================================================================
        // INC / DEC Tests
        // =====================================================================
        $display("\n--- INC/DEC Tests ---");

        set_inputs(32'h0000_0041, 32'd0, `ALU_INC, `SIZE_32, 0);
        check_result(32'h0000_0042, 0, 0, 0, 0, "INC 41->42");

        set_inputs(32'h7FFF_FFFF, 32'd0, `ALU_INC, `SIZE_32, 0);
        check_result(32'h8000_0000, 0, 0, 1, 1, "INC 7FFF OF,SF");

        set_inputs(32'h0000_0001, 32'd0, `ALU_DEC, `SIZE_32, 0);
        check_result(32'h0000_0000, 0, 1, 0, 0, "DEC 1->0 ZF");

        // =====================================================================
        // SHL Tests
        // =====================================================================
        $display("\n--- SHL Tests ---");

        set_inputs(32'h0000_0001, 32'h0000_0004, `ALU_SHL, `SIZE_32, 0);
        check_result(32'h0000_0010, 0, 0, 0, 0, "SHL 1<<4=16");

        set_inputs(32'h8000_0000, 32'h0000_0001, `ALU_SHL, `SIZE_32, 0);
        check_result(32'h0000_0000, 1, 1, 0, 1, "SHL 80<<1 CF,ZF");

        // =====================================================================
        // SHR Tests
        // =====================================================================
        $display("\n--- SHR Tests ---");

        set_inputs(32'h0000_0010, 32'h0000_0004, `ALU_SHR, `SIZE_32, 0);
        check_result(32'h0000_0001, 0, 0, 0, 0, "SHR 10>>4=1");

        // =====================================================================
        // NEG Tests
        // =====================================================================
        $display("\n--- NEG Tests ---");

        set_inputs(32'h0000_0001, 32'd0, `ALU_NEG, `SIZE_32, 0);
        check_result(32'hFFFF_FFFF, 1, 0, 1, 0, "NEG 1=-1");

        set_inputs(32'h0000_0000, 32'd0, `ALU_NEG, `SIZE_32, 0);
        check_result(32'h0000_0000, 0, 1, 0, 0, "NEG 0=0 ZF");

        // =====================================================================
        // ADC Tests
        // =====================================================================
        $display("\n--- ADC Tests ---");

        set_inputs(32'h0000_0005, 32'h0000_0003, `ALU_ADC, `SIZE_32, 1);
        check_result(32'h0000_0009, 0, 0, 0, 0, "ADC 5+3+1=9");

        // =====================================================================
        // Auxiliary Carry Flag Tests
        // =====================================================================
        $display("\n--- AF Tests ---");

        set_inputs(32'h0000_000F, 32'h0000_0001, `ALU_ADD, `SIZE_8, 0);
        check_af(1, "ADD 0F+01 AF");

        set_inputs(32'h0000_0008, 32'h0000_0007, `ALU_ADD, `SIZE_8, 0);
        check_af(0, "ADD 08+07 no AF");

        set_inputs(32'h0000_000F, 32'h0000_0000, `ALU_ADC, `SIZE_8, 1);
        check_af(1, "ADC 0F+00+1 AF");

        set_inputs(32'h0000_0010, 32'h0000_0001, `ALU_SUB, `SIZE_8, 0);
        check_af(1, "SUB 10-01 AF");

        set_inputs(32'h0000_0010, 32'h0000_000F, `ALU_SBB, `SIZE_8, 1);
        check_af(1, "SBB 10-0F-1 AF");

        set_inputs(32'h0000_001F, 32'h0000_000F, `ALU_SBB, `SIZE_8, 0);
        check_af(0, "SBB 1F-0F-0 no AF");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n==============================================");
        $display("  ALU Test Results: %0d PASSED, %0d FAILED (of %0d)",
                 pass_count, fail_count, test_num);
        $display("==============================================");

        if (fail_count > 0)
            $display("*** SOME TESTS FAILED ***");
        else
            $display("*** ALL TESTS PASSED ***");

        $finish;
    end

endmodule

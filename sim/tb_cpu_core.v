// =============================================================================
// tb_cpu_core.v - Testbench for the CPU core (cpu_core + memory_controller)
// =============================================================================
// Test 1: runs the self-checking program sim/programs/cpu_test.hex
//         (source: sim/programs/cpu_test.asm) and checks its results.
// Test 2: checks that an unimplemented opcode stops the core in FAULT.
//
// Run from the repository root:
//   iverilog -I src -o sim/tb_cpu_core.out sim/tb_cpu_core.v src/cpu_core.v \
//            src/alu.v src/register_file.v src/memory_controller.v
//   vvp sim/tb_cpu_core.out
//
// Plusargs:
//   +hex=<file>   program image (default: sim/programs/cpu_test.hex)
//   +trace        print every executed instruction (IP, opcode, registers)
// =============================================================================

`timescale 1ns / 1ps
`include "x86_defines.vh"

module tb_cpu_core;

    localparam MEM_BYTES = 8192;                // memory_controller default (8KB)
    localparam NUM_TESTS = 10;                  // tests in cpu_test.asm
    localparam TIMEOUT   = 200000;              // clock cycles

    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    always #10 clk = ~clk;                      // 50 MHz

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    wire [19:0] mem_addr;
    wire [31:0] mem_wdata, mem_rdata;
    wire [1:0]  mem_size;
    wire        mem_rd, mem_wr, mem_ready;

    wire [15:0] io_addr, io_wdata;
    wire [1:0]  io_size;
    wire        io_rd, io_wr;

    wire        halted, fault, inst_done;
    wire [15:0] dbg_ip;
    wire [7:0]  dbg_opcode;

    // I/O device model: port 0x60 reads 0x1234, everything else 0xFFFF
    wire [15:0] io_rdata = (io_addr == 16'h0060) ? 16'h1234 : 16'hFFFF;

    cpu_core cpu (
        .clk        (clk),
        .rst_n      (rst_n),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_size   (mem_size),
        .mem_rd     (mem_rd),
        .mem_wr     (mem_wr),
        .mem_rdata  (mem_rdata),
        .mem_ready  (mem_ready),
        .io_addr    (io_addr),
        .io_wdata   (io_wdata),
        .io_size    (io_size),
        .io_rd      (io_rd),
        .io_wr      (io_wr),
        .io_rdata   (io_rdata),
        .halted     (halted),
        .fault      (fault),
        .inst_done  (inst_done),
        .dbg_ip     (dbg_ip),
        .dbg_opcode (dbg_opcode)
    );

    memory_controller mem (
        .clk         (clk),
        .rst_n       (rst_n),
        .address     (mem_addr),
        .write_data  (mem_wdata),
        .access_size (mem_size),
        .read_en     (mem_rd),
        .write_en    (mem_wr),
        .read_data   (mem_rdata),
        .ready       (mem_ready)
    );

    // -------------------------------------------------------------------------
    // I/O port monitors
    // -------------------------------------------------------------------------
    reg [7:0]      post_code;                   // last value written to port 0x80
    reg [8*16-1:0] console;                     // characters written to port 0xE9
    integer        inst_count;
    reg            trace_en;

    always @(posedge clk) if (rst_n) begin
        if (io_wr && io_addr == 16'h0080)
            post_code <= io_wdata[7:0];
        if (io_wr && io_addr == 16'h00E9)
            console <= {console[8*15-1:0], io_wdata[7:0]};
        if (inst_done) begin
            inst_count = inst_count + 1;
            if (trace_en)
                $strobe("  %04h: op=%02h | AX=%04h CX=%04h DX=%04h BX=%04h SP=%04h BP=%04h SI=%04h DI=%04h FL=%04h",
                        dbg_ip, dbg_opcode,
                        cpu.u_regs.gpr[0][15:0], cpu.u_regs.gpr[1][15:0],
                        cpu.u_regs.gpr[2][15:0], cpu.u_regs.gpr[3][15:0],
                        cpu.u_regs.gpr[4][15:0], cpu.u_regs.gpr[5][15:0],
                        cpu.u_regs.gpr[6][15:0], cpu.u_regs.gpr[7][15:0],
                        cpu.u_regs.eflags[15:0]);
        end
    end

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
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
                $display("FAIL [%0d] %0s: expected=0x%h, got=0x%h",
                         test_num, name, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    reg [7:0] image [0:MEM_BYTES-1];
    integer   i;

    task poke;                                  // write one byte of RAM
        input [12:0] addr;
        input [7:0]  data;
        begin
            case (addr[1:0])
                2'd0: mem.mem_bank0[addr >> 2] = data;
                2'd1: mem.mem_bank1[addr >> 2] = data;
                2'd2: mem.mem_bank2[addr >> 2] = data;
                2'd3: mem.mem_bank3[addr >> 2] = data;
            endcase
        end
    endtask

    function [7:0] peek;                        // read one byte of RAM
        input [12:0] addr;
        begin
            case (addr[1:0])
                2'd0: peek = mem.mem_bank0[addr >> 2];
                2'd1: peek = mem.mem_bank1[addr >> 2];
                2'd2: peek = mem.mem_bank2[addr >> 2];
                2'd3: peek = mem.mem_bank3[addr >> 2];
            endcase
        end
    endfunction

    function [15:0] peek16;
        input [12:0] addr;
        begin
            peek16 = {peek(addr + 13'd1), peek(addr)};
        end
    endfunction

    task load_image;                            // copy image[] into RAM
        begin
            for (i = 0; i < MEM_BYTES; i = i + 1)
                poke(i[12:0], image[i]);
        end
    endtask

    task clear_image;
        begin
            for (i = 0; i < MEM_BYTES; i = i + 1)
                image[i] = 8'h00;
        end
    endtask

    task run;                                   // reset, run until HLT/FAULT
        integer cycles;
        begin
            rst_n      = 1'b0;
            post_code  = 8'h00;
            console    = {16{8'h00}};
            inst_count = 0;
            repeat (3) @(posedge clk);
            #1 rst_n = 1'b1;
            cycles = 0;
            while (!halted && !fault && cycles < TIMEOUT) begin
                @(posedge clk);
                #1 cycles = cycles + 1;
            end
            $display("  stopped after %0d instructions, %0d clock cycles (IP=%04h)",
                     inst_count, cycles, cpu.u_regs.eip[15:0]);
        end
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    reg [1023:0] hex_file;

    initial begin
        $dumpfile("tb_cpu_core.vcd");
        $dumpvars(0, tb_cpu_core);

        trace_en = $test$plusargs("trace");
        if (!$value$plusargs("hex=%s", hex_file))
            hex_file = "sim/programs/cpu_test.hex";

        $display("=============================================================");
        $display("  CPU Core Testbench");
        $display("=============================================================");

        // =====================================================================
        // Test 1: self-checking program
        // =====================================================================
        $display("\n--- Reset ---");
        #1;
        clear_image;
        $readmemh(hex_file, image);
        load_image;

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        check({16'd0, cpu.u_regs.seg[`SEG_CS]}, 32'h0000_F000, "CS=F000 after reset");
        check(cpu.u_regs.eip, 32'h0000_FFF0, "IP=FFF0 after reset");
        #1 rst_n = 1'b1;
        #1;
        check({12'd0, mem_addr}, 32'h000F_FFF0, "first fetch at FFFF0");

        $display("\n--- Program: cpu_test.asm ---");
        run;
        if (post_code != NUM_TESTS || cpu.u_regs.gpr[`REG_EBX][15:0] == 16'hDEAD)
            $display("  >>> cpu_test.asm stopped in its test %0d", post_code);

        check({31'd0, halted}, 32'd1, "stopped by HLT");
        check({31'd0, fault},  32'd0, "no unimplemented opcode");
        check({24'd0, post_code}, NUM_TESTS, "all program tests reached");
        check(console[31:0], "PASS", "console output is PASS");
        check({16'd0, cpu.u_regs.gpr[`REG_EAX][15:0]}, 32'h0000_600D, "AX=600D");
        check({16'd0, cpu.u_regs.gpr[`REG_ESP][15:0]}, 32'h0000_1000, "SP back at stack top");
        check({16'd0, peek16(13'h0010)}, 32'd5050, "mem: sum 1..100 = 5050");
        check({16'd0, peek16(13'h0012)}, 32'd144, "mem: fib(12) = 144");
        check({16'd0, peek16(13'h0014)}, 32'h0000_BEEF, "mem: write through ES:");
        check({16'd0, peek16(13'h0024)}, 32'd128, "mem: array[7] = 128");

        // =====================================================================
        // Test 2: unimplemented opcode -> FAULT
        // =====================================================================
        $display("\n--- Unimplemented opcode ---");
        clear_image;
        image[13'h1FF0] = 8'hEA;                // JMP FAR 0000:0100
        image[13'h1FF1] = 8'h00;
        image[13'h1FF2] = 8'h01;
        image[13'h1FF3] = 8'h00;
        image[13'h1FF4] = 8'h00;
        image[13'h0100] = 8'h90;                // NOP
        image[13'h0101] = 8'h0F;                // 0F: not implemented
        load_image;
        run;

        check({31'd0, fault},  32'd1, "FAULT on opcode 0F");
        check({31'd0, halted}, 32'd0, "not reported as HLT");
        check({24'd0, dbg_opcode}, 32'h0000_000F, "dbg_opcode=0F");
        check({16'd0, dbg_ip}, 32'h0000_0101, "dbg_ip=0101");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n=============================================================");
        $display("  CPU Core Results: %0d PASSED, %0d FAILED (of %0d)",
                 pass_count, fail_count, test_num);
        $display("=============================================================");

        if (fail_count == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** SOME TESTS FAILED ***");

        $finish;
    end

endmodule

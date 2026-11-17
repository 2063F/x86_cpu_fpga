// =============================================================================
// tb_cpu_cosim.v - CPU trace generator for co-simulation (tools/cosim.py)
// =============================================================================
// Runs a program on cpu_core + memory_controller (1MB) and writes an execution
// trace that tools/cosim.py compares against the Unicorn x86 emulator.
//
// Plusargs:
//   +hex=<file>    Memory image ($readmemh format, byte per entry)   [required]
//   +trace=<file>  Trace output file                                 [required]
//   +stall=<seed>  Insert random memory wait cycles (tests mem_ready handling)
//   +maxcycles=<n> Give up after n clock cycles (default 2,000,000)
//
// Trace lines (all values hex):
//   W <addr> <size> <data>     memory write
//   O <port> <size> <data>     OUT
//   I <port> <size>            IN  (the model returns ~port)
//   R <ip> <ax> <cx> <dx> <bx> <sp> <bp> <si> <di> <flags> <es> <cs> <ss> <ds>
//                              register state after each instruction
//   H / F / T                  stopped by HLT / unimplemented opcode / timeout
// =============================================================================

`timescale 1ns / 1ps
`include "x86_defines.vh"

module tb_cpu_cosim;

    localparam ADDR_BITS = 20;                  // 1MB RAM

    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    always #10 clk = ~clk;                      // 50 MHz

    // -------------------------------------------------------------------------
    // DUT: CPU core + memory controller
    // -------------------------------------------------------------------------
    wire [19:0] mem_addr;
    wire [31:0] mem_wdata, mem_rdata;
    wire [1:0]  mem_size;
    wire        mem_rd, mem_wr, mem_ready, mc_ready;

    wire [15:0] io_addr, io_wdata;
    wire [1:0]  io_size;
    wire        io_rd, io_wr;

    wire        halted, fault, inst_done;
    wire [15:0] dbg_ip;
    wire [7:0]  dbg_opcode;

    // Random wait-cycle injection: while bus_go is 0 the memory sees no
    // request, so an access that is cut short has to start again
    reg         stall_en = 1'b0;
    reg  [31:0] lfsr     = 32'h1;
    wire        bus_go   = !stall_en || lfsr[0];

    always @(posedge clk)
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

    assign mem_ready = mc_ready && bus_go;

    // I/O device model: reading a port returns the inverted port number
    wire [15:0] io_rdata = ~io_addr;

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

    memory_controller #(.ADDR_BITS(ADDR_BITS)) mem (
        .clk         (clk),
        .rst_n       (rst_n),
        .address     (mem_addr),
        .write_data  (mem_wdata),
        .access_size (mem_size),
        .read_en     (mem_rd && bus_go),
        .write_en    (mem_wr && bus_go),
        .read_data   (mem_rdata),
        .ready       (mc_ready)
    );

    // -------------------------------------------------------------------------
    // Program load, reset
    // -------------------------------------------------------------------------
    reg [1023:0]  hex_file, trace_file;
    integer       fd, max_cycles, cycles, stall_seed;

    initial begin
        if (!$value$plusargs("hex=%s", hex_file) ||
            !$value$plusargs("trace=%s", trace_file)) begin
            $display("usage: vvp tb_cpu_cosim.out +hex=<file> +trace=<file>");
            $finish;
        end
        if (!$value$plusargs("maxcycles=%d", max_cycles))
            max_cycles = 2000000;
        if ($value$plusargs("stall=%d", stall_seed)) begin
            stall_en = 1'b1;
            lfsr     = stall_seed | 32'h1;
        end

        #1;     // after memory_controller's own zero-initialization
        $readmemh(hex_file, mem.mem);

        fd = $fopen(trace_file, "w");

        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
    end

    // -------------------------------------------------------------------------
    // Trace
    // -------------------------------------------------------------------------
    initial cycles = 0;

    always @(posedge clk) if (rst_n) begin
        cycles = cycles + 1;

        if (mem_wr && mem_ready)
            $fdisplay(fd, "W %h %0d %h", mem_addr, (mem_size == `SIZE_16) ? 2 : 1,
                      (mem_size == `SIZE_16) ? mem_wdata[15:0] : {8'h00, mem_wdata[7:0]});
        if (io_wr)
            $fdisplay(fd, "O %h %0d %h", io_addr, (io_size == `SIZE_16) ? 2 : 1,
                      (io_size == `SIZE_16) ? io_wdata : {8'h00, io_wdata[7:0]});
        if (io_rd)
            $fdisplay(fd, "I %h %0d", io_addr, (io_size == `SIZE_16) ? 2 : 1);

        // $fstrobe prints the values after this clock edge has been applied
        if (inst_done)
            $fstrobe(fd, "R %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                     cpu.u_regs.eip[15:0],
                     cpu.u_regs.gpr[0][15:0], cpu.u_regs.gpr[1][15:0],
                     cpu.u_regs.gpr[2][15:0], cpu.u_regs.gpr[3][15:0],
                     cpu.u_regs.gpr[4][15:0], cpu.u_regs.gpr[5][15:0],
                     cpu.u_regs.gpr[6][15:0], cpu.u_regs.gpr[7][15:0],
                     cpu.u_regs.eflags[15:0],
                     cpu.u_regs.seg[`SEG_ES], cpu.u_regs.seg[`SEG_CS],
                     cpu.u_regs.seg[`SEG_SS], cpu.u_regs.seg[`SEG_DS]);

        if (halted || fault || cycles >= max_cycles) begin
            if (halted)     $fdisplay(fd, "H");
            else if (fault) $fdisplay(fd, "F %h %h", dbg_ip, dbg_opcode);
            else            $fdisplay(fd, "T");
            $fclose(fd);
            $finish;
        end
    end

endmodule

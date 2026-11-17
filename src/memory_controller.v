// =============================================================================
// memory_controller.v - Memory Controller for x86 CPU
// =============================================================================
// Provides byte/word/dword access to Block SRAM (B-SRAM).
// Initial implementation: 8KB (sufficient for early testing).
// The size is 2^ADDR_BITS bytes; testbenches may override ADDR_BITS.
//
// Memory Map (initial, ADDR_BITS = 13):
//   0x00000 - 0x01FFF : RAM (8KB, backed by B-SRAM)
//   0xFFFF0 - 0xFFFFF : Boot vector area (mapped to top of RAM)
//
// Addresses wrap at the RAM size, so the boot vector (0xFFFF0) lands on the
// last 16 bytes of RAM.
//
// For 8086 real mode: physical address = segment * 16 + offset (20 bits)
//
// Implementation:
//   The RAM is one byte-wide, true dual-port memory with synchronous read
//   (the form a B-SRAM can implement). Port A accesses the byte at the
//   requested address and port B the byte after it, so a 16-bit access at
//   any alignment takes a single RAM access. A 32-bit access takes two.
//
// Handshake:
//   Hold read_en/write_en, address, access_size (and write_data) stable until
//   `ready` is 1 in the same cycle. read_data is valid in that cycle.
//
//     access     cycles (request to ready)
//     read  8/16   2      (synchronous RAM: address, then data)
//     read  32     3
//     write 8/16   1
//     write 32     2
// =============================================================================

`include "x86_defines.vh"

module memory_controller #(
    parameter ADDR_BITS = 13,          // RAM size = 2^ADDR_BITS bytes (13 = 8KB)
    parameter INIT_FILE = ""           // $readmemh file, one byte per line ("" = none)
) (
    input  wire        clk,
    input  wire        rst_n,

    // =====================================================================
    // CPU Interface
    // =====================================================================
    input  wire [19:0] address,       // 20-bit physical address (1MB space)
    input  wire [31:0] write_data,    // Data to write
    input  wire [1:0]  access_size,   // 00=byte, 01=word, 10=dword
    input  wire        read_en,       // Read request
    input  wire        write_en,      // Write request

    output reg  [31:0] read_data,     // Data read from memory (valid when ready)
    output wire        ready          // Operation complete
);

    localparam MEM_SIZE = 1 << ADDR_BITS;

    // =========================================================================
    // Memory Array - 2^ADDR_BITS bytes (default 8KB = 8192 bytes)
    // =========================================================================
    reg [7:0] mem [0:MEM_SIZE-1] /* synthesis syn_ramstyle = "block_ram" */;

    // =========================================================================
    // Access sequencer
    // =========================================================================
    // `step` counts the cycles of the current access. A 32-bit access is done
    // as two 16-bit "beats": bytes 0-1 first, then bytes 2-3.
    reg [1:0] step;

    wire is_dword = (access_size == `SIZE_32);
    wire beat     = is_dword && (step == 2'd1);     // second half of a dword

    assign ready = write_en ? (!is_dword || step == 2'd1) :
                   read_en  ? (is_dword ? (step == 2'd2) : (step == 2'd1)) :
                              1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            step <= 2'd0;
        else if ((read_en || write_en) && !ready)
            step <= step + 2'd1;
        else
            step <= 2'd0;
    end

    // =========================================================================
    // Dual-port RAM: port A = byte at the address, port B = the next byte
    // =========================================================================
    wire [ADDR_BITS-1:0] addr_a = address[ADDR_BITS-1:0] +
                                  {{(ADDR_BITS-2){1'b0}}, beat, 1'b0};
    wire [ADDR_BITS-1:0] addr_b = addr_a + {{(ADDR_BITS-1){1'b0}}, 1'b1};

    wire       we_a = write_en;
    wire       we_b = write_en && (access_size != `SIZE_8);
    wire [7:0] wd_a = beat ? write_data[23:16] : write_data[7:0];
    wire [7:0] wd_b = beat ? write_data[31:24] : write_data[15:8];

    reg [7:0] q_a, q_b;

    always @(posedge clk) begin
        if (we_a)
            mem[addr_a] <= wd_a;
        else
            q_a <= mem[addr_a];
    end

    always @(posedge clk) begin
        if (we_b)
            mem[addr_b] <= wd_b;
        else
            q_b <= mem[addr_b];
    end

    // =========================================================================
    // Read data
    // =========================================================================
    reg [15:0] low_word;        // bytes 0-1 of a dword read

    always @(posedge clk) begin
        if (read_en && step == 2'd1)
            low_word <= {q_b, q_a};
    end

    always @(*) begin
        case (access_size)
            `SIZE_8:  read_data = {24'd0, q_a};
            `SIZE_16: read_data = {16'd0, q_b, q_a};
            `SIZE_32: read_data = {q_b, q_a, low_word};
            default:  read_data = 32'd0;
        endcase
    end

    // =========================================================================
    // Memory Initialization
    // =========================================================================
    // INIT_FILE is loaded for both simulation and synthesis (boot code).
    // In simulation the rest of the memory is cleared to zero first.
    integer i;

    generate
        if (INIT_FILE != "") begin : g_init_file
            initial begin
                // synthesis translate_off
                for (i = 0; i < MEM_SIZE; i = i + 1)
                    mem[i] = 8'h00;
                // synthesis translate_on
                $readmemh(INIT_FILE, mem);
            end
        end else begin : g_init_zero
            // synthesis translate_off
            initial begin
                for (i = 0; i < MEM_SIZE; i = i + 1)
                    mem[i] = 8'h00;
            end
            // synthesis translate_on
        end
    endgenerate

endmodule

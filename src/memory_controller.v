// =============================================================================
// memory_controller.v - Memory Controller for x86 CPU
// =============================================================================
// Provides byte/word/dword access to Block SRAM.
// Initial implementation: 8KB (sufficient for early testing).
// The size is 2^ADDR_BITS bytes; testbenches may override ADDR_BITS.
// Supports unaligned access by splitting into multiple aligned accesses.
//
// Memory Map (initial, ADDR_BITS = 13):
//   0x00000 - 0x01FFF : RAM (8KB, backed by B-SRAM)
//   0xFFFF0 - 0xFFFFF : Boot vector area (mapped to top of RAM)
//
// For 8086 real mode: physical address = segment * 16 + offset (20 bits)
// =============================================================================

`include "x86_defines.vh"

module memory_controller #(
    parameter ADDR_BITS = 13           // RAM size = 2^ADDR_BITS bytes (13 = 8KB)
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

    output reg  [31:0] read_data,     // Data read from memory
    output wire        ready          // Operation complete (always 1 for SRAM)
);

    // =========================================================================
    // Memory Array - 2^ADDR_BITS bytes (default 8KB = 8192 bytes)
    // Implemented as 4 byte-wide banks for individual byte access
    // =========================================================================
    localparam MEM_SIZE = 1 << ADDR_BITS;

    // 4 byte banks for 32-bit word, byte-addressable
    reg [7:0] mem_bank0 [0:MEM_SIZE/4-1];  // Byte 0 (LSB)
    reg [7:0] mem_bank1 [0:MEM_SIZE/4-1];  // Byte 1
    reg [7:0] mem_bank2 [0:MEM_SIZE/4-1];  // Byte 2
    reg [7:0] mem_bank3 [0:MEM_SIZE/4-1];  // Byte 3 (MSB)

    // =========================================================================
    // Address Mapping
    // =========================================================================
    // Map boot vector (0xFFFF0-0xFFFFF) to top of RAM
    // Map normal addresses directly (wrapping to available RAM)
    wire [ADDR_BITS-1:0] mapped_addr;
    wire                 is_boot_vector;

    assign is_boot_vector = (address[19:4] == 16'hFFFF);

    // For boot vector area: map to top of RAM
    // For normal area: direct mapping with wrap
    assign mapped_addr = is_boot_vector ?
                         {{(ADDR_BITS-4){1'b1}}, address[3:0]} :
                         address[ADDR_BITS-1:0];

    // Word-aligned address (for bank indexing)
    wire [ADDR_BITS-3:0] word_addr;
    wire [1:0]           byte_offset;

    assign word_addr   = mapped_addr[ADDR_BITS-1:2];
    assign byte_offset = mapped_addr[1:0];

    // =========================================================================
    // SRAM is single-cycle, always ready
    // =========================================================================
    assign ready = 1'b1;

    // =========================================================================
    // Read Logic (combinational for single-cycle reads)
    // =========================================================================
    wire [31:0] word_data;
    assign word_data = {mem_bank3[word_addr],
                        mem_bank2[word_addr],
                        mem_bank1[word_addr],
                        mem_bank0[word_addr]};

    // Next word for unaligned access
    wire [ADDR_BITS-3:0] next_word_addr;
    assign next_word_addr = word_addr + 1;

    wire [31:0] next_word_data;
    assign next_word_data = {mem_bank3[next_word_addr],
                             mem_bank2[next_word_addr],
                             mem_bank1[next_word_addr],
                             mem_bank0[next_word_addr]};

    // Combine current and next word, then shift to extract data at byte_offset
    wire [63:0] combined_data;
    assign combined_data = {next_word_data, word_data};

    always @(*) begin
        if (read_en) begin
            case (access_size)
                `SIZE_8:  read_data = {24'd0, combined_data[(byte_offset*8) +: 8]};
                `SIZE_16: read_data = {16'd0, combined_data[(byte_offset*8) +: 16]};
                `SIZE_32: read_data = combined_data[(byte_offset*8) +: 32];
                default:  read_data = 32'd0;
            endcase
        end else begin
            read_data = 32'd0;
        end
    end

    // =========================================================================
    // Write Logic
    // =========================================================================
    always @(posedge clk) begin
        if (write_en) begin
            case (access_size)
                `SIZE_8: begin
                    // Single byte write
                    case (byte_offset)
                        2'd0: mem_bank0[word_addr] <= write_data[7:0];
                        2'd1: mem_bank1[word_addr] <= write_data[7:0];
                        2'd2: mem_bank2[word_addr] <= write_data[7:0];
                        2'd3: mem_bank3[word_addr] <= write_data[7:0];
                    endcase
                end
                `SIZE_16: begin
                    // 16-bit write (may cross word boundary)
                    case (byte_offset)
                        2'd0: begin
                            mem_bank0[word_addr] <= write_data[7:0];
                            mem_bank1[word_addr] <= write_data[15:8];
                        end
                        2'd1: begin
                            mem_bank1[word_addr] <= write_data[7:0];
                            mem_bank2[word_addr] <= write_data[15:8];
                        end
                        2'd2: begin
                            mem_bank2[word_addr] <= write_data[7:0];
                            mem_bank3[word_addr] <= write_data[15:8];
                        end
                        2'd3: begin
                            mem_bank3[word_addr]      <= write_data[7:0];
                            mem_bank0[next_word_addr]  <= write_data[15:8];
                        end
                    endcase
                end
                `SIZE_32: begin
                    // 32-bit write (may cross word boundary)
                    case (byte_offset)
                        2'd0: begin
                            mem_bank0[word_addr] <= write_data[7:0];
                            mem_bank1[word_addr] <= write_data[15:8];
                            mem_bank2[word_addr] <= write_data[23:16];
                            mem_bank3[word_addr] <= write_data[31:24];
                        end
                        2'd1: begin
                            mem_bank1[word_addr]      <= write_data[7:0];
                            mem_bank2[word_addr]      <= write_data[15:8];
                            mem_bank3[word_addr]      <= write_data[23:16];
                            mem_bank0[next_word_addr] <= write_data[31:24];
                        end
                        2'd2: begin
                            mem_bank2[word_addr]      <= write_data[7:0];
                            mem_bank3[word_addr]      <= write_data[15:8];
                            mem_bank0[next_word_addr] <= write_data[23:16];
                            mem_bank1[next_word_addr] <= write_data[31:24];
                        end
                        2'd3: begin
                            mem_bank3[word_addr]      <= write_data[7:0];
                            mem_bank0[next_word_addr] <= write_data[15:8];
                            mem_bank1[next_word_addr] <= write_data[23:16];
                            mem_bank2[next_word_addr] <= write_data[31:24];
                        end
                    endcase
                end
                default: ;
            endcase
        end
    end

    // =========================================================================
    // Memory Initialization (for simulation / boot code loading)
    // =========================================================================
    integer i;
    initial begin
        // Initialize memory to zero
        for (i = 0; i < MEM_SIZE/4; i = i + 1) begin
            mem_bank0[i] = 8'h00;
            mem_bank1[i] = 8'h00;
            mem_bank2[i] = 8'h00;
            mem_bank3[i] = 8'h00;
        end
    end

endmodule

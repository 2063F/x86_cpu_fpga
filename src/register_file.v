// =============================================================================
// register_file.v - x86 Register File
// =============================================================================
// Implements the full x86 register set with 8/16/32-bit access support.
//
// General-Purpose Registers (32-bit, accessible as 32/16/8-bit):
//   Index 0: EAX / AX / AL,AH
//   Index 1: ECX / CX / CL,CH
//   Index 2: EDX / DX / DL,DH
//   Index 3: EBX / BX / BL,BH
//   Index 4: ESP / SP
//   Index 5: EBP / BP
//   Index 6: ESI / SI
//   Index 7: EDI / DI
//
// Segment Registers (16-bit):
//   Index 0: ES     Index 3: DS
//   Index 1: CS     Index 4: FS
//   Index 2: SS     Index 5: GS
//
// Special Registers:
//   EIP (Instruction Pointer)
//   EFLAGS (Flags Register)
// =============================================================================

`include "x86_defines.vh"

module register_file (
    input  wire        clk,
    input  wire        rst_n,         // Active-low reset

    // =====================================================================
    // General-Purpose Register Read Port A
    // =====================================================================
    input  wire [2:0]  rd_addr_a,     // Register index (0-7)
    input  wire [1:0]  rd_size_a,     // Access size (8/16/32)
    input  wire        rd_high_a,     // 1=access AH/BH/CH/DH (8-bit only)
    output reg  [31:0] rd_data_a,     // Read data output

    // =====================================================================
    // General-Purpose Register Read Port B
    // =====================================================================
    input  wire [2:0]  rd_addr_b,
    input  wire [1:0]  rd_size_b,
    input  wire        rd_high_b,
    output reg  [31:0] rd_data_b,

    // =====================================================================
    // General-Purpose Register Write Port
    // =====================================================================
    input  wire [2:0]  wr_addr,       // Register index (0-7)
    input  wire [31:0] wr_data,       // Data to write
    input  wire [1:0]  wr_size,       // Access size (8/16/32)
    input  wire        wr_high,       // 1=write to AH/BH/CH/DH (8-bit only)
    input  wire        wr_en,         // Write enable

    // =====================================================================
    // EIP (Instruction Pointer)
    // =====================================================================
    input  wire [31:0] eip_in,
    input  wire        eip_we,
    output wire [31:0] eip_out,

    // =====================================================================
    // EFLAGS
    // =====================================================================
    input  wire [31:0] eflags_in,
    input  wire        eflags_we,
    output wire [31:0] eflags_out,

    // =====================================================================
    // Segment Registers
    // =====================================================================
    input  wire [2:0]  seg_rd_addr,
    output wire [15:0] seg_rd_data,
    input  wire [2:0]  seg_wr_addr,
    input  wire [15:0] seg_wr_data,
    input  wire        seg_wr_en
);

    // =========================================================================
    // Register Storage
    // =========================================================================
    reg [31:0] gpr [0:7];     // General-purpose registers (EAX-EDI)
    reg [15:0] seg [0:5];     // Segment registers (ES, CS, SS, DS, FS, GS)
    reg [31:0] eip;           // Instruction pointer
    reg [31:0] eflags;        // Flags register

    // =========================================================================
    // Reset and Write Logic
    // =========================================================================
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // x86 reset state
            for (i = 0; i < 8; i = i + 1)
                gpr[i] <= 32'h0000_0000;

            // Reset vector: CS=0xF000, EIP=0x0000FFF0
            // Real mode: physical address = CS*16 + IP = 0xFFFF0
            eip    <= 32'h0000_FFF0;
            eflags <= 32'h0000_0002;  // Bit 1 is always set in x86

            seg[`SEG_CS] <= 16'hF000;
            seg[`SEG_DS] <= 16'h0000;
            seg[`SEG_SS] <= 16'h0000;
            seg[`SEG_ES] <= 16'h0000;
            seg[`SEG_FS] <= 16'h0000;
            seg[`SEG_GS] <= 16'h0000;
        end else begin
            // --- GPR Write ---
            if (wr_en) begin
                case (wr_size)
                    `SIZE_8: begin
                        if (wr_high)
                            // Write to AH/CH/DH/BH (bits 15:8)
                            gpr[wr_addr][15:8] <= wr_data[7:0];
                        else
                            // Write to AL/CL/DL/BL (bits 7:0)
                            gpr[wr_addr][7:0] <= wr_data[7:0];
                    end
                    `SIZE_16: begin
                        // Write lower 16 bits, preserve upper 16
                        gpr[wr_addr][15:0] <= wr_data[15:0];
                    end
                    `SIZE_32: begin
                        // Full 32-bit write
                        gpr[wr_addr] <= wr_data;
                    end
                    default: begin
                        gpr[wr_addr] <= wr_data;
                    end
                endcase
            end

            // --- EIP Write ---
            if (eip_we) begin
                eip <= eip_in;
            end

            // --- EFLAGS Write ---
            if (eflags_we) begin
                // Bit 1 is always set, bits 3,5 always clear
                eflags <= (eflags_in | 32'h0000_0002) & ~32'h0000_0028;
            end

            // --- Segment Register Write ---
            if (seg_wr_en) begin
                seg[seg_wr_addr] <= seg_wr_data;
            end
        end
    end

    // =========================================================================
    // Read Port A (combinational)
    // =========================================================================
    always @(*) begin
        case (rd_size_a)
            `SIZE_8: begin
                if (rd_high_a)
                    rd_data_a = {24'd0, gpr[rd_addr_a][15:8]};
                else
                    rd_data_a = {24'd0, gpr[rd_addr_a][7:0]};
            end
            `SIZE_16:
                rd_data_a = {16'd0, gpr[rd_addr_a][15:0]};
            `SIZE_32:
                rd_data_a = gpr[rd_addr_a];
            default:
                rd_data_a = gpr[rd_addr_a];
        endcase
    end

    // =========================================================================
    // Read Port B (combinational)
    // =========================================================================
    always @(*) begin
        case (rd_size_b)
            `SIZE_8: begin
                if (rd_high_b)
                    rd_data_b = {24'd0, gpr[rd_addr_b][15:8]};
                else
                    rd_data_b = {24'd0, gpr[rd_addr_b][7:0]};
            end
            `SIZE_16:
                rd_data_b = {16'd0, gpr[rd_addr_b][15:0]};
            `SIZE_32:
                rd_data_b = gpr[rd_addr_b];
            default:
                rd_data_b = gpr[rd_addr_b];
        endcase
    end

    // =========================================================================
    // Special Register Read Outputs
    // =========================================================================
    assign eip_out    = eip;
    assign eflags_out = eflags;
    assign seg_rd_data = seg[seg_rd_addr];

endmodule

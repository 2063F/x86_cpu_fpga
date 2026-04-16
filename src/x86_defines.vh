// =============================================================================
// x86_defines.vh - Common Definitions for x86 CPU
// =============================================================================
// Shared constants, opcodes, register encodings, and ALU operation codes
// used across all modules in the x86 CPU project.
// =============================================================================

`ifndef X86_DEFINES_VH
`define X86_DEFINES_VH

// =========================================================================
// Operand Sizes
// =========================================================================
`define SIZE_8    2'b00
`define SIZE_16   2'b01
`define SIZE_32   2'b10

// =========================================================================
// ALU Operations
// =========================================================================
`define ALU_ADD   4'h0
`define ALU_SUB   4'h1
`define ALU_AND   4'h2
`define ALU_OR    4'h3
`define ALU_XOR   4'h4
`define ALU_NOT   4'h5
`define ALU_NEG   4'h6
`define ALU_SHL   4'h7
`define ALU_SHR   4'h8
`define ALU_SAR   4'h9
`define ALU_ADC   4'hA
`define ALU_SBB   4'hB
`define ALU_INC   4'hC
`define ALU_DEC   4'hD
`define ALU_ROL   4'hE
`define ALU_ROR   4'hF

// =========================================================================
// General-Purpose Register Encoding (3-bit, matches x86 ModR/M)
// =========================================================================
`define REG_EAX   3'd0
`define REG_ECX   3'd1
`define REG_EDX   3'd2
`define REG_EBX   3'd3
`define REG_ESP   3'd4
`define REG_EBP   3'd5
`define REG_ESI   3'd6
`define REG_EDI   3'd7

// =========================================================================
// Segment Register Encoding
// =========================================================================
`define SEG_ES    3'd0
`define SEG_CS    3'd1
`define SEG_SS    3'd2
`define SEG_DS    3'd3
`define SEG_FS    3'd4
`define SEG_GS    3'd5

// =========================================================================
// EFLAGS Bit Positions
// =========================================================================
`define FLAG_CF   0     // Carry Flag
`define FLAG_PF   2     // Parity Flag
`define FLAG_AF   4     // Auxiliary Carry Flag
`define FLAG_ZF   6     // Zero Flag
`define FLAG_SF   7     // Sign Flag
`define FLAG_TF   8     // Trap Flag
`define FLAG_IF   9     // Interrupt Enable Flag
`define FLAG_DF   10    // Direction Flag
`define FLAG_OF   11    // Overflow Flag

// =========================================================================
// CPU States (for multi-cycle state machine)
// =========================================================================
`define CPU_RESET       4'h0
`define CPU_FETCH       4'h1
`define CPU_DECODE      4'h2
`define CPU_EXECUTE     4'h3
`define CPU_MEMORY      4'h4
`define CPU_WRITEBACK   4'h5
`define CPU_HALT        4'hF

`endif // X86_DEFINES_VH

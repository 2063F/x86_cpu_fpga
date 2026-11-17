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
// CPU States (multi-cycle state machine in cpu_core.v)
// =========================================================================
`define CPU_FETCH       4'h0    // Opcode / prefix byte fetch
`define CPU_MODRM       4'h1    // ModR/M byte fetch
`define CPU_DISP        4'h2    // Displacement fetch (8/16 bit)
`define CPU_IMM         4'h3    // Immediate fetch (8/16 bit)
`define CPU_IMM2        4'h4    // Second immediate (far pointer segment)
`define CPU_EA          4'h5    // Effective address calculation
`define CPU_LOAD        4'h6    // Memory operand read
`define CPU_EXECUTE     4'h7    // Execute / register writeback
`define CPU_STORE       4'h8    // Memory operand write
`define CPU_HALT        4'hE    // Stopped by HLT
`define CPU_FAULT       4'hF    // Stopped by unimplemented opcode

`endif // X86_DEFINES_VH

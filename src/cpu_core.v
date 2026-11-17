// =============================================================================
// cpu_core.v - Minimal x86 CPU Core (8086-compatible subset, 16-bit real mode)
// =============================================================================
// Multi-cycle CPU core built on alu.v and register_file.v.
//
// Instruction flow (states are skipped when an instruction does not need them):
//
//   FETCH -> MODRM -> DISP -> IMM -> EA -> LOAD -> EXECUTE -> STORE
//   (opcode)                         |     |       |          |
//                 effective address -+     |       |          +- memory write
//                          memory operand -+       +- ALU / register writeback
//
// Implemented instructions (Phase 3):
//   Data      : MOV (r/m,r | r,r/m | r,imm | r/m,imm | acc,moffs | sreg), LEA,
//               PUSH r16, POP r16, PUSH r/m16
//   Arithmetic: ADD OR ADC SBB AND SUB XOR CMP (r/m,r | r,r/m | acc,imm | r/m,imm)
//               INC DEC (r16, r/m), NOT NEG (r/m), TEST
//   Control   : JMP (short/near/far/indirect), Jcc, CALL (near/indirect), RET,
//               LOOP LOOPE LOOPNE JCXZ, HLT, NOP
//   Flags     : CLC STC CMC CLI STI CLD STD
//   I/O       : IN / OUT (imm8 and DX forms)
//   Prefixes  : segment override (ES: CS: SS: DS:)
//
// Not implemented yet: interrupts, string instructions, shifts/rotates,
// MUL/DIV, far CALL/RET, flag PUSH/POP. Fetching an unimplemented opcode
// stops the core in the FAULT state (`fault` output) so it is easy to spot.
//
// Notes:
//   - PUSH SP pushes the value of SP *before* the decrement (80286+ behavior).
//   - Memory bus: the request (mem_rd/mem_wr, address, size) is held until
//     mem_ready is 1. mem_rdata must be valid in the cycle mem_ready is 1.
//     memory_controller.v (synchronous B-SRAM) answers a read in the second
//     cycle; slower memories may insert more wait cycles.
// =============================================================================

`include "x86_defines.vh"

module cpu_core (
    input  wire        clk,
    input  wire        rst_n,         // Active-low reset

    // =====================================================================
    // Memory Bus (connects to memory_controller)
    // =====================================================================
    output wire [19:0] mem_addr,      // Physical address (segment*16 + offset)
    output wire [31:0] mem_wdata,
    output wire [1:0]  mem_size,      // `SIZE_8 / `SIZE_16
    output wire        mem_rd,
    output wire        mem_wr,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ready,

    // =====================================================================
    // I/O Port Bus (IN / OUT instructions, single-cycle strobes)
    // =====================================================================
    output wire [15:0] io_addr,
    output wire [15:0] io_wdata,
    output wire [1:0]  io_size,       // `SIZE_8 / `SIZE_16
    output wire        io_rd,         // io_rdata is sampled in the same cycle
    output wire        io_wr,
    input  wire [15:0] io_rdata,

    // =====================================================================
    // Status / Debug
    // =====================================================================
    output wire        halted,        // Stopped by HLT
    output wire        fault,         // Stopped by an unimplemented opcode
    output wire        inst_done,     // High in the last cycle of each instruction
    output wire [15:0] dbg_ip,        // IP of the instruction being executed
    output wire [7:0]  dbg_opcode     // Opcode of the instruction being executed
);

    // =========================================================================
    // Instruction decode helpers (pure functions of the opcode byte)
    // =========================================================================

    // Segment override prefix: 26 (ES) 2E (CS) 36 (SS) 3E (DS)
    function f_seg_prefix;
        input [7:0] op;
        begin
            f_seg_prefix = (op[7:5] == 3'b001) && (op[2:0] == 3'b110);
        end
    endfunction

    // Implemented opcodes
    function f_legal;
        input [7:0] op;
        begin
            casez (op)
                8'b00???0??,                    // ALU  r/m,r | r,r/m
                8'b00???10?,                    // ALU  acc,imm
                8'b010?????,                    // INC/DEC/PUSH/POP r16
                8'b0111????,                    // Jcc rel8
                8'h80, 8'h81, 8'h83,            // ALU  r/m,imm
                8'h84, 8'h85,                   // TEST r/m,r
                8'h88, 8'h89, 8'h8A, 8'h8B,     // MOV  r/m,r | r,r/m
                8'h8C, 8'h8D, 8'h8E,            // MOV sreg, LEA
                8'h90,                          // NOP
                8'b101000??,                    // MOV  acc,moffs | moffs,acc
                8'hA8, 8'hA9,                   // TEST acc,imm
                8'b1011????,                    // MOV  r,imm
                8'hC3,                          // RET
                8'hC6, 8'hC7,                   // MOV  r/m,imm
                8'b111000??,                    // LOOPNE LOOPE LOOP JCXZ
                8'b111001??,                    // IN/OUT imm8
                8'hE8, 8'hE9, 8'hEA, 8'hEB,     // CALL, JMP near/far/short
                8'b111011??,                    // IN/OUT DX
                8'hF4, 8'hF5,                   // HLT, CMC
                8'hF6, 8'hF7,                   // TEST/NOT/NEG r/m
                8'b111110??, 8'hFC, 8'hFD,      // CLC STC CLI STI CLD STD
                8'hFE, 8'hFF:                   // INC/DEC/CALL/JMP/PUSH r/m
                    f_legal = 1'b1;
                default:
                    f_legal = 1'b0;
            endcase
        end
    endfunction

    // Opcode is followed by a ModR/M byte
    function f_has_modrm;
        input [7:0] op;
        begin
            casez (op)
                8'b00???0??,
                8'h80, 8'h81, 8'h83, 8'h84, 8'h85,
                8'h88, 8'h89, 8'h8A, 8'h8B, 8'h8C, 8'h8D, 8'h8E,
                8'hC6, 8'hC7, 8'hF6, 8'hF7, 8'hFE, 8'hFF:
                    f_has_modrm = 1'b1;
                default:
                    f_has_modrm = 1'b0;
            endcase
        end
    endfunction

    // Immediate operand: 0 = none, 1 = 8-bit (sign-extended), 2 = 16-bit
    function [1:0] f_imm;
        input [7:0] op;
        input [2:0] reg_field;  // ModR/M reg field (only used by F6/F7)
        begin
            casez (op)
                8'b00???100: f_imm = 2'd1;
                8'b00???101: f_imm = 2'd2;
                8'b0111????: f_imm = 2'd1;
                8'h80:       f_imm = 2'd1;
                8'h81:       f_imm = 2'd2;
                8'h83:       f_imm = 2'd1;
                8'b101000??: f_imm = 2'd2;     // moffs16
                8'hA8:       f_imm = 2'd1;
                8'hA9:       f_imm = 2'd2;
                8'b10110???: f_imm = 2'd1;
                8'b10111???: f_imm = 2'd2;
                8'hC6:       f_imm = 2'd1;
                8'hC7:       f_imm = 2'd2;
                8'b111000??: f_imm = 2'd1;     // LOOPx / JCXZ rel8
                8'b111001??: f_imm = 2'd1;     // IN/OUT port imm8
                8'hE8, 8'hE9, 8'hEA: f_imm = 2'd2;
                8'hEB:       f_imm = 2'd1;
                8'hF6:       f_imm = (reg_field == 3'd0) ? 2'd1 : 2'd0;  // TEST
                8'hF7:       f_imm = (reg_field == 3'd0) ? 2'd2 : 2'd0;  // TEST
                default:     f_imm = 2'd0;
            endcase
        end
    endfunction

    // Operand width: 1 = 16-bit, 0 = 8-bit
    function f_word;
        input [7:0] op;
        begin
            casez (op)
                8'b010?????: f_word = 1'b1;    // INC/DEC/PUSH/POP r16
                8'h8C, 8'h8E: f_word = 1'b1;   // MOV sreg
                8'b1011????: f_word = op[3];   // MOV r,imm
                8'hE8:       f_word = 1'b1;    // CALL (pushes IP)
                default:     f_word = op[0];
            endcase
        end
    endfunction

    // Instructions that pop a word from the stack: POP r16, RET
    function f_pop_type;
        input [7:0] op;
        begin
            casez (op)
                8'b01011???, 8'hC3: f_pop_type = 1'b1;
                default:            f_pop_type = 1'b0;
            endcase
        end
    endfunction

    // Instructions that read their memory operand
    function f_needs_load;
        input [7:0] op;
        begin
            casez (op)
                8'b00???0??,
                8'h80, 8'h81, 8'h83, 8'h84, 8'h85,
                8'h8A, 8'h8B, 8'h8E,
                8'hA0, 8'hA1,
                8'hF6, 8'hF7, 8'hFE, 8'hFF,
                8'b01011???, 8'hC3:
                    f_needs_load = 1'b1;
                default:
                    f_needs_load = 1'b0;
            endcase
        end
    endfunction

    // ALU operation for the standard x86 "op" field (ADD OR ADC SBB AND SUB XOR CMP)
    function [3:0] f_alu_op;
        input [2:0] op3;
        begin
            case (op3)
                3'd0: f_alu_op = `ALU_ADD;
                3'd1: f_alu_op = `ALU_OR;
                3'd2: f_alu_op = `ALU_ADC;
                3'd3: f_alu_op = `ALU_SBB;
                3'd4: f_alu_op = `ALU_AND;
                3'd5: f_alu_op = `ALU_SUB;
                3'd6: f_alu_op = `ALU_XOR;
                default: f_alu_op = `ALU_SUB;  // CMP
            endcase
        end
    endfunction

    // Condition code evaluation for Jcc (opcode[3:0])
    function f_cond;
        input [3:0]  cc;
        input [15:0] f;
        reg          r;
        begin
            case (cc[3:1])
                3'd0: r = f[`FLAG_OF];                                   // O
                3'd1: r = f[`FLAG_CF];                                   // B / C
                3'd2: r = f[`FLAG_ZF];                                   // E / Z
                3'd3: r = f[`FLAG_CF] | f[`FLAG_ZF];                     // BE
                3'd4: r = f[`FLAG_SF];                                   // S
                3'd5: r = f[`FLAG_PF];                                   // P
                3'd6: r = f[`FLAG_SF] ^ f[`FLAG_OF];                     // L
                default: r = (f[`FLAG_SF] ^ f[`FLAG_OF]) | f[`FLAG_ZF];  // LE
            endcase
            f_cond = r ^ cc[0];
        end
    endfunction

    // =========================================================================
    // Instruction state
    // =========================================================================
    reg [3:0]  state;
    reg [7:0]  opcode;
    reg [7:0]  modrm;
    reg [15:0] disp;          // Displacement (sign-extended)
    reg [15:0] imm;           // Immediate (sign-extended)
    reg        seg_ovr_en;    // Segment override prefix seen
    reg [2:0]  seg_ovr;
    reg [15:0] ea;            // Effective address (offset) of the memory operand
    reg [2:0]  ea_seg;        // Segment register used with `ea`
    reg        rm_is_mem;     // r/m operand is in memory (not a register)
    reg [15:0] tmp;           // Memory operand read in LOAD
    reg [15:0] wdata;         // Data written in STORE
    reg [15:0] inst_ip;       // IP of the current instruction (debug)

    wire [1:0] mod  = modrm[7:6];
    wire [2:0] regf = modrm[5:3];
    wire [2:0] rm   = modrm[2:0];

    wire       w    = f_word(opcode);
    wire [1:0] size = w ? `SIZE_16 : `SIZE_8;

    wire is_moffs = (opcode[7:2] == 6'b101000);
    wire pop_type = f_pop_type(opcode);

    // =========================================================================
    // Register file
    // =========================================================================
    reg  [2:0]  ra_addr, rb_addr;
    reg  [1:0]  ra_size, rb_size;
    reg         ra_high, rb_high;
    wire [31:0] ra_data, rb_data;

    wire [2:0]  rf_wr_addr;
    wire [31:0] rf_wr_data;
    wire [1:0]  rf_wr_size;
    wire        rf_wr_high;
    wire        rf_wr_en;

    wire [31:0] eip_in, eip_out, eflags_in, eflags_out;
    wire        eip_we, eflags_we;

    wire [2:0]  seg_rd_addr, seg_wr_addr;
    wire [15:0] seg_rd_data, seg_wr_data;
    wire        seg_wr_en;

    register_file u_regs (
        .clk         (clk),
        .rst_n       (rst_n),
        .rd_addr_a   (ra_addr),
        .rd_size_a   (ra_size),
        .rd_high_a   (ra_high),
        .rd_data_a   (ra_data),
        .rd_addr_b   (rb_addr),
        .rd_size_b   (rb_size),
        .rd_high_b   (rb_high),
        .rd_data_b   (rb_data),
        .wr_addr     (rf_wr_addr),
        .wr_data     (rf_wr_data),
        .wr_size     (rf_wr_size),
        .wr_high     (rf_wr_high),
        .wr_en       (rf_wr_en),
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

    wire [15:0] ip    = eip_out[15:0];
    wire [15:0] flags = eflags_out[15:0];

    // =========================================================================
    // Instruction byte fetch (CS:IP)
    // =========================================================================
    wire [7:0]  fetch_b = mem_rdata[7:0];
    wire [15:0] fetch_w = mem_rdata[15:0];

    wire       disp16   = (mod == 2'b10) || (mod == 2'b00 && rm == 3'b110);
    wire [1:0] imm_kind = f_imm(opcode, regf);

    reg        fetching;
    reg [1:0]  fetch_size;

    always @(*) begin
        fetching   = 1'b1;
        fetch_size = `SIZE_8;
        case (state)
            `CPU_FETCH, `CPU_MODRM: ;
            `CPU_DISP: fetch_size = disp16 ? `SIZE_16 : `SIZE_8;
            `CPU_IMM:  fetch_size = (imm_kind == 2'd2) ? `SIZE_16 : `SIZE_8;
            `CPU_IMM2: fetch_size = `SIZE_16;
            default:   fetching   = 1'b0;
        endcase
    end

    wire [15:0] ip_next = ip + ((fetch_size == `SIZE_16) ? 16'd2 : 16'd1);

    // =========================================================================
    // Register read port selection
    // =========================================================================
    // EA state : port A = base register, port B = index register
    // otherwise: port A = "reg" operand,  port B = "r/m" operand
    reg [2:0] ea_base_reg;

    always @(*) begin
        case (rm)
            3'd0, 3'd1, 3'd7: ea_base_reg = `REG_EBX;
            3'd2, 3'd3, 3'd6: ea_base_reg = `REG_EBP;
            3'd4:             ea_base_reg = `REG_ESI;
            default:          ea_base_reg = `REG_EDI;
        endcase
    end

    always @(*) begin
        // Defaults: ModR/M reg field on port A, ModR/M r/m field on port B.
        // 8-bit registers 4-7 are AH/CH/DH/BH (high byte of registers 0-3).
        ra_addr = w ? regf : {1'b0, regf[1:0]};
        ra_high = !w && regf[2];
        ra_size = size;
        rb_addr = w ? rm : {1'b0, rm[1:0]};
        rb_high = !w && rm[2];
        rb_size = size;

        if (state == `CPU_EA) begin
            ra_addr = pop_type ? `REG_ESP : ea_base_reg;
            ra_size = `SIZE_16;
            ra_high = 1'b0;
            rb_addr = rm[0] ? `REG_EDI : `REG_ESI;
            rb_size = `SIZE_16;
            rb_high = 1'b0;
        end else begin
            casez (opcode)
                8'b010?????: begin              // INC/DEC/PUSH/POP r16
                    ra_addr = opcode[2:0];
                    ra_size = `SIZE_16;
                    ra_high = 1'b0;
                end
                8'b00???10?,                    // ALU acc,imm
                8'b1010????,                    // MOV moffs / TEST acc,imm
                8'b1110?1??: begin              // IN / OUT
                    ra_addr = `REG_EAX;
                    ra_high = 1'b0;
                end
                8'b111000??: begin              // LOOPx / JCXZ
                    ra_addr = `REG_ECX;
                    ra_size = `SIZE_16;
                    ra_high = 1'b0;
                end
                8'hFE, 8'hFF: begin             // Group 4/5 (SP for CALL/PUSH)
                    ra_addr = `REG_ESP;
                    ra_size = `SIZE_16;
                    ra_high = 1'b0;
                end
                default: ;
            endcase

            casez (opcode)
                8'b01010???, 8'hE8: begin       // PUSH r16, CALL rel16
                    rb_addr = `REG_ESP;
                    rb_size = `SIZE_16;
                    rb_high = 1'b0;
                end
                8'b111011??: begin              // IN/OUT DX
                    rb_addr = `REG_EDX;
                    rb_size = `SIZE_16;
                    rb_high = 1'b0;
                end
                default: ;
            endcase
        end
    end

    wire [15:0] reg_val = ra_data[15:0];
    wire [15:0] rm_val  = rm_is_mem ? tmp : rb_data[15:0];
    wire [15:0] sp_val  = (opcode[7:1] == 7'b1111111) ? ra_data[15:0] : rb_data[15:0];

    // =========================================================================
    // Effective address calculation (16-bit addressing modes)
    // =========================================================================
    //   rm  000: BX+SI  001: BX+DI  010: BP+SI  011: BP+DI
    //       100: SI     101: DI     110: BP (mod=00: disp16)  111: BX
    wire ea_direct = (mod == 2'b00) && (rm == 3'b110);
    wire ea_use_bp = (rm == 3'd2) || (rm == 3'd3) || (rm == 3'd6 && !ea_direct);

    wire [15:0] ea_calc =
        pop_type ? ra_data[15:0] :                       // SS:SP
        is_moffs ? imm :                                 // direct offset
                   (ea_direct ? 16'd0 : ra_data[15:0]) +
                   (rm[2]     ? 16'd0 : rb_data[15:0]) + disp;

    wire [2:0] ea_seg_calc =
        pop_type                ? `SEG_SS :
        seg_ovr_en              ? seg_ovr :
        (!is_moffs && ea_use_bp) ? `SEG_SS : `SEG_DS;

    // =========================================================================
    // ALU
    // =========================================================================
    reg  [3:0]  alu_op;
    reg  [15:0] alu_a, alu_b;
    wire [31:0] alu_result;
    wire        alu_cf, alu_zf, alu_sf, alu_of, alu_pf, alu_af;

    alu u_alu (
        .operand_a    ({16'd0, alu_a}),
        .operand_b    ({16'd0, alu_b}),
        .alu_op       (alu_op),
        .operand_size (size),
        .carry_in     (flags[`FLAG_CF]),
        .result       (alu_result),
        .flag_cf      (alu_cf),
        .flag_zf      (alu_zf),
        .flag_sf      (alu_sf),
        .flag_of      (alu_of),
        .flag_pf      (alu_pf),
        .flag_af      (alu_af)
    );

    wire [15:0] alu_res = alu_result[15:0];

    // FLAGS with the six arithmetic flags replaced by the ALU outputs
    wire [15:0] flags_alu = {flags[15:12], alu_of, flags[10:8],
                             alu_sf, alu_zf, flags[5], alu_af,
                             flags[3], alu_pf, flags[1], alu_cf};

    // =========================================================================
    // Execute stage decode (combinational, valid in the EXECUTE state)
    // =========================================================================
    localparam D_NONE  = 3'd0;   // No register/memory result
    localparam D_RM    = 3'd1;   // ModR/M r/m operand (register or memory)
    localparam D_REG   = 3'd2;   // ModR/M reg operand
    localparam D_ACC   = 3'd3;   // AL / AX
    localparam D_OPREG = 3'd4;   // Register encoded in opcode[2:0]
    localparam D_CX    = 3'd5;   // CX

    reg [2:0]  x_dst;         // Destination of x_val
    reg [15:0] x_val;         // Result value
    reg        x_flags_we;
    reg [15:0] x_flags;
    reg        x_seg_we;      // Write segment register (MOV sreg, r/m)
    reg        x_ip_we;       // Jump taken
    reg [15:0] x_ip;
    reg        x_push;        // Push x_val onto the stack
    reg        x_mem_wr;      // Write x_val to memory at ea (moffs)
    reg        x_halt;
    reg        x_fault;
    reg        x_io_rd, x_io_wr;

    wire [15:0] cx_dec = reg_val - 16'd1;   // LOOPx (port A = CX)

    // ALU operand selection. Kept separate from the execute decode below so
    // that the ALU inputs never depend on the ALU outputs.
    always @(*) begin
        alu_op = `ALU_ADD;
        alu_a  = rm_val;
        alu_b  = reg_val;

        casez (opcode)
            8'b00???0??: begin                  // ALU r/m,r | r,r/m
                alu_op = f_alu_op(opcode[5:3]);
                if (opcode[1]) begin
                    alu_a = reg_val;
                    alu_b = rm_val;
                end
            end
            8'b00???10?: begin                  // ALU acc,imm
                alu_op = f_alu_op(opcode[5:3]);
                alu_a  = reg_val;
                alu_b  = imm;
            end
            8'b0100????: begin                  // INC/DEC r16
                alu_op = opcode[3] ? `ALU_DEC : `ALU_INC;
                alu_a  = reg_val;
            end
            8'h80, 8'h81, 8'h83: begin          // ALU r/m,imm
                alu_op = f_alu_op(regf);
                alu_b  = imm;
            end
            8'h84, 8'h85: alu_op = `ALU_AND;    // TEST r/m,r
            8'hA8, 8'hA9: begin                 // TEST acc,imm
                alu_op = `ALU_AND;
                alu_a  = reg_val;
                alu_b  = imm;
            end
            8'hF6, 8'hF7: begin                 // TEST r/m,imm | NOT | NEG
                alu_b = imm;
                case (regf)
                    3'd2:    alu_op = `ALU_NOT;
                    3'd3:    alu_op = `ALU_NEG;
                    default: alu_op = `ALU_AND;
                endcase
            end
            8'hFE, 8'hFF:                       // INC/DEC r/m
                alu_op = regf[0] ? `ALU_DEC : `ALU_INC;
            default: ;
        endcase
    end

    always @(*) begin
        x_dst      = D_NONE;
        x_val      = alu_res;
        x_flags_we = 1'b0;
        x_flags    = flags_alu;
        x_seg_we   = 1'b0;
        x_ip_we    = 1'b0;
        x_ip       = ip + imm;      // relative jump target
        x_push     = 1'b0;
        x_mem_wr   = 1'b0;
        x_halt     = 1'b0;
        x_fault    = 1'b0;
        x_io_rd    = 1'b0;
        x_io_wr    = 1'b0;

        casez (opcode)
            // -------------------------------------------------------------
            // ADD OR ADC SBB AND SUB XOR CMP   r/m,r  |  r,r/m
            // -------------------------------------------------------------
            8'b00???0??: begin
                x_flags_we = 1'b1;
                if (opcode[5:3] != 3'd7)
                    x_dst = opcode[1] ? D_REG : D_RM;
            end

            // ADD OR ADC SBB AND SUB XOR CMP   AL/AX,imm
            8'b00???10?: begin
                x_flags_we = 1'b1;
                if (opcode[5:3] != 3'd7)
                    x_dst = D_ACC;
            end

            // INC r16 (40-47) / DEC r16 (48-4F)
            8'b0100????: begin
                x_flags_we = 1'b1;
                x_dst      = D_OPREG;
            end

            // PUSH r16
            8'b01010???: begin
                x_push = 1'b1;
                x_val  = reg_val;
            end

            // POP r16 (value already read into tmp, SP already updated)
            8'b01011???: begin
                x_dst = D_OPREG;
                x_val = tmp;
            end

            // Jcc rel8
            8'b0111????: x_ip_we = f_cond(opcode[3:0], flags);

            // ADD OR ADC SBB AND SUB XOR CMP   r/m,imm
            8'h80, 8'h81, 8'h83: begin
                x_flags_we = 1'b1;
                if (regf != 3'd7)
                    x_dst = D_RM;
            end

            // TEST r/m,r
            8'h84, 8'h85: x_flags_we = 1'b1;

            // MOV r/m,r
            8'h88, 8'h89: begin
                x_dst = D_RM;
                x_val = reg_val;
            end

            // MOV r,r/m
            8'h8A, 8'h8B: begin
                x_dst = D_REG;
                x_val = rm_val;
            end

            // MOV r/m16,sreg
            8'h8C: begin
                if (regf > 3'd5)
                    x_fault = 1'b1;
                else begin
                    x_dst = D_RM;
                    x_val = seg_rd_data;
                end
            end

            // LEA r16,m
            8'h8D: begin
                if (!rm_is_mem)
                    x_fault = 1'b1;
                else begin
                    x_dst = D_REG;
                    x_val = ea;
                end
            end

            // MOV sreg,r/m16 (loading CS this way is not allowed)
            8'h8E: begin
                if (regf == `SEG_CS || regf > 3'd5)
                    x_fault = 1'b1;
                else
                    x_seg_we = 1'b1;
            end

            // NOP
            8'h90: ;

            // MOV AL/AX,moffs
            8'hA0, 8'hA1: begin
                x_dst = D_ACC;
                x_val = tmp;
            end

            // MOV moffs,AL/AX
            8'hA2, 8'hA3: begin
                x_mem_wr = 1'b1;
                x_val    = reg_val;
            end

            // TEST AL/AX,imm
            8'hA8, 8'hA9: x_flags_we = 1'b1;

            // MOV r,imm
            8'b1011????: begin
                x_dst = D_OPREG;
                x_val = imm;
            end

            // RET (return address already read into tmp, SP already updated)
            8'hC3: begin
                x_ip_we = 1'b1;
                x_ip    = tmp;
            end

            // MOV r/m,imm
            8'hC6, 8'hC7: begin
                if (regf != 3'd0)
                    x_fault = 1'b1;
                else begin
                    x_dst = D_RM;
                    x_val = imm;
                end
            end

            // LOOPNE (E0) / LOOPE (E1) / LOOP (E2) / JCXZ (E3)
            8'b111000??: begin
                if (opcode[1:0] == 2'd3) begin
                    x_ip_we = (reg_val == 16'd0);
                end else begin
                    x_dst   = D_CX;
                    x_val   = cx_dec;
                    x_ip_we = (cx_dec != 16'd0) &&
                              (opcode[1] || (flags[`FLAG_ZF] == opcode[0]));
                end
            end

            // IN AL/AX,imm8 | IN AL/AX,DX
            8'hE4, 8'hE5, 8'hEC, 8'hED: begin
                x_io_rd = 1'b1;
                x_dst   = D_ACC;
                x_val   = io_rdata;
            end

            // OUT imm8,AL/AX | OUT DX,AL/AX
            8'hE6, 8'hE7, 8'hEE, 8'hEF: x_io_wr = 1'b1;

            // CALL rel16
            8'hE8: begin
                x_push  = 1'b1;
                x_val   = ip;
                x_ip_we = 1'b1;
            end

            // JMP rel16 / JMP rel8
            8'hE9, 8'hEB: x_ip_we = 1'b1;

            // HLT
            8'hF4: x_halt = 1'b1;

            // Flag instructions
            8'hF5: begin x_flags_we = 1'b1; x_flags = flags ^ (16'd1 << `FLAG_CF); end  // CMC
            8'hF8: begin x_flags_we = 1'b1; x_flags = flags & ~(16'd1 << `FLAG_CF); end // CLC
            8'hF9: begin x_flags_we = 1'b1; x_flags = flags |  (16'd1 << `FLAG_CF); end // STC
            8'hFA: begin x_flags_we = 1'b1; x_flags = flags & ~(16'd1 << `FLAG_IF); end // CLI
            8'hFB: begin x_flags_we = 1'b1; x_flags = flags |  (16'd1 << `FLAG_IF); end // STI
            8'hFC: begin x_flags_we = 1'b1; x_flags = flags & ~(16'd1 << `FLAG_DF); end // CLD
            8'hFD: begin x_flags_we = 1'b1; x_flags = flags |  (16'd1 << `FLAG_DF); end // STD

            // Group 3: TEST r/m,imm (/0)  NOT r/m (/2)  NEG r/m (/3)
            8'hF6, 8'hF7: begin
                case (regf)
                    3'd0: x_flags_we = 1'b1;
                    3'd2: x_dst = D_RM;         // NOT does not change flags
                    3'd3: begin
                        x_flags_we = 1'b1;
                        x_dst      = D_RM;
                    end
                    default: x_fault = 1'b1;
                endcase
            end

            // Group 4/5: INC (/0) DEC (/1) CALL (/2) JMP (/4) PUSH (/6) r/m
            8'hFE, 8'hFF: begin
                case (regf)
                    3'd0, 3'd1: begin
                        x_flags_we = 1'b1;
                        x_dst      = D_RM;
                    end
                    3'd2: begin                 // CALL r/m16
                        x_push  = 1'b1;
                        x_val   = ip;
                        x_ip_we = 1'b1;
                        x_ip    = rm_val;
                        x_fault = !w;
                    end
                    3'd4: begin                 // JMP r/m16
                        x_ip_we = 1'b1;
                        x_ip    = rm_val;
                        x_fault = !w;
                    end
                    3'd6: begin                 // PUSH r/m16
                        x_push  = 1'b1;
                        x_val   = rm_val;
                        x_fault = !w;
                    end
                    default: x_fault = 1'b1;
                endcase
            end

            default: x_fault = 1'b1;
        endcase
    end

    // Result goes to memory (STORE state follows) or to a register
    wire x_store  = x_push || x_mem_wr || (x_dst == D_RM && rm_is_mem);
    wire x_reg_we = (x_dst != D_NONE) && !(x_dst == D_RM && rm_is_mem);

    reg [2:0] x_reg_addr;
    reg       x_reg_high;
    reg [1:0] x_reg_size;

    always @(*) begin
        x_reg_size = size;
        case (x_dst)
            D_REG: begin
                x_reg_addr = w ? regf : {1'b0, regf[1:0]};
                x_reg_high = !w && regf[2];
            end
            D_ACC: begin
                x_reg_addr = `REG_EAX;
                x_reg_high = 1'b0;
            end
            D_OPREG: begin
                x_reg_addr = w ? opcode[2:0] : {1'b0, opcode[1:0]};
                x_reg_high = !w && opcode[2];
            end
            D_CX: begin
                x_reg_addr = `REG_ECX;
                x_reg_high = 1'b0;
                x_reg_size = `SIZE_16;
            end
            default: begin                      // D_RM
                x_reg_addr = w ? rm : {1'b0, rm[1:0]};
                x_reg_high = !w && rm[2];
            end
        endcase
    end

    // =========================================================================
    // Register file write ports
    // =========================================================================
    wire exec_ok = (state == `CPU_EXECUTE) && !x_fault;
    wire pop_sp  = (state == `CPU_EA) && pop_type;      // SP += 2
    wire push_sp = exec_ok && x_push;                   // SP -= 2

    wire [15:0] sp_dec = sp_val - 16'd2;
    wire [15:0] sp_inc = ra_data[15:0] + 16'd2;

    assign rf_wr_en   = pop_sp || push_sp || (exec_ok && x_reg_we);
    assign rf_wr_addr = (pop_sp || push_sp) ? `REG_ESP : x_reg_addr;
    assign rf_wr_size = (pop_sp || push_sp) ? `SIZE_16 : x_reg_size;
    assign rf_wr_high = (pop_sp || push_sp) ? 1'b0     : x_reg_high;
    assign rf_wr_data = pop_sp  ? {16'd0, sp_inc} :
                        push_sp ? {16'd0, sp_dec} : {16'd0, x_val};

    assign eflags_we = exec_ok && x_flags_we;
    assign eflags_in = {16'd0, x_flags};

    // IP: advance while fetching, load on taken jumps and far JMP
    wire far_jmp = (state == `CPU_IMM2) && mem_ready;

    assign eip_we = (fetching && mem_ready) || (exec_ok && x_ip_we);
    assign eip_in = far_jmp  ? {16'd0, imm} :
                    fetching ? {16'd0, ip_next} : {16'd0, x_ip};

    assign seg_wr_en   = far_jmp || (exec_ok && x_seg_we);
    assign seg_wr_addr = far_jmp ? `SEG_CS : regf;
    assign seg_wr_data = far_jmp ? fetch_w : rm_val;

    // =========================================================================
    // Memory bus
    // =========================================================================
    assign seg_rd_addr = fetching                 ? `SEG_CS :
                         (state == `CPU_EXECUTE)  ? regf    :   // MOV r/m,sreg
                                                    ea_seg;

    wire [15:0] mem_off = fetching ? ip : ea;

    assign mem_addr  = {seg_rd_data, 4'h0} + {4'h0, mem_off};
    assign mem_rd    = fetching || (state == `CPU_LOAD);
    assign mem_wr    = (state == `CPU_STORE);
    assign mem_size  = fetching ? fetch_size : size;
    assign mem_wdata = {16'd0, wdata};

    // =========================================================================
    // I/O bus
    // =========================================================================
    assign io_addr  = opcode[3] ? rb_data[15:0] : {8'h00, imm[7:0]};
    assign io_wdata = reg_val;
    assign io_size  = size;
    assign io_rd    = exec_ok && x_io_rd;
    assign io_wr    = exec_ok && x_io_wr;

    // =========================================================================
    // Status / debug outputs
    // =========================================================================
    assign halted     = (state == `CPU_HALT);
    assign fault      = (state == `CPU_FAULT);
    assign inst_done  = (exec_ok && !x_store) ||
                        (state == `CPU_STORE && mem_ready) || far_jmp;
    assign dbg_ip     = inst_ip;
    assign dbg_opcode = opcode;

    // =========================================================================
    // Control state machine
    // =========================================================================
    // r/m operand is in memory (ModR/M with mod != 11, or moffs form)
    wire rm_is_mem_next = (f_has_modrm(opcode) && mod != 2'b11) || is_moffs;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= `CPU_FETCH;
            opcode     <= 8'h90;
            modrm      <= 8'hC0;
            disp       <= 16'd0;
            imm        <= 16'd0;
            seg_ovr_en <= 1'b0;
            seg_ovr    <= `SEG_DS;
            ea         <= 16'd0;
            ea_seg     <= `SEG_DS;
            rm_is_mem  <= 1'b0;
            tmp        <= 16'd0;
            wdata      <= 16'd0;
            inst_ip    <= 16'd0;
        end else begin
            case (state)
                // ---------------------------------------------------------
                // Opcode fetch (segment prefixes loop back here)
                // ---------------------------------------------------------
                `CPU_FETCH: if (mem_ready) begin
                    if (!seg_ovr_en)
                        inst_ip <= ip;

                    if (f_seg_prefix(fetch_b)) begin
                        seg_ovr_en <= 1'b1;
                        seg_ovr    <= {1'b0, fetch_b[4:3]};
                    end else begin
                        opcode    <= fetch_b;
                        modrm     <= 8'hC0;
                        disp      <= 16'd0;
                        rm_is_mem <= 1'b0;

                        if (!f_legal(fetch_b))
                            state <= `CPU_FAULT;
                        else if (f_has_modrm(fetch_b))
                            state <= `CPU_MODRM;
                        else if (f_imm(fetch_b, 3'd0) != 2'd0)
                            state <= `CPU_IMM;
                        else if (f_pop_type(fetch_b))
                            state <= `CPU_EA;
                        else
                            state <= `CPU_EXECUTE;
                    end
                end

                // ---------------------------------------------------------
                // ModR/M byte
                // ---------------------------------------------------------
                `CPU_MODRM: if (mem_ready) begin
                    modrm <= fetch_b;

                    if (fetch_b[7:6] == 2'b01 || fetch_b[7:6] == 2'b10 ||
                        (fetch_b[7:6] == 2'b00 && fetch_b[2:0] == 3'b110))
                        state <= `CPU_DISP;
                    else if (f_imm(opcode, fetch_b[5:3]) != 2'd0)
                        state <= `CPU_IMM;
                    else if (fetch_b[7:6] != 2'b11)
                        state <= `CPU_EA;
                    else
                        state <= `CPU_EXECUTE;
                end

                // ---------------------------------------------------------
                // Displacement (8-bit sign-extended or 16-bit)
                // ---------------------------------------------------------
                `CPU_DISP: if (mem_ready) begin
                    disp  <= disp16 ? fetch_w : {{8{fetch_b[7]}}, fetch_b};
                    state <= (imm_kind != 2'd0) ? `CPU_IMM : `CPU_EA;
                end

                // ---------------------------------------------------------
                // Immediate (8-bit sign-extended or 16-bit)
                // ---------------------------------------------------------
                `CPU_IMM: if (mem_ready) begin
                    imm <= (imm_kind == 2'd2) ? fetch_w : {{8{fetch_b[7]}}, fetch_b};

                    if (opcode == 8'hEA)
                        state <= `CPU_IMM2;
                    else if (rm_is_mem_next)
                        state <= `CPU_EA;
                    else
                        state <= `CPU_EXECUTE;
                end

                // ---------------------------------------------------------
                // Far JMP: segment word (CS and IP are loaded here)
                // ---------------------------------------------------------
                `CPU_IMM2: if (mem_ready) begin
                    seg_ovr_en <= 1'b0;
                    state      <= `CPU_FETCH;
                end

                // ---------------------------------------------------------
                // Effective address (POP/RET: address is SS:SP, SP += 2)
                // ---------------------------------------------------------
                `CPU_EA: begin
                    ea        <= ea_calc;
                    ea_seg    <= ea_seg_calc;
                    rm_is_mem <= 1'b1;
                    state     <= f_needs_load(opcode) ? `CPU_LOAD : `CPU_EXECUTE;
                end

                // ---------------------------------------------------------
                // Memory operand read
                // ---------------------------------------------------------
                `CPU_LOAD: if (mem_ready) begin
                    tmp   <= fetch_w;
                    state <= `CPU_EXECUTE;
                end

                // ---------------------------------------------------------
                // Execute (register / flag / IP writes happen in this cycle)
                // ---------------------------------------------------------
                `CPU_EXECUTE: begin
                    if (x_fault) begin
                        state <= `CPU_FAULT;
                    end else if (x_store) begin
                        wdata <= x_val;
                        if (x_push) begin
                            ea     <= sp_dec;
                            ea_seg <= `SEG_SS;
                        end
                        state <= `CPU_STORE;
                    end else begin
                        seg_ovr_en <= 1'b0;
                        state      <= x_halt ? `CPU_HALT : `CPU_FETCH;
                    end
                end

                // ---------------------------------------------------------
                // Memory operand write
                // ---------------------------------------------------------
                `CPU_STORE: if (mem_ready) begin
                    seg_ovr_en <= 1'b0;
                    state      <= `CPU_FETCH;
                end

                // HALT / FAULT: stay until reset
                default: ;
            endcase
        end
    end

endmodule

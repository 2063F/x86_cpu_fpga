// =============================================================================
// alu.v - 32-bit Arithmetic Logic Unit for x86 CPU
// =============================================================================
// Supports 8/16/32-bit operations with full x86 flag computation.
// Implements: ADD, SUB, AND, OR, XOR, NOT, NEG, SHL, SHR, SAR,
//             ADC, SBB, INC, DEC, ROL, ROR
//
// Flag behavior follows Intel x86 specification:
//   CF - Carry/Borrow flag
//   ZF - Zero flag
//   SF - Sign flag
//   OF - Overflow flag
//   PF - Parity flag (even parity of low byte)
//   AF - Auxiliary carry (carry from bit 3)
// =============================================================================

`include "x86_defines.vh"

module alu (
    input  wire [31:0] operand_a,     // First operand
    input  wire [31:0] operand_b,     // Second operand
    input  wire [3:0]  alu_op,        // ALU operation select
    input  wire [1:0]  operand_size,  // 00=8bit, 01=16bit, 10=32bit
    input  wire        carry_in,      // Carry input (for ADC, SBB, RCL, RCR)

    output reg  [31:0] result,        // Operation result
    output wire        flag_cf,       // Carry flag
    output wire        flag_zf,       // Zero flag
    output wire        flag_sf,       // Sign flag
    output wire        flag_of,       // Overflow flag
    output wire        flag_pf,       // Parity flag
    output wire        flag_af        // Auxiliary carry flag
);

    // =========================================================================
    // Internal signals
    // =========================================================================
    reg  [32:0] result_ext;    // Extended result for carry detection
    reg         cf_out;        // Carry flag output
    reg         of_out;        // Overflow flag output
    reg         af_out;        // Auxiliary carry flag output

    wire [31:0] masked_result; // Result masked to operand size
    wire        sign_a;        // Sign bit of operand A
    wire        sign_b;        // Sign bit of operand B
    wire        sign_r;        // Sign bit of result

    // =========================================================================
    // Size-dependent masks and sign bit extraction
    // =========================================================================
    reg [31:0] size_mask;
    reg [4:0]  msb_pos;        // Position of the most significant bit

    always @(*) begin
        case (operand_size)
            `SIZE_8:  begin size_mask = 32'h0000_00FF; msb_pos = 5'd7;  end
            `SIZE_16: begin size_mask = 32'h0000_FFFF; msb_pos = 5'd15; end
            `SIZE_32: begin size_mask = 32'hFFFF_FFFF; msb_pos = 5'd31; end
            default:  begin size_mask = 32'hFFFF_FFFF; msb_pos = 5'd31; end
        endcase
    end

    assign sign_a = operand_a[msb_pos];
    assign sign_b = operand_b[msb_pos];
    assign sign_r = result[msb_pos];

    assign masked_result = result & size_mask;

    // =========================================================================
    // Main ALU operation
    // =========================================================================
    always @(*) begin
        result_ext = 33'd0;
        cf_out     = 1'b0;
        of_out     = 1'b0;
        af_out     = 1'b0;

        case (alu_op)
            // -----------------------------------------------------------------
            // ADD: result = A + B
            // -----------------------------------------------------------------
            `ALU_ADD: begin
                result_ext = {1'b0, operand_a & size_mask} + {1'b0, operand_b & size_mask};
                result     = result_ext[31:0];
                cf_out     = result_ext[msb_pos + 1];
                af_out     = ({1'b0, operand_a[3:0]} + {1'b0, operand_b[3:0]}) > 5'hF;
                // Signed overflow: both operands same sign, result different sign
                of_out     = (sign_a == sign_b) && (sign_r != sign_a);
            end

            // -----------------------------------------------------------------
            // ADC: result = A + B + CF
            // -----------------------------------------------------------------
            `ALU_ADC: begin
                result_ext = {1'b0, operand_a & size_mask} + {1'b0, operand_b & size_mask} + {32'd0, carry_in};
                result     = result_ext[31:0];
                cf_out     = result_ext[msb_pos + 1];
                af_out     = (operand_a[3:0] + operand_b[3:0] + {3'd0, carry_in}) > 5'hF;
                of_out     = (sign_a == sign_b) && (sign_r != sign_a);
            end

            // -----------------------------------------------------------------
            // SUB: result = A - B
            // -----------------------------------------------------------------
            `ALU_SUB: begin
                result_ext = {1'b0, operand_a & size_mask} - {1'b0, operand_b & size_mask};
                result     = result_ext[31:0];
                cf_out     = result_ext[32];  // Borrow
                af_out     = operand_a[3:0] < operand_b[3:0];
                // Signed overflow: operands different sign, result sign != A sign
                of_out     = (sign_a != sign_b) && (sign_r != sign_a);
            end

            // -----------------------------------------------------------------
            // SBB: result = A - B - CF
            // -----------------------------------------------------------------
            `ALU_SBB: begin
                result_ext = {1'b0, operand_a & size_mask} - {1'b0, operand_b & size_mask} - {32'd0, carry_in};
                result     = result_ext[31:0];
                cf_out     = result_ext[32];
                af_out     = {1'b0, operand_a[3:0]} < ({1'b0, operand_b[3:0]} + {4'd0, carry_in});
                of_out     = (sign_a != sign_b) && (sign_r != sign_a);
            end

            // -----------------------------------------------------------------
            // INC: result = A + 1 (CF not affected)
            // -----------------------------------------------------------------
            `ALU_INC: begin
                result = (operand_a & size_mask) + 32'd1;
                cf_out = carry_in;  // CF is preserved for INC
                af_out = (operand_a[3:0] == 4'hF);
                of_out = (operand_a & size_mask) == (size_mask >> 1);
                // OF set when incrementing from max positive (0x7F/0x7FFF/0x7FFFFFFF)
            end

            // -----------------------------------------------------------------
            // DEC: result = A - 1 (CF not affected)
            // -----------------------------------------------------------------
            `ALU_DEC: begin
                result = (operand_a & size_mask) - 32'd1;
                cf_out = carry_in;  // CF is preserved for DEC
                af_out = (operand_a[3:0] == 4'h0);
                of_out = (operand_a & size_mask) == ((size_mask >> 1) + 1);
                // OF set when decrementing from min negative (0x80/0x8000/0x80000000)
            end

            // -----------------------------------------------------------------
            // AND: result = A & B
            // -----------------------------------------------------------------
            `ALU_AND: begin
                result = operand_a & operand_b;
                cf_out = 1'b0;  // CF always cleared
                of_out = 1'b0;  // OF always cleared
                af_out = 1'b0;  // AF undefined (we clear it)
            end

            // -----------------------------------------------------------------
            // OR: result = A | B
            // -----------------------------------------------------------------
            `ALU_OR: begin
                result = operand_a | operand_b;
                cf_out = 1'b0;
                of_out = 1'b0;
                af_out = 1'b0;
            end

            // -----------------------------------------------------------------
            // XOR: result = A ^ B
            // -----------------------------------------------------------------
            `ALU_XOR: begin
                result = operand_a ^ operand_b;
                cf_out = 1'b0;
                of_out = 1'b0;
                af_out = 1'b0;
            end

            // -----------------------------------------------------------------
            // NOT: result = ~A (no flags affected)
            // -----------------------------------------------------------------
            `ALU_NOT: begin
                result = ~operand_a;
                cf_out = carry_in;  // Preserve all flags for NOT
                of_out = 1'b0;
                af_out = 1'b0;
            end

            // -----------------------------------------------------------------
            // NEG: result = 0 - A (two's complement negate)
            // -----------------------------------------------------------------
            `ALU_NEG: begin
                result_ext = 33'd0 - {1'b0, operand_a & size_mask};
                result     = result_ext[31:0];
                cf_out     = (operand_a & size_mask) != 32'd0;
                af_out     = operand_a[3:0] != 4'h0;
                of_out     = (operand_a & size_mask) == ((size_mask >> 1) + 1);
                // OF set only when negating the minimum negative value
            end

            // -----------------------------------------------------------------
            // SHL/SAL: Shift Left (logical and arithmetic are the same)
            // -----------------------------------------------------------------
            `ALU_SHL: begin
                case (operand_size)
                    `SIZE_8:  begin
                        result = {24'd0, operand_a[7:0]} << operand_b[4:0];
                        cf_out = (operand_b[4:0] != 0) ? operand_a[8 - operand_b[4:0]] : carry_in;
                    end
                    `SIZE_16: begin
                        result = {16'd0, operand_a[15:0]} << operand_b[4:0];
                        cf_out = (operand_b[4:0] != 0) ? operand_a[16 - operand_b[4:0]] : carry_in;
                    end
                    default: begin
                        result_ext = {1'b0, operand_a} << operand_b[4:0];
                        result = result_ext[31:0];
                        cf_out = (operand_b[4:0] != 0) ? result_ext[32] : carry_in;
                    end
                endcase
                // OF defined only for 1-bit shifts
                of_out = (operand_b[4:0] == 5'd1) ? (sign_r != cf_out) : 1'b0;
                af_out = 1'b0;  // AF undefined
            end

            // -----------------------------------------------------------------
            // SHR: Shift Right Logical
            // -----------------------------------------------------------------
            `ALU_SHR: begin
                case (operand_size)
                    `SIZE_8: begin
                        cf_out = (operand_b[4:0] != 0) ? operand_a[operand_b[4:0] - 1] : carry_in;
                        result = {24'd0, operand_a[7:0] >> operand_b[4:0]};
                    end
                    `SIZE_16: begin
                        cf_out = (operand_b[4:0] != 0) ? operand_a[operand_b[4:0] - 1] : carry_in;
                        result = {16'd0, operand_a[15:0] >> operand_b[4:0]};
                    end
                    default: begin
                        cf_out = (operand_b[4:0] != 0) ? operand_a[operand_b[4:0] - 1] : carry_in;
                        result = operand_a >> operand_b[4:0];
                    end
                endcase
                // OF: for 1-bit shift, OF = MSB of original operand
                of_out = (operand_b[4:0] == 5'd1) ? sign_a : 1'b0;
                af_out = 1'b0;
            end

            // -----------------------------------------------------------------
            // SAR: Shift Right Arithmetic (sign-extending)
            // -----------------------------------------------------------------
            `ALU_SAR: begin
                case (operand_size)
                    `SIZE_8: begin
                        cf_out = (operand_b[4:0] != 0) ? operand_a[operand_b[4:0] - 1] : carry_in;
                        result = {24'd0, $signed(operand_a[7:0]) >>> operand_b[4:0]};
                        result = {24'd0, result[7:0]};
                    end
                    `SIZE_16: begin
                        cf_out = (operand_b[4:0] != 0) ? operand_a[operand_b[4:0] - 1] : carry_in;
                        result = {16'd0, $signed(operand_a[15:0]) >>> operand_b[4:0]};
                        result = {16'd0, result[15:0]};
                    end
                    default: begin
                        cf_out = (operand_b[4:0] != 0) ? operand_a[operand_b[4:0] - 1] : carry_in;
                        result = $signed(operand_a) >>> operand_b[4:0];
                    end
                endcase
                of_out = 1'b0;  // OF always 0 for SAR with count 1
                af_out = 1'b0;
            end

            // -----------------------------------------------------------------
            // ROL: Rotate Left
            // -----------------------------------------------------------------
            `ALU_ROL: begin
                case (operand_size)
                    `SIZE_8: begin
                        result[7:0] = (operand_a[7:0] << operand_b[2:0]) |
                                      (operand_a[7:0] >> (8 - operand_b[2:0]));
                        result[31:8] = 24'd0;
                        cf_out = result[0];
                    end
                    `SIZE_16: begin
                        result[15:0] = (operand_a[15:0] << operand_b[3:0]) |
                                       (operand_a[15:0] >> (16 - operand_b[3:0]));
                        result[31:16] = 16'd0;
                        cf_out = result[0];
                    end
                    default: begin
                        result = (operand_a << operand_b[4:0]) |
                                 (operand_a >> (32 - operand_b[4:0]));
                        cf_out = result[0];
                    end
                endcase
                of_out = (operand_b[4:0] == 5'd1) ? (sign_r ^ cf_out) : 1'b0;
                af_out = 1'b0;
            end

            // -----------------------------------------------------------------
            // ROR: Rotate Right
            // -----------------------------------------------------------------
            `ALU_ROR: begin
                case (operand_size)
                    `SIZE_8: begin
                        result[7:0] = (operand_a[7:0] >> operand_b[2:0]) |
                                      (operand_a[7:0] << (8 - operand_b[2:0]));
                        result[31:8] = 24'd0;
                        cf_out = result[7];
                    end
                    `SIZE_16: begin
                        result[15:0] = (operand_a[15:0] >> operand_b[3:0]) |
                                       (operand_a[15:0] << (16 - operand_b[3:0]));
                        result[31:16] = 16'd0;
                        cf_out = result[15];
                    end
                    default: begin
                        result = (operand_a >> operand_b[4:0]) |
                                 (operand_a << (32 - operand_b[4:0]));
                        cf_out = result[31];
                    end
                endcase
                of_out = (operand_b[4:0] == 5'd1) ? (result[msb_pos] ^ result[msb_pos-1]) : 1'b0;
                af_out = 1'b0;
            end

            default: begin
                result = operand_a;
                cf_out = carry_in;
                of_out = 1'b0;
                af_out = 1'b0;
            end
        endcase
    end

    // =========================================================================
    // Flag outputs
    // =========================================================================

    // CF: Carry flag (set by individual operations above)
    assign flag_cf = cf_out;

    // ZF: Zero flag — set when masked result is zero
    assign flag_zf = (masked_result == 32'd0);

    // SF: Sign flag — MSB of the result based on operand size
    assign flag_sf = sign_r;

    // OF: Overflow flag (set by individual operations above)
    assign flag_of = of_out;

    // PF: Parity flag — even parity of the low byte
    // PF = 1 when the number of set bits in result[7:0] is even
    assign flag_pf = ~(^result[7:0]);

    // AF: Auxiliary carry flag (set by individual operations above)
    assign flag_af = af_out;

endmodule

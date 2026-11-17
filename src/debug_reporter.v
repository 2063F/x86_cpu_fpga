// =============================================================================
// debug_reporter.v - Reports a stopped CPU on the UART
// =============================================================================
// When the CPU stops (HLT or unimplemented opcode) it can no longer print
// anything itself, so this module sends one line through the UART transmitter:
//
//   *** HALT  IP=1234 OP=F4        (stopped by HLT)
//   *** FAULT IP=1234 OP=0F        (unimplemented opcode)
//
// IP and OP are the address (offset in CS) and the opcode byte of the
// instruction that stopped the CPU. The line is sent once; the module is
// re-armed by reset.
// =============================================================================

module debug_reporter (
    input  wire        clk,
    input  wire        rst_n,

    // CPU status
    input  wire        halted,
    input  wire        fault,
    input  wire [15:0] dbg_ip,
    input  wire [7:0]  dbg_opcode,

    // UART transmitter
    input  wire        tx_busy,
    output reg  [7:0]  tx_data,
    output wire        tx_start
);

    localparam LAST_CHAR = 5'd26;

    localparam S_IDLE = 2'd0;   // CPU running
    localparam S_SEND = 2'd1;   // Wait for the transmitter, then send a character
    localparam S_NEXT = 2'd2;   // Advance to the next character
    localparam S_DONE = 2'd3;   // Line sent

    reg [1:0] state;
    reg [4:0] idx;

    function [7:0] hex_digit;
        input [3:0] n;
        begin
            hex_digit = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
        end
    endfunction

    // "\r\n*** FAULT IP=xxxx OP=xx\r\n"  (HALT is padded to the same length)
    always @(*) begin
        case (idx)
            5'd0:    tx_data = 8'h0D;
            5'd1:    tx_data = 8'h0A;
            5'd2:    tx_data = "*";
            5'd3:    tx_data = "*";
            5'd4:    tx_data = "*";
            5'd5:    tx_data = " ";
            5'd6:    tx_data = fault ? "F" : "H";
            5'd7:    tx_data = "A";
            5'd8:    tx_data = fault ? "U" : "L";
            5'd9:    tx_data = fault ? "L" : "T";
            5'd10:   tx_data = fault ? "T" : " ";
            5'd11:   tx_data = " ";
            5'd12:   tx_data = "I";
            5'd13:   tx_data = "P";
            5'd14:   tx_data = "=";
            5'd15:   tx_data = hex_digit(dbg_ip[15:12]);
            5'd16:   tx_data = hex_digit(dbg_ip[11:8]);
            5'd17:   tx_data = hex_digit(dbg_ip[7:4]);
            5'd18:   tx_data = hex_digit(dbg_ip[3:0]);
            5'd19:   tx_data = " ";
            5'd20:   tx_data = "O";
            5'd21:   tx_data = "P";
            5'd22:   tx_data = "=";
            5'd23:   tx_data = hex_digit(dbg_opcode[7:4]);
            5'd24:   tx_data = hex_digit(dbg_opcode[3:0]);
            5'd25:   tx_data = 8'h0D;
            default: tx_data = 8'h0A;
        endcase
    end

    assign tx_start = (state == S_SEND) && !tx_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            idx   <= 5'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    idx <= 5'd0;
                    if (halted || fault)
                        state <= S_SEND;
                end
                S_SEND: begin
                    if (!tx_busy)
                        state <= S_NEXT;
                end
                S_NEXT: begin
                    if (idx == LAST_CHAR) begin
                        state <= S_DONE;
                    end else begin
                        idx   <= idx + 5'd1;
                        state <= S_SEND;
                    end
                end
                default: ;      // S_DONE: wait for reset
            endcase
        end
    end

endmodule

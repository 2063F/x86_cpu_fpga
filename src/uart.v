// =============================================================================
// uart.v - UART transmitter / receiver (8 data bits, no parity, 1 stop bit)
// =============================================================================
// Transmitter: write one byte with tx_start while tx_busy is 0.
// Receiver   : received bytes go into a small FIFO. rx_valid is 1 while the
//              FIFO holds data, rx_data is the oldest byte, and a 1-cycle
//              pulse on rx_read removes it. Bytes that arrive while the FIFO
//              is full, or with a bad stop bit, are dropped.
//
// Baud rate = CLK_FREQ / round-down(CLK_FREQ / BAUD)
//   50 MHz, 115200 baud -> 434 clock cycles per bit (error 0.006%)
// =============================================================================

module uart #(
    parameter CLK_FREQ  = 50000000,    // Clock frequency [Hz]
    parameter BAUD      = 115200,      // Baud rate
    parameter FIFO_BITS = 4            // Receive FIFO holds 2^FIFO_BITS bytes
) (
    input  wire       clk,
    input  wire       rst_n,

    // Transmitter
    input  wire [7:0] tx_data,
    input  wire       tx_start,        // Ignored while tx_busy is 1
    output wire       tx_busy,

    // Receiver
    output wire [7:0] rx_data,         // Oldest received byte (valid if rx_valid)
    output wire       rx_valid,
    input  wire       rx_read,         // Remove the oldest byte

    // Serial lines
    input  wire       rxd,
    output wire       txd
);

    localparam integer DIV = CLK_FREQ / BAUD;   // Clock cycles per bit

    // Counter start values (the counters count down to 0)
    localparam [15:0] BIT_TIME  = DIV - 1;      // One bit
    localparam [15:0] HALF_TIME = DIV / 2 - 1;  // Half a bit

    // =========================================================================
    // Transmitter
    // =========================================================================
    reg [15:0] tx_cnt;          // Clock cycles left in the current bit
    reg [3:0]  tx_bits;         // Bits left to send (0 = idle)
    reg [9:0]  tx_shift;        // {stop, data[7:0], start}, sent LSB first

    assign tx_busy = (tx_bits != 4'd0);
    assign txd     = tx_busy ? tx_shift[0] : 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_cnt   <= 16'd0;
            tx_bits  <= 4'd0;
            tx_shift <= 10'h3FF;
        end else if (!tx_busy) begin
            if (tx_start) begin
                tx_shift <= {1'b1, tx_data, 1'b0};
                tx_bits  <= 4'd10;
                tx_cnt   <= BIT_TIME;
            end
        end else if (tx_cnt != 16'd0) begin
            tx_cnt <= tx_cnt - 16'd1;
        end else begin
            tx_shift <= {1'b1, tx_shift[9:1]};
            tx_bits  <= tx_bits - 4'd1;
            tx_cnt   <= BIT_TIME;
        end
    end

    // =========================================================================
    // Receiver
    // =========================================================================
    localparam RX_IDLE  = 2'd0;
    localparam RX_START = 2'd1;     // Waiting for the middle of the start bit
    localparam RX_DATA  = 2'd2;     // Sampling the 8 data bits
    localparam RX_STOP  = 2'd3;     // Sampling the stop bit

    reg [1:0]  rxd_sync;            // 2-FF synchronizer
    reg [1:0]  rx_state;
    reg [15:0] rx_cnt;
    reg [2:0]  rx_bit;
    reg [7:0]  rx_shift;
    reg        rx_done;             // 1-cycle pulse: rx_shift holds a new byte

    wire rxd_s = rxd_sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxd_sync <= 2'b11;
            rx_state <= RX_IDLE;
            rx_cnt   <= 16'd0;
            rx_bit   <= 3'd0;
            rx_shift <= 8'd0;
            rx_done  <= 1'b0;
        end else begin
            rxd_sync <= {rxd_sync[0], rxd};
            rx_done  <= 1'b0;

            case (rx_state)
                RX_IDLE: begin
                    if (!rxd_s) begin               // Falling edge: start bit
                        rx_state <= RX_START;
                        rx_cnt   <= HALF_TIME;
                    end
                end

                RX_START: begin
                    if (rx_cnt != 16'd0) begin
                        rx_cnt <= rx_cnt - 16'd1;
                    end else if (!rxd_s) begin      // Still low: real start bit
                        rx_state <= RX_DATA;
                        rx_cnt   <= BIT_TIME;
                        rx_bit   <= 3'd0;
                    end else begin                  // Glitch
                        rx_state <= RX_IDLE;
                    end
                end

                RX_DATA: begin
                    if (rx_cnt != 16'd0) begin
                        rx_cnt <= rx_cnt - 16'd1;
                    end else begin
                        rx_shift <= {rxd_s, rx_shift[7:1]};     // LSB first
                        rx_cnt   <= BIT_TIME;
                        rx_bit   <= rx_bit + 3'd1;
                        if (rx_bit == 3'd7)
                            rx_state <= RX_STOP;
                    end
                end

                default: begin                      // RX_STOP
                    if (rx_cnt != 16'd0) begin
                        rx_cnt <= rx_cnt - 16'd1;
                    end else begin
                        rx_done  <= rxd_s;          // Drop the byte on a framing error
                        rx_state <= RX_IDLE;
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // Receive FIFO
    // =========================================================================
    reg [7:0]         fifo [0:(1 << FIFO_BITS) - 1];
    reg [FIFO_BITS:0] wr_ptr, rd_ptr;       // One extra bit to tell full from empty

    wire fifo_full = (wr_ptr[FIFO_BITS] != rd_ptr[FIFO_BITS]) &&
                     (wr_ptr[FIFO_BITS-1:0] == rd_ptr[FIFO_BITS-1:0]);

    assign rx_valid = (wr_ptr != rd_ptr);
    assign rx_data  = fifo[rd_ptr[FIFO_BITS-1:0]];

    always @(posedge clk) begin
        if (rx_done && !fifo_full)
            fifo[wr_ptr[FIFO_BITS-1:0]] <= rx_shift;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
        end else begin
            if (rx_done && !fifo_full)
                wr_ptr <= wr_ptr + 1'b1;
            if (rx_read && rx_valid)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

endmodule

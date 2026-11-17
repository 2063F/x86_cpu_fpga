// =============================================================================
// soc_top.v - Top level for Tang Primer 25K: CPU + ROM + RAM + UART + LEDs
// =============================================================================
// Runs the program in INIT_FILE (default: the UART monitor) on cpu_core.
//
// Memory map (physical address = segment * 16 + offset):
//   0x00000 - 0x7FFFF : RAM  (32KB, repeated)
//   0x80000 - 0xFFFFF : ROM  (4KB, repeated; holds INIT_FILE, writes ignored)
//   The ROM is normally used as F000:F000 - F000:FFFF. The CPU starts at the
//   reset vector F000:FFF0, which is ROM offset 0xFF0.
//
// I/O ports (IN / OUT instructions):
//   0x00  LED register   write: bit 0 -> led[0], bit 1 -> led[1]
//                        read : last value written
//   0x01  Buttons        read : bit 0 = user button
//   0x10  UART data      write: send a byte (ignored while the transmitter is busy)
//                        read : oldest received byte (removes it from the FIFO)
//   0x11  UART status    read : bit 0 = received data available
//                               bit 1 = transmitter ready
//   Reading any other port returns 0xFFFF.
//
// Debug aids:
//   - When the CPU stops (HLT or unimplemented opcode) one line with the
//     address and opcode is sent on the UART (see debug_reporter.v).
//   - On an unimplemented opcode (FAULT) the two LEDs blink alternately.
//
// Clock: 50 MHz (20 ns period), used directly.
// Reset: power-on reset, and the reset button (active high).
// UART : 115200 baud, 8 data bits, no parity, 1 stop bit.
// =============================================================================

`include "x86_defines.vh"

module soc_top #(
    parameter INIT_FILE     = "firmware/monitor.hex",   // ROM contents
    parameter CLK_FREQ      = 50000000,                 // Clock frequency [Hz]
    parameter BAUD          = 115200,                   // UART baud rate
    parameter RAM_ADDR_BITS = 15,                       // RAM size = 2^n bytes (32KB)
    parameter ROM_ADDR_BITS = 12,                       // ROM size = 2^n bytes (4KB)
    parameter BLINK_BIT     = 22                        // FAULT blink: 2^(BLINK_BIT+1) cycles
) (
    input  wire       clk,       // 50 MHz system clock
    input  wire       rst_btn,   // Reset button (active high)
    input  wire       user_btn,  // User button (active high)
    input  wire       uart_rx,   // UART receive  (from the USB debugger)
    output wire       uart_tx,   // UART transmit (to the USB debugger)
    output wire [1:0] led        // 2x onboard LEDs
);

    localparam IO_LED       = 16'h0000;
    localparam IO_BTN       = 16'h0001;
    localparam IO_UART_DATA = 16'h0010;
    localparam IO_UART_STAT = 16'h0011;

    // =========================================================================
    // Reset generation and button synchronizers
    // =========================================================================
    // rst_n is released 256 clock cycles after power-on / after the reset
    // button is released.
    reg [1:0] rst_sync = 2'b11;
    reg [1:0] btn_sync = 2'b00;
    reg [8:0] rst_cnt  = 9'd0;
    reg       rst_n    = 1'b0;

    always @(posedge clk) begin
        rst_sync <= {rst_sync[0], rst_btn};
        btn_sync <= {btn_sync[0], user_btn};

        if (rst_sync[1])
            rst_cnt <= 9'd0;
        else if (!rst_cnt[8])
            rst_cnt <= rst_cnt + 9'd1;

        rst_n <= rst_cnt[8] && !rst_sync[1];
    end

    // =========================================================================
    // CPU
    // =========================================================================
    wire [19:0] mem_addr;
    wire [31:0] mem_wdata, mem_rdata;
    wire [1:0]  mem_size;
    wire        mem_rd, mem_wr, mem_ready;

    wire [15:0] io_addr, io_wdata;
    reg  [15:0] io_rdata;
    wire [1:0]  io_size;
    wire        io_rd, io_wr;

    wire        cpu_halted, cpu_fault, cpu_inst_done;
    wire [15:0] cpu_dbg_ip;
    wire [7:0]  cpu_dbg_opcode;

    cpu_core u_cpu (
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
        .halted     (cpu_halted),
        .fault      (cpu_fault),
        .inst_done  (cpu_inst_done),
        .dbg_ip     (cpu_dbg_ip),
        .dbg_opcode (cpu_dbg_opcode)
    );

    // =========================================================================
    // Memory: RAM in the lower half of the address space, ROM in the upper half
    // =========================================================================
    wire        sel_rom = mem_addr[19];
    wire [31:0] ram_rdata, rom_rdata;
    wire        ram_ready, rom_ready;

    memory_controller #(
        .ADDR_BITS (RAM_ADDR_BITS)
    ) u_ram (
        .clk         (clk),
        .rst_n       (rst_n),
        .address     (mem_addr),
        .write_data  (mem_wdata),
        .access_size (mem_size),
        .read_en     (mem_rd && !sel_rom),
        .write_en    (mem_wr && !sel_rom),
        .read_data   (ram_rdata),
        .ready       (ram_ready)
    );

    memory_controller #(
        .ADDR_BITS (ROM_ADDR_BITS),
        .INIT_FILE (INIT_FILE)
    ) u_rom (
        .clk         (clk),
        .rst_n       (rst_n),
        .address     (mem_addr),
        .write_data  (32'd0),
        .access_size (mem_size),
        .read_en     (mem_rd && sel_rom),
        .write_en    (1'b0),                // read only
        .read_data   (rom_rdata),
        .ready       (rom_ready)
    );

    assign mem_rdata = sel_rom ? rom_rdata : ram_rdata;
    assign mem_ready = sel_rom ? rom_ready : ram_ready;

    // =========================================================================
    // UART (shared by the CPU and the debug reporter)
    // =========================================================================
    wire [7:0] uart_rx_data;
    wire       uart_rx_valid;
    wire       uart_tx_busy;

    wire       cpu_tx_start = io_wr && (io_addr == IO_UART_DATA);
    wire       cpu_rx_read  = io_rd && (io_addr == IO_UART_DATA);

    wire [7:0] dbg_tx_data;
    wire       dbg_tx_start;

    uart #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD)
    ) u_uart (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (dbg_tx_start ? dbg_tx_data : io_wdata[7:0]),
        .tx_start (dbg_tx_start || cpu_tx_start),
        .tx_busy  (uart_tx_busy),
        .rx_data  (uart_rx_data),
        .rx_valid (uart_rx_valid),
        .rx_read  (cpu_rx_read),
        .rxd      (uart_rx),
        .txd      (uart_tx)
    );

    debug_reporter u_reporter (
        .clk        (clk),
        .rst_n      (rst_n),
        .halted     (cpu_halted),
        .fault      (cpu_fault),
        .dbg_ip     (cpu_dbg_ip),
        .dbg_opcode (cpu_dbg_opcode),
        .tx_busy    (uart_tx_busy),
        .tx_data    (dbg_tx_data),
        .tx_start   (dbg_tx_start)
    );

    // =========================================================================
    // I/O ports
    // =========================================================================
    reg [7:0] led_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            led_reg <= 8'h00;
        else if (io_wr && io_addr == IO_LED)
            led_reg <= io_wdata[7:0];
    end

    always @(*) begin
        case (io_addr)
            IO_LED:       io_rdata = {8'h00, led_reg};
            IO_BTN:       io_rdata = {15'd0, btn_sync[1]};
            IO_UART_DATA: io_rdata = uart_rx_valid ? {8'h00, uart_rx_data} : 16'h0000;
            IO_UART_STAT: io_rdata = {14'd0, !uart_tx_busy, uart_rx_valid};
            default:      io_rdata = 16'hFFFF;
        endcase
    end

    // =========================================================================
    // LEDs
    // =========================================================================
    reg [BLINK_BIT:0] blink_cnt = 0;

    always @(posedge clk)
        blink_cnt <= blink_cnt + 1'b1;

    assign led = cpu_fault ? {blink_cnt[BLINK_BIT], ~blink_cnt[BLINK_BIT]}
                           : led_reg[1:0];

endmodule

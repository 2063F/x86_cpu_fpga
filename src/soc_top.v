// =============================================================================
// soc_top.v - Top level for Tang Primer 25K: CPU + memory + LED/button I/O
// =============================================================================
// Runs the program in INIT_FILE on cpu_core. The same pins as blinky.v are
// used, so constraints/tang_primer_25k.cst works unchanged.
//
// I/O ports (IN / OUT instructions):
//   0x00  LED register   write: bit 0 -> led[0], bit 1 -> led[1]
//                        read : last value written
//   0x01  Buttons        read : bit 0 = user button
//   Reading any other port returns 0xFFFF.
//
// If the CPU stops on an unimplemented opcode (FAULT), the two LEDs blink
// alternately instead of showing the LED register.
//
// Clock: 50 MHz (20 ns period), used directly.
// Reset: power-on reset, and the reset button (active high).
// =============================================================================

`include "x86_defines.vh"

module soc_top #(
    parameter INIT_FILE = "firmware/led_demo.hex",  // Program loaded into RAM
    parameter BLINK_BIT = 22                        // FAULT blink: 2^(BLINK_BIT+1) cycles
) (
    input  wire       clk,       // 50 MHz system clock
    input  wire       rst_btn,   // Reset button (active high)
    input  wire       user_btn,  // User button (active high)
    output wire [1:0] led        // 2x onboard LEDs
);

    localparam IO_LED = 16'h0000;
    localparam IO_BTN = 16'h0001;

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
    // CPU and memory
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

    memory_controller #(
        .INIT_FILE (INIT_FILE)
    ) u_mem (
        .clk         (clk),
        .rst_n       (rst_n),
        .address     (mem_addr),
        .write_data  (mem_wdata),
        .access_size (mem_size),
        .read_en     (mem_rd),
        .write_en    (mem_wr),
        .read_data   (mem_rdata),
        .ready       (mem_ready)
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
            IO_LED:  io_rdata = {8'h00, led_reg};
            IO_BTN:  io_rdata = {15'd0, btn_sync[1]};
            default: io_rdata = 16'hFFFF;
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

// =============================================================================
// tb_uart.v - Testbench for the UART (50 MHz, 115200 baud)
// =============================================================================

`timescale 1ns / 1ps

module tb_uart;

    localparam real BIT_NS = 1.0e9 / 115200.0;  // Ideal bit time: 8680.6 ns

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg  [7:0] tx_data = 8'h00;
    reg        tx_start = 1'b0;
    wire       tx_busy;
    wire [7:0] rx_data;
    wire       rx_valid;
    reg        rx_read = 1'b0;
    reg        tb_rxd = 1'b1;       // Serial line driven by the testbench
    reg        loopback = 1'b0;     // 1: connect txd to rxd
    wire       txd;
    wire       rxd = loopback ? txd : tb_rxd;

    always #10 clk = ~clk;          // 50 MHz

    uart #(
        .CLK_FREQ (50000000),
        .BAUD     (115200)
    ) uut (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (tx_data),
        .tx_start (tx_start),
        .tx_busy  (tx_busy),
        .rx_data  (rx_data),
        .rx_valid (rx_valid),
        .rx_read  (rx_read),
        .rxd      (rxd),
        .txd      (txd)
    );

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num   = 0;

    task check;
        input [31:0]     actual;
        input [31:0]     expected;
        input [8*40-1:0] name;
        begin
            test_num = test_num + 1;
            if (actual === expected) begin
                $display("PASS [%0d] %0s", test_num, name);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL [%0d] %0s: expected=0x%0h, got=0x%0h",
                         test_num, name, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Start transmitting one byte (returns after the start pulse)
    task start_tx;
        input [7:0] data;
        begin
            @(posedge clk);
            #1 tx_data = data; tx_start = 1'b1;
            @(posedge clk);
            #1 tx_start = 1'b0;
        end
    endtask

    // Receive one byte from txd, sampling at the ideal bit times
    reg [7:0] line_byte;
    reg       line_stop;
    integer   k;

    task capture_txd;
        begin
            @(negedge txd);
            #(BIT_NS * 1.5);
            for (k = 0; k < 8; k = k + 1) begin
                line_byte[k] = txd;
                #(BIT_NS);
            end
            line_stop = txd;
        end
    endtask

    // Drive one byte onto tb_rxd. `bit_ns` is the bit time, `stop` the stop bit.
    task drive_rxd;
        input [7:0] data;
        input real  bit_ns;
        input       stop;
        begin
            tb_rxd = 1'b0;
            #(bit_ns);
            for (k = 0; k < 8; k = k + 1) begin
                tb_rxd = data[k];
                #(bit_ns);
            end
            tb_rxd = stop;
            #(bit_ns);
            tb_rxd = 1'b1;
        end
    endtask

    // Take the oldest byte out of the receive FIFO
    reg [7:0] popped;

    task pop_rx;
        begin
            @(posedge clk);
            #1 popped = rx_data;
            rx_read = 1'b1;
            @(posedge clk);
            #1 rx_read = 1'b0;
        end
    endtask

    integer i, errors;
    real    t_start, t_end;

    initial begin
        $dumpfile("tb_uart.vcd");
        $dumpvars(0, tb_uart);

        $display("==============================================");
        $display("  UART Test Suite");
        $display("==============================================");

        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // =====================================================================
        // Transmitter
        // =====================================================================
        $display("\n--- Transmitter ---");
        check({31'd0, txd}, 1, "TX line idles high");
        check({31'd0, tx_busy}, 0, "TX not busy when idle");

        fork
            start_tx(8'h55);
            capture_txd;
        join
        check({24'd0, line_byte}, 32'h55, "TX byte 55");
        check({31'd0, line_stop}, 1, "TX stop bit");

        @(negedge tx_busy);
        fork
            start_tx(8'hA3);
            begin
                @(negedge txd) t_start = $realtime;
                capture_txd_rest;
            end
        join
        check({24'd0, line_byte}, 32'hA3, "TX byte A3");
        @(negedge tx_busy) t_end = $realtime;
        // 10 bits should take 10 bit times (within 1%)
        check((t_end - t_start) > BIT_NS * 9.9 && (t_end - t_start) < BIT_NS * 10.1,
              1, "TX frame is 10 bit times long");

        // tx_start while busy must not disturb the byte being sent
        fork
            begin
                start_tx(8'h0F);
                repeat (1000) @(posedge clk);
                start_tx(8'hFF);                // ignored
            end
            capture_txd;
        join
        check({24'd0, line_byte}, 32'h0F, "tx_start ignored while busy");
        @(negedge tx_busy);

        // =====================================================================
        // Receiver
        // =====================================================================
        $display("\n--- Receiver ---");
        check({31'd0, rx_valid}, 0, "RX FIFO empty after reset");

        drive_rxd(8'h5A, BIT_NS, 1'b1);
        #(BIT_NS);
        check({31'd0, rx_valid}, 1, "RX byte available");
        pop_rx;
        check({24'd0, popped}, 32'h5A, "RX byte 5A");
        @(posedge clk); #1;
        check({31'd0, rx_valid}, 0, "RX FIFO empty after read");

        drive_rxd(8'hC3, BIT_NS * 1.03, 1'b1);  // sender 3% slow
        #(BIT_NS);
        pop_rx;
        check({24'd0, popped}, 32'hC3, "RX with baud rate -3%");

        drive_rxd(8'h3C, BIT_NS * 0.97, 1'b1);  // sender 3% fast
        #(BIT_NS);
        pop_rx;
        check({24'd0, popped}, 32'h3C, "RX with baud rate +3%");

        drive_rxd(8'h77, BIT_NS, 1'b0);         // stop bit low
        #(BIT_NS * 2);
        check({31'd0, rx_valid}, 0, "RX framing error is dropped");

        tb_rxd = 1'b0;                          // short glitch, not a start bit
        #(BIT_NS * 0.2);
        tb_rxd = 1'b1;
        #(BIT_NS * 12);
        check({31'd0, rx_valid}, 0, "RX ignores a short glitch");

        // =====================================================================
        // Receive FIFO (16 bytes)
        // =====================================================================
        $display("\n--- Receive FIFO ---");
        for (i = 0; i < 17; i = i + 1)          // 17th byte does not fit
            drive_rxd(8'h80 + i, BIT_NS, 1'b1);
        #(BIT_NS);
        errors = 0;
        for (i = 0; i < 16; i = i + 1) begin
            if (!rx_valid) errors = errors + 1;
            pop_rx;
            if (popped !== 8'h80 + i) errors = errors + 1;
        end
        check(errors, 0, "FIFO returns 16 bytes in order");
        @(posedge clk); #1;
        check({31'd0, rx_valid}, 0, "byte arriving at a full FIFO is dropped");

        drive_rxd(8'h99, BIT_NS, 1'b1);
        #(BIT_NS);
        pop_rx;
        check({24'd0, popped}, 32'h99, "FIFO works again after overflow");

        // =====================================================================
        // Loopback: every byte value through TX -> RX
        // =====================================================================
        $display("\n--- Loopback ---");
        loopback = 1'b1;
        errors = 0;
        for (i = 0; i < 256; i = i + 1) begin
            start_tx(i[7:0]);
            @(negedge tx_busy);
            repeat (4) @(posedge clk);
            if (!rx_valid) errors = errors + 1;
            pop_rx;
            if (popped !== i[7:0]) errors = errors + 1;
        end
        check(errors, 0, "loopback of all 256 byte values");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n==============================================");
        $display("  UART Results: %0d PASSED, %0d FAILED (of %0d)",
                 pass_count, fail_count, test_num);
        $display("==============================================");

        if (fail_count > 0)
            $display("*** SOME TESTS FAILED ***");
        else
            $display("*** ALL TESTS PASSED ***");

        $finish;
    end

    // Like capture_txd, but the start edge has already been seen
    task capture_txd_rest;
        begin
            #(BIT_NS * 1.5);
            for (k = 0; k < 8; k = k + 1) begin
                line_byte[k] = txd;
                #(BIT_NS);
            end
            line_stop = txd;
        end
    endtask

endmodule

; =============================================================================
; hello.asm - Example program for the UART monitor
; =============================================================================
; Prints a message on the UART, shows a pattern on the LEDs and returns to
; the monitor. Load it at 0000:0100 and run it:
;
;   nasm -f bin -o firmware/examples/hello.bin firmware/examples/hello.asm
;   python3 tools/upload.py PORT firmware/examples/hello.bin
;
; Programs started by the monitor run with CS=DS=ES=SS=0 and a valid stack.
; =============================================================================

        cpu     8086
        bits    16
        org     0x100

%define PORT_LED        0x00
%define PORT_UART_DATA  0x10
%define PORT_UART_STAT  0x11
%define UART_TX_READY   0x02

start:
        mov     al, 2
        out     PORT_LED, al            ; LED 1 on, LED 0 off
        mov     si, message
.next:
        mov     al, [si]
        test    al, al
        jz      .done
        call    putc
        inc     si
        jmp     .next
.done:
        jmp     0xF000:0xF000           ; back to the monitor

; putc: send AL on the UART
putc:
        push    ax
.wait:
        in      al, PORT_UART_STAT
        test    al, UART_TX_READY
        jz      .wait
        pop     ax
        out     PORT_UART_DATA, al
        ret

message:
        db      "Hello from RAM!", 13, 10, 0

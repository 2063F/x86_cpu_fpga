; =============================================================================
; led_demo.asm - LED counter demo for soc_top (ROM image, 4KB)
; =============================================================================
; Counts on the two onboard LEDs (00 -> 01 -> 10 -> 11 -> 00 ...), about four
; steps per second at 50 MHz. While the user button is held the count runs
; backwards. Does not use the UART: the simplest program to check that the
; CPU runs on the board.
;
; To use it, set the INIT_FILE parameter of soc_top to "firmware/led_demo.hex".
;
; Build (from the repository root):
;   nasm -f bin -o firmware/led_demo.bin firmware/led_demo.asm
;   python3 tools/bin2hex.py firmware/led_demo.bin firmware/led_demo.hex
; =============================================================================

        cpu     8086
        bits    16
        org     0xF000          ; the ROM is F000:F000 - F000:FFFF

%define PORT_LED    0x00
%define PORT_BTN    0x01

%define STACK_TOP   0x8000      ; top of the 32KB RAM

; -----------------------------------------------------------------------------
; Constants (ROM offset 0x000)
; -----------------------------------------------------------------------------
; The delay is DELAY_OUTER x DELAY_INNER executions of LOOP (5 clock cycles
; each): 40 x 65536 x 5 = 13.1M cycles = 0.26 s at 50 MHz.
; The testbench (sim/tb_soc_top.v) overwrites these two words with small
; values so that the simulation finishes quickly.
delay_outer:    dw 40           ; F000:F000
delay_inner:    dw 0            ; F000:F002 (0 means 65536)

; -----------------------------------------------------------------------------
; Code
; -----------------------------------------------------------------------------
        times 0x10-($-$$) db 0
start:
        xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, STACK_TOP
        xor     bx, bx          ; BL = counter

main:
        mov     al, bl
        out     PORT_LED, al
        call    delay
        in      al, PORT_BTN
        test    al, 1
        jnz     .down
        inc     bx              ; button released: count up
        jmp     main
.down:
        dec     bx              ; button held: count down
        jmp     main

; delay: wait DELAY_OUTER x DELAY_INNER loop iterations (uses CX, DX)
delay:
        mov     dx, [cs:delay_outer]
.outer:
        mov     cx, [cs:delay_inner]
.inner:
        loop    .inner
        dec     dx
        jnz     .outer
        ret

; -----------------------------------------------------------------------------
; Reset vector (F000:FFF0)
; -----------------------------------------------------------------------------
        times 0xFF0-($-$$) db 0xFF
        jmp     start
        times 0x1000-($-$$) db 0xFF

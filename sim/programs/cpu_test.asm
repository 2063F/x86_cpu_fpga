; =============================================================================
; cpu_test.asm - Self-checking test program for cpu_core (Phase 3)
; =============================================================================
; 8KB memory image for sim/tb_cpu_core.v. Uses only instructions that cpu_core
; implements. Each test writes its number to I/O port 0x80 before it starts;
; on a mismatch the program stops (HLT) with BX = 0xDEAD, so the last value
; written to port 0x80 tells which test failed.
;
; On success it prints "PASS" on the debug console (port 0xE9) and halts with
; AX = 0x600D.
;
; Build (from the repository root):
;   nasm -f bin -o sim/programs/cpu_test.bin sim/programs/cpu_test.asm
;   python3 tools/bin2hex.py sim/programs/cpu_test.bin sim/programs/cpu_test.hex
; =============================================================================

        cpu     8086
        bits    16
        org     0

%define PORT_POST   0x80        ; test progress code
%define PORT_PUTC   0xE9        ; debug console
%define PORT_TEST   0x60        ; testbench returns 0x1234 when read

%define STACK_TOP   0x1000
%define NUM_TESTS   10

%macro TEST 1                   ; announce test number
        mov     al, %1
        out     PORT_POST, al
%endmacro

%macro ASSERT_EQ 2              ; stop unless %1 == %2
        cmp     %1, %2
        je      %%ok
        jmp     fail
%%ok:
%endmacro

%macro ASSERT_CC 1              ; stop unless condition %1 is true
        j%1     %%ok
        jmp     fail
%%ok:
%endmacro

; -----------------------------------------------------------------------------
; Data (0x0010 - 0x00FF)
; -----------------------------------------------------------------------------
        times 0x10-($-$$) db 0

result_sum:     dw 0            ; 0x0010: 1+2+...+100 = 5050 (0x13BA)
result_fib:     dw 0            ; 0x0012: fib(12) = 144
result_mem:     dw 0            ; 0x0014: 0xBEEF written through ES:
array:          times 8 dw 0    ; 0x0016: 1,2,4,...,128
jump_table:     dw via_table_a, via_table_b
msg_pass:       db "PASS", 0

; -----------------------------------------------------------------------------
; Code (0x0100 -)
; -----------------------------------------------------------------------------
        times 0x100-($-$$) db 0
start:
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, STACK_TOP

        ; ---- 1: MOV, 8-bit register halves --------------------------------
        TEST    1
        mov     ax, 0x1234
        mov     bl, ah
        mov     bh, al
        ASSERT_EQ bx, 0x3412
        mov     cx, bx
        mov     dh, cl
        mov     dl, 0x56
        ASSERT_EQ dx, 0x1256

        ; ---- 2: ADD/ADC/SUB/SBB (32-bit arithmetic in DX:AX) ---------------
        TEST    2
        mov     ax, 0xFFFF
        mov     dx, 0x0001
        add     ax, 1           ; 0x0001FFFF + 1 = 0x00020000
        adc     dx, 0
        ASSERT_EQ ax, 0
        ASSERT_EQ dx, 2
        sub     ax, 1           ; 0x00020000 - 1 = 0x0001FFFF
        sbb     dx, 0
        ASSERT_EQ ax, 0xFFFF
        ASSERT_EQ dx, 1

        ; ---- 3: flags and conditional jumps -------------------------------
        TEST    3
        mov     al, 0x7F
        add     al, 1           ; 0x80: signed overflow
        ASSERT_CC o
        ASSERT_CC s
        ASSERT_CC nc
        ASSERT_CC nz
        mov     al, 0xFF
        add     al, 1           ; 0x00: carry, zero
        ASSERT_CC c
        ASSERT_CC z
        ASSERT_CC no
        mov     ax, 5
        cmp     ax, 0xFFFF      ; unsigned 5 < 65535, signed 5 > -1
        ASSERT_CC b
        ASSERT_CC g
        mov     ax, 0x8000
        cmp     ax, 1           ; signed -32768 < 1, unsigned 0x8000 > 1
        ASSERT_CC l
        ASSERT_CC a
        stc
        ASSERT_CC c
        cmc
        ASSERT_CC nc
        xor     ax, ax          ; result 0 has even parity
        ASSERT_CC pe

        ; ---- 4: LOOP (sum 1..100) -----------------------------------------
        TEST    4
        xor     ax, ax
        mov     cx, 100
.sum:   add     ax, cx
        loop    .sum
        ASSERT_EQ ax, 5050
        mov     [result_sum], ax
        ASSERT_EQ cx, 0
        xor     cx, cx
        jcxz    .cx_zero
        jmp     fail
.cx_zero:

        ; ---- 5: addressing modes ------------------------------------------
        TEST    5
        mov     bx, array       ; array[i] = 1 << i  via [bx+si]
        xor     si, si
        mov     ax, 1
        mov     cx, 8
.fill:  mov     [bx+si], ax
        add     ax, ax
        add     si, 2
        loop    .fill
        ASSERT_EQ word [array + 14], 128
        mov     di, array + 6
        ASSERT_EQ word [di], 8
        ASSERT_EQ word [di - 2], 4
        ASSERT_EQ byte [bx + 4], 4
        mov     bp, array       ; BP-based addressing uses SS (SS == DS here)
        mov     di, 4
        ASSERT_EQ word [bp + di + 2], 8
        lea     si, [bx + di + 0x100]
        ASSERT_EQ si, array + 0x104
        mov     ax, [array + 8] ; moffs form (opcode A1)
        ASSERT_EQ ax, 16

        ; ---- 6: PUSH/POP ---------------------------------------------------
        TEST    6
        mov     ax, 0x1111
        mov     bx, 0x2222
        push    ax
        push    bx
        ASSERT_EQ sp, STACK_TOP - 4
        push    word [array + 2]
        pop     cx
        pop     ax              ; swapped
        pop     bx
        ASSERT_EQ cx, 2
        ASSERT_EQ ax, 0x2222
        ASSERT_EQ bx, 0x1111
        ASSERT_EQ sp, STACK_TOP

        ; ---- 7: CALL/RET (recursive Fibonacci) ----------------------------
        TEST    7
        mov     ax, 12
        call    fib
        ASSERT_EQ ax, 144
        mov     [result_fib], ax
        ASSERT_EQ sp, STACK_TOP

        ; ---- 8: indirect JMP / CALL ---------------------------------------
        TEST    8
        xor     dx, dx
        mov     bx, jump_table
        call    [bx]            ; via_table_a: DX |= 1
        mov     si, 2
        call    [bx + si]       ; via_table_b: DX |= 2
        mov     ax, .after_jmp
        jmp     ax
        jmp     fail
.after_jmp:
        ASSERT_EQ dx, 3

        ; ---- 9: segment registers and segment override --------------------
        TEST    9
        mov     ax, 0x0001      ; ES:0004 is the same byte as DS:0014
        mov     es, ax
        mov     word [es:result_mem - 0x10], 0xBEEF
        ASSERT_EQ word [result_mem], 0xBEEF
        mov     dx, es
        ASSERT_EQ dx, 1

        ; ---- 10: INC/DEC/NEG/NOT/TEST/AND/OR/XOR, IN ----------------------
        TEST    10
        mov     ax, 0x00FF
        inc     ax
        ASSERT_EQ ax, 0x0100
        dec     ah
        ASSERT_EQ ax, 0x0000
        dec     ax
        ASSERT_EQ ax, 0xFFFF
        neg     ax
        ASSERT_EQ ax, 1
        not     ax
        ASSERT_EQ ax, 0xFFFE
        and     ax, 0x0FF0
        or      al, 0x0F
        xor     ah, 0xFF
        ASSERT_EQ ax, 0xF0FF
        test    al, 0x80
        ASSERT_CC nz
        test    ah, 0x0F
        ASSERT_CC z
        inc     byte [array]    ; memory operand: 1 -> 2
        ASSERT_EQ byte [array], 2
        dec     word [array]
        in      ax, PORT_TEST
        ASSERT_EQ ax, 0x1234
        mov     dx, PORT_TEST
        xor     ax, ax
        in      al, dx
        ASSERT_EQ ax, 0x0034

        ; ---- all tests passed ---------------------------------------------
        mov     si, msg_pass
        call    puts
        mov     ax, 0x600D
        hlt

fail:
        mov     bx, 0xDEAD
        hlt

; -----------------------------------------------------------------------------
; Subroutines
; -----------------------------------------------------------------------------

; fib: AX = n  ->  AX = fib(n)   (recursive, preserves BX)
fib:
        cmp     ax, 2
        jb      .done
        push    bx
        dec     ax
        push    ax
        call    fib             ; fib(n-1)
        mov     bx, ax
        pop     ax
        dec     ax
        call    fib             ; fib(n-2)
        add     ax, bx
        pop     bx
.done:  ret

; puts: print the zero-terminated string at DS:SI on the debug console
puts:
.next:  mov     al, [si]
        test    al, al
        jz      .done
        out     PORT_PUTC, al
        inc     si
        jmp     .next
.done:  ret

via_table_a:
        or      dx, 1
        ret
via_table_b:
        or      dx, 2
        ret

; -----------------------------------------------------------------------------
; Reset vector: the CPU starts at F000:FFF0, which memory_controller maps to
; the last 16 bytes of RAM.
; -----------------------------------------------------------------------------
        times 0x1FF0-($-$$) db 0
        jmp     0x0000:start
        times 0x2000-($-$$) db 0

; =============================================================================
; monitor.asm - UART monitor for soc_top (ROM image, 4KB)
; =============================================================================
; A small machine-language monitor on the UART (115200 baud, 8N1).
;
; Commands (all numbers are hexadecimal, addresses are offsets in segment 0):
;   d ADDR [LEN]      dump LEN bytes of memory (default 40)
;   w ADDR BYTE...    write bytes to memory
;   g ADDR            run the program at 0000:ADDR
;   ?                 help
;
; A program started with `g` runs with CS=DS=ES=SS=0 and BX=ADDR. It returns
; to the monitor with `jmp 0xF000:0xF000` (the monitor restarts).
; tools/upload.py uses the w / d / g commands to load and run a program.
;
; Memory used by the monitor (RAM, segment 0):
;   7E00 - 7EFF   stack
;   7F00 - 7F7F   command line buffer
;   7FF0 - 7FF1   "JMP BX" used by the g command
;
; The code uses only instructions implemented by cpu_core (no shifts, no
; string instructions, no far CALL).
;
; Build (from the repository root):
;   nasm -f bin -o firmware/monitor.bin firmware/monitor.asm
;   python3 tools/bin2hex.py firmware/monitor.bin firmware/monitor.hex
; =============================================================================

        cpu     8086
        bits    16
        org     0xF000          ; the ROM is F000:F000 - F000:FFFF

%define PORT_LED        0x00
%define PORT_UART_DATA  0x10
%define PORT_UART_STAT  0x11
%define UART_RX_AVAIL   0x01
%define UART_TX_READY   0x02

%define STACK_TOP       0x7F00
%define LINE_BUF        0x7F00
%define LINE_MAX        120
%define TRAMPOLINE      0x7FF0

%define CR              13
%define LF              10
%define BS              8
%define DEL             127

; -----------------------------------------------------------------------------
; Entry point (F000:F000)
; -----------------------------------------------------------------------------
start:
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, STACK_TOP
        mov     word [TRAMPOLINE], 0xE3FF       ; bytes FF E3 = JMP BX
        mov     al, 1
        out     PORT_LED, al                    ; LED 0 on: monitor is running
        mov     si, msg_banner
        call    puts

; -----------------------------------------------------------------------------
; Command loop
; -----------------------------------------------------------------------------
prompt:
        mov     sp, STACK_TOP                   ; commands may bail out from subroutines
        mov     si, msg_prompt
        call    puts
        call    getline
        call    skip_spaces
        mov     al, [si]
        test    al, al
        jz      prompt                          ; empty line
        inc     si
        or      al, 0x20                        ; lower case
        cmp     al, 'd'
        jne     .not_dump
        jmp     cmd_dump
.not_dump:
        cmp     al, 'w'
        jne     .not_write
        jmp     cmd_write
.not_write:
        cmp     al, 'g'
        jne     .not_go
        jmp     cmd_go
.not_go:
        cmp     al, '?'
        je      cmd_help
        cmp     al, 'h'
        je      cmd_help

error:
        mov     si, msg_error
        call    puts
        jmp     prompt

cmd_help:
        mov     si, msg_help
        call    puts
        jmp     prompt

; ---- d ADDR [LEN] -----------------------------------------------------------
cmd_dump:
        call    gethex
        jcxz    .error
        mov     bx, ax                          ; BX = address
        call    gethex
        mov     di, ax                          ; DI = bytes left
        jcxz    .default_len
        jmp     .start
.default_len:
        mov     di, 0x40
.start:
        call    end_of_line
        test    di, di
        jz      .done
.line:
        mov     ax, bx
        call    puthex16
        mov     al, ':'
        call    putc
        mov     cx, 16
.byte:
        mov     al, ' '
        call    putc
        mov     al, [bx]
        call    puthex8
        inc     bx
        dec     di
        jz      .last
        loop    .byte
        call    newline
        jmp     .line
.last:
        call    newline
.done:
        jmp     prompt
.error:
        jmp     error

; ---- w ADDR BYTE... ---------------------------------------------------------
cmd_write:
        call    gethex
        jcxz    .error
        mov     bx, ax                          ; BX = address
        call    gethex
        jcxz    .error                          ; at least one byte
.next:
        mov     [bx], al
        inc     bx
        call    gethex
        jcxz    .end
        jmp     .next
.end:
        call    end_of_line
        jmp     prompt
.error:
        jmp     error

; ---- g ADDR -----------------------------------------------------------------
cmd_go:
        call    gethex
        jcxz    .error
        mov     bx, ax
        call    end_of_line
        jmp     0x0000:TRAMPOLINE               ; RAM: JMP BX
.error:
        jmp     error

; -----------------------------------------------------------------------------
; Subroutines
; -----------------------------------------------------------------------------

; putc: send AL (preserves all registers)
putc:
        push    ax
.wait:
        in      al, PORT_UART_STAT
        test    al, UART_TX_READY
        jz      .wait
        pop     ax
        out     PORT_UART_DATA, al
        ret

; getc: wait for a character, return it in AL
getc:
        in      al, PORT_UART_STAT
        test    al, UART_RX_AVAIL
        jz      getc
        in      al, PORT_UART_DATA
        ret

; newline: send CR LF (uses AL)
newline:
        mov     al, CR
        call    putc
        mov     al, LF
        jmp     putc

; puts: send the zero-terminated string at CS:SI (uses AL, SI)
puts:
        mov     al, [cs:si]
        test    al, al
        jz      .done
        call    putc
        inc     si
        jmp     puts
.done:
        ret

; getline: read a line into LINE_BUF with echo and backspace handling.
;          Returns SI = LINE_BUF (zero-terminated). Uses AL, DI.
getline:
        mov     di, LINE_BUF
.next:
        call    getc
        cmp     al, CR
        je      .done
        cmp     al, BS
        je      .backspace
        cmp     al, DEL
        je      .backspace
        cmp     al, ' '
        jb      .next                           ; ignore LF and other control codes
        cmp     di, LINE_BUF + LINE_MAX
        jae     .next                           ; line is full
        mov     [di], al
        inc     di
        call    putc                            ; echo
        jmp     .next
.backspace:
        cmp     di, LINE_BUF
        je      .next
        dec     di
        mov     al, BS
        call    putc
        mov     al, ' '
        call    putc
        mov     al, BS
        call    putc
        jmp     .next
.done:
        mov     byte [di], 0
        call    newline
        mov     si, LINE_BUF
        ret

; skip_spaces: advance SI past spaces
skip_spaces:
        cmp     byte [si], ' '
        jne     .done
        inc     si
        jmp     skip_spaces
.done:
        ret

; end_of_line: jump to `error` unless only spaces remain at SI
end_of_line:
        call    skip_spaces
        cmp     byte [si], 0
        je      .ok
        jmp     error
.ok:
        ret

; gethex: parse a hex number at SI.
;         Returns AX = value, CX = number of digits (0 = no number), SI advanced.
;         Uses DX.
gethex:
        call    skip_spaces
        xor     dx, dx
        xor     cx, cx
.next:
        mov     al, [si]
        call    hexval
        jc      .done
        add     dx, dx                          ; DX <<= 4
        add     dx, dx
        add     dx, dx
        add     dx, dx
        or      dl, al
        inc     si
        inc     cx
        jmp     .next
.done:
        mov     ax, dx
        ret

; hexval: convert the hex digit character in AL to its value.
;         CF = 1 if AL is not a hex digit.
hexval:
        cmp     al, '0'
        jb      .bad
        cmp     al, '9'
        jbe     .digit
        or      al, 0x20                        ; lower case
        cmp     al, 'a'
        jb      .bad
        cmp     al, 'f'
        ja      .bad
        sub     al, 'a' - 10
        clc
        ret
.digit:
        sub     al, '0'
        clc
        ret
.bad:
        stc
        ret

; puthex16: send AX as four hex digits (preserves AX)
puthex16:
        push    ax
        mov     al, ah
        call    puthex8
        pop     ax
        ; fall through: low byte

; puthex8: send AL as two hex digits (preserves AX)
puthex8:
        push    ax
        xor     ah, ah
        add     ax, ax                          ; AX <<= 4: AH = high digit
        add     ax, ax
        add     ax, ax
        add     ax, ax
        push    ax
        mov     al, ah
        call    putnibble
        pop     ax
        xor     ah, ah
        add     ax, ax                          ; AX <<= 4: AH = low digit
        add     ax, ax
        add     ax, ax
        add     ax, ax
        mov     al, ah
        call    putnibble
        pop     ax
        ret

; putnibble: send the hex digit for AL (0-15)
putnibble:
        cmp     al, 10
        jb      .digit
        add     al, 'A' - '0' - 10
.digit:
        add     al, '0'
        jmp     putc

; -----------------------------------------------------------------------------
; Messages
; -----------------------------------------------------------------------------
msg_banner:
        db      CR, LF, "x86_cpu_fpga monitor (? = help)", CR, LF, 0
msg_prompt:
        db      "> ", 0
msg_error:
        db      "?", CR, LF, 0
msg_help:
        db      "d ADDR [LEN]    dump memory", CR, LF
        db      "w ADDR BYTE...  write bytes", CR, LF
        db      "g ADDR          run (return with jmp 0xF000:0xF000)", CR, LF
        db      "numbers are hex", CR, LF, 0

; -----------------------------------------------------------------------------
; Reset vector (F000:FFF0)
; -----------------------------------------------------------------------------
        times 0xFF0-($-$$) db 0xFF
        jmp     start
        times 0x1000-($-$$) db 0xFF

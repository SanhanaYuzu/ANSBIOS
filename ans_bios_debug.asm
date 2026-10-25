; ans_bios_debug.asm -- minimal diagnostic ROM.
; Reset vector directly writes 'A' to COM1, then near-jumps to init
; which writes 'B' and halts.  No stack, no segments, no BIOS code.
; If you see "AB" on serial stdio, the reset vector + serial work.

BITS 16
org 0

times 0x8000 db 0

init:
    mov al, 'B'
    mov dx, 0x3F8
    out dx, al
    hlt
    jmp init

    times 0xFFF0 - ($ - $$) db 0
reset_vector:
    mov al, 'A'
    mov dx, 0x3F8
    out dx, al
    jmp init
    times 65536 - ($ - $$) db 0

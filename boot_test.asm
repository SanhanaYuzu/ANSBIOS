; ============================================================
;  boot_test.asm  --  self-test boot sector for ANS VirtualBIOS
;  Loaded at 0x7C00 by the BIOS. Exercises the installed real-mode
;  interrupts:
;    - INT 10h AH=0x0E  (teletype)  -> proves video handler works
;    - INT 13h AH=0x42  (extended LBA read) -> proves disk ext handler
;    - INT 13h AH=0x02  (CHS read, LBA-assist) -> proves CHS handler
;  If both reads succeed it prints OK markers; otherwise FAIL markers.
;  Build: nasm -f bin boot_test.asm -o boot_test.bin  (512 bytes)
; ============================================================

BITS 16
org 0x7C00

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x8000
    sti

    mov si, msg_int10
    call print10

    ; ---- INT 13h extended read: 4 sectors from LBA1 -> 0x9000 ----
    mov word [dap+2], 4          ; transfer count
    mov word [dap+4], 0x9000     ; buffer offset
    mov word [dap+6], 0          ; buffer segment
    mov dword [dap+8], 1         ; LBA low  = 1
    mov dword [dap+12], 0        ; LBA high = 0
    mov si, dap
    mov dl, 0x80
    mov ah, 0x42
    int 0x13
    jc .ext_fail
    mov si, msg_ext_ok
    call print10
    jmp .do_chs
.ext_fail:
    mov si, msg_ext_fail
    call print10

.do_chs:
    ; ---- INT 13h CHS read: cyl0/head0/sec2 == LBA1 -> 0x8E00 ----
    mov ax, 0
    mov es, ax
    mov ah, 0x02                 ; read sectors
    mov al, 1                    ; count = 1
    mov ch, 0                    ; cylinder low
    mov cl, 2                    ; sector = 2  (LBA = (0*255+0)*63 + (2-1) = 1)
    mov dh, 0                    ; head
    mov dl, 0x80                 ; drive
    mov bx, 0x8E00              ; buffer
    int 0x13
    jc .chs_fail
    mov si, msg_chs_ok
    call print10
    jmp .done
.chs_fail:
    mov si, msg_chs_fail
    call print10

.done:
    hlt
    jmp .done

print10:
    lodsb
    test al, al
    jz .ret
    mov ah, 0x0E
    mov bx, 0
    int 0x10
    jmp print10
.ret:
    ret

msg_int10    db "ANS BOOT: int10 teletype test", 0x0D, 0x0A, 0
msg_ext_ok    db "INT13 EXT READ (LBA1 x4 -> 0x9000) OK", 0x0D, 0x0A, 0
msg_ext_fail  db "INT13 EXT READ FAILED", 0x0D, 0x0A, 0
msg_chs_ok    db "INT13 CHS READ (c0 h0 s2 -> 0x8E00) OK", 0x0D, 0x0A, 0
msg_chs_fail  db "INT13 CHS READ FAILED", 0x0D, 0x0A, 0

dap db 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

    times 510 - ($ - $$) db 0
    dw 0xAA55

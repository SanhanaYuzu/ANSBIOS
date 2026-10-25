; ans_bios_dbg2.asm -- milestone diagnostic.
; serial_putc writes directly to COM1 (no LSR wait) so it can't hang.
; init prints a marker char before/after each step:
;   'a' start, 's' after serial_init, 'c' after clear_screen,
;   then banner via print_string, 'p' after, 'l' after load_boot, 'j' before jmp.
; Whatever markers appear tell us how far init gets.

BITS 16
org 0

times 0x8000 db 0

init:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x8000
    sti
    cld

    mov al, 'a'
    call putc

    call serial_init
    mov al, 's'
    call putc

    call clear_screen
    mov al, 'c'
    call putc

    mov si, banner
    call print_string

    mov si, crlf
    call print_string
    mov al, 'p'
    call putc

    call load_boot
    mov al, 'l'
    call putc

    mov ax, [0x7DFE]
    cmp ax, 0xAA55
    jne no_boot
    mov al, 'j'
    call putc

    mov dl, 0x80
    jmp 0x0000:0x7C00

no_boot:
    mov si, msg_noboot
    call print_string
    hlt
    jmp no_boot

; ---- direct serial out (no LSR wait) ----
serial_init:
    push dx
    push ax
    mov dx, 0x3FB
    mov al, 0x80
    out dx, al
    mov dx, 0x3F8
    mov al, 0x01
    out dx, al
    mov dx, 0x3F9
    mov al, 0x00
    out dx, al
    mov dx, 0x3FB
    mov al, 0x03
    out dx, al
    pop ax
    pop dx
    ret

putc:
    push dx
    mov dx, 0x3F8
    out dx, al
    pop dx
    ret

; ---- VGA ----
cursor_var equ 0x0500

clear_screen:
    push es
    push di
    push ax
    mov ax, 0xB800
    mov es, ax
    mov di, 0
    mov cx, 80*25
    mov ax, 0x0F20
    rep stosw
    pop ax
    pop di
    pop es
    push ds
    xor ax, ax
    mov ds, ax
    mov word [cursor_var], 0
    pop ds
    ret

emit_char:
    push ax
    push bx
    push di
    push es
    cmp al, 0x0A
    jne .ser1
    push ax
    mov al, 0x0D
    call putc
    pop ax
.ser1:
    call putc
    push ds
    xor ax, ax
    mov ds, ax
    mov di, [cursor_var]
    pop ds
    cmp al, 0x0D
    je .cr
    cmp al, 0x0A
    je .lf
    mov bx, 0xB800
    mov es, bx
    mov ah, 0x0F
    mov [es:di], ax
    add di, 2
    jmp .wrap
.cr:
    mov ax, di
    mov bx, 160
    xor dx, dx
    div bx
    mul bx
    mov di, ax
    jmp .store
.lf:
    add di, 160
    jmp .wrap
.wrap:
    cmp di, 4000
    jb .store
    mov di, 0
.store:
    push ds
    xor ax, ax
    mov ds, ax
    mov [cursor_var], di
    pop ds
    pop es
    pop di
    pop bx
    pop ax
    ret

print_string:
    push si
    push ax
.ps:
    cs lodsb
    test al, al
    jz .pd
    call emit_char
    jmp .ps
.pd:
    pop ax
    pop si
    ret

lba0   equ 0x0510
lba1   equ 0x0511
lba2   equ 0x0512
lba3   equ 0x0513
buf_off equ 0x0514
buf_seg equ 0x0516
count  equ 0x0518

ata_read_sector:
    pusha
    mov dx, 0x1F6
    mov al, [lba3]
    and al, 0x0F
    or al, 0xE0
    out dx, al
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    mov dx, 0x1F3
    mov al, [lba0]
    out dx, al
    mov dx, 0x1F4
    mov al, [lba1]
    out dx, al
    mov dx, 0x1F5
    mov al, [lba2]
    out dx, al
    mov dx, 0x1F7
    mov al, 0x20
    out dx, al
.wait:
    in al, dx
    test al, 0x80
    jnz .wait
    test al, 0x08
    jz .wait
    mov cx, 256
    mov dx, 0x1F0
    push es
    push di
    xor ax, ax
    mov es, ax
    mov di, 0x0600
    rep insw
    pop di
    pop es
    popa
    ret

read_sectors:
    push ds
    xor ax, ax
    mov ds, ax
    pusha
    mov cx, [count]
.rs_loop:
    call ata_read_sector
    push es
    push si
    push di
    push cx
    mov si, 0x0600
    mov ax, [buf_seg]
    mov es, ax
    mov di, [buf_off]
    mov cx, 256
    rep movsw
    pop cx
    pop di
    pop si
    pop es
    add word [buf_off], 512
    adc word [buf_seg], 0
    add byte [lba0], 1
    add byte [lba1], 1
    adc byte [lba2], 1
    adc byte [lba3], 1
    loop .rs_loop
    popa
    pop ds
    ret

load_boot:
    push ds
    xor ax, ax
    mov ds, ax
    mov byte [lba0], 0
    mov byte [lba1], 0
    mov byte [lba2], 0
    mov byte [lba3], 0
    pop ds
    call ata_read_sector
    push ds
    push es
    push si
    push di
    xor ax, ax
    mov ds, ax
    mov si, 0x0600
    mov es, ax
    mov di, 0x7C00
    mov cx, 256
    rep movsw
    pop di
    pop si
    pop es
    pop ds
    ret

banner     db "ANS VirtualBIOS v0.1  (C) 2026 ANS", 0
crlf       db 0x0D, 0x0A, 0
msg_noboot db "NO BOOTABLE MEDIA FOUND", 0x0D, 0x0A, 0

    times 0xFFF0 - ($ - $$) db 0
reset_vector:
    jmp init
    times 65536 - ($ - $$) db 0

; ============================================================
;  ANS VirtualBIOS  --  minimal 16-bit real-mode BIOS (64KiB ROM)
;
;  Phase 2: REAL bootable BIOS. Standard PC BIOS layout:
;    - reset far-jumps to 0xF000:init (runs at CS=0xF000, real-mode
;      addressable because `-machine pc` aliases the 64KiB image to
;      0xF0000). The same image is also at 0xFFFF0000 for the reset
;      vector at 0xFFFFFFF0.
;    - installs a real IVT at 0x0000:0x0000 with handlers in 0xF000.
;    - INT 10h (text), INT 13h (disk: reset/status/CHS read LBA-assist/
;      params/disktype/ext-check 0x41/ext-read 0x42/ext-verify 0x43),
;      INT 16h (keyboard), INT 15h (memory 0x88/0xE801), INT 11h/12h/1Ah.
;    - reads LBA0 (boot sector) via ATA LBA28 PIO and chains to 0x7C00
;      with DL=0x80. A real bootloader (SYSLINUX/FreeDOS) then uses the
;      installed INT 13h/10h to load the rest of the OS.
;
;  Build : nasm -f bin ans_bios.asm -o ansbios.bin   (must be 65536 bytes)
;  Run   : qemu-system-x86_64 -machine pc -bios ansbios.bin \
;            -drive file=disk.img,format=raw,if=ide -serial stdio
; ============================================================

BITS 16
org 0

; ---------------- low-RAM variables (DS=0, conventional RAM) ----------------
cursor_var  equ 0x0500
lba0   equ 0x0510
lba1   equ 0x0511
lba2   equ 0x0512
lba3   equ 0x0513
buf_off equ 0x0514
buf_seg equ 0x0516
count  equ 0x0518
cyl16  equ 0x051A
head8  equ 0x051C
sec6   equ 0x051E
nlow   equ 0x0520
nhigh  equ 0x0522
mlow   equ 0x0524
mhigh  equ 0x0526
tmp_ch equ 0x0528
tmp_cl equ 0x052A
tmp_dh equ 0x052C
tmp_al equ 0x052E
tmp_bx equ 0x0530
tmp_seg equ 0x0532

HEADS  equ 255
SPT    equ 63

; ---------------- INIT (runs at CS=0xF000, real mode) ----------------
init:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x8000
    sti
    cld

    call install_ivt                  ; wire real-mode interrupt handlers FIRST
    call pci_enable_vga               ; enable PCI VGA memory aperture (QEMU -bios skips option ROM)
    call vga_text_init                ; clean 80x25 text mode (clears screen)

    mov si, logo
    call print_string
    mov si, crlf
    call print_string
    mov si, version
    call print_string
    mov si, crlf
    call print_string
    mov si, post_line
    call print_string
    call delay                        ; brief pause so the screen is readable

    call load_boot                   ; read LBA0 -> 0x7C00

    mov ax, [0x7DFE]                ; boot signature
    cmp ax, 0xAA55
    jne no_boot

    mov dl, 0x80                     ; boot drive = first HDD
    jmp 0x0000:0x7C00               ; hand off to boot sector

no_boot:
    mov si, msg_noboot
    call print_string
    hlt
    jmp no_boot

; ---------------- install IVT at 0x0000:0x0000 ----------------
install_ivt:
    push ax
    push cx
    push di
    push es
    xor ax, ax
    mov es, ax
    mov di, 0
    mov cx, 256
.ivt_fill:
    mov word [es:di], int_default
    mov word [es:di+2], 0xF000
    add di, 4
    loop .ivt_fill
    ; override the ones we implement
    mov word [0x10*4], int10_handler
    mov word [0x10*4+2], 0xF000
    mov word [0x13*4], int13_handler
    mov word [0x13*4+2], 0xF000
    mov word [0x16*4], int16_handler
    mov word [0x16*4+2], 0xF000
    mov word [0x15*4], int15_handler
    mov word [0x15*4+2], 0xF000
    mov word [0x11*4], int11_handler
    mov word [0x11*4+2], 0xF000
    mov word [0x12*4], int12_handler
    mov word [0x12*4+2], 0xF000
    mov word [0x1A*4], int1a_handler
    mov word [0x1A*4+2], 0xF000
    pop es
    pop di
    pop cx
    pop ax
    ret

; ---------------- serial (COM1) ----------------
serial_putc:
    push dx
    mov dx, 0x3F8
    out dx, al
    pop dx
    ret

; ---- serial-only string print (COM1, no VGA writes) for diagnostics ----
serial_print:
    push ax
    push si
    push dx
.sp_l:
    cs lodsb
    test al, al
    jz .sp_d
    mov dx, 0x3F8
    out dx, al
    jmp .sp_l
.sp_d:
    pop dx
    pop si
    pop ax
    ret

; ---- serial-only 16-bit hex print (COM1) for diagnostics ----
serial_print_hex16:
    push ax
    push bx
    push cx
    push dx
    mov bx, ax
    mov cx, 4
.sh_l:
    rol bx, 4
    mov al, bl
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .sh_d
    add al, 7
.sh_d:
    mov dx, 0x3F8
    out dx, al
    loop .sh_l
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---------------- PCI: enable VGA memory aperture ----------------
; QEMU's `-bios ansbios.bin` replaces the main BIOS ROM but does NOT run the
; VGA device's option ROM.  SeaBIOS would normally walk PCI and set the VGA
; device's Command register (offset 0x04) Memory Space Enable (bit 1) so the
; legacy 0xA0000-0xBFFFF framebuffer window (where 0xB8000 text lives) is
; decoded by the controller.  With that bit 0, CPU stores to 0xB8000 never
; reach the VGA VRAM -> black screen, even though I/O-port register writes
; (which only need bit 0) still work.  This routine does the enable.
pci_enable_vga:
    push ax
    push bx
    push cx
    push dx
    push si

    xor cx, cx                  ; device number (bus 0, dev 0..31, func 0)
.scan_dev:
    ; Build CONFIG_ADDRESS for the device's header (offset 0x00):
    ;   EAX = 0x80000000 | (dev << 11) | (func << 8) | (reg & ~3)
    mov eax, 0x80000000
    mov bx, cx
    shl bx, 11                  ; dev << 11
    or  ax, bx                  ; func=0, reg=0 -> ax = dev<<11
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx                 ; EAX = (device_id << 16) | vendor_id
    cmp ax, 0xFFFF              ; vendor 0xFFFF => slot empty
    je  .next_dev

    ; Read the Class Code dword at offset 0x08:
    ;   byte 0x0B = base class, 0x0A = subclass, 0x09 = prog-if, 0x08 = rev
    mov eax, 0x80000000
    mov bx, cx
    shl bx, 11
    or  ax, bx
    or  ax, 0x08                ; reg = 0x08 (already 4-aligned)
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx                 ; EAX = class dword (0x0B..0x08 = B|S|P|R)
    shr eax, 16                 ; AX = (base_class << 8) | subclass
    cmp ah, 0x03                ; base class 0x03 = Display controller
    jne .next_dev
    cmp al, 0x00                ; subclass 0x00 = VGA-compatible controller
    jne .next_dev

    ; Found the VGA device.  Enable its Command register (offset 0x04):
    ;   bit 0 = I/O Space, bit 1 = Memory Space, bit 2 = Bus Master.
    mov eax, 0x80000000
    mov bx, cx
    shl bx, 11
    or  ax, bx
    or  ax, 0x04                ; reg = 0x04
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx                 ; read command(low16) | status(high16)
    or  ax, 0x0007              ; set I/O + Memory + Bus Master
    out dx, ax                  ; 16-bit write touches only Command
    mov si, pci_msg_found
    call print_string
    jmp .done                   ; only one VGA; stop scanning

.next_dev:
    inc cx
    cmp cx, 32
    jb  .scan_dev
    mov si, pci_msg_nofound     ; scanned all slots, nothing matched
    call print_string
.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---------------- force legacy VGA text mode (disable VBE) ----------------
; QEMU's std VGA keeps the LFB graphics surface active while VBE extensions
; are on; that hides the 0xB8000 text framebuffer, so even a fully-programmed
; text mode shows black.  Disabling VBE restores the legacy text surface.
vbe_disable:
    push ax
    push dx
    mov dx, 0x1CE
    mov ax, 0x00
    out dx, ax          ; DISPI index 0 (ID)
    mov dx, 0x1CF
    mov ax, 0xB0C0
    out dx, ax          ; set a valid VBE ID (enables extensions)
    mov dx, 0x1CE
    mov ax, 0x04
    out dx, ax          ; DISPI index 4 (ENABLE)
    mov dx, 0x1CF
    mov ax, 0x00
    out dx, ax          ; disable VBE -> legacy text mode
    pop dx
    pop ax
    ret

; ---------------- VGA text mode ----------------
clear_screen:
    push es
    push di
    push ax
    mov ax, 0xB800
    mov es, ax
    mov di, 0
    mov cx, 80*25
    ; DIAGNOSTIC: white background, black solid block (0xDB). If the display
    ; and DAC work, the screen will be white (blocks or solid white).
    mov ax, 0xF0DB
    rep stosw
    pop ax
    pop di
    pop es
    push ds
    xor ax, ax
    mov ds, ax
    mov word [cursor_var], 0
    pop ds
    ; diagnostic: read back the first word of the text buffer and report it.
    ; F0DB => CPU<->VGA memory path works (black screen is display-side).
    ; 0000 => writes never reached VRAM (PCI / legacy-aperture decode issue).
    pusha
    push ds
    xor ax, ax
    mov ds, ax
    mov ax, 0xB800
    mov es, ax
    xor di, di
    mov ax, [es:di]
    mov si, vga_dbg_rd
    call serial_print
    call serial_print_hex16
    mov al, 0x0D
    call serial_putc
    mov al, 0x0A
    call serial_putc
    pop ds
    popa
    ret

; vga_text_init: program std VGA for 80x25 color text (mode 3).
; Values now match SeaBIOS stdvgamodes.c for mode 0x03 exactly.
vga_text_init:
    push ax
    push bx
    push cx
    push dx
    push si
    push ds
    xor ax, ax
    mov ds, ax
    call vbe_disable
    mov si, vga_dbg_vbe
    call serial_print

    ; 1) Misc Output Register
    mov al, 0x67
    mov dx, 0x3C2
    out dx, al

    ; 2) Unlock CRTC registers 0-7 (CR11 bit 7 = 0)
    mov dx, 0x3D4
    mov al, 0x11
    out dx, al
    inc dx
    in al, dx
    and al, 0x7F
    out dx, al
    dec dx

    ; 3) Write CRTC registers 0x00..0x18
    mov si, vga_crtc_table
    mov cx, 0x19
    xor bh, bh
.crtcloop:
    mov al, bh
    out dx, al
    inc dx
    cs lodsb
    out dx, al
    dec dx
    inc bh
    loop .crtcloop

    ; 4) Sequencer: reset while we configure SR1..SR4, then unreset (run).
    ;    Per SeaBIOS / real VGA BIOS, normal running value for SR0 is 0x03.
    mov dx, 0x3C4
    mov al, 0
    out dx, al
    inc dx
    mov al, 0x01
    out dx, al
    dec dx
    mov si, vga_seq_table
    mov cx, 4
    mov bh, 1
.seqloop:
    mov al, bh
    out dx, al
    inc dx
    cs lodsb
    out dx, al
    dec dx
    inc bh
    loop .seqloop
    mov al, 0
    out dx, al
    inc dx
    mov al, 0x03
    out dx, al
    dec dx

    ; 5) Graphics Controller registers 0x00..0x08
    mov dx, 0x3CE
    mov si, vga_gc_table
    mov cx, 9
    xor bh, bh
.gcloop:
    mov al, bh
    out dx, al
    inc dx
    cs lodsb
    out dx, al
    dec dx
    inc bh
    loop .gcloop

    ; 6) Attribute Controller: reset flip-flop, write AR0..AR19 (20 regs),
    ;    then enable display with AR index 0x20.
    mov dx, 0x3DA
    in al, dx
    mov dx, 0x3C0
    mov si, vga_ac_table
    mov cx, 0x14          ; 20 registers (0x00..0x13)
    xor bh, bh
.acloop:
    mov al, bh
    out dx, al
    cs lodsb
    out dx, al
    inc bh
    loop .acloop
    mov dx, 0x3DA
    in al, dx
    mov dx, 0x3C0
    mov al, 0x20
    out dx, al

    ; 7) Initialize the DAC palette (QEMU does not run its VGA BIOS option ROM
    ;    when -bios is used, so the color lookup table may be all zeros).
    mov al, 0xFF
    mov dx, 0x3C6
    out dx, al            ; PEL mask = 0xFF (all bits)
    mov dx, 0x3C8
    xor al, al
    out dx, al            ; start at DAC index 0
    mov si, vga_dac_table
    mov cx, 16*3
.dacloop:
    cs lodsb
    mov dx, 0x3C9
    out dx, al
    loop .dacloop

    ; 8) Clear the text buffer
    call clear_screen

    pop ds
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; delay: short busy-wait (~0.5s in QEMU) so the boot screen is readable
; before we hand off to the boot sector.
delay:
    push cx
    push dx
    mov dx, 0x0010
.dl_outer:
    mov cx, 0xFFFF
.dl_inner:
    dec cx
    jnz .dl_inner
    dec dx
    jnz .dl_outer
    pop dx
    pop cx
    ret

; emit_char: AL=char -> VGA + COM1
;   serial: LF->CRLF ; CP437 0xCD -> UTF-8 U+2550 (clean double line)
emit_char:
    push ax
    push bx
    push di
    push es
    mov bl, al
    cmp al, 0x0A
    jne .ser_lf_done
    mov al, 0x0D
    call serial_putc
.ser_lf_done:
    cmp bl, 0xCD
    jne .ser_plain
    mov al, 0xE2
    call serial_putc
    mov al, 0x95
    call serial_putc
    mov al, 0x90
    call serial_putc
    jmp .ser_done
.ser_plain:
    mov al, bl
    call serial_putc
.ser_done:
    mov al, bl
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

; ---------------- ATA PIO ----------------
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
    adc byte [lba1], 0
    adc byte [lba2], 0
    adc byte [lba3], 0
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

; ---------------- 32-bit helpers ----------------
; mul32x16: DX:AX (N, 32-bit) * [mlow]/[mhigh] (M, 32-bit) -> DX:AX (32-bit)
;   clobbers [nlow],[nhigh],[mlow],[mhigh]
mul32x16:
    push bx
    push si
    push di
    push cx
    mov [nlow], ax
    mov [nhigh], dx
    xor ax, ax
    xor dx, dx
    mov di, 32
.mloop:
    mov bx, [nlow]
    and bx, 1
    jz .mskip
    add ax, [mlow]
    adc dx, [mhigh]
.mskip:
    shr word [nhigh], 1
    rcr word [nlow], 1
    shl word [mlow], 1
    rcl word [mhigh], 1
    dec di
    jnz .mloop
    pop cx
    pop di
    pop si
    pop bx
    ret

; mul16x16: AX * CX -> DX:AX
mul16x16:
    push cx
    mov [mlow], cx
    mov word [mhigh], 0
    pop cx
    xor dx, dx
    call mul32x16
    ret

; chs_to_lba: [cyl16],[head8],[sec6] -> [lba0..3] (28-bit)
chs_to_lba:
    mov ax, [cyl16]
    mov cx, HEADS
    call mul16x16
    xor bx, bx
    mov bl, [head8]
    add ax, bx
    adc dx, 0
    mov word [mlow], SPT
    mov word [mhigh], 0
    call mul32x16
    xor bx, bx
    mov bl, [sec6]
    dec bx
    add ax, bx
    adc dx, 0
    mov [lba0], ax
    mov [lba1], dx
    mov word [lba2], 0
    mov word [lba3], 0
    ret

; ============================================================
;  INTERRUPT HANDLERS (live in ROM, segment 0xF000)
; ============================================================

; ---- unknown interrupt: just return cleanly ----
int_default:
    iret

; ---- INT 10h : video ----
int10_handler:
    sti
    cmp ah, 0x0E
    je int10_teletype
    cmp ah, 0x00
    je int10_setmode
    cmp ah, 0x0F
    je int10_getstate
    cmp ah, 0x02
    je int10_setcursor
    cmp ah, 0x03
    je int10_getcursor
    cmp ah, 0x13
    je int10_writestr
    iret

int10_teletype:
    push ax
    push bx
    push es
    call emit_char
    pop es
    pop bx
    pop ax
    iret

int10_setmode:
    call clear_screen
    iret

int10_getstate:
    mov ax, 0x5003        ; AH=80 cols, AL=mode 3
    mov bh, 0
    iret

int10_setcursor:
    push ax
    push bx
    push dx
    push ds
    xor ax, ax
    mov ds, ax
    mov al, dh
    mov bl, 80
    mul bl
    xor bh, bh
    mov bl, dl
    add ax, bx
    shl ax, 1
    mov [cursor_var], ax
    pop ds
    pop dx
    pop bx
    pop ax
    iret

int10_getcursor:
    push ax
    push bx
    push ds
    xor ax, ax
    mov ds, ax
    mov ax, [cursor_var]
    mov bl, 160
    div bl
    mov dh, al
    mov dl, ah
    shr dl, 1
    mov ch, 0x0E
    mov cl, 0x0F
    pop ds
    pop bx
    pop ax
    iret

int10_writestr:
    push ax
    push cx
    push si
    push es
    mov si, bp
.wsl:
    jcxz .wse
    mov al, [es:si]
    call emit_char
    inc si
    dec cx
    jmp .wsl
.wse:
    pop es
    pop si
    pop cx
    pop ax
    iret

; ---- INT 13h : disk ----
int13_handler:
    sti
    cmp dl, 0x80
    je .dok
    mov ah, 0x01
    stc
    iret
.dok:
    cmp ah, 0x00
    je int13_reset
    cmp ah, 0x01
    je int13_status
    cmp ah, 0x02
    je int13_read_chs
    cmp ah, 0x03
    je int13_write_chs
    cmp ah, 0x08
    je int13_params
    cmp ah, 0x15
    je int13_disktype
    cmp ah, 0x41
    je int13_ext_check
    cmp ah, 0x42
    je int13_ext_read
    cmp ah, 0x43
    je int13_ext_verify
    mov ah, 0x01
    stc
    iret

int13_reset:
    mov ah, 0
    clc
    iret
int13_status:
    mov ah, 0
    clc
    iret
int13_write_chs:
    mov ah, 0x01
    stc
    iret
int13_params:
    mov dl, 1
    mov dh, HEADS-1
    mov ch, 1
    mov cl, SPT
    mov bl, 0
    mov ah, 0
    clc
    iret
int13_disktype:
    mov ah, 0x30
    mov cx, 0x03FF
    xor dx, dx
    clc
    iret
int13_ext_check:
    mov bx, 0xAA55
    mov ah, 0x21
    mov cx, 0x0001
    clc
    iret
int13_ext_verify:
    mov ah, 0
    clc
    iret

int13_ext_read:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push ds
    push es
    mov di, [si+4]
    mov bp, [si+6]
    mov cx, [si+2]
    mov ax, [si+8]
    mov [lba0], ax
    mov ax, [si+0xA]
    mov [lba1], ax
    mov ax, [si+0xC]
    mov [lba2], ax
    mov ax, [si+0xE]
    mov [lba3], ax
    xor ax, ax
    mov ds, ax
    mov [buf_off], di
    mov [buf_seg], bp
    mov [count], cx
    call read_sectors
    mov ah, 0
    clc
    pop es
    pop ds
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    iret

int13_read_chs:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push ds
    push es
    mov [tmp_ch], ch
    mov [tmp_cl], cl
    mov [tmp_dh], dh
    mov [tmp_al], al
    mov [tmp_bx], bx
    mov [tmp_seg], es
    ; cylinder (10-bit) = CH | ((CL>>6)<<8)
    mov al, [tmp_cl]
    shr al, 6
    xor ah, ah
    mov bx, ax
    shl bx, 8
    mov al, [tmp_ch]
    xor ah, ah
    add ax, bx
    mov [cyl16], ax
    mov al, [tmp_dh]
    mov [head8], al
    mov al, [tmp_cl]
    and al, 0x3F
    mov [sec6], al
    call chs_to_lba
    xor ax, ax
    mov ds, ax
    mov ax, [tmp_bx]
    mov [buf_off], ax
    mov ax, [tmp_seg]
    mov [buf_seg], ax
    mov al, [tmp_al]
    xor ah, ah
    mov [count], ax
    call read_sectors
    mov ah, 0
    clc
    pop es
    pop ds
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    iret

; ---- INT 16h : keyboard ----
int16_handler:
    sti
    cmp ah, 0x00
    je int16_getkey
    cmp ah, 0x01
    je int16_checkkey
    iret

int16_getkey:
    push ax
    push dx
.wait:
    in al, 0x64
    test al, 1
    jz .wait
    in al, 0x60
    mov ah, al
    cmp al, 0x1C
    jne .nk
    mov al, 0x0D
    jmp .done
.nk:
    mov al, 0
.done:
    pop dx
    pop ax
    iret

int16_checkkey:
    push bp
    mov bp, sp
    in al, 0x64
    test al, 1
    jz .nokey
    in al, 0x60
    mov ah, al
    cmp al, 0x1C
    jne .cknk
    mov al, 0x0D
    jmp .ckdone
.cknk:
    mov al, 0
.ckdone:
    and word [bp+4], 0xFFBF   ; clear ZF (key available)
    pop bp
    iret
.nokey:
    or word [bp+4], 0x0040    ; set ZF (no key)
    pop bp
    iret

; ---- INT 15h : system services ----
int15_handler:
    cmp ah, 0x88
    je int15_e88
    cmp ax, 0xE801
    je int15_e801
    cmp ax, 0xE820
    je int15_e820
    stc
    iret
int15_e88:
    mov ax, 0x3C00
    clc
    iret
int15_e801:
    mov ax, 0xE801
    mov cx, 0x3C00
    xor dx, dx
    clc
    iret
int15_e820:
    stc
    iret

; ---- INT 11h : equipment list ----
int11_handler:
    xor ax, ax
    iret

; ---- INT 12h : conventional memory size ----
int12_handler:
    mov ax, 0x0280
    iret

; ---- INT 1Ah : time of day ----
int1a_handler:
    cmp ah, 0x00
    je int1a_time
    iret
int1a_time:
    xor ax, ax
    xor cx, cx
    xor dx, dx
    clc
    iret

; ---------------- data (in ROM, read via CS) ----------------
logo:
    db 0x0D, 0x0A
    times 12 db ' '
    times 56 db 0xCD
    db 0x0D, 0x0A
    times 25 db ' '
    db "A N S   V I R T U A L   B I O S"
    db 0x0D, 0x0A
    times 12 db ' '
    times 56 db 0xCD
    db 0x0D, 0x0A, 0

version     db "ANS VirtualBIOS v0.2  (C) 2026 ANS  [real-mode BIOS]", 0x0D, 0x0A, 0
crlf        db 0x0D, 0x0A, 0
post_line   db "POST done -- booting Hard Disk (DL=0x80)...", 0x0D, 0x0A, 0
msg_noboot  db "NO BOOTABLE MEDIA FOUND", 0x0D, 0x0A, 0

; PCI scan diagnostics (serial only)
pci_msg_found    db "[PCI] VGA device found, memory aperture enabled", 0x0D, 0x0A, 0
pci_msg_nofound  db "[PCI] no VGA display device found on bus 0", 0x0D, 0x0A, 0

; VGA diagnostics (serial only)
vga_dbg_vbe  db "[VGA] VBE disabled, legacy text mode forced", 0x0D, 0x0A, 0
vga_dbg_rd   db "[VGA] B8000[0] readback = 0x", 0

; Standard VGA 80x25 text mode (mode 3) register tables.
; Used by vga_text_init to bring the display out of the QEMU placeholder.
vga_crtc_table:
    db 0x5F,0x4F,0x50,0x82,0x55,0x81,0xBF,0x1F
    db 0x00,0x4F,0x0D,0x0E,0x00,0x00,0x00,0x00
    db 0x9C,0x8E,0x8F,0x28,0x1F,0x96,0xB9,0xA3,0xFF
vga_seq_table:
    db 0x00,0x03,0x00,0x02    ; SR1..SR4 (SeaBIOS mode 3: SR1=0x00 -> 9-dot font)
vga_gc_table:
    db 0x00,0x00,0x00,0x00,0x00,0x10,0x0E,0x0F,0xFF
vga_ac_table:
    db 0x00,0x01,0x02,0x03,0x04,0x05,0x14,0x07
    db 0x38,0x39,0x3A,0x3B,0x3C,0x3D,0x3E,0x3F
    db 0x0C,0x00,0x0F,0x08

; Standard VGA 16-color DAC palette (6-bit RGB).
; QEMU does not initialize the DAC when a custom -bios is used.
vga_dac_table:
    db 0x00,0x00,0x00, 0x00,0x00,0x2A, 0x00,0x2A,0x00, 0x00,0x2A,0x2A
    db 0x2A,0x00,0x00, 0x2A,0x00,0x2A, 0x2A,0x15,0x00, 0x2A,0x2A,0x2A
    db 0x15,0x15,0x15, 0x15,0x15,0x3F, 0x15,0x3F,0x15, 0x15,0x3F,0x3F
    db 0x3F,0x15,0x15, 0x3F,0x15,0x3F, 0x3F,0x3F,0x15, 0x3F,0x3F,0x3F

; ---------------- reset vector at file offset 0xFFF0 (far jump) ----------------
    times 0xFFF0 - ($ - $$) db 0
reset_vector:
    jmp 0xF000:init
    times 65536 - ($ - $$) db 0

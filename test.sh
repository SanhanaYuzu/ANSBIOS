#!/usr/bin/env bash
# test.sh -- build, make a 16MiB IDE disk image with the self-test boot
# sector, and run it under QEMU with the standard PC machine (-machine pc)
# so the 64KiB BIOS is aliased to 0xF0000 and our real-mode INT handlers
# (installed at 0xF000) are callable.
#
#   ./test.sh            -> headless: banner on serial stdio
#   ./test.sh gui        -> graphical display (see the VGA logo + boot msgs)
set -e

QEMU=${QEMU:-qemu-system-x86_64}
command -v "$QEMU" >/dev/null 2>&1 || { echo "ERROR: $QEMU not found. Install: sudo apt install qemu-system-x86"; exit 1; }
command -v nasm  >/dev/null 2>&1 || { echo "ERROR: nasm not found. Install: sudo apt install nasm"; exit 1; }

# Always rebuild so edits to the .asm sources take effect.
./build.sh

# 16MiB IDE hard-disk image, test boot sector at LBA0.
dd if=/dev/zero of=disk.img bs=512 count=32768 2>/dev/null
dd if=boot_test.bin of=disk.img bs=512 conv=notrunc 2>/dev/null

if [ "$1" = "gui" ]; then
    echo "Launching QEMU (graphical). Close the window to exit."
    "$QEMU" -machine pc -vga std -bios ansbios.bin -drive file=disk.img,format=raw,if=ide
else
    echo "Launching QEMU (headless). Expect the ANS logo + boot OK lines on serial stdio."
    echo "Press Ctrl-C to quit QEMU."
    "$QEMU" -machine pc -vga std -bios ansbios.bin -drive file=disk.img,format=raw,if=ide -display none -serial stdio -monitor none
fi

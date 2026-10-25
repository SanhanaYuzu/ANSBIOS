#!/usr/bin/env bash
# build.sh -- assemble ANS VirtualBIOS + the test boot sector.
# Run inside WSL2 (or any Linux with nasm):
#   sudo apt install nasm qemu-system-x86  (if missing)
#   ./build.sh
set -e

command -v nasm >/dev/null 2>&1 || { echo "ERROR: nasm not found. Install: sudo apt install nasm"; exit 1; }

nasm -f bin ans_bios.asm -o ansbios.bin
nasm -f bin boot_test.asm -o boot_test.bin

SIZE=$(stat -c%s ansbios.bin 2>/dev/null || wc -c < ansbios.bin)
echo "ansbios.bin  : $SIZE bytes (must be exactly 65536 / 64KiB)"
echo "boot_test.bin: $(stat -c%s boot_test.bin 2>/dev/null || wc -c < boot_test.bin) bytes (must be 512)"
[ "$SIZE" -eq 65536 ] || { echo "ERROR: ansbios.bin is not 64KiB"; exit 1; }
echo "OK: build complete."

#!/usr/bin/env bash
# boot_sys.sh -- run the SYSLINUX disk (built by mkdisk.sh) under QEMU with
# the ANS VirtualBIOS. The SYSLINUX menu on the serial/display proves the
# BIOS chained a real bootloader.
set -e

QEMU=${QEMU:-qemu-system-x86_64}
command -v "$QEMU" >/dev/null 2>&1 || { echo "ERROR: $QEMU not found"; exit 1; }
[ -f disk.img ] || { echo "ERROR: disk.img missing. Run ./mkdisk.sh first."; exit 1; }
[ -f ansbios.bin ] || { echo "ERROR: ansbios.bin missing. Run ./build.sh first."; exit 1; }

echo "Launching QEMU with SYSLINUX disk. Expect the SYSLINUX menu."
echo "Press Ctrl-C to quit."
"$QEMU" -machine pc -bios ansbios.bin -drive file=disk.img,format=raw,if=ide -serial stdio -display none -monitor none

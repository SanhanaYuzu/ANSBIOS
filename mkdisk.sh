#!/usr/bin/env bash
# mkdisk.sh -- build a REAL bootable disk image using SYSLINUX.
# SYSLINUX's boot sector loads ldlinux.sys via INT 13h (extended read 0x42),
# which exercises ANS VirtualBIOS's real-mode INT 13h/10h handlers. If the
# SYSLINUX menu appears under QEMU, the BIOS has truly chained a bootloader.
#
# Requires: sudo apt install syslinux mtools dosfstools
set -e

command -v syslinux >/dev/null 2>&1 || { echo "ERROR: need syslinux + mtools + dosfstools"; echo "  sudo apt install syslinux mtools dosfstools"; exit 1; }
command -v nasm    >/dev/null 2>&1 || { echo "ERROR: nasm missing"; exit 1; }

# Build the BIOS so ansbios.bin is current.
./build.sh

# 16MiB IDE disk image with a FAT filesystem.
dd if=/dev/zero of=disk.img bs=512 count=32768 2>/dev/null
mkfs.vfat -n ANSBOOT disk.img

# Install SYSLINUX (writes ldlinux.sys + a boot sector that uses INT 13h).
syslinux disk.img

# Minimal config: just show a menu proving the bootloader loaded.
cat > syslinux.cfg <<'EOF'
MENU TITLE ANS VirtualBIOS -- real boot OK
PROMPT 0
TIMEOUT 100
DEFAULT ans
LABEL ans
  MENU LABEL Our BIOS loaded SYSLINUX via INT 13h
  LOCALBOOT 0x80
EOF
mcopy -i disk.img syslinux.cfg ::/syslinux.cfg

echo "Built disk.img with SYSLINUX. Now run: ./boot_sys.sh"
echo "(You should see the SYSLINUX menu -> proof the BIOS really boots.)"

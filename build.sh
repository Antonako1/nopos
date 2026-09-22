#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# build.sh — Build the NopOS 1.44 MiB FAT12 floppy image.
#
# Runs inside WSL. Uses the Windows AstraC.exe via WSL interop.
#
# Output:
#   output/floppy.img    (1.44 MiB / 1474560 bytes, FAT12 filesystem)
#   boot/BOOTLOADER.BIN  (512-byte FAT12 bootsector)
#   boot/SECOND_STAGE.BIN
#   kernel/kernel.BIN
#
# Disk layout (FAT12, standard 1.44 MB floppy):
#   LBA 0                 boot sector (BOOTLOADER.BIN, includes the BPB)
#   LBA 1-9               FAT #1
#   LBA 10-18             FAT #2
#   LBA 19-32             root directory (224 entries)
#   LBA 33+               data clusters: STAGE2.BIN and KERNEL.BIN
# =============================================================================

# Compiler path. Override with: ASTRAC=/path/to/AstraC.exe ./build.sh
ASTRAC="${ASTRAC:-/mnt/c/Users/anton/source/repos/AstraC/build/Release/AstraC.exe}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_DIR="$SCRIPT_DIR/boot"
KERNEL_DIR="$SCRIPT_DIR/kernel"
OUT_DIR="$SCRIPT_DIR/output"

if [ ! -x "$ASTRAC" ]; then
    echo "ERROR: AstraC not found at: $ASTRAC" >&2
    echo "       Set ASTRAC=/path/to/AstraC.exe" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# AstraC.exe is a Windows binary: it does not understand WSL /mnt/c paths, so
# translate every file argument to its Windows form (C:\...) before calling it.
BOOTLOADER_WIN="$(wslpath -w "$BOOT_DIR/BOOTLOADER.AS")"
SECOND_STAGE_WIN="$(wslpath -w "$BOOT_DIR/SECOND_STAGE.AS")"
KERNEL_WIN="$(wslpath -w "$KERNEL_DIR/kernel.ac")"

echo "==> [1/4] Assemble bootloader"
"$ASTRAC" asm "$BOOTLOADER_WIN" bits 16 org 7C00 arch i286 warn 2

echo "==> [2/4] Assemble second stage"
"$ASTRAC" asm "$SECOND_STAGE_WIN" bits 16 org 7E00 warn 2

echo "==> [3/4] Compile kernel"
"$ASTRAC" comp "$KERNEL_WIN" bits 32 org 10000 entry _start warn 2 debug

echo "==> [4/4] Create FAT12 floppy image"

FLOPPY="$OUT_DIR/floppy.img"

# 2880 sectors of 512 bytes = 1474560 bytes (standard 3.5" HD floppy).
dd if=/dev/zero of="$FLOPPY" bs=512 count=2880 status=none

# Format it as FAT12. mformat writes its own boot sector + BPB, both FATs and
# an empty root directory.
mformat -i "$FLOPPY" -f 1440 ::

# Place the two payloads into the filesystem under 8.3 names.
mcopy -i "$FLOPPY" "$BOOT_DIR/SECOND_STAGE.BIN" ::STAGE2.BIN
mcopy -i "$FLOPPY" "$KERNEL_DIR/kernel.BIN"    ::KERNEL.BIN

# Replace mformat's boot sector with ours. BOOTLOADER.AS already contains a
# BPB identical to mformat's, so the filesystem stays consistent.
dd if="$BOOT_DIR/BOOTLOADER.BIN" of="$FLOPPY" bs=512 count=1 conv=notrunc status=none

# The bootsector must be exactly 512 bytes and end in 0x55 0xAA.
BOOT_SIZE="$(stat -c%s "$BOOT_DIR/BOOTLOADER.BIN")"
if [ "$BOOT_SIZE" -ne 512 ]; then
    echo "ERROR: BOOTLOADER.BIN is $BOOT_SIZE bytes (expected 512)" >&2
    exit 1
fi

echo
echo "Done."
echo "  bootsector:    $BOOT_SIZE bytes"
echo "  second stage:  $(stat -c%s "$BOOT_DIR/SECOND_STAGE.BIN") bytes"
echo "  kernel:        $(stat -c%s "$KERNEL_DIR/kernel.BIN") bytes"
echo "  floppy.img:    $(stat -c%s "$FLOPPY") bytes"
echo
echo "  FAT12 contents:"
mdir -i "$FLOPPY" ::
echo
echo "Run in QEMU:  qemu-system-i386 -fda output/floppy.img -boot a"

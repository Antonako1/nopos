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
#   LBA 33+               data clusters: STAGE2.BIN, KERNEL.BIN, and root/ files
# =============================================================================

# Compiler path. Override with: ASTRAC=/path/to/AstraC.exe ./build.sh
ASTRAC="${ASTRAC:-/mnt/c/Users/anton/source/repos/AstraC/build/Release/AstraC.exe}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_DIR="$SCRIPT_DIR/boot"
KERNEL_DIR="$SCRIPT_DIR/kernel"
ROOT_DIR="$SCRIPT_DIR/root"
OUT_DIR="$SCRIPT_DIR/output"

if [ ! -x "$ASTRAC" ]; then
    echo "ERROR: AstraC not found at: $ASTRAC" >&2
    echo "       Set ASTRAC=/path/to/AstraC.exe" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# --- 0. Increment Build Number in BUILDNUM.AH ---
BUILDNUM_FILE="$KERNEL_DIR/BUILDNUM.AH"
if [ -f "$BUILDNUM_FILE" ]; then
    CURRENT_BUILD=$(grep -oE '[0-9]+' "$BUILDNUM_FILE" | head -n 1 || echo 0)
    [ -z "$CURRENT_BUILD" ] && CURRENT_BUILD=0
    NEXT_BUILD=$((CURRENT_BUILD + 1))
    echo "#define BUILDNUM $NEXT_BUILD" > "$BUILDNUM_FILE"
    echo "==> Build Number: #$NEXT_BUILD"
else
    echo "#define BUILDNUM 1" > "$BUILDNUM_FILE"
    echo "==> Build Number: #1"
fi

# AstraC.exe is a Windows binary: it does not understand WSL /mnt/c paths, so
# translate every file argument to its Windows form (C:\...) before calling it.
BOOTLOADER_WIN="$(wslpath -w "$BOOT_DIR/BOOTL.AS")"
BOOT_MBR_WIN="$(wslpath -w "$BOOT_DIR/BOOT_MBR.AS")"
FAT32_VBR_WIN="$(wslpath -w "$BOOT_DIR/VBR32.AS")"
SECOND_STAGE_WIN="$(wslpath -w "$BOOT_DIR/SSTAGE2.AS")"
KERNEL_WIN="$(wslpath -w "$KERNEL_DIR/kernel.ac")"

echo "==> [1/5] Assemble floppy bootloader"
"$ASTRAC" asm "$BOOTLOADER_WIN" bits 16 org 7C00 arch i286 warn 2

echo "==> [2/5] Assemble HDD MBR & FAT32 VBR bootloaders"
"$ASTRAC" asm "$BOOT_MBR_WIN" bits 16 org 7C00 arch i386 warn 2
"$ASTRAC" asm "$FAT32_VBR_WIN" bits 16 org 7C00 arch i386 warn 2

echo "==> [3/5] Assemble second stage"
"$ASTRAC" asm "$SECOND_STAGE_WIN" bits 16 org 7E00 warn 2

echo "==> [4/5] Compile kernel"
"$ASTRAC" comp "$KERNEL_WIN" bits 32 org 10000 entry _start warn 2 debug #verbose

echo "==> [5/5] Create FAT12 floppy image & Hard Disk image"
# HDD_IMG="$OUT_DIR/os_disk.img"
# dd if=/dev/zero of="$HDD_IMG" bs=1M count=1 status=none
FLOPPY="$OUT_DIR/floppy.img"


# 2880 sectors of 512 bytes = 1474560 bytes (standard 3.5" HD floppy).
dd if=/dev/zero of="$FLOPPY" bs=512 count=2880 status=none

# Format it as FAT12. mformat writes its own boot sector + BPB, both FATs and
# an empty root directory.
mformat -i "$FLOPPY" -f 1440 ::

# Place the main boot payloads into the filesystem under 8.3 names.
mcopy -i "$FLOPPY" "$BOOT_DIR/SSTAGE2.BIN" ::STAGE2.BIN
mcopy -i "$FLOPPY" "$KERNEL_DIR/kernel.BIN"     ::KERNEL.BIN
mcopy -i "$FLOPPY" "$BOOT_DIR/BOOT_MBR.BIN" ::BOOTMBR.BIN
mcopy -i "$FLOPPY" "$BOOT_DIR/VBR32.BIN"    ::VBR32.BIN

# Function to parse and stage a CONTAINER file
process_container() {
    local container_file="$1"
    local container_dir
    container_dir="$(dirname "$container_file")"

    echo "--> Processing CONTAINER in: $container_dir"

    # Temporary staging directory
    local STAGE_DIR
    STAGE_DIR="$(mktemp -d)"

    local excludes=""
    local paths=()

    # Read CONTAINER line-by-line (stripping Windows \r line endings)
    while IFS= read -r line || [ -n "$line" ]; do
        # Clean line
        line="$(echo "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue

        if [[ "$line" == EXCLUDE=* ]]; then
            excludes="${line#EXCLUDE=}"
        else
            paths+=("$line")
        fi
    done < "$container_file"

    # 1. Copy specified paths into staging directory
    for rel_path in "${paths[@]}"; do
        local full_path="$container_dir/$rel_path"
        if [ -e "$full_path" ]; then
            cp -r "$full_path" "$STAGE_DIR/"
        else
            echo "    WARNING: Path not found: $full_path" >&2
        fi
    done

    # 2. Apply exclusions
    if [ -n "$excludes" ]; then
        IFS=',' read -ra EXCL_ARRAY <<< "$excludes"
        for item in "${EXCL_ARRAY[@]}"; do
            item="$(echo "$item" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [ -z "$item" ] && continue

            if [[ "$item" == .* ]]; then
                # Extension match (e.g., .BIN -> *.BIN)
                find "$STAGE_DIR" -type f -name "*$item" -delete
            else
                # Exact filename match (e.g., kernel.AS)
                find "$STAGE_DIR" -name "$item" -delete
            fi
        done
    fi

    # 3. Determine target directory inside FAT image
    local rel_target="${container_dir#$ROOT_DIR}"
    rel_target="${rel_target#/}"

    local target_fat_dir="::/"
    if [ -n "$rel_target" ]; then
        target_fat_dir="::/$rel_target"
        # Ensure subdirectory exists inside disk image
        mmd -i "$FLOPPY" "$target_fat_dir" 2>/dev/null || true
    fi

    # 4. Copy staged files to floppy image
    shopt -s nullglob
    local staged_files=("$STAGE_DIR"/*)
    shopt -u nullglob

    if [ ${#staged_files[@]} -gt 0 ]; then
        mcopy -i "$FLOPPY" -s "${staged_files[@]}" "$target_fat_dir"
    fi

    # Clean up temp folder
    rm -rf "$STAGE_DIR"
}

# --- Copy Files / Containers to Floppy Image ---

if [ -d "$ROOT_DIR" ]; then
    # Find and process all CONTAINER files
    shopt -s globstar nullglob
    CONTAINERS=("$ROOT_DIR"/**/CONTAINER)
    shopt -u globstar nullglob

    if [ ${#CONTAINERS[@]} -gt 0 ]; then
        for container in "${CONTAINERS[@]}"; do
            process_container "$container"
        done
    else
        # Fallback: copy root/ directory directly if no CONTAINER file exists
        echo "--> Copying source files directly..."
        shopt -s nullglob
        ROOT_FILES=("$ROOT_DIR"/*)
        shopt -u nullglob
        if [ ${#ROOT_FILES[@]} -gt 0 ]; then
            mcopy -i "$FLOPPY" -s "${ROOT_FILES[@]}" ::/
        fi
    fi
fi

# Replace mformat's boot sector with ours. BOOTL.AS already contains a
# BPB identical to mformat's, so the filesystem stays consistent.
dd if="$BOOT_DIR/BOOTL.BIN" of="$FLOPPY" bs=512 count=1 conv=notrunc status=none

# The bootsector must be exactly 512 bytes and end in 0x55 0xAA.
BOOT_SIZE="$(stat -c%s "$BOOT_DIR/BOOTL.BIN")"
if [ "$BOOT_SIZE" -ne 512 ]; then
    echo "ERROR: BOOTL.BIN is $BOOT_SIZE bytes (expected 512)" >&2
    exit 1
fi

echo
echo "Done."
echo "  bootsector:    $BOOT_SIZE bytes"
echo "  second stage:  $(stat -c%s "$BOOT_DIR/SSTAGE2.BIN") bytes"
echo "  kernel:        $(stat -c%s "$KERNEL_DIR/kernel.BIN") bytes"
echo "  floppy.img:    $(stat -c%s "$FLOPPY") bytes"
echo
echo "  FAT12 contents:"
mdir -i "$FLOPPY" ::
echo
echo "Run in QEMU:   qemu-system-i386 -fda output/floppy.img -boot a"
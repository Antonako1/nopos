; boot/VBR32.AS — FAT32 Volume Boot Record (512 bytes)
;
; Loaded by MBR to 0x7C00. Parses FAT32 BPB/EBPB, traverses 32-bit FAT cluster
; chain for STAGE2.BIN, loads STAGE2.BIN to 0x7E00 using INT 13h Extensions,
; and jumps to 0x0000:0x7E00.
;
; Built with: AstraC asm VBR32.AS bits 16 org 7C00 arch i386

.org 0x7C00
.use16
.code

    DB 0xEB, 0x58, 0x90    ; JMP SHORT main (offset 0x5A) + NOP

; ── FAT32 BIOS Parameter Block & Extended BPB (Offsets 0x03..0x59) ─────────
oem_name:           DB "NOPOS32 "
bytes_per_sector:   DW 512
sectors_per_cluster:DB 8
reserved_sectors:   DW 32
num_fats:           DB 2
root_entries:       DW 0       ; Always 0 in FAT32
total_sectors16:    DW 0
media_type:         DB 0xF8
sectors_per_fat16:  DW 0
sectors_per_track:  DW 63
num_heads:          DW 255
hidden_sectors:     DD 2048    ; LBA offset of partition
total_sectors32:    DD 65536   ; Total sectors in volume

; Extended FAT32 BPB fields (Offset 0x24)
sectors_per_fat32:  DD 512
ext_flags:          DW 0
fs_version:         DW 0
root_cluster:       DD 2       ; Root directory cluster
fs_info_sector:     DW 1
backup_boot_sec:    DW 6
reserved_bytes:     DB 0,0,0,0,0,0,0,0,0,0,0,0
drive_number:       DB 0x80
reserved1:          DB 0
boot_signature:     DB 0x29
volume_id:          DD 0x12345678
volume_label:       DB "NOPOS DISK "
fs_type:            DB "FAT32   "

main:
    CLI
    XOR AX, AX
    MOV DS, AX
    MOV ES, AX
    MOV SS, AX
    MOV SP, 0x7C00
    STI

    MOV [drive_number], DL     ; Save boot drive number

    ; Calculate Data LBA Start:
    ; Data_LBA = hidden_sectors + reserved_sectors + (num_fats * sectors_per_fat32)
    MOV EAX, [sectors_per_fat32]
    MOVZX EBX, BYTE [num_fats]
    IMUL EAX, EBX              ; EAX = FATs total sectors
    MOVZX EBX, WORD [reserved_sectors]
    ADD EAX, EBX               ; EAX = reserved + FATs
    ADD EAX, [hidden_sectors]  ; EAX = partition LBA + reserved + FATs
    MOV [data_lba_start], EAX

    ; Load Root Directory Cluster (RootCluster = 2)
    MOV EAX, [root_cluster]
    MOV BX, 0x7E00             ; Buffer address
    CALL read_cluster

    ; Search Root Directory at 0x7E00 for "STAGE2  BIN"
    MOV SI, 0x7E00
    MOV CX, 16                 ; Entries per sector (512 / 32 = 16)

.search_entry:
    CMP BYTE [SI], 0           ; End of directory
    JZ .file_not_found
    PUSH SI
    PUSH CX
    MOV DI, stage2_name
    MOV CX, 11
.cmp_loop:
    LODSB
    MOV BL, [DI]
    INC DI
    CMP AL, BL
    JNE .cmp_mismatch
    DEC CX
    JNZ .cmp_loop
    POP CX
    POP SI
    JMP .found_stage2
.cmp_mismatch:
    POP CX
    POP SI
    ADD SI, 32                 ; Next 32-byte directory entry
    DEC CX
    JNZ .search_entry

.file_not_found:
    MOV SI, msg_not_found
    CALL print_string
    HLT

.found_stage2:
    ; Get STAGE2.BIN starting cluster: High 16 bits [SI+20], Low 16 bits [SI+26]
    MOV AX, [SI + 20]          ; Cluster High
    SHL EAX, 16
    MOV AX, [SI + 26]          ; Cluster Low
    MOV [current_cluster], EAX

    ; Load STAGE2.BIN clusters into 0x7E00
    MOV BX, 0x7E00

.load_chain:
    MOV EAX, [current_cluster]
    CMP EAX, 0x0FFFFFF8        ; EOF threshold
    JAE .stage2_loaded

    CALL read_cluster

    ; Advance destination memory pointer by (sectors_per_cluster * 512)
    MOVZX EAX, BYTE [sectors_per_cluster]
    SHL EAX, 9                 ; Multiply by 512
    ADD BX, AX

    ; Next cluster from FAT table
    MOV EAX, [current_cluster]
    CALL get_next_cluster
    MOV [current_cluster], EAX
    JMP .load_chain

.stage2_loaded:
    MOV DL, [drive_number]
    JMP 0x0000:0x7E00          ; Jump to Stage 2

; ── Helper Routines ──────────────────────────────────────────────────────────

; Reads cluster in EAX to ES:BX
read_cluster:
    PUSH EAX
    PUSH EBX

    ; Sector LBA = data_lba_start + (cluster - 2) * sectors_per_cluster
    SUB EAX, 2
    MOVZX ECX, BYTE [sectors_per_cluster]
    IMUL EAX, ECX
    ADD EAX, [data_lba_start]  ; EAX = Starting Sector LBA

    ; Read sectors_per_cluster sectors to ES:BX
    MOVZX CX, BYTE [sectors_per_cluster]
.read_loop:
    PUSH EAX
    PUSH CX
    PUSH BX

    MOV [dap_lba_low], EAX
    MOV [dap_buffer_off], BX
    MOV DL, [drive_number]
    MOV SI, dap_struct
    MOV AH, 0x42
    INT 0x13
    JC .read_err

    POP BX
    ADD BX, 512
    POP CX
    POP EAX
    INC EAX
    DEC CX
    JNZ .read_loop

    POP EBX
    POP EAX
    RET

.read_err:
    MOV SI, msg_disk_err
    CALL print_string
    HLT

; Given cluster in EAX, reads next cluster from FAT32 table into EAX
get_next_cluster:
    MOV EBX, EAX
    SHL EAX, 2                 ; Byte offset in FAT = cluster * 4
    MOV ECX, EAX
    SHR EAX, 9                 ; Sector index = byte offset / 512
    MOVZX EDX, WORD [reserved_sectors]
    ADD EAX, EDX
    ADD EAX, [hidden_sectors]  ; EAX = FAT sector LBA

    AND ECX, 511               ; Byte offset inside sector

    ; Read FAT sector to temporary buffer 0x0500
    PUSH ECX
    MOV [dap_lba_low], EAX
    MOV WORD [dap_buffer_off], 0x0500
    MOV DL, [drive_number]
    MOV SI, dap_struct
    MOV AH, 0x42
    INT 0x13
    JC .read_err
    POP ECX

    ; Read 32-bit FAT entry at 0x0500 + ECX
    MOV EAX, [0x0500 + ECX]
    AND EAX, 0x0FFFFFFF        ; Mask top 4 bits (FAT32 uses 28 bits)
    RET

print_string:
    LODSB
    OR AL, AL
    JZ .done
    MOV AH, 0x0E
    MOV BX, 0x0007
    INT 0x10
    JMP print_string
.done:
    RET

; ── Data Section ─────────────────────────────────────────────────────────────
data_lba_start:   DD 0
current_cluster:  DD 0
stage2_name:      DB "STAGE2  BIN"
msg_not_found:    DB "STAGE2.BIN not found!", 0
msg_disk_err:     DB "dr err!", 0

dap_struct:
dap_size:       DB 16
dap_reserved:   DB 0
dap_count:      DW 1
dap_buffer_off: DW 0x7E00
dap_buffer_seg: DW 0x0000
dap_lba_low:    DD 0
dap_lba_high:   DD 0

.org 0x7DFE
    DW 0xAA55

; boot/BOOT_MBR.AS — Master Boot Record (MBR) Stage 1 Boot Sector (512 bytes)
;
; Relocates itself from 0x7C00 to 0x0600.
; Scans 64-byte MBR partition table (at 0x0600 + 0x1BE) for active partition (flag 0x80).
; Uses BIOS INT 13h Extended Read (AH=42h LBA) to load partition VBR to 0x7C00.
; Jumps to 0x0000:0x7C00 passing boot drive in DL.
;
; Built with: AstraC asm BOOT_MBR.AS bits 16 org 7C00 arch i386

.org 0x7C00
.use16
.code

mbr_entry:
    CLI
    XOR AX, AX
    MOV DS, AX
    MOV ES, AX
    MOV SS, AX
    MOV SP, 0x7C00
    STI

    ; Relocate MBR code from 0x7C00 to 0x0600 (512 bytes)
    MOV SI, 0x7C00
    MOV DI, 0x0600
    MOV CX, 256
    CLD
.reloc_loop:
    MOVSW
    DEC CX
    JNZ .reloc_loop

    ; Jump to relocated code at 0x0600
    JMP 0x0000:.relocated

.relocated:
    MOV [boot_drive], DL   ; Save BIOS boot drive number (0x80 for HDD)

    ; Search Partition Table at 0x0600 + 0x01BE for Active Partition (0x80)
    MOV SI, 0x07BE         ; 0x0600 + 0x01BE
    MOV CX, 4

.check_partition:
    MOV AL, [SI]
    TEST AL, 0x80
    JNZ .found_active
    ADD SI, 16             ; Next 16-byte partition entry
    DEC CX
    JNZ .check_partition

    ; No active partition found -> Error
    MOV SI, msg_no_active
    CALL print_string
    HLT

.found_active:
    ; SI points to active partition entry
    ; Offset +8 contains 32-bit Starting LBA
    MOV EAX, [SI + 8]
    MOV [dap_lba_low], EAX

    ; Prepare BIOS INT 13h AH=42h Extended Read DAP (Disk Address Packet)
    ; DAP struct at 0x0600 + offset (dap_struct)
    MOV DL, [boot_drive]
    MOV SI, dap_struct
    MOV AH, 0x42
    INT 0x13
    JC .read_error

    ; Jump to VBR loaded at 0x0000:0x7C00
    MOV DL, [boot_drive]
    JMP 0x0000:0x7C00

.read_error:
    MOV SI, msg_read_err
    CALL print_string
    HLT

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
boot_drive:     DB 0x80
msg_no_active:  DB "MBR: No active partition", 13, 10, 0
msg_read_err:   DB "MBR: Read error", 13, 10, 0

; Disk Address Packet (DAP) for INT 13h AH=42h
dap_struct:
dap_size:       DB 16      ; DAP size
dap_reserved:   DB 0
dap_count:      DW 1       ; Read 1 sector
dap_buffer_off: DW 0x7C00  ; Destination Offset (0x7C00)
dap_buffer_seg: DW 0x0000  ; Destination Segment (0x0000)
dap_lba_low:    DD 0       ; LBA low 32 bits
dap_lba_high:   DD 0       ; LBA high 32 bits

; ── MBR Partition Table Placeholder at Offset 446 (0x1BE) ───────────────────
.org 0x7DBE
partition_table:
    DB 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 ; Entry 1
    DB 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 ; Entry 2
    DB 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 ; Entry 3
    DB 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 ; Entry 4

; Bootsector Signature
.org 0x7DFE
    DW 0xAA55

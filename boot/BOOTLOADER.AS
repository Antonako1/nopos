; boot/BOOTLOADER.AS — FAT12 boot sector (512 bytes)
;
; Loads STAGE2.BIN from a FAT12-formatted floppy into 0x7E00 and jumps to it.
;
; The floppy is formatted by build.sh with mtools (mformat -f 1440), so the
; BPB below must match the standard 1.44 MB FAT12 geometry exactly:
;
;   512 B/sector, 1 sector/cluster, 1 reserved sector, 2 FATs, 224 root
;   entries, 2880 total sectors, media 0xF0, 9 sectors/FAT, 18 sectors/track,
;   2 heads.
;
; Built with: AstraC asm BOOTLOADER.AS bits 16 org 7C00 arch i286

.org 0x7C00
.use16
.code

    ; 3-byte jump over the BPB: JMP SHORT main (0x3C) + NOP.
    ; `main` must remain at offset 62; if the BPB below changes size, update 0x3C.
    DB 0xEB, 0x3C, 0x90

; ── FAT12 BIOS Parameter Block (offsets 3..61) ──────────────────────────────
OEM:                    DB "NOPOS   "
bpb_bytes_per_sector:   DW 512
bpb_sectors_per_cluster:DB 1
bpb_reserved_sectors:   DW 1
bpb_num_fats:           DB 2
bpb_root_entries:       DW 224
bpb_total_sectors:      DW 2880
bpb_media:              DB 0xF0
bpb_sectors_per_fat:    DW 9
bpb_sectors_per_track:  DW 18
bpb_num_heads:          DW 2
bpb_hidden_sectors:     DD 0
bpb_total_sectors32:    DD 0
bpb_drive_number:       DB 0
bpb_reserved:           DB 0
bpb_boot_signature:     DB 0x29
bpb_volume_id:          DD 0x12345678
bpb_volume_label:       DB "NO NAME    "
bpb_fs_type:            DB "FAT12   "

main:
    CLI
    MOV [bpb_drive_number], DL   ; remember the boot drive

    ; Real-mode segments: DS=ES=SS=0, stack just below the boot sector.
    XOR AX, AX
    MOV DS, AX
    MOV ES, AX
    MOV SS, AX
    MOV SP, 0x7C00

    ; Load the FAT (9 sectors) into 0x0500.
    MOV AX, 1
    MOV CX, [bpb_sectors_per_fat]
    MOV BX, 0x0500
.load_fat:
    PUSH AX                      ; read_sector trashes AX and CX
    PUSH CX
    CALL read_sector
    POP CX
    POP AX
    INC AX
    ADD BX, 512
    LOOP .load_fat

    ; Load the root directory (14 sectors) into 0x7E00.
    MOV AX, 19                   ; root dir LBA = reserved(1) + FATs(2*9)
    MOV CX, 14                   ; 224 entries * 32 bytes / 512
    MOV BX, 0x7E00
.load_root:
    PUSH AX
    PUSH CX
    CALL read_sector
    POP CX
    POP AX
    INC AX
    ADD BX, 512
    LOOP .load_root

    ; Search the root directory for the 8.3 name "STAGE2  BIN".
    MOV CX, [bpb_root_entries]
    MOV BX, 0x7E00
.search:
    PUSH CX
    PUSH BX
    MOV SI, filename
    MOV DI, BX
    MOV CX, 11
.compare:
    MOV AL, [SI]
    CMP AL, [DI]
    JNE .next
    INC SI
    INC DI
    LOOP .compare
    POP BX                       ; matched: restore entry base
    POP CX
    JMP .found
.next:
    POP BX
    POP CX
    ADD BX, 32
    LOOP .search
    JMP error

.found:
    ; BX = directory entry; first cluster is at offset 26.
    MOV AX, [BX + 26]
    MOV BX, 0x7E00               ; load over the (now unused) root dir buffer
.load_file:
    CMP AX, 0x0FF8               ; end-of-chain marker?
    JAE .done
    PUSH AX
    ADD AX, 31                   ; LBA = 31 + cluster number
    CALL read_sector
    ADD BX, 512
    POP AX
    CALL next_cluster
    JMP .load_file

.done:
    MOV DL, [bpb_drive_number]
    JMP 0x0000:0x7E00

error:
    MOV SI, errmsg
    MOV AH, 0x0E
.loop:
    LODSB
    OR AL, AL
    JZ .hang
    INT 0x10
    JMP .loop
.hang:
    HLT
    JMP .hang

errmsg:  DB "ERR", 0
filename: DB "STAGE2  BIN"

; next_cluster: AX = cluster -> AX = next cluster (FAT was loaded at 0x0500).
next_cluster:
    MOV CX, AX                   ; CX = cluster (parity)
    MOV DX, AX
    SHR DX, 1
    ADD DX, AX                   ; DX = cluster * 3 / 2
    MOV SI, 0x0500
    ADD SI, DX
    MOV AX, [SI]                 ; 16-bit pair straddling the entry
    TEST CX, 1
    JNZ .odd
    AND AX, 0x0FFF
    RET
.odd:
    SHR AX, 4
    RET

; read_sector: AX = LBA, ES:BX = destination. Trashes AX, CX, DX.
read_sector:
    PUSH BX
    XOR DX, DX
    DIV WORD [bpb_sectors_per_track]   ; AX = LBA/spt, DX = LBA%spt
    MOV CX, DX
    INC CL                       ; CL = sector (1..18)
    XOR DX, DX
    DIV WORD [bpb_num_heads]          ; AX = cylinder, DX = head
    MOV CH, AL                   ; CH = cylinder (0..79, fits a floppy)
    MOV DH, DL                   ; DH = head
    MOV DL, [bpb_drive_number]
    MOV AX, 0x0201               ; AH=02 (read), AL=1 sector
    INT 0x13
    POP BX
    JC error
    RET

.times 510-($-$$) DB 0
DW 0xAA55

; boot/SECOND_STAGE.AS — second-stage loader
;
; Loads KERNEL.BIN from the FAT12 filesystem into 0x10000, enables the A20
; gate, switches to 32-bit protected mode, and jumps to the kernel.
;
; On entry DL still holds the boot drive (set by the boot sector). The BPB
; geometry below must match the FAT12 BPB in BOOTLOADER.AS.
;
; Built with: AstraC asm SECOND_STAGE.AS bits 16 org 7E00

.org 0x7E00
.use16
.code

main:
    MOV [drive], DL

    ; Real-mode segments: DS=ES=SS=0, stack just below the boot sector.
    XOR AX, AX
    MOV DS, AX
    MOV ES, AX
    MOV SS, AX
    MOV SP, 0x7C00

    ; Load the FAT (9 sectors) into 0x2100.
    MOV AX, 1
    MOV CX, [spf]
    MOV BX, 0x2100
.load_fat:
    PUSH AX                      ; read_sector trashes AX and CX
    PUSH CX
    CALL read_sector
    POP CX
    POP AX
    INC AX
    ADD BX, 512
    LOOP .load_fat

    ; Load the root directory (14 sectors) into 0x0500.
    MOV AX, 19                   ; root dir LBA = reserved(1) + FATs(2*9)
    MOV CX, 14
    MOV BX, 0x0500
.load_root:
    PUSH AX
    PUSH CX
    CALL read_sector
    POP CX
    POP AX
    INC AX
    ADD BX, 512
    LOOP .load_root

    ; Search the root directory for the 8.3 name "KERNEL  BIN".
    MOV CX, 224
    MOV BX, 0x0500
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
    MOV BX, 0x1000               ; load kernel at 0x1000:0x0000 (0x10000)
    MOV ES, BX
    XOR BX, BX
.load_file:
    CMP AX, 0x0FF8               ; end-of-chain marker?
    JAE .loaded
    PUSH AX
    ADD AX, 31                   ; LBA = 31 + cluster number
    CALL read_sector
    ADD BX, 512
    POP AX
    CALL next_cluster
    JMP .load_file

.loaded:
    CLI

    ; Enable the A20 gate via the system control port 0x92.
    IN 0x92
    OR AL, 0x02
    OUT 0x92

    ; Load the GDT.
    LGDT [gdt_desc]

    ; Set PE (protected mode enable) in CR0.
    ; CR0 moves are hand-encoded: the assembler mis-encodes EAX in .use16.
    DB 0x0F, 0x20, 0xC0     ; MOV EAX, CR0
    DB 0x83, 0xC8, 0x01     ; OR  EAX, 1
    DB 0x0F, 0x22, 0xC0     ; MOV CR0, EAX

    ; Far jump to flush the prefetch queue and load a 32-bit code segment.
    DB 0xEA                 ; JMP FAR
    DW pm_entry             ; offset (pm_entry lives below 64 KiB)
    DW 0x08                 ; code segment selector

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

errmsg:  DB "SE", 0
filename: DB "KERNEL  BIN"

drive: DB 0
spf:   DW 9
spt:   DW 18
heads: DW 2

; next_cluster: AX = cluster -> AX = next cluster (FAT was loaded at 0x2100).
next_cluster:
    MOV CX, AX                   ; CX = cluster (parity)
    MOV DX, AX
    SHR DX, 1
    ADD DX, AX                   ; DX = cluster * 3 / 2
    MOV SI, 0x2100
    ADD SI, DX
    MOV AX, [SI]
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
    DIV WORD [spt]               ; AX = LBA/spt, DX = LBA%spt
    MOV CX, DX
    INC CL                       ; CL = sector (1..18)
    XOR DX, DX
    DIV WORD [heads]             ; AX = cylinder, DX = head
    MOV CH, AL
    MOV DH, DL
    MOV DL, [drive]
    MOV AX, 0x0201               ; AH=02 (read), AL=1 sector
    INT 0x13
    POP BX
    JC error
    RET

; ── GDT (flat 4 GiB segments; descriptors hand-encoded as DB) ──────────────
gdt_start:
    DB 0, 0, 0, 0, 0, 0, 0, 0       ; null descriptor
    DB 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x9A, 0xCF, 0x00  ; code (ring 0, 32-bit)
    DB 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00  ; data (ring 0, 32-bit)
gdt_end:

gdt_desc:
    DW gdt_end - gdt_start - 1       ; limit
    DD gdt_start                     ; base

; ── 32-bit entry ────────────────────────────────────────────────────────────
.use32
pm_entry:
    MOV AX, 0x10        ; data segment selector
    MOV DS, AX
    MOV ES, AX
    MOV FS, AX
    MOV GS, AX
    MOV SS, AX
    MOV ESP, 0x90000    ; stack at 576 KiB

    ; Jump to the kernel (register-indirect to avoid a relative-offset bug).
    MOV EAX, 0x10000
    JMP EAX

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

#define SVGA_TARGET_MODE 0x105   ; 1024x768x8 (256 colors)
#define SVGA_ON

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

    ; Advance destination ES segment by 0x20 (512 bytes)
    MOV DX, ES
    ADD DX, 0x0020
    MOV ES, DX

    POP AX
    CALL next_cluster
    JMP .load_file

.loaded:
    ; Gather the BIOS E820 memory map before switching to protected mode.
    CALL gather_e820

    ; Detect VBE, query the target mode, and set it.
    #ifdef SVGA_ON
    CALL init_svga
    #endif

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

; gather_e820: Query the BIOS E820 memory map and fill kernel_table.
;   INT 15h, AX=0xE820. Each 20-byte entry is written to ES:DI; the entry
;   count is stored in e820cnt. Trashes AX, BX, CX, DX, DI, BP.
gather_e820:
    XOR AX, AX
    MOV ES, AX                  ; ES = 0
    MOV DI, kernel_table        ; ES:DI = first E820_ENTRY
    XOR BP, BP                  ; entry counter
    XOR EBX, EBX                ; continuation value (0 = start)
.e820_next:
    MOV EAX, 0xE820
    MOV EDX, 0x534D4150         ; 'SMAP'
    MOV ECX, 20                 ; E820_ENTRY size (no ACPI 3.0 fields)
    INT 0x15
    JC .e820_done               ; error / E820 unsupported
    CMP EAX, 0x534D4150         ; BIOS must echo 'SMAP'
    JNE .e820_done
    ADD DI, 20                  ; entry written; advance to next slot
    INC BP
    CMP BP, 32                  ; cap at E820_MAX_ENTRIES
    JAE .e820_done
    TEST EBX, EBX               ; EBX == 0 => last entry
    JNZ .e820_next
.e820_done:
    MOV [e820cnt], BP           ; store count (high word stays zero)
    RET

; init_svga: Detect VBE, query mode info for SVGA_TARGET_MODE, and set it.
;   Fills vesa_table (VESA_INFO) and vbe_table (VBE_MODE_INFO). Trashes
;   AX, BX, CX, DI, ES. Does nothing if VBE is unsupported.
init_svga:
    XOR AX, AX
    MOV ES, AX

    ; Get VBE controller information (INT 10h AX=4F00).
    MOV AX, 0x4F00
    MOV DI, vesa_table
    INT 0x10
    CMP AX, 0x004F              ; AL=4F (supported) and AH=0 (success)
    JNE .done

    ; Get VBE mode information for the target mode (INT 10h AX=4F01).
    MOV AX, 0x4F01
    MOV CX, SVGA_TARGET_MODE
    MOV DI, vbe_table
    INT 0x10
    CMP AX, 0x004F
    JNE .done

    ; Set the video mode (INT 10h AX=4F02). Bit 14 requests a linear
    ; framebuffer so VBE reports a physical base address in PhysBasePtr.
    MOV AX, 0x4F02
    MOV BX, SVGA_TARGET_MODE
    OR  BX, 0x4000
    INT 0x10
    CMP AX, 0x004F
    JNE .done
.done:
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

    ; Pass the KERNEL_TABLE* as the first argument to the kernel's _start().
    MOV EAX, kernel_table
    PUSH EAX

    ; Enter the kernel (register-indirect to avoid a relative-offset bug).
    MOV EAX, 0x10000
    CALL EAX

.data
; KERNEL_TABLE passed to the kernel. Layout must match kernel/kernel.ah:
;     E820_ENTRY    e820entries[E820_MAX_ENTRIES];  // 32 * 20 = 640 bytes
;     U32           e820cnt;                          // 4 bytes
;     VESA_INFO     vesa_info;                        // 512 bytes
;     VBE_MODE_INFO vbe_mode_info;                    // 256 bytes
kernel_table:
    .times 640 DB 0             ; 32 E820_ENTRY slots (20 bytes each)
e820cnt: DD 0
vesa_table:
    .times 512 DB 0             ; VESA_INFO (VBE controller info)
vbe_table:
    .times 256 DB 0             ; VBE_MODE_INFO (mode info)
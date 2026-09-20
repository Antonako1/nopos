; boot/SECOND_STAGE.AS — Second-stage loader
;
; Loads KERNEL from floppy sectors 10-18 (LBA 9-17) into 0x10000, enables the
; A20 gate, switches to 32-bit protected mode, and jumps to the kernel.
;
; Built with: AstraC asm SECOND_STAGE.AS bits 16 org 7E00
.org 0x7E00
.use16
.code
main:
    
    ; Read KERNEL: CHS 0/0/10 (sector 10), 9 sectors -> 0x1000:0x0000 (0x10000)
    MOV AX, 0x1000      ; ES = 0x1000
    MOV ES, AX
    XOR BX, BX          ; ES:BX = 0x10000
    MOV CX, 0x000A      ; CH=0 (cylinder 0), CL=10 (sector 10)
    XOR DX, DX          ; DH=0 (head 0), DL=0 (drive A:)
    MOV AX, 0x0209      ; AH=0x02 (read sectors), AL=9 (sector count)
    INT 0x13
    JC error

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
    MOV SI, err_msg
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

err_msg DB "SE", 0

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

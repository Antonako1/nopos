; boot/BOOTLOADER.AS — First-stage bootloader (512-byte bootsector)
;
; Loads SECOND_STAGE from floppy sectors 2-9 (LBA 1-8) into 0x7E00 and jumps
; to it. Runs in 16-bit real mode (CHS reads via INT 0x13).
;
; Built with: AstraC asm BOOTLOADER.AS bits 16 org 7C00 arch i286
.org 0x7C00
.use16
.code
main:
    CLI
    JMP start

start:
    ; Real-mode segments: CS=DS=ES=SS=0, stack just below the bootsector.
    XOR AX, AX
    MOV DS, AX
    MOV ES, AX
    MOV SS, AX
    MOV SP, 0x7C00
    

    ; Read SECOND_STAGE: CHS 0/0/2 (sector 2), 8 sectors -> 0x0000:0x7E00
    MOV BX, 0x7E00      ; ES:BX = 0x0000:0x7E00
    MOV CX, 0x0002      ; CH=0 (cylinder 0), CL=2 (sector 2)
    MOV DH, 0           ; DH=0 (head 0), leave DL untouched!
    MOV AX, 0x0208      ; AH=0x02 (read sectors), AL=8 (sector count)
    INT 0x13
    JC error

    ; Hand control to the second stage.
    JMP 0x0000:0x7E00

error:
    MOV SI, err_msg
    MOV AH, 0x0E        ; teletype output
.loop:
    LODSB
    OR AL, AL
    JZ .hang
    INT 0x10
    JMP .loop
.hang:
    HLT
    JMP .hang

err_msg DB "ERR", 0

; Pad to 510 bytes and append the boot signature 0xAA55.
.times 510-($-$$) DB 0
DW 0xAA55

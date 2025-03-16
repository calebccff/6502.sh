    processor 6502

    SEG
    ORG $0;ROM_BASE; ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $BB ; A register
    .byte $0A ; X register
    .byte $00 ; Y register
    .byte $E5 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$57 ; Program Counter

; 8-bit Fibonacci sequence generator
; TODO: Add 16-bit support :D
Reset
    LDA #$00
    JSR OUTNUM ; Print A
    STA $00 ; Make sure address $00 is zero
    LDA #$01 ; Load the value VAL_A into the accumulator
LoopForever
    STA $01  ; Store A in zero page address 0
    JSR OUTNUM ; Print A
    ADC $00  ; Add value in address $00
    BCS AddWrapped
    STA $02  ; Store result in address $02
    JSR OUTNUM
    ADC $01  ; Add value in addres $01
    BCS AddWrapped
    STA $00  ; Store result in $00
    JSR OUTNUM ; Print A
    ADC $02  ; Add value in $02
    BCS AddWrapped
    JMP LoopForever ; Jump back to the LoopForever label

OUTNUM:
    PHA
    JSR OUTHEX
    LDX #$0A
    STX $8400
    PLA
    RTS
OUTHEX:
    PHA ; Save fow lower nibble
    LSR ; Shift upper nibble down
    LSR
    LSR
    LSR
    JSR OUTLOWER
    PLA

OUTLOWER:   ; Output lower nibble
    AND #$0F ; Lower nibble
    ORA #$30 ; Map to ASCII
    CMP #$3A ; Digit?
    BCC OUTB
    ADC #$06 ; Offset to hex
OUTB:
    STA $8400
    RTS


AddWrapped
    LDA #$BB
    STA $8010 ; ASSERT (test over)

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector


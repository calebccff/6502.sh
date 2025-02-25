    processor 6502

    SEG
    ORG $0;ROM_BASE; ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $80 ; A register
    .byte $80 ; X register
    .byte $40 ; Y register
    .byte $27 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$1E ; Program Counter

Reset
    LDX #$80
    STX $00
    CPX $00
    CPX #$7F
    LDA #$80
    CMP $00
    CMP #$00
    LDY #$40
    CPY #$40
    STA $4010

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector


    processor 6502

    SEG
    ORG $0;ROM_BASE;    ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $66 ; A register
    .byte $FD ; X register
    .byte $42 ; Y register
    .byte $24 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$11 ; Program Counter

Reset
    JSR Sub
    LDY #$42
    STX $8010

    ORG Reset+$40
Sub
    LDA #$66
    TSX
    RTS

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector

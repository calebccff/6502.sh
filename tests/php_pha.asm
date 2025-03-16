    processor 6502

    SEG
    ORG $0;ROM_BASE;    ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $FE ; A register
    .byte $FD ; X register
    .byte $A5 ; Y register
    .byte $A4 ; P (status) register
    .byte $FD ; Stack pointer
    .word $0;ROM_BASE;+$18 ; Program Counter

Reset
    LDA #$A5
    SED
    PHP
    TSX
    PHA
    TXA
    TSX
    CLD
    LDY $1FE
    STA $8010

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector

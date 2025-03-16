    processor 6502

    SEG
    ORG $0;ROM_BASE;    ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $02 ; A register
    .byte $02 ; X register
    .byte $3A ; Y register
    .byte $24 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$1C ; Program Counter

Reset
    LDY #$3A
    STY $101
    LDX #$02
    STX $102
    LDA $101
    AND $100,X
    STA $8010


    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector

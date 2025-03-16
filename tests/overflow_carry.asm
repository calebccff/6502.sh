    processor 6502

    SEG
    ORG $0;ROM_BASE; ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $60 ; A register
    .byte $D0 ; X register
    .byte $00 ; Y register
    .byte $65 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$11 ; Program Counter

Reset
    LDA #$D0 ; Load the value $D0 into the accumulator
    TAX
    ADC #$90 ; Add the value $90
             ; this should set the overflow flag
    STA $8010

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector

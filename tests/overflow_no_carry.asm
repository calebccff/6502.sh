    processor 6502

    SEG
    ORG $0;ROM_BASE; ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $A0 ; A register
    .byte $00 ; X register
    .byte $50 ; Y register
    .byte $E4 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$11 ; Program Counter

Reset
    LDA #$50 ; Load the value $50 into the accumulator
    TAY
    ADC #$50 ; Add the value $50
             ;this should set the overflow and carry flags
    STA $8010

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector

    processor 6502

    SEG
    ORG $0;ROM_BASE; ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $5A ; A register
    .byte $5A ; X register
    .byte $5A ; Y register
    .byte $24 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$17 ; Program Counter

Reset
    LDA #$5A
    STA $0155
    LDX $0155 ; Load value at 0x0155 into X
    LDY $0155 ; Load value at 0x0155 into Y
    STX $4010

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector

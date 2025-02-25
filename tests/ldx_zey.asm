    processor 6502

    SEG
    ORG $0;ROM_BASE; ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $07 ; A register
    .byte $07 ; X register
    .byte $04 ; Y register
    .byte $24 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$14 ; Program Counter

Reset
    LDA #$07
    STA $17  ; store 7 at 0x17
    LDY #$4  ; load 4 into Y
    LDX $13,Y ; Load X from 0x13 + Y (0x13 + 0x04) = 0x17
    STX $4010

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector

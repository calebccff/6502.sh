    processor 6502

    SEG
    ORG $0;ROM_BASE;    ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $66 ; A register
    .byte $80 ; X register
    .byte $00 ; Y register
    .byte $65 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$1E ; Program Counter

Reset
    LDX #$80
    STX $00
    LDA #$80
    ADC $00 ; Add value in 0x00 to A, result should be 0x100, setting zero and carry flags
    BEQ Success
    CLC
    LDA #$5A
    sta $4010 ; ASSERT
Success
    LDA #$66 ; Carry flag should still be set
    STA $4010 ; ASSERT

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector


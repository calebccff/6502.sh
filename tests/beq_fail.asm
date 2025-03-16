    processor 6502

    SEG
    ORG $0;ROM_BASE;    ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $41 ; A register
    .byte $81 ; X register
    .byte $00 ; Y register
    .byte $64 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$19 ; Program Counter

Reset
    LDX #$81 ; 0x81 + 0x80 = 0x101 so zero flag won't be set and we won't branch
    STX $00
    LDA #$80
    ADC $00 ; Add value in 0x00 to A, result should be 0x100, setting zero and carry flags
    BEQ Fail ; shouldn't branch
    CLC
    LDA #$41
    STA $8010
Fail
    LDA #$66 ; Carry flag should still be set
    STA $8010

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector


    processor 6502

    SEG
    ORG $0;ROM_BASE;    ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $00 ; A register
    .byte $00 ; X register
    .byte $42 ; Y register
    .byte $61 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$14 ; Program Counter

Reset
    CLI
    LDA #$90
    ADC #$D0 ; Cause the overflow and carry bits to be set
             ; so we can track it across the BRK/RTI
    BRK
    LDY #$42
    STA $4010

    ; Put the interrupt routine higher up so we can't just slide into it
    ORG Reset+$40
Int
    LDA #$01
    AND #$02
    BVC Failed ; Overflow bit should still be set
    BNE Failed ; We just set the zero flag (implicitly with LDA/AND)
    RTI

Failed ; ASSERT with invalid machine state = fail
    STA $4010

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Int ; And the IRQ/BRK vector

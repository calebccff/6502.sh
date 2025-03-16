    processor 6502

    SEG
    ORG $0;ROM_BASE;    ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $BB ; A register
    .byte $BB ; X register
    .byte $36 ; Y register
    .byte $27 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$24 ; Program Counter

Reset
    LDY #$36     ; Load 0x36 into Y
    LDX #$BB     ; Load 0xBB into X
    STX $013A    ; Store X in 0x013A
    LDA #$04     ; Load 0x04 into A
    STA $A4      ; Store A in 0xA4 (LSB)
    LDA #$01     ; Load 0x01 into A
    STA $A5      ; Store A in 0xA5 (MSB)
    LDA ($A4),Y  ; Load A from the address where the LSB is the value of address $A4, + Y
        ; and the MSB is the value of address $(A4 + 1) + the carry from the previous add.

    CMP #$BB
    BEQ Pass
    STA $8010 ; ASSERT if value doesn't match (test failed)
Pass
    STA $8010

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector

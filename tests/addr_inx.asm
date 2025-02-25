    processor 6502

    SEG
    ORG $0;ROM_BASE;    ; Cartridge address

Expected ; Expected machine state at end of test
    .word $0F0F ; Indicate that this is a test ROM
    .byte $BB ; A register
    .byte $E9 ; X register
    .byte $BB ; Y register
    .byte $27 ; P (status) register
    .byte $FF ; Stack pointer
    .word $0;ROM_BASE;+$24 ; Program Counter

Reset
    LDX #$E9     ; Load 0xE9 into X
    LDY #$BB     ; Load 0xBB into Y
    STY $100     ; Store Y in 0x100
    LDA #$00     ; Load 0x04 into A
    STA $3A      ; Store A in 0x3A (LSB)
    LDA #$01     ; Load 0x01 into A
    STA $3B      ; Store A in 0x3B (MSB)
    LDA ($51,X)  ; Load A from zero page address sum of 0x51 + X (0x51 + 0xE9)
    ; The sum is 0x13A but it wraps at 0xFF so becomes 0x3A which is address of
    ; LSB of target address, 0x3A and 0x3B are read to get the value (0xBB) and
    ; it is stored in A

    CMP #$BB
    BEQ Pass
    STA $4010 ; ASSERT if value doesn't match (test failed)
Pass
    STA $4010 ; ASSERT test passed

    ORG $0;NMI_VECTOR; ; Address of section

        ; Store the 16-bit address of the Reset label
        ; to be jumped to when any of these vectors occur
        ; This address is usually mapped to cartridge ROM in the NES
    .word Reset ; in the NMI vector
    .word Reset ; The Reset Vector
    .word Reset ; And the IRQ/BRK vector


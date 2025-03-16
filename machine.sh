# 6502 Machine definition

SZ_1K=1024

# Address where ROMs are loaded
ROM_BASE=$((0xC000))
ROM_SIZE=$((0x4000))

# Total address space in the machine (RAM + ROM, excluding MMIO)
RAM_SIZE=$((32*SZ_1K)) #$((2048*SZ_1K))

# For functional test
#
# Do `set pc 400` after loading bin
# ROM_BASE=$((0x0))
# ROM_SIZE=$((0x10000))

# RAM_SIZE=$((0))

NMI_VECTOR=$((ROM_BASE+ROM_SIZE-6))
RESET_VECTOR=$((ROM_BASE+ROM_SIZE-4))
IRQ_VECTOR=$((ROM_BASE+ROM_SIZE-2))

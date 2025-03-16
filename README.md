# ./6502.sh

6502.sh is a fully-functional 6502 emulator and debugger written in [busybox
ash](https://linux.die.net/man/1/ash) compliant shell script, using only a
handful of busybox tools.

## Features

6502.sh has a whopping 32k of RAM and 16k ROM in its default configuration,
however this can be easily adjusted by editing [`machine.sh`](/machine.sh).

It includes an interactive debugger with single-stepping, breakpoints (break on
code, data access, JSR/RTS), and more. See [#Debugger](#debugger) for detailed
instructions.

STDIO is directed to an ACIA compatible serial port at `$8400` allowing for
programs like BASIC to run.

Launching with the `-d` flag will make 6502.sh output additional info about the
instructions being executed to a socket (`/tmp/65sh.sock`). You can watch this
log by running [`./watch.sh`](/watch.sh).

## Requirements

The dasm compiler is required for building wozmon and the unit tests. cc65 is
required for BASIC.

## Usage

```shell
$ ./6502.sh ./progs/basic/basic.bin
Loading ./progs/basic/basic.bin...
Reset vector: $E836

6502 EhBASIC [C]old/[W]arm ? c

Memory size ? 32768

31999 Bytes free

Enhanced BASIC 2.22p5

Ready
10 PRINT "HI FROM 6502.SH"
20 GOTO 10
RUN
HI FROM 6502.SH
HI FROM 6502.SH
HI FROM 6502.SH
HI FROM 6502.SH
> Dropping into debug monitor
Status: $36
    negative : 0
    overflow : 0
    constant : 1
    break    : 1
    decimal  : 0
    interrupt: 1
    zero     : 1
    carry    : 0
Registers:
    A : $00
    X : $DF
    Y : $02
    SP: $FF
    PC: $C4C3
Ran 31204 instructions
65sh> 

```

Unit tests can be run with [`test.sh`](/test.sh), they live in the tests
subdirectory.

Some example programs can be found in [`progs`](/progs/):

* wozmon - A port of the Apple I monitor
* basic - Enhanced BASIC port (compile with `make`, cc65 is required)

Any DASM compatible assembly can be built with `./build.sh path/to/source.asm`,
the resulting binary is placed in `build/`, e.g.

```shell
$ ./build.sh progs/wozmon.asm

Complete. (0)
```

## TODO

* Emulate more hardware? Disk?
* Plugin system for hardware modules
* Performance optimisations (JIT to shell?)

### Serial port

An ACIA compatible serial port is emulated. Tx delay loops are NOT recommended
here as they only serve to slow the emulator down.

For each opcode executed, the emulator checks for input on stdin and buffers a
single character that can be read from `$8400` by the emulated program. Output
is available by writing a character to the same address. You can check if a
character is pending by reading `$8401` and checking bit 3 (value `$08`).

### Additional registers

| Address | Name      | R/W | Description |
|---------|-----------|-----|-------------|
| `$8010` | ASSERT    |  WO | Writes will trigger a test assert. This is used for unit tests which describe the expected state of the machine at the start of the test ROM. |
| `$8040` | HALT      |  WO | Writes will halt execution and drop to the debugger. |

### Trap

Writes of any value to `$8040` act as a trap or breakpoint and cause the
emulator to pause execution and drop to the monitor (described below).

Alternatively, executing any branching instruction that sets the program counter
to point to itself (causing an infinite loop) will also cause a trap.

Finally, pressing the backtick key (`\``) will always cause the emulator to
trap.

In call cases the emulator will drop to the debugger `65sh>`.

### Debugger

6502.sh includes a built-in monitor/debugger which you can drop to by pressing
the `backtick` '\`' key on your keyboard or via a trap in the program (described
above). You can also halt before execution by launching *6502.sh* with the `-d`
flag.

> **NOTE:** Unlike in GDB, ctrl+c will cause the emulator to exit rather than
> trap into the debugger.

```txt
Loading ./build/fibonacci.bin...
Reset vector: $8009
Registers:
    A : $00
    X : $00
    Y : $00
    PC: $8009
Ran 0 instructions
65sh> 
```

#### Debug socket

Run with the `-d` flag to enable the debug socket, and run `./watch.sh` in a
separate terminal. This will output the fetch/decode/execute internals of the
CPU.

The format is `PC: opcode | addressing mode | instruction <arguments>`.

```txt
C90B: $20 | ABS $E0FC       | JSR $E0FC
E0FC: $6C | IND (=$207 )    | JMP $E865
E865: $48 | IMP             | PHA (SP=$1F9)
E866: $AD | ABS $8401       | LDA $8401 <- $00
E869: $68 | IMP             | PLA (A=$39 SP=$1F9)
E86A: $8D | ABS $8400       | STA $8400 <- $39
E86D: $60 | IMP             | RTS $C90E
C90E: $C9 | IMM $C90F       | CMP $39 $0D = $2C
C910: $D0 | REL $C911       | BNE (Z=0) $14 (20)
C926: $29 | IMM $C927       | AND $FF
C928: $60 | IMP             | RTS $C8E4
C8E4: $C8 | IMP             | INY $04
C8E5: $CA | IMP             | DEX $01
C8E6: $D0 | REL $C8E7       | BNE (Z=0) $F7 (-9)
C8DF: $B1 | (71),4  = $7FFF | LDA $7FFF <- $39
C8E1: $20 | ABS $C8EE       | JSR $C8EE
C8EE: $C9 | IMM $C8EF       | CMP $39 $20 = $19
C8F0: $90 | REL $C8F1       | BCC (C=1) $19 (25)
C8F2: $48 | IMP             | PHA (SP=$1FB)
C8F3: $A5 | ZER $F          | LDA $F    <- $00
C8F5: $D0 | REL $C8F6       | BNE (Z=1) $0A (10)
C8F7: $A5 | ZER $E          | LDA $E    <- $04
```

The debug monitor uses a GDB-like syntax, the most useful commands are:

* `dt` - toggle debug output
* `p` - dump CPU registers
* `c` - continue execution
* `s` - step a single instruction
* `b`, `del ID` - add and remove breakpoints (note that the PC must be set to
  the address in question for the breakpoint to be hit).
* `bmem`, `del mem ID` - add/remove breakpoints based on memory access.

#### Logging/self-debug

These commands configure logging or help debug the emulator itself.

* `v` - enable verbose mode (`set -x`)
* `d [CATEGORIES]` - list available debug categories (no args), or set debug
  categories.
* `dt` - toggle standard debug output on/off (standard categories are `INSTR`,
  `ADDR`, `OPCODE`)

#### Breakpoints

These commands manipulate breakpoints.

* `b ADDR` - break just before the instruction at `ADDR` is executed
* `bmem ADDR` - break immediately after any read or write to `ADDR`
* `del [mem] ID` - remove breakpoint with number `ID` (or memory breakpoint
  `ID`).
* * `i`, `info` - list breakpoints

#### Machine state

These commands allow for viewing or manipulating the machine state.

* `p [VAR]` - print all CPU registers or a specific one (printed as hex)
* `echo VAR` - `echo`
* `set VAR VAL` - set a variable (this can be any global, usually `pc`, `a`,
  `x`, `y`, `s` - program counter, CPU registers, stack pointer, etc)
* `ps` - print status flags
* `stack` - show info about the stack and stack pointer
* `c` - continue execution

These are the available global variables (that are useful to modify), though you
may find joy in manipulating some of the others:

* `pc` - Program counter
* `s` - Stack pointer
* `a`, `x`, `y` - CPU registers
* `p` - status register (note that there are also variables for accessing the
  individual status flags, are kept in sync with the status register and it's
  recommended to treat them as read-only. The uppercase variants are bitmasks).

#### Debug categories

* INSTR - print info about the running instruction
* MEM - show memory accesses
* ADDR - show addressing modes / address decoding
* OPCODE - show opcodes
* STATUS - show changes to status bits

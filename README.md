# ./6502.sh

6502.sh is a mostly-functional 6502 emulator and debugger written in [busybox
ash](https://linux.die.net/man/1/ash) compliant shell script, using only a
handful of busybox tools for ROM loading, etc.

## Specs

6502.sh has a whopping 2k of RAM and 32k ROM in its default configuration,
however this can be easily adjusted by editing [`machine.sh`](/machine.sh).

## Features

### Serial port

An ACIA compatible serial port is emulated. Tx delay loops are NOT recommended
here as they only serve to slow the emulator down.

For each opcode executed, the emulator checks for input on stdin and buffers a
single character that can be read from `$5000` by the emulated program. Output
is available by writing a character to the same address. You can check if a
character is pending by reading `$5001` and checking bit 3 (value `$08`).

### Trap

Writes of any value to `$4040` act as a trap or breakpoint and cause the
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

Launching with the `-d` flag will also redirect debug logs to a socket (usually
`/tmp/65sh.sock`), this makes it possible to interact with the emulator while
logging each instruction executed. You can watch this log with a simple
one-liner like `while true; do cat /tmp/65sh.sock 2>/dev/null; sleep 0.1; done`
or execute [`./watch.sh`](/watch.sh).

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

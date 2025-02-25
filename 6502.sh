#!/bin/sh -e
#
# 6502 emulator in busybox ash
#

trap 'exec 3>&-; rm /tmp/65sh.sock' EXIT
# Kill the loading subshell
trap 'touch /tmp/65sh.connected; exit $?' INT

exec 3>&2

BASEDIR=$(dirname $0)

. $BASEDIR/machine.sh

# Debugger variables
EXITCODE=0
DO_TRAP=0
SINGLE_STEP=0
BREAKPOINTS=
# break on write to address
BREAKPOINTS_WRITE=
IN_SUBROUTINE=0
# Halt when next returning from a subroutine
BREAK_ON_RTS=0
BREAK_ON_JSR=0
VERBOSE=0

# Available debug categories
DEBUG_CATEGORIES="INSTR, MEM, ADDR, OPCODE, STATUS"
# Default categories (provides most readable output)
# NOTE: the leading/trailing comma simplify manipulating and checking
# the debug categories, they are required.
DEBUG_DEFAULT=",INSTR,ADDR,OPCODE,"
# Initialise debug mask
DEBUG=""
# Must be comma separated with comma at the start and end!
# DEBUG=",instr," # ,INSTR,MEM,ADDR,OPCODE,STATUS,
# DEBUG=",ADDR,INSTR,OPCODE,"

# Spinner go spinny
LOAD_ANIMATION="|/-\\"

# Debug mode
if [ "$1" = "-d" ]; then
	shift
	DO_TRAP=1
	DEBUG="$DEBUG_DEFAULT"

	[[ -e /tmp/65sh.sock ]] || mknod /tmp/65sh.sock p
	[[ -e /tmp/65sh.connected ]] && rm /tmp/65sh.connected || :
	# The exec to redirect to the FIFO will hang until something connects
	# to the other side, tell the user what to do and draw a lil animation
	# to let them know we're waiting.
	{
	wait_count=0
	sleep 0.2
	# Wait for the flag to be created, or die if our parent process does
	# PPID doesn't actually refer to the shell we're a subshell of, hence the INT
	# trap at the top
	while ! [ -e "/tmp/65sh.connected" ] && [ -d /proc/$PPID ]; do
		if [ $wait_count -eq 0 ]; then
			printf 'Waiting for connection to /tmp/65sh.sock\n'
			printf 'Please run ./watch.sh in another terminal or just cat /tmp/65sh.sock   '
		fi
		printf '\b\b%s ' ${LOAD_ANIMATION:$((wait_count%4)):1}
		wait_count=$((wait_count+1))
		sleep 0.5
	done
	} &
	exec 3>/tmp/65sh.sock
	touch /tmp/65sh.connected
	# Clean up
	printf '\b\b  \n'
fi

error() {
	local fmt
	fmt="$1"
	shift
	printf "$fmt" $@ >&2

	{
	dump_registers
	dump_status
	} >&2
	EXITCODE=1
	DO_TRAP=1
	return 0
}

debug() {
	if ! [[ "$DEBUG" =~ ",$1," ]]; then return; fi
	local mask fmt
	mask="$1"
	fmt=$2
	shift 2
	printf "$fmt" $@ >&3
}

a=0
x=0
y=0
s=$((0xff))
pc=0x0
p=0x24 # 0b00100100 -- IRQ disable, B flag

# Total instructions run
instr_count=0
# Max stack depth reached
stack_max_depth=0

# Input buffer
nextchar=""
# Last command run by the debug monitor, this is run
# if you just press enter at the prompt with no input.
# Useful for single-stepping
mon_last_input="c"

# store the status register as separate variables
# for ease of access. These are kept in sync with
# the update_status() function in the rare case
# they are written to
 negative=0
 overflow=0
constant=1
    break=0
  decimal=0
interrupt=1
     zero=0
    carry=0

 NEGATIVE=0x80 # 128
 OVERFLOW=0x40 # 64
 CONSTANT=0x20 # 32
    BREAK=0x10 # 16
  DECIMAL=0x08
INTERRUPT=0x04
     ZERO=0x02
    CARRY=0x01

# 7  bit  0
# ---- ----
# NVss DIZC
# |||| ||||
# |||| |||+- Carry
# |||| ||+-- Zero
# |||| |+--- Interrupt Disable
# |||| +---- Decimal
# ||++------ No CPU effect, see: the B flag
# |+-------- Overflow
# +--------- Negative

# RAM/ROM is a space separated array of numbers 0-255. Decimal is used over
# hex since that is the "native" representation of shell.
# NOTE: This is a rare case where a subshell is more efficient, if RAM_SIZE
# is 16k then we would need a FOR loop that runs 16384 times and that becomes
# quite noticeable in shell.
heap="$(yes 000 | head -${RAM_SIZE} | tr '\n' ' ')"

# Loaded by loadbin()
rom=""

memset_impl_cut() {
	# Set memory in heap
	# $1: "heap" or "rom"
	# $2: dest addr (relative to ram/rom base)
	# $3: value
	# $4: count
	debug MEM 'memset $%02X, $%02X, $%02X\n' "$2" "$3" "$4"
	local dest value count first last i max cmd
	# Convert hex literals to "numbers"
	dest=$2
	value=$(($3))
	count=$(($4))

	case $1 in
	heap)
		max=$RAM_SIZE
		;;
	rom)
		max=$ROM_SIZE
		;;
	*)
		error "Memset called for unknown memory area: %s\n" "$1"
		return 1
		;;
	esac

	if [ $((dest+count)) -gt $max ]; then
		error "memset failed! $@\n"
		return 1
	fi

	# Split the heap into everything before and after the bytes we want to set

	# Start slice
	cmd=""
	# handle the fact that cut counts from 1 and MUST produce output
	# Print everything up until the memory we're writing to
	if [ $((dest)) -gt 0 ]; then
		cmd="printf \"%s \" \$$1 | cut -z -d' ' -f1-$((dest));"
	fi

	# printf the new middle values.
	# Note the load-bearing space
	cmd="$cmd printf '"
	i=count
	until [ $((i--)) -eq 0 ]; do
		cmd="$cmd $value"
	done
	# Note the load-boearing space
	cmd="$cmd ';"

	# Get the end slice if there is one, deal with awkward offsets again
	if [ $((dest+count+1)) -lt $max ]; then
		cmd="$cmd printf \"%s \" \$$1 | cut -z -d' ' -f$((dest+count+1))-$max"
	fi

	# set -x
	eval "set +x; $1=\$($cmd)"
}

## Even newer/faster, avoids more(?) subshell
memset_impl() {
	# Set memory in heap
	# $1: "heap" or "rom"
	# $2: dest addr (relative to ram/rom base)
	# $3: value
	# $4: count
	debug MEM 'memset $%02X, $%02X, $%02X\n' "$2" "$3" "$4"
	local dest value count first last i max cmd
	# Convert hex literals to "numbers"
	dest=$2
	# Ensure $value has the format %03d by pre-pending zeros
	# and taking the last 3 digits
	value="00$(($3))"
	value=${value: -3}
	count=$(($4))

	case $1 in
	heap)
		max=$RAM_SIZE
		;;
	rom)
		max=$ROM_SIZE
		;;
	*)
		error "Memset called for unknown memory area: %s\n" "$1"
		return 1
		;;
	esac

	if [ $((dest+count)) -gt $max ]; then
		error "memset failed! $@\n"
		return 1
	fi

	# Split the heap into everything before and after the bytes we want to set
	# $1 is the name of the region (either "heap" or "rom") that we're writing

	cmd=""
	# Start slice
	if [ $((dest)) -gt 0 ]; then
		cmd="\${$1:0:$((dest*4))}" # Will always end in a space
	fi

	i=count
	# Insert the value $count times
	until [ $((i--)) -eq 0 ]; do
		cmd="${cmd}${value}"
	done

	# Append the end slice
	if [ $((dest+count)) -lt $max ]; then
		cmd="$cmd \${$1:$(((dest+count) * 4)):$((max*4))}"
	fi

	# set -x
	eval "$1=\"$cmd\""
	# set +x
}

mem_target() {
	# $1: variable to set target name
	# $2: target address variable name
	# $3: target address variable value
	if [ $3 -ge $ROM_BASE ]; then
		eval "$1="rom"; $2=\$(($3-ROM_BASE))"
	elif [ $3 -ge $RAM_SIZE ]; then
		eval "$1=mmio"
	else # RAM
		eval "$1="heap"" # memory starts at 0
	fi
}

memset() {
	# $1: dest addr (phys)
	# $2: value
	# $3: count
	local dest target
	dest=$1
	mem_target target dest $dest
	memset_impl $target $dest $2 $3
}

readb() {
	debug MEM '(readb $%04X)' "$2"
	# $1: variable to set
	# $2: address to read
	local target readb_addr_rel readb_addr_abs readb_val

	readb_addr_rel=$(($2))
	readb_addr_abs=$readb_addr_rel

	# Handle MMIO
	case $readb_addr_rel in
	$((0x5000)))
		# ACIA_DATA (UART data) read
		if [ -z "$nextchar" ]; then
			readb_val="000"
		else
			readb_val="$nextchar"
			nextchar=""
		fi
		;;
	$((0x5001)))
		# ACIA_STATUS (UART status register)
		if [ -z "$nextchar" ]; then
			readb_val="000"
		else
			# Data pending status
			readb_val="008"
		fi
		;;
	*)
		# Now update readb_addr_rel to be relative to the target region
		mem_target target readb_addr_rel $readb_addr_rel

		if [ "$target" = "mmio" ]; then
			debug MEM 'MMIO $%04X\n' $readb_addr_abs
			readb_val="000"
		else
			readb_val="\${$target:$((readb_addr_rel*4)):3}"
		fi
		;;
	esac

	# Evaluate and assign to $1, remove up to 2 leading zeroes, allowing the
	# value to be '000'. Then check for breakpoints while we have access to the
	# variable.
	eval "$1=\"$readb_val\"; $1=\${$1#0}; $1=\${$1#0}; breakpoint_mem_hit Read \$readb_addr_abs \$$1"

	# set -x # if [ $target = heap ]; then echo \\\"\$$target\\\"; fi; 
	# set +x
}

# Read 16-bit value (and convert to little endian)
readh() {
	# $1: variable to set
	# $2: address to read
	local high low algo
	debug MEM ' [readh: '
	readb low $2
	readb high $(($2+1))
	# debug INSTR 'readh low $%02X high $%02X\n' $low $high
	# FIXME: Ok no this is really dumb but my IDE can't handle bitshifts
	# and thinks it's a redirections which messes up ALL syntax highlighting
	algo="(( (high<<8) + low ))"
	eval "$1=\$$algo; debug MEM ' => $%04X] \n' \$$1"
}

# Assert that test completed successfully.
# The test ROMs encode the expected state of the machine
# at the end of the test. Parse the data and validate that
# the state matches.
test_assert() {
	local ta tx ty tpc tp ts magic taddr failed

	# dump_registers
	# dump_status
	# dump_stack

	taddr=$ROM_BASE

	readh magic $taddr
	taddr=$((taddr+2))

	if [ $magic -ne $((0x0f0f)) ]; then
		error 'ROM wrote ASSERT register but is not a test ROM\n'
		error 'Expected magic header $0F0F but got $%04X\n' "$magic"
		exit 1
	fi

	readb ta $((taddr++))
	readb tx $((taddr++))
	readb ty $((taddr++))
	readb tp $((taddr++))
	readb ts $((taddr++))
	readh tpc $taddr
	taddr=$((taddr+2))

	failed=0

	printf '\nTest results:\n'
	printf '  A: $%02X   exp $%02X' $a $ta
	if [ $a -ne $ta ]; then printf '  Failed!\n'; failed=1; else printf '\n'; fi
	printf '  X: $%02X   exp $%02X' $x $tx
	if [ $x -ne $tx ]; then printf '  Failed!\n'; failed=1; else printf '\n'; fi
	printf '  Y: $%02X   exp $%02X' $y $ty
	if [ $y -ne $ty ]; then printf '  Failed!\n'; failed=1; else printf '\n'; fi
	printf '  P: $%02X   exp $%02X' $p $tp
	if [ $p -ne $tp ]; then printf '  Failed!\n'; failed=1; else printf '\n'; fi
	printf ' SP: $%02X   exp $%02X' $s $ts
	if [ $s -ne $ts ]; then printf '  Failed!\n'; failed=1; else printf '\n'; fi
	printf ' PC: $%04X exp $%04X' $pc $tpc
	if [ $pc -ne $tpc ]; then printf '  Failed!\n'; failed=1; else printf '\n'; fi

	printf '\n'
	if [ $failed -eq 1 ]; then
		printf 'State mismatch! Test failed.\n'
		DO_TRAP=1
		# exit 1
	else
		printf 'Test passed!\n'
		exit 0
	fi
}

writeb() {
	debug MEM ' writeb $%04X $%02X ' "$1" $2
	# $1: address to write
	# $2: byte to write
	local dest val target
	dest=$(($1))
	val=$(($2))

	breakpoint_mem_hit Write $dest $val

	case $dest in
	# ASSERT register
	# A write to here signifies the machine is in the wrong
	# state, usually a test failure.
	$((0x4010)))
		test_assert
		return
		;;
	# HALT register, traps the emulator as if a breakpoint were hit
	$((0x4040)))
		printf '\nHALT! $%02X\n' $val
		DO_TRAP=1
		return
		;;
	# ACIA compatible serial port @ $5000
	$((0x4018))|$((0x5000)))
		# FIXME: surely there's a better way to
		# go from decimal -> ASCII
		printf "\x$(printf '%02x' $val)"
		return
		;;
	$((0x5002))|$((0x5003)))
		# ACIA cmd and ctrl registers
		return
		;;
	esac

	mem_target target dest $dest

	# FIXME: replace with something optimised
	memset_impl $target $dest $val 1
}

##### Load binary #####

loadbin() {
	# $1: path to binary
	# RAM/ROM is a space separated array of numbers 0-255.
	# Decimal is used over hex since that is the
	# "native" representation of shell and saves additional
	# conversions in arithmetic expressions.
	rom=$(hexdump -v -e '1024/1 "%03u "" "' $1)
}

##### Debug / state dump #####

dump_status() {
	printf 'Status: $%02X\n' $p
	printf "    negative : %d\n" "$negative"
	printf "    overflow : %d\n" "$overflow"
	printf "    constant : %d\n" "$constant"
	printf "    break    : %d\n" "$break"
	printf "    decimal  : %d\n" "$decimal"
	printf "    interrupt: %d\n" "$interrupt"
	printf "    zero     : %d\n" "$zero"
	printf "    carry    : %d\n" "$carry"
}

dump_stack() {
	printf 'Stack $1%02X (max depth %d):\n' $s $stack_max_depth
	local i val
	i=0x100
	until [ $((i--)) -lt $((0xff-stack_max_depth+1)) ]; do
	# for i in $(seq 0xff -1 $((0xff-stack_max_depth+1))); do
		readb val $((0x100 + i))
		printf '%04X: $%02X' $((0x100 + i)) $val
		if [ $((i-1)) -eq $s ]; then
			printf '  <'
		elif [ $i -eq $s ]; then
			printf '  <--'
		fi
		printf '\n'
	done
}

dump_heap() {
	printf "Heap:\n"
	# printf '$%02X ' $heap
	local i j ROW_SIZE
	i=1
	ROW_SIZE=16
	# eval "set -- $heap"
	# eval "printf '$%d ' $(seq -s' ' $i $((i+ROW_SIZE)))"
	until [ $i -gt $RAM_SIZE ]; do
		# set -x
		printf "%04x: " $((i-1))
		printf '$%02X ' $heap | eval "cut -d' ' -f$i-$((i+ROW_SIZE))"
		# set +x
		# printf "\n"
		i=$((i+ROW_SIZE))
		# echo "i: $i"
	done
	printf "\n"
}

dump_registers() {
	local val
	printf 'Registers:\n    A : $%02X\n    X : $%02X\n    Y : $%02X\n    SP: $%02X\n    PC: $%04X\n' $a $x $y $s $pc
	printf 'Ran %d instructions\n' $instr_count
}

##### Status helpers #####

carry_set() {
	p=$((p|CARRY))
	carry=1
}

carry_clear() {
	p=$((p&(~CARRY&0xff)))
	carry=0
}

zero_set() {
	p=$((p|ZERO))
	zero=1
}

zero_clear() {
	p=$((p&(~ZERO & 0xff)))
	zero=0
}

oflow_set() {
	p=$((p|OVERFLOW))
	overflow=1
}

oflow_clear() {
	p=$((p&(~OVERFLOW & 0xff)))
	overflow=0
}

interrupt_set() {
	p=$((p|INTERRUPT))
	interrupt=1
}

interrupt_clear() {
	p=$((p&(~INTERRUPT&0xff)))
	interrupt=0
}

break_set() {
	p=$((p|BREAK))
	break=1
}

break_clear() {
	p=$((p&(~BREAK&0xff)))
	break=0
}

negative_set() {
	p=$((p|NEGATIVE))
	negative=1
}

negative_clear() {
	p=$((p&(~NEGATIVE & 0xff)))
	negative=0
}

decimal_set() {
	p=$((p|DECIMAL))
	decimal=1
}

decimal_clear() {
	p=$((p&(~DECIMAL & 0xff)))
	decimal=0
}

update_status() {
	[[ $(($1 & CARRY)) -gt 0 ]] && carry_set || carry_clear
	[[ $(($1 & ZERO)) -gt 0 ]] && zero_set || zero_clear
	[[ $(($1 & INTERRUPT)) -gt 0 ]] && interrupt_set || interrupt_clear
	# [[ $(($1 & DECIMAL)) -gt 0 ]] && decimal_set || decimal_clear
	[[ $(($1 & BREAK)) -gt 0 ]] && break_set || break_clear
	# [[ $(($1 & CONSTANT)) -gt 0 ]] && constant_set || constant_clear
	[[ $(($1 & OVERFLOW)) -gt 0 ]] && oflow_set || oflow_clear
	[[ $(($1 & NEGATIVE)) -gt 0 ]] && negative_set || negative_clear
}

update_negative_zero_bits() {
	debug STATUS 'update_negative_zero_bits $%02X\n' $1
	[[ $(($1 & 0x80)) -eq $((0x80)) ]] && negative_set || negative_clear
	[[ $1 -eq 0 ]] && zero_set || zero_clear
}

update_carry() {
	debug STATUS 'update_carry $%02X\n' $1
	[[ $(($1 & 0x80)) -gt 0 ]] && carry_set || carry_clear
}

to_signed() {
	# $1: name of variable containing the value to convert
	#
	# This is basically two's complement, but im not sure quite how
	# it comes up with the right answer tbh
	local temp mask invmask sign
	eval "temp=\$$1"
	sign="+"
	mask=$((0x80))
	invmask=$((0x7F))
	if [ $temp -gt $((0xFFFF)) ]; then
		error 'to_signed: value larger than 16 bits?? 0x%x\n' $temp
		exit 1
	fi
	if [ $temp -gt $((0xFF)) ]; then
		mask=$((0x8000))
		invmask=$((0x7FFF))
		temp=$((temp & 0xFFFF))
	else
		temp=$((temp & 0xFF))
	fi
	if [ $((temp & mask)) -gt 0 ]; then
		sign="-"
		temp=$(( (~(temp) & invmask) +1))
	fi
	eval "$1=\$((0 ${sign} (temp)))"
}

##### Stack #####

stack_push() {
	writeb $((0x100 + s--)) $1
	s=$((s&0xFF))
	if [ $stack_max_depth -lt $((0xff-s)) ]; then
		stack_max_depth=$((stack_max_depth+1))
	fi
}

stack_pop() {
	# Handle wrap around
	s=$(((s+1)&0xFF))

	readb $1 $((0x100 + s))
}

stack_peak() {
	readb $1 $((0x100 + s + 1))
}

stack_poke() {
	writeb $((0x100 + s)) $1
}

stack_pushpc() {
	stack_push $((pc >> 8))
	stack_push $(((pc-1) & 0xff))
}

stack_poppc() {
	local msb eqn

	stack_pop pc
	stack_pop msb

	# Dumb workaround for borked syntax highlighting in my IDE
	eqn="((pc|(msb<<8)))"
	eval "pc=\$$eqn"
}

##### Instructions #####

adc_impl() {
	# $1: val to add
	local val sum
	val=$1
	sum=$((val+a+carry))
	if [ -z "$val" -o "$val" = " " ]; then
		echo "'$heap'"
		exit 1
	fi
	# echo "val: '$val' a: '$a' sum: $sum"

	debug INSTR 'ADC (A=$%02X) $%02X = $%03X' $a $val $sum

	# Magic shorthand to figure out if overflow should be set by seeing
	# if bit 7 is set when it shouldn't be
	if [ $(( ( a^sum ) & ( val^sum ) & 0x80 )) -eq $((0x80)) ]; then
		oflow_set
	fi

	a=$((sum & 0xff))
	update_negative_zero_bits $a
	[[ $sum -gt 255 ]] && carry_set || carry_clear
}

adc() {
	# $1: address of byte to add
	local val

	readb val $1
	adc_impl $val
}

sbc() {
	local val

	readb val $1
	debug INSTR 'SBC (A=$%02X) $%02X implies ' $a $val
	adc_impl $(((~val) & 0xFF))
}

and() {
	local val
	readb val $1
	debug INSTR 'AND $%02X' "$val"
	a=$((a & $val))
	update_negative_zero_bits $a
}

bit() {
	local val sum
	readb val $1
	sum=$((a & val))
	update_negative_zero_bits $sum
	[[ $((val & 0x40)) -gt 0 ]] && oflow_set || oflow_clear
	[[ $((val & 0x80)) -gt 0 ]] && negative_set || negative_clear
}

lda() {
	readb a $1
	debug INSTR 'LDA $%-4X <- $%02X' $1 $a
	update_negative_zero_bits $a
}

ldy() {
	readb y $1
	debug INSTR 'LDY $%-4X <- $%02X' $1 $y
	update_negative_zero_bits $y
}

ldx() {
	readb x $1
	debug INSTR 'LDX $%-4X <- $%02X' $1 $x
	update_negative_zero_bits $x
}

sta() {
	debug INSTR 'STA $%-4X <- $%02X' "$1" $a
	writeb $1 $a
}

stx() {
	debug INSTR 'STX $%-4X <- $%02X' "$1" $x
	writeb $1 $x
}

sty() {
	debug INSTR 'STY $%-4X <- $%02X' "$1" $y
	writeb $1 $y
}

cmp() {
	local res val
	readb val $1
	res=$(( (a-val) & 0xff ))
	debug INSTR 'CMP $%02X $%02X = $%02X' "$a" "$val" $res
	update_negative_zero_bits $res
	[[ $a -ge $val ]] && carry_set || carry_clear
}

cpy() {
	local res val
	readb val $1
	debug INSTR 'CPY $%02X' "$val"
	res=$(( (y-val) & 0xff ))
	update_negative_zero_bits $res
	[[ $y -ge $val ]] && carry_set || carry_clear
}

cpx() {
	local res val
	readb val $1
	debug INSTR 'CPX $%02X' "$val"
	res=$(( (x-val) & 0xff ))
	update_negative_zero_bits $res
	[[ $x -ge $val ]] && carry_set || carry_clear
}

beq() {
	local val
	readb val $1
	debug INSTR 'BEQ (Z=%d) $%02X' $zero "$val"
	to_signed val
	debug INSTR ' (%d)' $val
	[[ $zero -eq 1 ]] && pc=$((pc+$val)) || :
}

bne() {
	local val
	readb val $1
	debug INSTR 'BNE (Z=%d) $%02X' $zero "$val"
	to_signed val
	debug INSTR ' (%d)' $val
	if [ $zero -eq 0 ]; then
		pc=$((pc+$val))
	fi
}

# Branch if minus (negative)
bmi() {
	local val
	readb val $1
	debug INSTR 'BMI (N=%d) $%02X' $negative "$val"
	to_signed val
	debug INSTR ' (%d)' $val
	[[ $negative -eq 1 ]] && pc=$((pc+$val)) || :
}

# Branch if positive
bpl() {
	local val
	readb val $1
	debug INSTR 'BPL (N=%d) $%02X' $negative $val
	to_signed val
	debug INSTR ' (%d)' $val
	[[ $negative -eq 0 ]] && pc=$((pc+$val)) || :
}

# Branch if carry clear
bcc() {
	local val
	readb val $1
	debug INSTR 'BCC (C=%d) $%02X' $carry "$val"
	to_signed val
	debug INSTR ' (%d)' $val
	[[ $carry -eq 0 ]] && pc=$((pc+$val)) || :
}

# Branch if overflow set
bvs() {
	local val
	readb val $1
	debug INSTR 'BVS (V=%d) $%02X' $overflow $val
	to_signed val
	debug INSTR ' (%d)' $val
	[[ $overflow -eq 1 ]] && pc=$((pc+$val)) || :
}

# Branch if overflow clear
bvc() {
	local val
	readb val $1
	debug INSTR 'BVC (V=%d) $%02X' $overflow $val
	to_signed val
	debug INSTR ' (%d)' $val
	[[ $overflow -eq 0 ]] && pc=$((pc+val)) || :
}

# Branch if carry set
bcs() {
	local val
	readb val $1
	debug INSTR 'BCS (C=%d) $%02X' $carry $val
	to_signed val
	debug INSTR ' (%d)' $val
	[[ $carry -eq 1 ]] && pc=$((pc+val)) || :
}

clc() {
	debug INSTR 'CLC (C=%d)' $carry
	carry_clear
}

sec() {
	debug INSTR 'SEC (C=%d)' $carry
	carry_set
}

cli() {
	debug INSTR 'CLI (I=%d)' $interrupt
	interrupt_clear
}

sei() {
	debug INSTR 'SEI (I=%d)' $interrupt
	interrupt_set
}

sed_instr() {
	debug INSTR 'SED (D=%d)' $decimal
	decimal_set
}

cld() {
	debug INSTR 'CLD (D=%d)' $decimal
	decimal_clear
}

clv() {
	debug INSTR 'CLV (V=%d)' $overflow
	oflow_clear
}

ora() {
	local val
	readb val $1
	a=$((a|val))
	debug INSTR 'ORA $%02X' $a
	update_negative_zero_bits $a
}

# Push status register to the stack
php() {
	local status
	debug INSTR 'PHP (SP=$%02X)' $((0x100 + s)) # Show stack pointer

	# Always set bit 5 (unused)
	# Set bit 4 (B/break) if BRK or PHP instruction
	status=$((p|0x30))
	stack_push $status
}

# Restore status register from the stack. Ignore B and C flags
plp() {
	local mask
	debug INSTR 'PLP (SP=$%02X)' $((0x100 + s)) # Show stack pointer

	stack_pop p
	mask=$((~0x30 & 0xFF))
	debug INSTR ' mask=0x%02X p=$%02X' $mask $p
	update_status $((p&mask))
}

# Push A to the stack
pha() {
	debug INSTR 'PHA (SP=$%02X)' $((0x100 + s)) # Show stack pointer
	stack_push $a
}

# Pop stack into A
pla() {
	stack_pop a
	debug INSTR 'PLA (A=$%02X)' $a

	update_negative_zero_bits $a
}

# Software interrupt
brk() {
	debug INSTR 'BRK (I=%d)' $interrupt
	# Do nothing if IRQs are disabled
	# [[ $interrupt -eq 1 ]] && return || :

	# Return address skips a byte after the BRK
	# to be used as a marker
	pc=$((pc+2))
	stack_pushpc

	break_set

	debug INSTR ' implicit '
	php

	interrupt_set

	# Set PC to address in interrupt vector
	readh pc $IRQ_VECTOR

	debug INSTR ' IRQ pc=$%04X' $pc
}

rti() {
	debug INSTR 'RTI implicit '

	plp

	stack_poppc

	debug INSTR ' pc=$%04X' $pc

	# Clear the break flag
	break_clear
}

# Jump to subroutine
jsr() {
	# Push PC - 1 to stack
	stack_pushpc
	pc=$1

	debug INSTR 'JSR $%04X' $pc
}

rts() {
	stack_poppc

	# Restore PC from stack (and add 1)
	pc=$((pc+1))

	debug INSTR 'RTS $%04X' $pc
}

txs() {
	s=$x

	debug INSTR 'TXS $%02X' $x
}

tsx() {
	x=$s
	update_negative_zero_bits $x

	debug INSTR 'TSX $%02X' $x
}

tax() {
	debug INSTR 'TAX $%02X' $a
	x=$a
	update_negative_zero_bits $x
}

tay() {
	debug INSTR 'TAY $%02X' $a
	y=$a
	update_negative_zero_bits $y
}

tya() {
	debug INSTR 'TYA $%02X' $y
	a=$y
	update_negative_zero_bits $a
}

txa() {
	debug INSTR 'TXA $%02X' $x
	a=$x
	update_negative_zero_bits $a
}

iny() {
	# FIXME: handle negative y ??
	y=$(((y+1) & 0xFF))
	debug INSTR 'INY $%02X' $y
	update_negative_zero_bits $y
}

inc() {
	local val
	readb val $addr
	writeb $addr $((val+1))
	debug INSTR 'INC $%04X $%02X' $addr $((val+1))
	update_negative_zero_bits $x
}

inx() {
	x=$(((x+1) & 0xFF))
	debug INSTR 'INX $%02X' $x
	update_negative_zero_bits $x
}

dec() {
	# FIXME: handle negative ??
	a=$(((a-1) & 0xFF))
	debug INSTR 'DEC $%02X' $a
	update_negative_zero_bits $a
}

dey() {
	# FIXME: handle negative y ??
	y=$(((y-1) & 0xFF))
	debug INSTR 'DEY $%02X' $y
	update_negative_zero_bits $y
}

dex() {
	# FIXME: handle negative y ??
	x=$(((x-1) & 0xFF))
	debug INSTR 'DEX $%02X' $x
	update_negative_zero_bits $x
}

eor() {
	local val
	readb val $1
	debug INSTR 'EOR $%02X^$%02X' $a $val
	a=$((a^val))
	debug INSTR ' = $%02X' $a
	update_negative_zero_bits $a
}

lsr_mem() {
	local val
	readb val $addr

	[[ $((val & 0x1)) -eq 1 ]] && carry_set || carry_clear

	val=$((val>>1))
	writeb $addr $val
	debug INSTR 'LSR $%02X' $val
	update_negative_zero_bits $val
}

lsr_acc() {
	[[ $((a & 0x1)) -eq 1 ]] && carry_set || carry_clear

	a=$((a>>1))
	debug INSTR 'LSR $%02X' $a
	update_negative_zero_bits $a
}

rol_mem() {
	local val eqn oldcarry
	readb val $1
	oldcarry=$carry
	update_carry $val
	eqn="(( ((val<<1) | oldcarry ) & 0xFF))"
	eval "val=\$$eqn"
	debug INSTR 'ROL $%02X' $val
	writeb $1 $val
	update_negative_zero_bits $val
}

# Arithmetic shift left
asl() {
	# $1: variable to operate on, e.g. 'a'
	local val eqn
	eval "val=\$$1"
	update_carry $val
	eval "val=\$(( (val << 1) & 0xFF))"
	update_negative_zero_bits $val
	eval "$1=\$val"
	debug INSTR 'ASL $%02X' $val
}

##### Addressing modes #####

# Implied addressing does nothing
addr_imp() {
	debug ADDR 'IMP             | '
}

addr_imm() {
	addr=$((pc++))
	debug ADDR 'IMM $%-4X       | ' $addr
}

# Set the "addr" variable to the 16-bit value at $pc
# and increment $pc
addr_abs() {
	readh addr $pc
	pc=$((pc+2))
	debug ADDR 'ABS $%-4X       | ' $addr
}

addr_abx() {
	readh addr $pc
	pc=$((pc+2))

	addr=$((addr+x))

	debug ADDR 'ABX $%-4X       | ' $addr
}

addr_aby() {
	readh addr $pc
	pc=$((pc+2))

	addr=$((addr+y))

	debug ADDR 'ABY $%-4X       | ' $addr
}

addr_zer() {
	readb addr $((pc++))
	debug ADDR 'ZER $%-4X       | ' $addr
}

addr_zex() {
	readb addr $((pc++))
	addr=$(( (addr+x) & 0xFF ))
	debug ADDR 'ZEX $%-2X         | ' $addr
}

addr_zey() {
	readb addr $((pc++))
	addr=$(( (addr+y) & 0xFF ))
	debug ADDR 'ZEY $%-2X         | ' $addr
}

addr_rel() {
	addr=$((pc++))
	debug ADDR 'REL $%-4X       | ' $addr
}

addr_ind() {
	readh addr $pc
	debug ADDR 'IND (=$%-4X) | ' $addr
	readh addr $addr
}

# Indexed indirect (Indirect,X)
addr_indx() {
	local sum inter
	readb inter $((pc++))
	sum=$(( (inter+x) & 0xFF ))
	readh addr $sum
	debug ADDR '($%-2X,$%-2X) $%-4X | ' $inter $x $addr
}

addr_indy() {
	local lsb_addr msb eqn
	readb lsb_addr $((pc++))
	readb addr $lsb_addr
	addr=$((addr+y))
	update_carry $addr
	addr=$((addr & 0xFF))
	readb msb $((lsb_addr+1+$carry))
	# Useless eval because my IDE treats arithmetic expressions like subshells
	eqn="((addr + (msb << 8) ))"
	eval "addr=\$$eqn"
	debug ADDR '(%-2X),%-2X = $%-4X | ' $lsb_addr $y $addr
}

read_char() {
	eval "$1=\$(hexdump -v -e '1/1 \"%u\" \"\n\"' -n1)"
}

stty_configure() {
	stty -icanon -echo min 0 time 0 2>/dev/null || :
}

stty_reset() {
	stty icanon echo min 1 time 0 || :
}

breakpoint_hit() {
	if [ -z "$BREAKPOINTS" ]; then return 1; fi

	local bp i opcode instruction

	i=0

	eval "set -- $BREAKPOINTS"
	for bp do
		if [ $((pc)) -eq $(($bp)) ]; then
			readb opcode $bp
			decode_execute $opcode instruction
			printf '\nBreakpoint hit!     %d: $%04X\n    $%02X "%s"\n' $i $bp $opcode "$instruction"
			return 0
		fi
		shift
		i=$((i+1))
	done

	return 1
}

# Check if the address we're writing to has a breakpoint
breakpoint_mem_hit() {
	# $1: access type (read|write)
	# $2: address
	# $3: value being written
	if [ -z "$BREAKPOINTS_WRITE" ]; then return; fi

	local bp i addr val at
	at=$1
	addr=$2
	val=$3

	i=0

	eval "set -- $BREAKPOINTS_WRITE"
	for bp do
		if [ $((addr)) -eq $(($bp)) ]; then
			printf '\n%5s breakpoint hit! %d: $%-4X $%02X\n' $at $i $bp $val
			DO_TRAP=1
			return
		fi
		shift
		i=$((i+1))
	done

	return
}

save () {
	for i do printf %s\\n "$i" | sed "s/'/'\\\\''/g;1s/^/'/;\$s/\$/' \\\\/" ; done
	echo " "
}

# Debug monitor
run_monitor() {
	local inp cmd bp i idx addr fmt spec target tmp

	if [ $DO_TRAP -eq 1 ]; then
		dump_registers
	fi

	while true; do
		printf '65sh> '
		OLD_IFS="$IFS"
		if ! IFS=$';\n' read inp; then
			exit 1
		fi
		IFS="$OLD_IFS"
		if [ -z "$inp" ]; then
			inp="$mon_last_input"
		else
			mon_last_input="$inp"
		fi
		if [ "${inp:0:5}" = "eval" ]; then
			eval "${inp:5}"
			continue
		fi
		# Strip hex signifiers
		inp="$(printf '%s ' "$inp" | tr -d '$')"

		# Perform additional splitting/parsing on the input
		while true; do
			eval "set -- $inp"
			inp=""
			cmd="$1"
			shift
			if ! [[ "$cmd" =~ '/' ]]; then
				break
			fi
			# Split by '/' as well
			inp="$(echo $cmd | tr '/' ' ') $*"
		done

		case $cmd in
		# Verbose
		v)
			if [ $VERBOSE -eq 0 ]; then VERBOSE=1; set -x; else VERBOSE=0; set +x; fi
			;;
		# View or manipulate log categories
		d)
			if [ $# -lt 1 ]; then
				printf 'Debug: %s\n' "$DEBUG"
				printf 'Available categories: %s\n' "$DEBUG_CATEGORIES"
			else
				DEBUG=",$@,"
			fi
			;;
		# Toggle default logging
		dt)
			if [ -n "$1" ]; then
				[[ "$DEBUG" =~ "$1" ]] && DEBUG="${DEBUG//,"$1"/}" || DEBUG="${DEBUG}$1,"
			else
				if [ -z "$DEBUG" ]; then
					DEBUG="$DEBUG_DEFAULT"
				else
					DEBUG=""
				fi
			fi
			printf 'Debug: '%s'\n' "$DEBUG"
			;;
		# Breakpoints
		b)
			if [ -z "$1" ]; then
				error "Breakpoint address not specified"
				continue
			fi
			bp="$1"
			i="$(echo "$BREAKPOINTS" | tr -dc ' ' | wc -c)"
			printf '    Breakpoint     %d: $%04X\n' $i $((0x$bp))
			BREAKPOINTS="${BREAKPOINTS} 0x${bp}"
			;;
		# Break on write to address
		bmem)
			if [ -z "$1" ]; then
				continue
			fi
			bp="0x$1"
			i="$(echo "$BREAKPOINTS_WRITE" | tr -dc ' ' | wc -c)"
			printf '    Mem Breakpoint %d: $%04X\n' $i $((bp))
			BREAKPOINTS_WRITE="${BREAKPOINTS_WRITE} ${bp}"
			;;
		# Break on jump to subroutine
		bsr|bjs)
			BREAK_ON_JSR=$((BREAK_ON_JSR^1))
			if [ $BREAK_ON_JSR -eq 1 ]; then
				printf '    Will break on next JSR instruction\n'
			else
				printf '    Will NOT break on next JSR instruction\n'
			fi
			;;
		# Break on next return from subroutine (equiv to gdb "finish")
		brt|finish)
			if [ $IN_SUBROUTINE -eq 0 ]; then
				printf "    Can't break on RTS when not in a subroutine!\n"
				continue
			fi
			BREAK_ON_RTS=$((BREAK_ON_RTS^1))
			if [ $BREAK_ON_RTS -eq 1 ]; then
				printf '    Will break on next RTS instruction\n'
			else
				printf '    Will NOT break on next RTS instruction\n'
			fi
			;;
		del)
			if [ -z "$1" ]; then
				error 'del requires an argument\n'
				continue
			fi
			if [ $1 = "mem" ]; then
				eval "set -- BREAKPOINTS_WRITE \"$2\" $BREAKPOINTS_WRITE"
			else
				eval "set -- BREAKPOINTS \"$1\" $BREAKPOINTS"
			fi

			target=$1
			idx=$(($2)) || return
			shift 2
			eval "$target="
			i=0
			for bp do
				if [ $idx -ne $i ]; then
					eval "$target=\"\$$target \$bp\""
				fi
				i=$((i+1))
			done
			;;
		# Breakpoint info
		i|info)
			eval "set -- $BREAKPOINTS"
			i=0
			for bp do
				printf '    Breakpoint     %d: $%04X\n' $i $bp
				i=$((i+1))
			done
			eval "set -- $BREAKPOINTS_WRITE"
			i=0
			for bp do
				printf '    Mem Breakpoint %d: $%04X\n' $i $bp
				i=$((i+1))
			done
			;;
		# Print a register (or ALL)
		p)
			if [ $# -lt 1 ]; then
				dump_registers
			else
				eval "printf '%s: $%02X\n' $1 \$$1"
			fi
			;;
		# Print a variable
		echo)
			eval "printf "%s" \\\"\$$1\\\""
			;;
		# Set variable, e.g. pc
		set)
			addr=$((0x$2)) || eval "addr=$(($2))" || continue
			eval "$1=\$addr"
			if [ "$1" = "p" ]; then
				update_status $p
			fi
			;;
		ps)
			dump_status
			;;
		stack)
			dump_stack
			;;
		# Continue execution
		c)

			printf 'Continuing execution...\n'
			DO_TRAP=0
			SINGLE_STEP=0
			return
			;;
		# Step a single instructions
		s)
			printf '\n'
			DO_TRAP=0
			SINGLE_STEP=1
			# Leave DO_TRAP set so we drop
			# back after one instruction
			return
			;;
		# Examine memory
		x)
			spec='1X'
			if [ $# -gt 1 ]; then
				spec="$1"
				shift
			fi
			# Either variable or literal address
			addr=$((0x$1)) || eval "addr=$(($1))" || continue

			for i in $(seq 1 ${spec:0:-1}); do
				fmt="\$%02${spec: -1}"
				tmp=$((addr + i - 1))
				case ${spec: -1} in
				x|X) readb val $tmp ;;
				b|d) readb val $tmp; fmt="\$%-2d" ;;
				h) readh val $tmp; tmp=$((tmp + 1)); fmt='$%04X' ;; 
				*) break ;;
				esac
				printf "%04X: $fmt\n" $tmp $val
			done
			;;
		# Write memory
		w)
			# Either variable or literal address
			addr=$((0x$1)) || eval "addr=$(($1))" || continue
			printf "%04X: $%02X\n" $addr $2
			writeb $addr $2
			;;
		q)
			exit 0
			;;
		esac
	done
}

decode_execute() {
	# $1: opcode to decode
	# $2: variable to store instruction in
	#     for decode_only behaviour (instruction)
	#     won't be executed
	local opcode
	opcode="$1"

	case $opcode in
	$((0x00)))
		if [ -n "$2" ]; then
			eval "$2='BRK imp'"
			return
		fi
		addr_imp
		brk
		;;
	$((0x01)))
		if [ -n "$2" ]; then
			eval "$2='ORA inx'"
			return
		fi
		addr_indx
		ora $addr
		;;
	$((0x05)))
		if [ -n "$2" ]; then
			eval "$2='ORA zer'"
			return
		fi
		addr_zer
		ora $addr
		;;
	$((0x06)))
		if [ -n "$2" ]; then
			eval "$2='ASL zer'"
			return
		fi
		addr_zer
		readb __val $addr
		asl __val
		writeb $addr __val
		;;
	$((0x08)))
		if [ -n "$2" ]; then
			eval "$2='PHP imp'"
			return
		fi
		addr_imp
		php
		;;
	$((0x09)))
		if [ -n "$2" ]; then
			eval "$2='ORA imm'"
			return
		fi
		addr_imm
		ora $addr
		;;
	$((0x0A)))
		if [ -n "$2" ]; then
			eval "$2='ASL acc'"
			return
		fi
		addr_imp
		asl a
		;;
	$((0x10)))
		if [ -n "$2" ]; then
			eval "$2='BPL rel'"
			return
		fi
		addr_rel
		bpl $addr
		;;
	$((0x18)))
		if [ -n "$2" ]; then
			eval "$2='CLC imp'"
			return
		fi
		addr_imp
		clc
		;;
	$((0x20)))
		if [ -n "$2" ]; then
			eval "$2='JSR abs'"
			return
		fi
		addr_abs
		jsr $addr
		# Track that we entered a subroutine
		IN_SUBROUTINE=$((IN_SUBROUTINE+1))
		if [ $BREAK_ON_JSR -eq 1 ]; then
			printf '\nJSR HIT!\n'
			BREAK_ON_JSR=0
			DO_TRAP=1
		fi
		;;
	$((0x26)))
		if [ -n "$2" ]; then
			eval "$2='ROL zer'"
			return
		fi
		addr_zer
		rol_mem $addr
		;;
	$((0x24)))
		if [ -n "$2" ]; then
			eval "$2='BIT zer'"
			return
		fi
		addr_zer
		bit $addr
		;;
	$((0x28)))
		if [ -n "$2" ]; then
			eval "$2='PLP imp'"
			return
		fi
		addr_imp
		plp
		;;
	$((0x29)))
		if [ -n "$2" ]; then
			eval "$2='AND imm'"
			return
		fi
		addr_imm
		and $addr
		;;
	$((0x2C)))
		if [ -n "$2" ]; then
			eval "$2='BIT abs'"
			return
		fi
		addr_abs
		bit $addr
		;;
	$((0x30)))
		if [ -n "$2" ]; then
			eval "$2='BMI rel'"
			return
		fi
		addr_rel
		bmi $addr
		;;
	$((0x38)))
		if [ -n "$2" ]; then
			eval "$2='SEC imp'"
			return
		fi
		addr_imp
		sec
		;;
	$((0x3A)))
		if [ -n "$2" ]; then
			eval "$2='DEC imp'"
			return
		fi
		addr_imp
		dec
		;;
	$((0x3D)))
		if [ -n "$2" ]; then
			eval "$2='AND abs,X'"
			return
		fi
		addr_abx
		and $addr
		;;
	$((0x40)))
		if [ -n "$2" ]; then
			eval "$2='RTI imp'"
			return
		fi
		addr_imp
		rti
		;;
	$((0x46)))
		if [ -n "$2" ]; then
			eval "$2='LSR zer'"
			return
		fi
		addr_zer
		lsr_mem $addr
		;;
	$((0x48)))
		if [ -n "$2" ]; then
			eval "$2='PHA imp'"
			return
		fi
		addr_imp
		pha
		;;
	$((0x49)))
		if [ -n "$2" ]; then
			eval "$2='EOR imm'"
			return
		fi
		addr_imm
		eor $addr
		;;
	$((0x4A)))
		if [ -n "$2" ]; then
			eval "$2='LSR acc'"
			return
		fi
		addr_imp
		lsr_acc
		;;
	$((0x4C)))
		if [ -n "$2" ]; then
			eval "$2='JMP abs'"
			return
		fi
		addr_abs
		pc=$addr
		debug INSTR 'JMP $%02X' $pc
		;;
	$((0x50)))
		if [ -n "$2" ]; then
			eval "$2='BVC rel'"
			return
		fi
		addr_rel
		bvc $addr
		;;
	$((0x58)))
		if [ -n "$2" ]; then
			eval "$2='CLI imp'"
			return
		fi
		addr_imp
		cli
		;;
	$((0x60)))
		if [ -n "$2" ]; then
			eval "$2='RTS imp'"
			return
		fi
		addr_imp
		rts
		IN_SUBROUTINE=$((IN_SUBROUTINE-1))
		if [ $BREAK_ON_RTS -eq 1 ]; then
			printf '\nRTS HIT!\n'
			BREAK_ON_RTS=0
			DO_TRAP=1
		fi
		;;
	$((0x65)))
		if [ -n "$2" ]; then
			eval "$2='ADC zer'"
			return
		fi
		addr_zer
		adc $addr
		;;
	$((0x68)))
		if [ -n "$2" ]; then
			eval "$2='PLA imp'"
			return
		fi
		addr_imp
		pla
		;;
	$((0x69)))
		if [ -n "$2" ]; then
			eval "$2='ADC imm'"
			return
		fi
		addr_imm
		adc $addr
		;;
	$((0x6C)))
		if [ -n "$2" ]; then
			eval "$2='JMP ind'"
			return
		fi
		addr_ind
		pc=$addr
		debug INSTR 'JMP $%02X' $pc
		;;
	$((0x70)))
		if [ -n "$2" ]; then
			eval "$2='BVS rel'"
			return
		fi
		addr_rel
		bvs $addr
		;;
	$((0x75)))
		if [ -n "$2" ]; then
			eval "$2='ADC zex'"
			return
		fi
		addr_zex
		adc $addr
		;;
	$((0x78)))
		if [ -n "$2" ]; then
			eval "$2='ADC zex'"
			return
		fi
		addr_imp
		sei
		;;
	$((0x84)))
		if [ -n "$2" ]; then
			eval "$2='STY zer'"
			return
		fi
		addr_zer
		sty $addr
		;;
	$((0x85)))
		if [ -n "$2" ]; then
			eval "$2='STA zer'"
			return
		fi
		addr_zer
		sta $addr
		;;
	$((0x86)))
		if [ -n "$2" ]; then
			eval "$2='STX zer'"
			return
		fi
		addr_zer
		stx $addr
		;;
	$((0x88)))
		if [ -n "$2" ]; then
			eval "$2='DEY imp'"
			return
		fi
		addr_imp
		dey
		;;
	$((0x8A)))
		if [ -n "$2" ]; then
			eval "$2='TXA imp'"
			return
		fi
		addr_imp
		txa
		;;
	$((0x8C)))
		if [ -n "$2" ]; then
			eval "$2='STY abs'"
			return
		fi
		addr_abs
		sty $addr
		;;
	$((0x8D)))
		if [ -n "$2" ]; then
			eval "$2='STA abs'"
			return
		fi
		addr_abs
		sta $addr
		;;
	$((0x8E)))
		if [ -n "$2" ]; then
			eval "$2='STX abs'"
			return
		fi
		addr_abs
		stx $addr
		;;
	$((0x90)))
		if [ -n "$2" ]; then
			eval "$2='BCC rel'"
			return
		fi
		addr_rel
		bcc $addr
		;;
	$((0x91)))
		if [ -n "$2" ]; then
			eval "$2='STA iny'"
			return
		fi
		addr_indy
		sta $addr
		;;
	$((0x94)))
		if [ -n "$2" ]; then
			eval "$2='STY zex'"
			return
		fi
		addr_zex
		sty $addr
		;;
	$((0x95)))
		if [ -n "$2" ]; then
			eval "$2='STA zex'"
			return
		fi
		addr_zex
		sta $addr
		;;
	$((0x96)))
		if [ -n "$2" ]; then
			eval "$2='STX zey'"
			return
		fi
		addr_zey
		stx $addr
		;;
	$((0x98)))
		if [ -n "$2" ]; then
			eval "$2='TYA imp'"
			return
		fi
		addr_imp
		tya
		;;
	$((0x99)))
		if [ -n "$2" ]; then
			eval "$2='STA aby'"
			return
		fi
		addr_aby
		sta $addr
		;;
	$((0x9A)))
		if [ -n "$2" ]; then
			eval "$2='TXS imp'"
			return
		fi
		addr_imp
		txs
		;;
	$((0x9D)))
		if [ -n "$2" ]; then
			eval "$2='STX abx'"
			return
		fi
		addr_abx
		sta $addr
		;;
	$((0xA0)))
		if [ -n "$2" ]; then
			eval "$2='LDY imm'"
			return
		fi
		addr_imm
		ldy $addr
		;;
	$((0xA1)))
		if [ -n "$2" ]; then
			eval "$2='LDA idx'"
			return
		fi
		addr_indx
		lda $addr
		;;
	$((0xA2)))
		if [ -n "$2" ]; then
			eval "$2='LDX imm'"
			return
		fi
		addr_imm
		ldx $addr
		;;
	$((0xA4)))
		if [ -n "$2" ]; then
			eval "$2='LDY zer'"
			return
		fi
		addr_zer
		ldy $addr
		;;
	$((0xA5)))
		if [ -n "$2" ]; then
			eval "$2='LDA zer'"
			return
		fi
		addr_zer
		lda $addr
		;;
	$((0xA6)))
		if [ -n "$2" ]; then
			eval "$2='LDX zer'"
			return
		fi
		addr_zer
		ldx $addr
		;;
	$((0xA8)))
		if [ -n "$2" ]; then
			eval "$2='TAY imp'"
			return
		fi
		addr_imp
		tay
		;;
	$((0xA9)))
		if [ -n "$2" ]; then
			eval "$2='LDA imm'"
			return
		fi
		addr_imm
		lda $addr
		;;
	$((0xAA)))
		if [ -n "$2" ]; then
			eval "$2='TAX imp'"
			return
		fi
		addr_imp
		tax
		;;
	$((0xAC)))
		if [ -n "$2" ]; then
			eval "$2='LDY abs'"
			return
		fi
		addr_abs
		ldy $addr
		;;
	$((0xAD)))
		if [ -n "$2" ]; then
			eval "$2='LDA abs'"
			return
		fi
		addr_abs
		lda $addr
		;;
	$((0xAE)))
		if [ -n "$2" ]; then
			eval "$2='LDX abs'"
			return
		fi
		addr_abs
		ldx $addr
		;;
	$((0xB0)))
		if [ -n "$2" ]; then
			eval "$2='BCS rel'"
			return
		fi
		addr_rel
		bcs $addr
		;;
	$((0xB1)))
		if [ -n "$2" ]; then
			eval "$2='LDA idy'"
			return
		fi
		addr_indy
		lda $addr
		;;
	$((0xB4)))
		if [ -n "$2" ]; then
			eval "$2='LDY zex'"
			return
		fi
		addr_zex
		ldy $addr
		;;
	$((0xB5)))
		if [ -n "$2" ]; then
			eval "$2='LDA zex'"
			return
		fi
		addr_zex
		lda $addr
		;;
	$((0xB6)))
		if [ -n "$2" ]; then
			eval "$2='LDX zey'"
			return
		fi
		addr_zey
		ldx $addr
		;;
	$((0xB8)))
		if [ -n "$2" ]; then
			eval "$2='CLV imp'"
			return
		fi
		addr_imp
		clv
		;;
	$((0xB9)))
		if [ -n "$2" ]; then
			eval "$2='LDA aby'"
			return
		fi
		addr_aby
		lda $addr
		;;
	$((0xBA)))
		if [ -n "$2" ]; then
			eval "$2='TSX imp'"
			return
		fi
		addr_imp
		tsx
		;;
	$((0xBC)))
		if [ -n "$2" ]; then
			eval "$2='LDY abx'"
			return
		fi
		addr_abx
		ldy $addr
		;;
	$((0xBD)))
		if [ -n "$2" ]; then
			eval "$2='LDA abx'"
			return
		fi
		addr_abx
		lda $addr
		;;
	$((0xBE)))
		if [ -n "$2" ]; then
			eval "$2='LDX aby'"
			return
		fi
		addr_aby
		ldx $addr
		;;
	$((0xC0)))
		if [ -n "$2" ]; then
			eval "$2='CPY imm'"
			return
		fi
		addr_imm
		cpy $addr
		;;
	$((0xC4)))
		if [ -n "$2" ]; then
			eval "$2='CPY zer'"
			return
		fi
		addr_zer
		cpy $addr
		;;
	$((0xC5)))
		if [ -n "$2" ]; then
			eval "$2='CMP zer'"
			return
		fi
		addr_zer
		cmp $addr
		;;
	$((0xC8)))
		if [ -n "$2" ]; then
			eval "$2='INY imp'"
			return
		fi
		addr_imp
		iny
		;;
	$((0xC9)))
		if [ -n "$2" ]; then
			eval "$2='CMP imm'"
			return
		fi
		addr_imm
		cmp $addr
		;;
	$((0xCA)))
		if [ -n "$2" ]; then
			eval "$2='DEX imp'"
			return
		fi
		addr_imp
		dex
		;;
	$((0xCC)))
		if [ -n "$2" ]; then
			eval "$2='CPY abs'"
			return
		fi
		addr_abs
		cpy $addr
		;;
	$((0xCD)))
		if [ -n "$2" ]; then
			eval "$2='CMP abs'"
			return
		fi
		addr_abs
		cmp $addr
		;;
	$((0xD0)))
		if [ -n "$2" ]; then
			eval "$2='BNE rel'"
			return
		fi
		addr_rel
		bne $addr
		;;
	$((0xD1)))
		if [ -n "$2" ]; then
			eval "$2='CMP iny'"
			return
		fi
		addr_indy
		cmp $addr
		;;
	$((0xD5)))
		if [ -n "$2" ]; then
			eval "$2='CMP zex'"
			return
		fi
		addr_zex
		cmp $addr
		;;
	$((0xD8)))
		if [ -n "$2" ]; then
			eval "$2='CLD imp'"
			return
		fi
		addr_imp
		cld
		;;
	$((0xD9)))
		if [ -n "$2" ]; then
			eval "$2='CMP aby'"
			return
		fi
		addr_aby
		cmp $addr
		;;
	$((0xDD)))
		if [ -n "$2" ]; then
			eval "$2='CMP abx'"
			return
		fi
		addr_abx
		cmp $addr
		;;
	$((0xE0)))
		if [ -n "$2" ]; then
			eval "$2='CPX imm'"
			return
		fi
		addr_imm
		cpx $addr
		;;
	$((0xE4)))
		if [ -n "$2" ]; then
			eval "$2='CPX zer'"
			return
		fi
		addr_zer
		cpx $addr
		;;
	$((0xE5)))
		if [ -n "$2" ]; then
			eval "$2='SBC zer'"
			return
		fi
		addr_zer
		sbc $addr
		;;
	$((0xE6)))
		if [ -n "$2" ]; then
			eval "$2='SBC zer'"
			return
		fi
		addr_zer
		inc $addr
		;;
	$((0xE8)))
		if [ -n "$2" ]; then
			eval "$2='INX zer'"
			return
		fi
		addr_imp
		inx
		;;
	$((0xE9)))
		if [ -n "$2" ]; then
			eval "$2='SBC imm'"
			return
		fi
		addr_imm
		sbc $addr
		;;
	$((0xEA)))
		if [ -n "$2" ]; then
			eval "$2='NOP imp'"
			return
		fi
		addr_imp
		debug INSTR 'NOP'
		;;
	$((0xEC)))
		if [ -n "$2" ]; then
			eval "$2='CPX abs'"
			return
		fi
		addr_abs
		cpx $addr
		;;
	$((0xF0)))
		if [ -n "$2" ]; then
			eval "$2='BEQ rel'"
			return
		fi
		addr_rel
		beq $addr
		;;
	$((0xF8)))
		if [ -n "$2" ]; then
			eval "$2='SED imp'"
			return
		fi
		addr_imp
		sed_instr
		;;
	$((0xFF)))
		# Invalid opcode! We didn't halt?
		error 'Failed to halt at $%-4X (rel $%X)\n' $pc $((pc-ROM_BASE))
		;;
	*)
		error 'Unknown opcode $%02X\n' $opcode
		return 1
		;;
	esac
}

run_cpu() {
	local opcode addr char oldpc

	stty_configure

	while [ $pc -lt $((ROM_BASE+ROM_SIZE)) ]; do

		# Read keyboard input
		read_char char
		# The backtick ` triggers the debugger
		if [ "$char" = "96" ]; then
			trap_int
		elif [ -z "$nextchar" ]; then
			case $char in
			# Map '£' to backspace
			163)
				char=8
				;;
			# Map LF -> CR for msbasic
			10)
				char=13
				;;
			esac
			nextchar="$char"
		fi

		if breakpoint_hit || [ $DO_TRAP -eq 1 -o $SINGLE_STEP -eq 1 ]; then
			# Reconfigure the PTY to have a normal prompt for our
			# debug monitor
			stty_reset
			run_monitor
			# Back to non-blocking polled input with echo off
			stty_configure
		fi

		# Save PC (trap detection)
		oldpc=$pc
		readb opcode $((pc++))
		if [ -z "$opcode" ]; then error "Couldn't read opcode!" && break; fi
		# if [ -n "$nextchar" ]; then
		# 	debug OPCODE 'IN: $%02X\n' $nextchar
		# fi
		debug OPCODE '%04X: $%02X | ' $((pc-1)) $opcode

		decode_execute $opcode || DO_TRAP=1

		instr_count=$((instr_count+1))

		if [ $oldpc -eq $pc ]; then
			error '\n\n[!!!] TRAP!\n'
			dump_stack
		fi

		# New line for each opcode we execute
		if [ -n "$DEBUG" ]; then
			printf "\n" >&3
		fi
	done
}


##### Machine init #####

if [ $# -lt 1 ]; then
	echo "Usage: $0 ROM.bin"
	exit 1
fi

echo "Loading $1..."
loadbin $1

# Load reset vector
readh reset $RESET_VECTOR
printf "Reset vector: \$%X\n" "$reset"
pc=$reset

trap 'stty icanon echo min 1 time 0 || :; exit $EXITCODE' TERM

trap_int() {
	if [ $DO_TRAP -eq 1 ]; then
		# dump_status
		# dump_registers
		exit 1
	else
		DO_TRAP=1
	fi
}

run_cpu

# writeb 1023 2
# writeb 1010 255
dump_status
# dump_heap
dump_registers

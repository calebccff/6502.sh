#!/bin/sh -e

. machine.sh

hex () {
	printf "%0${pad}x\n" "$1"
}

preprocess() {
	# $1: in
	# $2: out
	cat $1 | sed \
		-e "s/;ROM_BASE;/$(hex $ROM_BASE)/g" \
		-e "s/;RESET_VECTOR;/$(hex $((RESET_VECTOR)))/g" \
		-e "s/;NMI_VECTOR;/$(hex $((NMI_VECTOR))))/g" \
		 > $2
}

compile() {
	base=$(basename $1 .asm)
	dasm $1 -f3 -obuild/$base.bin -sbuild/$base.sym.in
	cat build/$base.sym.in | head -n -1 | tail -n +2 | tr -s ' ' | cut -d' ' -f1,2 | sed 's/ / = $/g' > build/$base.sym
	rm build/$base.sym.in
}

mkdir -p build

if [ $# -eq 0 ]; then
	# Default to just building all tests
	for x in tests/*.asm; do
		test=$(basename $x .asm)
		# echo "Pre-process: $x"
		preprocess $x build/$test.asm
		# echo "Compile: build/$test.asm"
		compile build/$test.asm
	done
else
	preprocess $1 build/$(basename $1)
	compile build/$(basename $1)
fi



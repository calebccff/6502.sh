#!/bin/sh -e

./build.sh

if [ $# -gt 0 ]; then
	for x in $@; do
		echo -e "\n\n=========== Running $x ==========="
		./6502.sh $x
	done
	exit 0
fi

for x in tests/*.asm; do
	x=build/$(basename $x .asm).bin
	echo -e "\n\n=========== Running $x ==========="
	./6502.sh $x || exit 1
done

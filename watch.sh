#!/bin/sh

# $1: path to socket
sockaddr=${1:-/tmp/65sh.sock}

echo "Connecting to emulator on $sockaddr"
while true; do
	if [ -e /tmp/65sh.sock ]; then
		echo "Connected to emulator"
		cat /tmp/65sh.sock 2>/dev/null
	else
		sleep 0.1
	fi
done

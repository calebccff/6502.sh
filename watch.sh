#!/bin/sh

# $1: path to socket
sockaddr=${1:-/tmp/65sh.sock}

echo "Connecting to emulator on $sockaddr"
while true; do
	cat /tmp/65sh.sock 2>/dev/null
	sleep 0.1
done

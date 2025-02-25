#!/bin/sh

exec shellcheck -e SC3043,SC3018,SC3010 -s ash -S warning ./6502.sh

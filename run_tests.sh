#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2024 John Meneghini <jmeneghi@redhat.com> All rights reserved.
#
# Must be run as root
#
# Requires access to a physical tape drive.
#
# This test was developed with a QUANTUM ULTRIUM 4 U53F tape drive.
#

# this utility assumes the tape_reset_lib.sh libary is in the same directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. $DIR/tape_reset_lib.sh

check_root

[[ $# -lt 4 ]] || [[ $# -gt 4 ]] && check_params

DEV="$1"
SDEV="$2"

check_param2 $DEV
check_param2 $SDEV

DEBUG="$3"
DMESG="$4"

if [ -f $PWD/tape_reset_tests.log ]; then
	echo "rm -f  tape_reset_tests.log"
	cp -f  $PWD/tape_reset_tests.log $PWD/tape_reset_tests.log.old
	rm -f  $PWD/tape_reset_tests.log
fi

echo ""

for TEST in  tape_reset_test.sh tape_reset_status.sh tape_reset_load.sh tape_reset_eod.sh ;
do
#	echo "./$TEST $DEV $SDEV $DEBUG $DMESG"
	./$TEST $DEV $SDEV $DEBUG $DMESG 2>&1 | tee -a tape_reset_tests.log
done

if [ -f $PWD/tape_reset_tests.log ]; then
	grep ^-- $PWD/tape_reset_tests.log
fi

echo ""
echo "Done with $PWD/tape_reset_tests.log"
echo ""

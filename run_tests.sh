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

modprobe -r scsi_debug
modprobe scsi_debug tur_ms_to_ready=10000 ptype=1  max_luns=1 dev_size_mb=10000

[[ $# -lt 6 ]] || [[ $# -gt 7 ]] && check_debug_params

DEV="$1"
SDEV="$2"

check_param2 $DEV
check_param2 $SDEV
check_sdev_params $DEV $SDEV

DEBUG="$3"
DMESG="$4"
STOERR="$5"
SL="$6"
N="$7"

if [ -f $PWD/tape_reset_tests.log ]; then
	echo "rm -f  tape_reset_tests.log"
	cp -f  $PWD/tape_reset_tests.log $PWD/tape_reset_tests.log.old
	rm -f  $PWD/tape_reset_tests.log
fi

echo ""

# Determine which test to run by looking at the device model

NDEV=$(echo "$DEV" | awk -F"/dev/" '{print $2}')
MODEL=$(cat /sys/class/scsi_tape/$NDEV/device/model)

if [[ "$MODEL" == "scsi_debug" ]]; then
	$DIR/tape_reset_test_debug.sh $DEV $SDEV $DEBUG $DMESG $STOERR $SL $N 2>&1 | tee -a tape_reset_tests.log
else
	$DIR/tape_reset_test.sh $DEV $SDEV $DEBUG $DMESG $STOERR 2>&1 | tee -a tape_reset_tests.log
fi

if [ -f $PWD/tape_reset_tests.log ]; then
	grep -A 2 -E "TEST.FAILED" $PWD/tape_reset_tests.log
fi

echo ""
echo "Done with $PWD/tape_reset_tests.log"
echo ""

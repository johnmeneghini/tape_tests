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

if [ "$EUID" -ne 0 ]
	then echo "Please run as root"
	exit 1
fi

if [ $# -lt 3 -o $# -gt 3 ]
then
  echo ""
  echo " usage: ${0##*/} <st_device> <sg_device> <0|1|2>"
  echo ""
  echo "  These tests were developed with a QUANTUM ULTRIUM 4 U53F tape drive"
  echo "  and is designed to be used with real hardware."
  echo ""
  echo "  Runs all tests and concatenates out put in file tape_reset_tests.log"
  echo ""
  echo "  example:"
  echo ""
  echo "      ${0##*/} /dev/nst0 /dev/sg1 0 # debug off"
  echo "      ${0##*/} /dev/nst1 /dev/sg2 1 # debug on"
  echo "      ${0##*/} /dev/st0 /dev/sg1 2  # debug on, display dmesgs"
  echo ""

  which lsscsi > /dev/null 2>&1 || dnf install -y lsscsi
  lsscsi -ig
  ps x | grep dmesg | grep Tw | awk '{print $1}' | xargs kill -9  > /dev/null 2>&1
  exit
fi

DEV="$1"
SDEV="$2"
DEBUG="$3"

if [ ! -c $DEV ]; then
  echo "  Invalid argument: ${DEV}" >&2
  lsscsi -ig
  exit 1
fi

if [ ! -c $SDEV ]; then
  echo "  Invalid argument: ${SDEV}" >&2
  lsscsi -ig
  exit 1
fi

if [ ! -f $PWD/tape_reset.sh ]; then
  echo "  Error: $PWD/tape_reset.sh is missing"
  exit 1
fi

if [ -f $PWD/tape_reset_tests.log ]; then
	echo "rm -f  tape_reset_tests.log"
	cp -f  $PWD/tape_reset_tests.log $PWD/tape_reset_tests.log.old
	rm -f  $PWD/tape_reset_tests.log
fi

echo ""

for TEST in  tape_reset_test.sh tape_reset_status.sh tape_reset_load.sh tape_reset_eod.sh ;
do
#	echo "./$TEST $DEV $SDEV $DEBUG"
	./$TEST $DEV $SDEV $DEBUG 2>&1 | tee -a tape_reset_tests.log
done

if [ -f $PWD/tape_reset_tests.log ]; then
	grep ^-- $PWD/tape_reset_tests.log
fi

echo ""
echo "Done with $PWD/tape_reset_tests.log"
echo ""

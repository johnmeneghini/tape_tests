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

if [ $# -lt 3 -o $# -gt 3 ]
then
  echo ""
  echo " usage: ${0##*/} <st_device> <sg_device> <0|1|2>"
  echo ""
  echo "  This test was developed with a QUANTUM ULTRIUM 4 U53F tape drive"
  echo "  and is designed to be used with real hardware."
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

which mt > /dev/null 2>&1 || dnf install -y mt-st

if [ "$DEBUG" -gt 1 ]; then
	echo "Start dmesg -Tw"
	dmesg -C
	dmesg -Tw &
fi

echo ""

uname -r
lsscsi -ig

if [ "$DEBUG" -gt 0 ]; then
	echo 1 > /sys/module/st/drivers/scsi\:st/debug_flag
else
	echo 0 > /sys/module/st/drivers/scsi\:st/debug_flag
fi

echo -n "/sys/module/st/drivers/scsi\:st/debug_flag : "
cat /sys/module/st/drivers/scsi\:st/debug_flag
echo ""

set -e
set -v

# Write two files on the tape and make sure we can read them
mt -f $DEV status
mt -f $DEV rewind
mt -f $DEV status
dd if=/dev/random count=1001024 of=$DEV
dd if=/dev/random count=1001024 of=$DEV
mt -f $DEV rewind
mt -f $DEV status
dd if=$DEV count=1024 of=/dev/nul
mt -f $DEV status

# Reset the device with IO inprogress
mt -f $DEV eod
mt -f $DEV status
set +e
$PWD/tape_reset.sh $SDEV 5 &
dd if=/dev/random count=1001024 of=$DEV

# These commands should fail
mt -f $DEV status
mt -f $DEV weof 1
mt -f $DEV wset 1
dd if=$DEV count=1024 of=/dev/nul
dd if=/dev/random count=1001024 of=$DEV
mt -f $DEV status

# rewind should succeed
set -e
mt -f $DEV rewind
mt -f $DEV status

# Reset the device with IO inprogress
mt -f $DEV eod
mt -f $DEV status
set +e
$PWD/tape_reset.sh $SDEV 5 &
dd if=/dev/random count=1001024 of=$DEV
mt -f $DEV status

# seek should succeed after reset
set -e
mt -f $DEV eod
mt -f $DEV status

# Reset the device with IO inprogress
set +e
$PWD/tape_reset.sh $SDEV 5 &
dd if=/dev/random count=1001024 of=$DEV
mt -f $DEV status

# retension should succeed after reset
set -e
mt -f $DEV retension
mt -f $DEV status

# Reset the device with IO inprogress
mt -f $DEV eod
mt -f $DEV status
set +e
$PWD/tape_reset.sh $SDEV 5 &
dd if=/dev/random count=1001024 of=$DEV
mt -f $DEV status

# Reset the device with IO inprogress
set +e
$PWD/tape_reset.sh $SDEV 5 &
dd if=/dev/random count=1001024 of=$DEV
mt -f $DEV status

# eject should succeed after reset
set -e
mt -f $DEV eject
mt -f $DEV status

# Reset the device with no tape
$PWD/tape_reset.sh $SDEV 1 &
sleep 3

# Status should succeed
mt -f $DEV status

# These command should succeed, even though there's no tape.
mt -f $DEV weof 1
mt -f $DEV wset 1
mt -f $DEV eod
dd if=$DEV count=1024 of=/dev/nul
dd if=/dev/random count=1001024 of=$DEV

# Load the tape should succed
mt -f $DEV load
mt -f $DEV status

# Reset the device with tape at EOD
mt -f $DEV eod
mt -f $DEV status
$PWD/tape_reset.sh $SDEV 1 &
mt -f $DEV status
sleep 3

# These commands fail after reset
set +e
dd if=/dev/random count=101024 of=$DEV
mt -f $DEV weof 1
mt -f $DEV wset 1
dd if=$DEV count=1024 of=/dev/nul
dd if=/dev/random count=1001024 of=$DEV

# Reset the device while at BOT
set -e
mt -f $DEV rewind
mt -f $DEV status
$PWD/tape_reset.sh $SDEV 1 &
sleep 3

# These commands should fail
set +e
dd if=/dev/random count=101024 of=$DEV
mt -f $DEV weof 1
mt -f $DEV wset 1
dd if=$DEV count=1024 of=/dev/nul
dd if=/dev/random count=1001024 of=$DEV

# Done, rewind the tape
set -e
mt -f $DEV status
mt -f $DEV rewind
mt -f $DEV status

set +v

if [ "$DEBUG" -gt 1 ]; then
	echo "kill dmesg -Tw"
	ps x | grep dmesg | grep Tw | awk '{print $1}' | xargs kill -9  > /dev/null 2>&1
fi


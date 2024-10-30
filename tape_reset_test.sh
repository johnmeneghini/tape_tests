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
lsscsi -ig
echo ""

if [ "$DEBUG" -gt 0 ]; then
	echo 1 > /sys/module/st/drivers/scsi\:st/debug_flag
else
	echo 0 > /sys/module/st/drivers/scsi\:st/debug_flag
fi

echo -n "/sys/module/st/drivers/scsi\:st/debug_flag : "
cat /sys/module/st/drivers/scsi\:st/debug_flag
echo ""
uname -r
echo ""

set -e
set -v

#
# Write two files on the tape and make sure we can read them
#
mt -f $DEV status
mt -f $DEV rewind
mt -f $DEV status
dd if=/dev/random count=1001024 of=$DEV
dd if=/dev/random count=1001024 of=$DEV
mt -f $DEV rewind
mt -f $DEV status
dd if=$DEV count=1024 of=/dev/null
mt -f $DEV fsf 1
mt -f $DEV status
dd if=$DEV count=1024 of=/dev/null
mt -f $DEV status
mt -f $DEV eod
mt -f $DEV status

set +e

#
# Reset the device with IO inprogress
#
$PWD/tape_reset.sh $SDEV 5 &

#
# These commands should fail
#
dd if=/dev/random count=1001024 of=$DEV && echo "---TEST FAILED--- with status $?"
mt -f $DEV weof 1 && echo "---TEST FAILED--- with status $?"
mt -f $DEV wset 1 && echo "---TEST FAILED--- with status $?"
dd if=$DEV count=1024 of=/dev/null && echo "---TEST FAILED--- with status $?"
dd if=/dev/random count=1001024 of=$DEV && echo "---TEST FAILED--- with status $?"

#
# These command should succeed
#
mt -f $DEV status || echo "---TEST FAILED--- with status $?"
mt -f $DEV rewind || echo "---TEST FAILED--- with status $?"
mt -f $DEV status || echo "---TEST FAILED--- with status $?"
mt -f $DEV eod || echo "---TEST FAILED--- with status $?"
mt -f $DEV status || echo "---TEST FAILED--- with status $?"

#
# Reset the device with IO inprogress
#
$PWD/tape_reset.sh $SDEV 5 &

#
# This command should fail
#
dd if=/dev/random count=1001024 of=$DEV && echo "---TEST FAILED--- with status $?"

#
# Seek should succeed after reset
#
mt -f $DEV status || echo "---TEST FAILED--- with status $?"
mt -f $DEV eod || echo "---TEST FAILED--- with status $?"
mt -f $DEV status || echo "---TEST FAILED--- with status $?"

#
# Reset the device with IO inprogress
#
$PWD/tape_reset.sh $SDEV 5 &

#
# This command should fail
#
dd if=/dev/random count=1001024 of=$DEV && echo "---TEST FAILED--- with status $?"

#
# retension should succeed after reset
#
mt -f $DEV status || echo "---TEST FAILED--- with status $?"
mt -f $DEV rretension || echo "---TEST FAILED--- with status $?"
mt -f $DEV status || echo "---TEST FAILED--- with status $?"
mt -f $DEV eod || echo "---TEST FAILED--- with status $?"
mt -f $DEV status || echo "---TEST FAILED--- with status $?"

#
# Reset the device with IO inprogress
#
$PWD/tape_reset.sh $SDEV 5 &

#
# This command should fail
#
dd if=/dev/random count=1001024 of=$DEV && echo "---TEST FAILED--- with status $?"

#
# eject should succeed after reset
#
mt -f $DEV status || echo "---TEST FAILED--- with status $?"
mt -f $DEV eject || echo "---TEST FAILED--- with status $?"
mt -f $DEV status || echo "---TEST FAILED--- with status $?"

#
# Reset the device with no tape
#
$PWD/tape_reset.sh $SDEV 1 &
sleep 3

#
# Status should succeed
#
mt -f $DEV status || echo "---TEST FAILED--- with status $?"

#
# These command fail when there's no tape.
#
mt -f $DEV weof 1 && echo "---TEST FAILED--- with status $?"
mt -f $DEV wset 1 && echo "---TEST FAILED--- with status $?"
mt -f $DEV eod && echo "---TEST FAILED--- with status $?"
dd if=$DEV count=1024 of=/dev/null && echo "---TEST FAILED--- with status $?"
dd if=/dev/random count=1001024 of=$DEV && echo "---TEST FAILED--- with status $?"

#
# Load the tape should succed
#
mt -f $DEV status || echo "---TEST FAILED--- with status $?"
mt -f $DEV load || echo "---TEST FAILED--- with status $?"
mt -f $DEV status || echo "---TEST FAILED--- with status $?"
mt -f $DEV eod || echo "---TEST FAILED--- with status $?"
mt -f $DEV status || echo "---TEST FAILED--- with status $?"

#
# Reset the device with tape at EOD
#
$PWD/tape_reset.sh $SDEV 1 &
sleep 3

#
# These commands should fail
#
dd if=/dev/random count=1001024 of=$DEV && echo "---TEST FAILED--- with status $?"
mt -f $DEV weof 1 && echo "---TEST FAILED--- with status $?"
mt -f $DEV wset 1 && echo "---TEST FAILED--- with status $?"
dd if=$DEV count=1024 of=/dev/null && echo "---TEST FAILED--- with status $?"
dd if=/dev/random count=1001024 of=$DEV && echo "---TEST FAILED--- with status $?"

#
# These command should succeed
#
mt -f $DEV status || echo "---TEST FAILED--- with status $?"
mt -f $DEV rewind || echo "---TEST FAILED--- with status $?"
mt -f $DEV status || echo "---TEST FAILED--- with status $?"

#
# Reset the device while at BOT
#
$PWD/tape_reset.sh $SDEV 1 &
sleep 3

#
# These commands should fail
#
dd if=/dev/random count=1001024 of=$DEV && echo "---TEST FAILED--- with status $?"
mt -f $DEV weof 1 && echo "---TEST FAILED--- with status $?"
mt -f $DEV wset 1 && echo "---TEST FAILED--- with status $?"
dd if=$DEV count=1024 of=/dev/null && echo "---TEST FAILED--- with status $?"
dd if=/dev/random count=1001024 of=$DEV && echo "---TEST FAILED--- with status $?"

#
# Done, rewind the tape
#
mt -f $DEV status || echo "---TEST FAILED--- with status $?"
mt -f $DEV rewind || echo "---TEST FAILED--- with status $?"
mt -f $DEV status || echo "---TEST FAILED--- with status $?"

set +v

echo ""
echo "Done"
echo ""

if [ "$DEBUG" -gt 1 ]; then
	echo "kill dmesg -Tw"
	ps x | grep dmesg | grep Tw | awk '{print $1}' | xargs kill -9  > /dev/null 2>&1
fi


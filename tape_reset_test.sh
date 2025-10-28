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

[[ $# -lt 5 ]] || [[ $# -gt 5 ]] && check_params

DEV="$1"
SDEV="$2"
D=${DEV:4}
echo "$D"

check_param2 $DEV
check_param2 $SDEV
check_sdev_params $DEV $SDEV
check_dev_nodebug_param $DEV

DEBUG="$3"
DMESG="$4"
STOERR="$5"

set_debug
set_dmesg

echo ""
lsscsi -igN
echo ""

TDEV=$(echo "$DEV" | awk -F"/" '{print $3}')

set +e

#
# Write two files on the tape and make sure we can read them
#

test_reset_blocked_false "$TDEV"
do_cmd_true "sg_map -st -x -i"
test_reset_blocked_false "$TDEV"
do_cmd_true "stinit -f $DIR/stinit.conf -v $DEV"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV rewind"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV stshowoptions"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV stsetoptions no-blklimits"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV stshowoptions"
test_reset_blocked_false "$TDEV"
do_cmd_true "dd if=/dev/random count=1001024 of=$DEV"
test_reset_blocked_false "$TDEV"
do_cmd_true "dd if=/dev/random count=1001024 of=$DEV"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV rewind "
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"
do_cmd_true "dd if=$DEV count=1024 of=/dev/null"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV fsf 1"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"
do_cmd_true "dd if=$DEV count=1024 of=/dev/null"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV eod"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"

#
# Reset the device and wait
#
$DIR/tape_reset.sh $SDEV 5 &

echo "Sleep for 10 seconds"
sleep 10

do_cmd_true "sg_map -st -x -i"
test_reset_blocked_true "$TDEV"

#
# These commands should fail
#
do_cmd_false "mt -f $DEV stsetoptions no-blklimits"
test_reset_blocked_true "$TDEV"
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV "
test_reset_blocked_true "$TDEV"
do_cmd_false "mt -f $DEV weof 1 "
test_reset_blocked_true "$TDEV"
do_cmd_false "mt -f $DEV wset 1"
test_reset_blocked_true "$TDEV"
do_cmd_false "dd if=$DEV count=1024 of=/dev/null"
test_reset_blocked_true "$TDEV"
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"
test_reset_blocked_true "$TDEV"

#
# The commands before rewind should have position_reset set to 1
# the ones after rewind should have position_reset set to 0;
# all commands should succeed.
#
do_cmd_true "sg_map -st -x -i"
test_reset_blocked_true "$TDEV"
do_cmd_true "stinit -f $DIR/stinit.conf -v $DEV"
test_reset_blocked_true "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_true "$TDEV"
do_cmd_true "mt -f $DEV rewind"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV eod"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV stsetoptions no-blklimits"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV stshowoptions"
test_reset_blocked_false "$TDEV"
do_cmd_true "sg_map -st -x -i"
test_reset_blocked_false "$TDEV"

#
# Reset the device with IO in progress
#
$DIR/tape_reset.sh $SDEV 5 &

#
# This command should fail
#
test_reset_blocked_false "$TDEV"
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"
test_reset_blocked_true "$TDEV"

do_cmd_true "sg_map -st -x -i"
test_reset_blocked_true "$TDEV"
do_cmd_true "stinit -f $DIR/stinit.conf -v $DEV"
test_reset_blocked_true "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_true "$TDEV"

#
# Seek should succeed after reset
#
do_cmd_true "mt -f $DEV eod"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"

#
# Reset the device with IO inprogress
#
$DIR/tape_reset.sh $SDEV 5 &

#
# This command should fail
#
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"
test_reset_blocked_true "$TDEV"

#
# retension should succeed after reset
#
do_cmd_true "mt -f $DEV status"
test_reset_blocked_true "$TDEV"
do_cmd_true "mt -f $DEV retension"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV eod"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"

#
# Reset the devices
#
$DIR/tape_reset.sh $SDEV 5 &

echo "Sleep for 10 seconds"
sleep 10

#
# This command should fail
#
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"
test_reset_blocked_true "$TDEV"

#
# eject should succeed after reset
#
do_cmd_true "mt -f $DEV status"
test_reset_blocked_true "$TDEV"
do_cmd_true "mt -f $DEV eject"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"

#
# Reset the device with no tape
#
$DIR/tape_reset.sh $SDEV 1 &

echo "Sleep for 3 seconds"
sleep 3

#
# Status should succeed
#
do_cmd_true "mt -f $DEV status"
test_reset_blocked_true "$TDEV"

#
# These commands fail when there's no tape.
#
do_cmd_false "mt -f $DEV weof 1"
do_cmd_false "mt -f $DEV wset 1"
test_reset_blocked_true "$TDEV"
do_cmd_false "mt -f $DEV eod"
test_reset_blocked_true "$TDEV"
do_cmd_false "dd if=$DEV count=1024 of=/dev/null"
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"
test_reset_blocked_true "$TDEV"

#
# Load the tape should succed
#
do_cmd_true "mt -f $DEV status"
test_reset_blocked_true "$TDEV"
do_cmd_true "mt -f $DEV load"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV eod"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_false "$TDEV"

#
# Reset the device with tape at EOD
#
$DIR/tape_reset.sh $SDEV 1 &

echo "Sleep for 3 seconds"
sleep 3

#
# These commands should fail
#
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"
test_reset_blocked_true "$TDEV"
do_cmd_false "mt -f $DEV weof 1"
do_cmd_false "mt -f $DEV wset 1"
do_cmd_false "dd if=$DEV count=1024 of=/dev/null"
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"
test_reset_blocked_true "$TDEV"

#
# These command should succeed
#
do_cmd_true "sg_map -st -x -i"
do_cmd_true "stinit -f $DIR/stinit.conf -v $DEV"
do_cmd_true "mt -f $DEV status"
test_reset_blocked_true "$TDEV"
do_cmd_true "mt -f $DEV rewind"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"

#
# Reset the device while at BOT
#
$DIR/tape_reset.sh $SDEV 1 &

echo "Sleep for 3 seconds"
sleep 3

#
# These commands should fail
#
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"
test_reset_blocked_true "$TDEV"
do_cmd_false "mt -f $DEV weof 1"
do_cmd_false "mt -f $DEV wset 1"
test_reset_blocked_true "$TDEV"
do_cmd_false "dd if=$DEV count=1024 of=/dev/null"
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"
test_reset_blocked_true "$TDEV"

#
# Done, rewind the tape
#
do_cmd_true "mt -f $DEV status"
test_reset_blocked_true "$TDEV"
do_cmd_true "mt -f $DEV rewind"
test_reset_blocked_false "$TDEV"
do_cmd_true "mt -f $DEV status"

clear_dmesg

echo ""
echo "Done"
echo ""

exit

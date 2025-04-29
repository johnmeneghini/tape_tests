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
D=${DEV:4}
echo "$D"

check_param2 $DEV
check_param2 $SDEV

DEBUG="$3"
DMESG="$4"

set_debug
set_dmesg

echo ""
lsscsi -ig
echo ""

set +e

#
# Write two files on the tape and make sure we can read them
#

do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV rewind"
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV stshowoptions"
do_cmd_true "mt -f $DEV stsetoptions no-blklimits"
do_cmd_true "mt -f $DEV stshowoptions"
do_cmd_true "dd if=/dev/random count=1001024 of=$DEV"
do_cmd_true "dd if=/dev/random count=1001024 of=$DEV"
do_cmd_true "mt -f $DEV rewind "
do_cmd_true "mt -f $DEV status"
do_cmd_true "dd if=$DEV count=1024 of=/dev/null"
do_cmd_true "mt -f $DEV fsf 1"
do_cmd_true "mt -f $DEV status"
do_cmd_true "dd if=$DEV count=1024 of=/dev/null"
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV eod"
do_cmd_true "mt -f $DEV status"

#
# Reset the device
#
$DIR/tape_reset.sh $SDEV 5 &
sleep 7

#
# These commands should fail
#
do_cmd_false "mt -f $DEV stsetoptions no-blklimits"
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV "
do_cmd_false "mt -f $DEV weof 1 "
do_cmd_false "mt -f $DEV wset 1"
do_cmd_false "dd if=$DEV count=1024 of=/dev/null"
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"

#
# These command should succeed
#
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV rewind"
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV eod"
do_cmd_true "mt -f $DEV stsetoptions no-blklimits"
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV stshowoptions"

#
# Reset the device with IO inprogress
#
$DIR/tape_reset.sh $SDEV 5 &

#
# This command should fail
#
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"

#
# Seek should succeed after reset
#
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV eod"
do_cmd_true "mt -f $DEV status"

#
# Reset the device with IO inprogress
#
$DIR/tape_reset.sh $SDEV 5 &

#
# This command should fail
#
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"

#
# retension should succeed after reset
#
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV retension"
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV eod"
do_cmd_true "mt -f $DEV status"

#
# Reset the device with IO inprogress
#
$DIR/tape_reset.sh $SDEV 5 &

#
# This command should fail
#
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"

#
# eject should succeed after reset
#
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV eject"
do_cmd_true "mt -f $DEV status"

#
# Reset the device with no tape
#
$DIR/tape_reset.sh $SDEV 1 &
sleep 3

#
# Status should succeed
#
do_cmd_true "mt -f $DEV status"

#
# These command fail when there's no tape.
#
do_cmd_false "mt -f $DEV weof 1"
do_cmd_false "mt -f $DEV wset 1"
do_cmd_false "mt -f $DEV eod"
do_cmd_false "dd if=$DEV count=1024 of=/dev/null"
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"

#
# Load the tape should succed
#
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV load"
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV eod"
do_cmd_true "mt -f $DEV status"

#
# Reset the device with tape at EOD
#
$DIR/tape_reset.sh $SDEV 1 &
sleep 3

#
# These commands should fail
#
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"
do_cmd_false "mt -f $DEV weof 1"
do_cmd_false "mt -f $DEV wset 1"
do_cmd_false "dd if=$DEV count=1024 of=/dev/null"
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"

#
# These command should succeed
#
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV rewind"
do_cmd_true "mt -f $DEV status"

#
# Reset the device while at BOT
#
$DIR/tape_reset.sh $SDEV 1 &
sleep 3

#
# These commands should fail
#
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"
do_cmd_false "mt -f $DEV weof 1"
do_cmd_false "mt -f $DEV wset 1"
do_cmd_false "dd if=$DEV count=1024 of=/dev/null"
do_cmd_false "dd if=/dev/random count=1001024 of=$DEV"

#
# Done, rewind the tape
#
do_cmd_true "mt -f $DEV status"
do_cmd_true "mt -f $DEV rewind"
do_cmd_true "mt -f $DEV status"

echo ""
echo "Done"
echo ""

clear_dmesg


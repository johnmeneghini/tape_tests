#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2024 John Meneghini <jmeneghi@redhat.com> All rights reserved.
#
# Must be run as root
#

# this utility assumes the tape_reset_lib.sh libary is in the same directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. $DIR/tape_reset_lib.sh

check_root

[[ $# -lt 5 ]] || [[ $# -gt 5 ]] && check_debug_params

DEBUG="$3"
DMESG="$4"
SL="$5"

set_dmesg

N=4

modprobe -r scsi_debug
echo ""
echo "--- modprobe scsi_debug tur_ms_to_ready=10000 ptype=1  max_luns=$N dev_size_mb=10000 scsi_level=$SL"
modprobe scsi_debug tur_ms_to_ready=10000 ptype=1  max_luns=$N dev_size_mb=10000 scsi_level=$SL
lsscsi -ig
echo ""

DEV="$1"
SDEV="$2"

check_param2 "/dev/nst$DEV"
check_param2 "/dev/sg$SDEV"

set_debug

g=1
((g=N-g))

h=$DEV
j=$DEV
((j=j+g))

do_cmd_true "sg_map -st -x -i"

echo " Send the stinit cmmmand"
for i in $(seq $h $j); do
    do_cmd_true "stinit -f $DIR/stinit.conf -v /dev/nst$i"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f /dev/nst$i status"
    test_reset_blocked_false "nst$i"
done

echo " Sleeping for 20 seconds"
sleep 20

echo " Check the status"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i status"
   test_reset_blocked_false "nst$i"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i stshowoptions"
done

echo " Set options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i stsetoptions no-blklimits"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i stshowoptions"
done

echo " Load the tape"
for i in $(seq $h $j); do
    do_cmd_true "mt -f /dev/nst$i load"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f /dev/nst$i status"
done

echo " Try writing the tape"
for i in $(seq $h $j); do
    do_cmd_true "dd if=/dev/random count=50 of=/dev/nst$i "
    do_cmd_true "mt -f /dev/nst$i weof 1 "
done

echo " Rewind the tape"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i rewind"
done

echo " Try reading the tape"
for i in $(seq $h $j); do
    do_cmd_true "dd if=/dev/nst$i count=50 of=/dev/null"
done

h=$SDEV
j=$SDEV
((j=j+g))

echo "Reset the targets"
for i in $(seq $h $j); do
    do_cmd_true "sg_reset --target /dev/sg$i"
done

echo " Sleeping for 5 seconds"
sleep 5

h=$DEV
j=$DEV
((j=j+g))

do_cmd_true "sg_map -st -x -i"

echo " Send the stinit cmmmand"
for i in $(seq $h $j); do
    do_cmd_true "stinit -f $DIR/stinit.conf -v /dev/nst$i"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true " mt -f /dev/nst$i status"
    test_reset_blocked_true "nst$i"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i stshowoptions"
done

echo " Set options"
for i in $(seq $h $j); do
   do_cmd_false "mt -f /dev/nst$i stsetoptions no-blklimits"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i stshowoptions"
done

echo " Try writing to the tape"
for i in $(seq $h $j); do
    do_cmd_false "dd if=/dev/random count=50 of=/dev/nst$i "
    do_cmd_false "mt -f /dev/nst$i weof 1 "
    test_reset_blocked_true "nst$i"
done

echo " Try reading the tape"
for i in $(seq $h $j); do
    do_cmd_false "dd if=/dev/nst$i count=50 of=/dev/null"
    test_reset_blocked_true "nst$i"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true " mt -f /dev/nst$i status"
done

echo " Load the tape"
for i in $(seq $h $j); do
    do_cmd_true "mt -f /dev/nst$i load"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f /dev/nst$i status"
    test_reset_blocked_false "nst$i"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i stshowoptions"
done

echo " Set options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i stsetoptions no-blklimits"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i stshowoptions"
done

echo " Try writing to the tape"
for i in $(seq $h $j); do
    do_cmd_true "dd if=/dev/random count=50 of=/dev/nst$i "
    do_cmd_true "mt -f /dev/nst$i weof 1 "
done

echo " Rewind the tape"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i rewind"
done

echo " Try reading the tape"
for i in $(seq $h $j); do
    do_cmd_true "dd if=/dev/nst$i count=50 of=/dev/null"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f /dev/nst$i status"
done

echo " Erase the tape"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i erase"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f /dev/nst$i status"
done

echo " Rewind the tape"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i rewind"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f /dev/nst$i status"
done

echo ""
echo "Done"
echo ""

clear_dmesg

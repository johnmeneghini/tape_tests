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

[[ $# -lt 4 ]] || [[ $# -gt 4 ]] && check_debug_params

DEBUG="$3"
DMESG="$4"

set_dmesg

N=1

modprobe -r scsi_debug
modprobe scsi_debug tur_ms_to_ready=10000 ptype=1  max_luns=$N dev_size_mb=10000 scsi_level=6
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
done

echo " Sleeping for 20 seconds"
sleep 20

echo " Check the status"
for i in $(seq $h $j); do
   do_cmd_true "mt -f /dev/nst$i status"
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

echo " Try writing to the tape"
for i in $(seq $h $j); do
    do_cmd_true "dd if=/dev/random count=50 of=/dev/nst$i "
    do_cmd_true "mt -f /dev/nst$i weof 1 "
    do_cmd_true "mt -f /dev/nst$i wset 1"
    do_cmd_true "dd if=/dev/nst$i count=50 of=/dev/null"
    do_cmd_true "dd if=/dev/random count=50 of=/dev/nst$i"
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
    do_cmd_false "dd if=/dev/random count=50 of=/dev/nst$i "
    do_cmd_false "mt -f /dev/nst$i weof 1 "
    do_cmd_false "mt -f /dev/nst$i wset 1"
    do_cmd_false "dd if=/dev/nst$i count=50 of=/dev/null"
    do_cmd_false "dd if=/dev/random count=50 of=/dev/nst$i"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true " mt -f /dev/nst$i status"
done

echo " Load the tape"
for i in $(seq $h $j); do
    do_cmd_true "mt -f /dev/nst$i load"
done

# Everytime I rewind the tape the scsi_debug tape emulator loses it's mind.

#echo " Rewind the tape"
#for i in $(seq $h $j); do
#   do_cmd_true "mt -f /dev/nst$i rewind"
#done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f /dev/nst$i status"
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
    do_cmd_true "mt -f /dev/nst$i wset 1"
    do_cmd_true "dd if=/dev/nst$i count=50 of=/dev/null"
    do_cmd_true "dd if=/dev/random count=50 of=/dev/nst$i"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f /dev/nst$i status"
done

echo ""
echo "Done"
echo ""

clear_dmesg

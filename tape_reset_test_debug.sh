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

[[ $# -lt 6 ]] || [[ $# -gt 7 ]] && check_debug_params

DEBUG="$3"
DMESG="$4"
STOERR="$5"
SL="$6"
N="$7"

if [ -z "$N" ]; then
    N=4
elif [ "$N" -eq 0 ]; then
    N=4
else
    echo "N = $N"
fi

set_dmesg

modprobe -r scsi_debug
echo ""
echo "--- modprobe scsi_debug tur_ms_to_ready=10000 ptype=1  max_luns=$N dev_size_mb=10000 scsi_level=$SL"
modprobe scsi_debug tur_ms_to_ready=10000 ptype=1  max_luns=$N dev_size_mb=10000 scsi_level=$SL
lsscsi -igN
echo ""

dev="$1"
sdev="$2"

check_param2 "$dev"
check_param2 "$sdev"
check_sdev_params $dev $sdev
check_dev_debug_param $dev

set_debug

DEV=$(echo "$dev" | awk -F"st" '{print $2}')
SDEV=$(echo "$sdev" | awk -F"sg" '{print $2}')

TAPE=$(echo "$dev" | awk -F"st" '{print $1}')
TAPE="${TAPE}st"

g=1
((g=N-g))

h=$DEV
j=$DEV
((j=j+g))

do_cmd_true "sg_map -st -x -i"

echo " Send the stinit cmmmand"
for i in $(seq $h $j); do
    do_cmd_true "stinit -f $DIR/stinit.conf -v $TAPE$i"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f $TAPE$i status"
    test_reset_blocked_false "nst$i"
done

echo " Sleeping for 20 seconds"
sleep 20

echo " Check the status"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i status"
   test_reset_blocked_false "nst$i"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i stshowoptions"
done

echo " Set options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i stsetoptions no-blklimits"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i stshowoptions"
done

echo " Load the tape"
for i in $(seq $h $j); do
    do_cmd_true "mt -f $TAPE$i load"
    test_reset_blocked_false "nst$i"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f $TAPE$i status"
done

echo " Try writing the tape"
for i in $(seq $h $j); do
    do_cmd_true "dd if=/dev/random count=50 of=$TAPE$i "
    do_cmd_true "mt -f $TAPE$i weof 1 "
done

echo " Rewind the tape"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i rewind"
done

echo " Try reading the tape"
for i in $(seq $h $j); do
    do_cmd_true "dd if=$TAPE$i count=50 of=/dev/null"
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

do_cmd_warn "sg_map -st -x -i"
check_dmesg

echo " Send the stinit cmmmand"
for i in $(seq $h $j); do
    do_cmd_warn "stinit -f $DIR/stinit.conf -v $TAPE$i"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true " mt -f $TAPE$i status"
    test_reset_blocked_true "nst$i"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i stshowoptions"
done

echo " Set options"
for i in $(seq $h $j); do
   do_cmd_warn "mt -f $TAPE$i stsetoptions no-blklimits"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i stshowoptions"
done

echo " Try writing to the tape"
for i in $(seq $h $j); do
    do_cmd_false "dd if=/dev/random count=50 of=$TAPE$i "
    do_cmd_false "mt -f $TAPE$i weof 1 "
    test_reset_blocked_true "nst$i"
done

echo " Try reading the tape"
for i in $(seq $h $j); do
    do_cmd_false "dd if=$TAPE$i count=50 of=/dev/null"
    test_reset_blocked_true "nst$i"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true " mt -f $TAPE$i status"
done

echo " Load the tape"
for i in $(seq $h $j); do
    do_cmd_true "mt -f $TAPE$i load"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f $TAPE$i status"
    test_reset_blocked_false "nst$i"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i stshowoptions"
done

echo " Set options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i stsetoptions no-blklimits"
done

echo " Read options"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i stshowoptions"
done

echo " Try writing to the tape"
for i in $(seq $h $j); do
    do_cmd_true "dd if=/dev/random count=50 of=$TAPE$i "
    do_cmd_true "mt -f $TAPE$i weof 1 "
done

echo " Rewind the tape"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i rewind"
done

echo " Try reading the tape"
for i in $(seq $h $j); do
    do_cmd_true "dd if=$TAPE$i count=50 of=/dev/null"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f $TAPE$i status"
done

echo " Erase the tape"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i erase"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f $TAPE$i status"
done

echo " Rewind the tape"
for i in $(seq $h $j); do
   do_cmd_true "mt -f $TAPE$i rewind"
done

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true "mt -f $TAPE$i status"
done

echo ""
echo "Done"
echo ""

clear_dmesg

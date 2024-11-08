#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2024 John Meneghini <jmeneghi@redhat.com> All rights reserved.
#
# Must be run as root
#

if [ "$EUID" -ne 0 ]
        then echo "Please run as root"
        exit 1
fi

do_cmd_true() {
echo  ""
echo  "$1"
$1 || echo "--- $1 TEST FAILED--- with status $?"
}

do_cmd_false() {
echo  ""
echo  "$1"
$1 && echo "--- $1 TEST FAILED--- with status $?"
}

if [ $# -lt 3 -o $# -gt 3 ]
then
  echo ""
  echo " Usage: ${0##*/} /dev/nst<n> /dev/sg<n> <0|1|2>"
  echo ""
  echo "  Example:"
  echo ""
  echo "      ${0##*/} 0 1 0 = /dev/nst0 /dev/sg1 nodebug"
  echo "      ${0##*/} 3 4 1 = /dev/nst3 /dev/sg4 debug"
  echo "      ${0##*/} 3 4 2 = /dev/nst3 /dev/sg4 debug display dmesgs"
  echo ""

  which lsscsi > /dev/null 2>&1 || dnf install -y lsscsi
  ps x | grep dmesg | grep Tw | awk '{print $1}' | xargs kill -9  > /dev/null 2>&1
  modprobe -r scsi_debug
  modprobe scsi_debug tur_ms_to_ready=10000 ptype=1  max_luns=1 dev_size_mb=1000
  lsscsi -ig
  modprobe -r scsi_debug
  exit
fi

which mt > /dev/null 2>&1 || dnf install -y mt-st

DEBUG="$3"

echo ""
uname -r

if [ "$DEBUG" -gt 0 ]; then
	echo 1 > /sys/module/st/drivers/scsi\:st/debug_flag
else
	echo 0 > /sys/module/st/drivers/scsi\:st/debug_flag
fi

echo ""
echo -n "/sys/module/st/drivers/scsi\:st/debug_flag : "
cat /sys/module/st/drivers/scsi\:st/debug_flag

if [ "$DEBUG" -gt 1 ]; then
	dmesg -C
	dmesg -Tw &
fi

N=1

modprobe -r scsi_debug
modprobe scsi_debug tur_ms_to_ready=10000 ptype=1  max_luns=$N dev_size_mb=10000
lsscsi -ig
echo ""

DEV="$1"
SDEV="$2"

if [ ! -c /dev/nst$DEV ]; then
  echo "  Invalid argument: ${DEV}" >&2
  exit 1
fi

if [ ! -c /dev/sg$SDEV ]; then
  echo "  Invalid argument: ${SDEV}" >&2
  exit 1
fi

g=1
((g=N-g))

h=$DEV
j=$DEV
((j=j+g))

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

echo " Check the status"
for i in $(seq $h $j); do
    do_cmd_true " mt -f /dev/nst$i status"
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

ps x | grep dmesg | grep Tw | awk '{print $1}' | xargs kill -9  > /dev/null 2>&1

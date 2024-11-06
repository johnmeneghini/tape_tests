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

modprobe -r scsi_debug
modprobe scsi_debug tur_ms_to_ready=10000 ptype=1  max_luns=4 dev_size_mb=1000
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

h=$DEV
j=$DEV
((j=j+3))

echo " Check the status"
for i in $(seq $h $j); do
    echo =================================================================
    echo " mt -f /dev/nst$i status"
    mt -f /dev/nst$i status;
    echo " status $?"
    echo =================================================================
done

echo " Sleeping for 20 seconds"
sleep 20

echo " Check the status"
for i in $(seq $h $j); do
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    echo "mt -f /dev/nst$i status"
    mt -f /dev/nst$i status;
    echo " status $?"
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
done

echo " Load the tape"
for i in $(seq $h $j); do
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    echo "mt -f /dev/nst$i load"
    mt -f /dev/nst$i load;
    echo " status $?"
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
done

echo " Check the status"
for i in $(seq $h $j); do
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    echo "mt -f /dev/nst$i status"
    mt -f /dev/nst$i status;
    echo " status $?"
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
done

h=$SDEV
j=$SDEV
((j=j+3))

echo "Reset the targets"

for i in $(seq $h $j); do
    echo =================================================================
    echo "sg_reset --target /dev/sg$i status"
    sg_reset --target /dev/sg$i
    echo " status $?"
    echo =================================================================
done

echo " Sleeping for 5 seconds"
sleep 5

h=$DEV
j=$DEV
((j=j+3))

echo " Check the status"
for i in $(seq $h $j); do
    echo =================================================================
    echo " mt -f /dev/nst$i status"
    mt -f /dev/nst$i status;
    echo " status $?"
    echo =================================================================
done

echo " Load the tape"
for i in $(seq $h $j); do
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    echo "mt -f /dev/nst$i load"
    mt -f /dev/nst$i load;
    echo " status $?"
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
done

echo " Check the status"
for i in $(seq $h $j); do
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    echo "mt -f /dev/nst$i status"
    mt -f /dev/nst$i status;
    echo " status $?"
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
done

echo " Rewind the tape"
for i in $(seq $h $j); do
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    echo "mt -f /dev/nst$i rewind"
    mt -f /dev/nst$i rewind;
    echo " status $?"
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
done

echo " Check the status"
for i in $(seq $h $j); do
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    echo "mt -f /dev/nst$i status"
    mt -f /dev/nst$i status;
    echo " status $?"
    echo +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
done

#for i in $(seq $h $j); do
#    echo =================================================================
#    echo " mt -f /dev/nst$i eod"
#    mt -f /dev/nst$i eod;
##    echo " status $?"
#    echo =================================================================
##done

echo ""
echo "Done"
echo ""

ps x | grep dmesg | grep Tw | awk '{print $1}' | xargs kill -9  > /dev/null 2>&1

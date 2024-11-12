#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2024 John Meneghini <jmeneghi@redhat.com> All rights reserved.
#
# Must be run as root
#

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

check_root() {
	if [ "$EUID" -ne 0 ]
		then echo "Please run as root"
		exit 1
	fi

	if [ ! -f $DIR/tape_reset.sh ]; then
		echo "  Error: $DIR/tape_reset.sh is missing"
		exit 1
	fi
}

check_debug_params() {
	echo ""
	echo " Usage: ${0##*/} <st_num> <sg_num> <debug> <dmesg>"
	echo ""
	echo "    <st_num> : /dev/st<st_num> e.g.(/dev/st1 = 1)"
	echo "    <sg_num> : /dev/sg<sg_num> e.g (/dev/sg3 = 3)"
	echo "    <debug>  : 1 = debug on | 0 = debug off"
	echo "    <dmesg>  : 1 = dmesg on | 0 = dmesg off"
	echo ""
	echo "  Example:"
	echo ""
	echo "      ${0##*/} 3 4 1 0    # /dev/st3 /dev/sg4 debug nodmesg"
	echo "      ${0##*/} 1 3 1 1    # /dev/st1 /dev/sg3 debug dmesg"
	echo "      ${0##*/} 0 1 0 0    # /dev/st0 /dev/sg1 nodebug nodmesg"
	echo ""

	which lsscsi > /dev/null 2>&1 || dnf install -y lsscsi
	ps x | grep dmesg | grep Tw | awk '{print $1}' | xargs kill -9  > /dev/null 2>&1
	modprobe -r scsi_debug
	modprobe scsi_debug tur_ms_to_ready=10000 ptype=1  max_luns=1 dev_size_mb=1000
	lsscsi -ig
	modprobe -r scsi_debug
	exit 1
}

check_params() {
	echo ""
	echo " usage: ${0##*/} <st_device> <sg_device>  <debug> <dmesg>"
	echo ""
	echo "    <st_device> : name of st device               e.g.:(/dev/st1)"
	echo "    <sg_device> : name of corresponding sg device e.g.: (/dev/sg3)"
	echo "    <debug>  : 1 = debug on | 0 = debug off"
	echo "    <dmesg>  : 1 = dmesg on | 0 = dmesg off"
	echo ""
	echo "  These tests were developed with a QUANTUM ULTRIUM 4 U53F tape drive"
	echo "  and is designed to be used with real hardware."
	echo ""
	echo "  Example:"
	echo ""
	echo "      ${0##*/} /dev/nst0 /dev/sg1 0 0"
	echo "      ${0##*/} /dev/nst1 /dev/sg2 1 0"
	echo "      ${0##*/} /dev/st0 /dev/sg1 1 1"
	echo ""

	which mt > /dev/null 2>&1 || dnf install -y mt-st
	which lsscsi > /dev/null 2>&1 || dnf install -y lsscsi
	lsscsi -ig
	ps x | grep dmesg | grep Tw | awk '{print $1}' | xargs kill -9  > /dev/null 2>&1
	exit 1
}

check_param2() {
	if [ ! -c $1 ]; then
		echo "  Invalid argument: ${1}" >&2
		lsscsi -ig
		exit 1
	fi
}

set_debug() {
	if [ "$DEBUG" -gt 0 ]; then
		echo 1 > /sys/module/st/drivers/scsi\:st/debug_flag
	else
		echo 0 > /sys/module/st/drivers/scsi\:st/debug_flag
	fi

	echo ""
	echo -n "/sys/module/st/drivers/scsi\:st/debug_flag : "
	cat /sys/module/st/drivers/scsi\:st/debug_flag
}

set_dmesg() {
	echo ""
	uname -r
	if [ "$DMESG" -gt 0 ]; then
		dmesg -C
		dmesg -Tw &
	fi
}

clear_dmesg() {
	if [ "$DMESG" -gt 0 ]; then
	    ps x | grep dmesg | grep Tw | awk '{print $1}' | xargs kill -9  > /dev/null 2>&1
	fi
}

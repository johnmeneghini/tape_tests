#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2024 John Meneghini <jmeneghi@redhat.com> All rights reserved.
#
# Must be run as root
#

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

counter=1

stop_on_pos_err() {
	echo "--- position_lost_in_reset TEST FAILED--- with status $1"
	if [[ "$STOERR" -eq 1 ]]; then
		exit 1
	fi
}

stop_on_cmd_err() {
	cmd_err="$(cat .cmd_err)"
	echo "--- $1 TEST FAILED : $cmd_err"
	if [[ "$STOERR" -eq 1 ]]; then exit 1; fi
}

stop_on_err() {
	echo "--- $1 TEST FAILED --- with status $2"
	if [[ "$STOERR" -eq 1 ]]; then exit 1; fi
}

do_cmd_true() {
	echo  ""
	echo  "--- $1 --- (test $counter)"
	$1 2> .cmd_err || stop_on_err "$1" $?
	cat .cmd_err
	grep -E "failed|error" .cmd_err > /dev/null 2>&1 && stop_on_cmd_err "$1"
	rm -f .cmd_err
	((counter++))
}

do_cmd_warn() {
	echo  ""
	echo  "--- $1 --- (test $counter)"
	$1 2> .cmd_err || stop_on_err "$1" $?
	cat .cmd_err
	cmd_err="$(cat .cmd_err)"
	grep -E "failed|error" .cmd_err > /dev/null 2>&1 && echo "--- $1 TEST WARN : $cmd_err"
	rm -f .cmd_err
	((counter++))
}

test_reset_blocked_false() {
	if [ -f /sys/class/scsi_tape/$1/position_lost_in_reset ]; then
		p1=$(cat /sys/class/scsi_tape/$1/position_lost_in_reset)
		echo  "/sys/class/scsi_tape/$1/position_lost_in_reset $p1"
		[[ "$p1" != "0" ]] && stop_on_pos_err $p1
	fi
}

test_reset_blocked_true() {
	if [ -f /sys/class/scsi_tape/$1/position_lost_in_reset ]; then
		p1=$(cat /sys/class/scsi_tape/$1/position_lost_in_reset)
		echo  "/sys/class/scsi_tape/$1/position_lost_in_reset $p1"
		[[ "$p1" != "1" ]] && stop_on_pos_err $p1
	fi
}

do_cmd_false() {
	echo  ""
	echo  "--- $1 --- (test $counter)"
	$1 2> .cmd_err && stop_on_err "$1" $?
	cat .cmd_err
	[ -s .cmd_err ] || stop_on_cmd_err "$1"
	rm -f .cmd_err
	((counter++))
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
	echo " Usage: ${0##*/} <st_device> <sg_device> <debug> <dmesg> <stop_on_error> <scsi_level> [number]"
	echo ""
	echo "     <st_device> : e.g.(/dev/nst1)"
	echo "     <sg_device> : e.g (/dev/sg3)"
	echo "         <debug> : 1 = debug on | 0 = debug off"
	echo "         <dmesg> : 1 = dmesg on | 0 = dmesg off"
	echo " <stop_on_error> : 1 =  stop on | 0 = stop off"
	echo "    <scsi_level> : 1 to 8 - see: /usr/src/kernels/$(uname -r)/include/scsi/scsi.h"
	echo "       [number]  : optional: number of tape devices (defaults to 4)"
	echo "                      "
	echo "  Example:"
	echo ""
	echo "      ${0##*/} /dev/nst3 /dev/sg4 1 0 1 6   # /dev/nst3 /dev/sg4 debug nodmesg stop SCSI_SPC_3"
	echo "      ${0##*/} /dev/nst1 /dev/sg3 1 1 0 2 1 # /dev/nst1 /dev/sg3 debug dmesg nostop SCSI_2 [1 tape device]"
	echo "      ${0##*/} /dev/nst0 /dev/sg1 0 0 0 8 2 # /dev/nst0 /dev/sg1 nodebug nodmesg nostop SCSI_SPC_5 [2 tape devices]"
	echo ""

	which lsscsi > /dev/null 2>&1 || dnf install -y lsscsi
	ps x | grep dmesg | grep Tw | awk '{print $1}' | xargs kill -9  > /dev/null 2>&1
	modprobe -r scsi_debug
	modprobe scsi_debug tur_ms_to_ready=10000 ptype=1  max_luns=1 dev_size_mb=1000
	lsscsi -igN
	exit 1
}

check_params() {
	echo ""
	echo " usage: ${0##*/} <st_device> <sg_device> <debug> <dmesg> <stop_on_error>"
	echo ""
	echo "    <st_device> : name of st device e.g.:(/dev/st1)"
	echo "    <sg_device> : name of corresponding sg device e.g.: (/dev/sg3)"
	echo "        <debug> : 1 = debug on | 0 = debug off"
	echo "        <dmesg> : 1 = dmesg on | 0 = dmesg off"
	echo "<stop_on_error> : 1 =  stop on | 0 = stop off"
	echo ""
	echo "  These tests were developed with a QUANTUM ULTRIUM 4 U53F tape drive"
	echo "  and is designed to be used with real hardware."
	echo ""
	echo "  Example:"
	echo ""
	echo "      ${0##*/} /dev/nst3 /dev/sg4 1 0 1  # /dev/nst3 /dev/sg4 debug nodmesg stop"
	echo "      ${0##*/} /dev/nst1 /dev/sg3 1 1 0  # /dev/nst1 /dev/sg3 debug dmesg nostop"
	echo "      ${0##*/} /dev/nst0 /dev/sg1 0 0 0  # /dev/nst0 /dev/sg1 nodebug nodmesg nostop"
	echo ""

	which mt > /dev/null 2>&1 || dnf install -y mt-st
	which lsscsi > /dev/null 2>&1 || dnf install -y lsscsi
	lsscsi -igN
	ps x | grep dmesg | grep Tw | awk '{print $1}' | xargs kill -9  > /dev/null 2>&1
	exit 1
}

check_param2() {
	if [ ! -c $1 ]; then
		echo "  Invalid argument: ${1}" >&2
		lsscsi -igN
		exit 1
	fi
}

check_dev_nodebug_param() {
	NDEV=$(echo "$1" | awk -F"/dev/" '{print $2}')

	MODEL=$(cat /sys/class/scsi_tape/$NDEV/device/model)

	if [[ "$MODEL" == "scsi_debug"* ]]; then
		echo "  Invalid argument: $1 is a scsi_debug device ($MODEL)" >&2
		exit 1
	fi
}

check_dev_debug_param() {
	NDEV=$(echo "$1" | awk -F"/dev/" '{print $2}')

	MODEL=$(cat /sys/class/scsi_tape/$NDEV/device/model)

	if [[ "$MODEL" != "scsi_debug"* ]]; then
		echo "  Invalid Argument: $1 is not a scsi_debug device ($MODEL)" >&2
		exit 1
	fi
}

check_sdev_params() {
	NDEV=$(echo "$1" | awk -F"/dev/" '{print $2}')
	NSDEV=$(echo "$2" | awk -F"/dev/" '{print $2}')

	GENERIC=$(ls /sys/class/scsi_tape/$NDEV/device/scsi_generic)

	if [[ "$GENERIC" != "$NSDEV" ]]; then
		echo "  Invalid argument: $2 is not the generic device for $1 ($GENERIC)" >&2
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
	echo -n "--- "
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

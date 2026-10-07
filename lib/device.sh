#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# device.sh - device discovery, test profiles, feature detection and
# restoration of anything the harness changes.
#
# After setup the following are defined:
#   TT_MODE      hw | sdebug | mock
#   DEV          no-rewind node   (/dev/nstN)
#   REWDEV       rewind node      (/dev/stN)
#   SG           sg node          (/dev/sgN)
#   HCTL         H:C:T:L
#   PEERS        other tape no-rewind nodes on the same H:C:T (array)
#   PEER_SGS     matching sg nodes (array)
#   HAVE_POS_LOST, CAN_PART, HAVE_INJECT   0|1

TT_LOADED_SDEBUG=0
declare -ga PEERS=() PEER_SGS=()

# Values to restore are kept on disk: tests run in subshells.
restore_save() { mkdir -p "$TT_RUN/restore"; [[ -e $TT_RUN/restore/$1 ]] || echo "$2" > "$TT_RUN/restore/$1"; }
restore_take() { local f=$TT_RUN/restore/$1; [[ -e $f ]] || return 1; cat "$f"; rm -f "$f"; }

# --------------------------------------------------------------------------
# profiles: sizes and timeouts per mode (all overridable from the CLI/env)
# --------------------------------------------------------------------------
tt_profile() {
	case "$TT_MODE" in
	hw)
		: "${TT_BS:=262144}"
		: "${TT_FILE_BYTES:=$((256 << 20))}"
		: "${TT_INFLIGHT_BYTES:=$((8 << 30))}"
		: "${TT_FIXED_BS:=65536}"
		: "${TT_VERIFY:=full}"
		: "${TT_SHORT_TMO:=900}"
		: "${TT_IO_TMO:=10800}"
		: "${TT_LONG_TMO:=14400}"
		: "${TT_SETTLE:=5}"
		: "${TT_HOLD:=20}"
		;;
	sdebug)
		# scsi_debug's tape is TAPE_UNITS (10000) blocks and keeps only
		# the first 4 bytes of each block, hence "first4" verification.
		: "${TT_BS:=32768}"
		: "${TT_FILE_BYTES:=$((1 << 20))}"
		: "${TT_INFLIGHT_BYTES:=$((12 << 20))}"
		: "${TT_FIXED_BS:=4096}"
		: "${TT_VERIFY:=first4}"
		: "${TT_SHORT_TMO:=120}"
		: "${TT_IO_TMO:=600}"
		: "${TT_LONG_TMO:=600}"
		: "${TT_SETTLE:=1}"
		: "${TT_HOLD:=5}"
		: "${TT_SDEBUG_INFLIGHT_DELAY:=10}"	# jiffies per command
		# after UNLOAD scsi_debug reports NOT READY without ASC 3A, so a
		# not-ready poll would always run to its limit
		: "${TT_READY_WAIT:=10}"; export TT_READY_WAIT
		;;
	mock)
		: "${TT_BS:=4096}"
		: "${TT_FILE_BYTES:=$((64 << 10))}"
		: "${TT_INFLIGHT_BYTES:=$((1 << 20))}"
		: "${TT_FIXED_BS:=1024}"
		: "${TT_VERIFY:=full}"
		: "${TT_SHORT_TMO:=60}"
		: "${TT_IO_TMO:=120}"
		: "${TT_LONG_TMO:=120}"
		: "${TT_SETTLE:=0}"
		: "${TT_HOLD:=2}"
		: "${TT_MOCK_INFLIGHT_DELAY:=0.01}"
		;;
	esac
	: "${TT_NFILES:=3}"
	export TT_BS TT_FILE_BYTES TT_INFLIGHT_BYTES TT_FIXED_BS TT_VERIFY \
	       TT_SHORT_TMO TT_IO_TMO TT_LONG_TMO TT_SETTLE TT_HOLD TT_NFILES
}

# --------------------------------------------------------------------------
# preflight
# --------------------------------------------------------------------------
tt_preflight_tools() {
	command -v python3 >/dev/null || die "python3 is required"
	python3 -c 'import sys; sys.exit(sys.version_info < (3, 6))' ||
		die "python3 >= 3.6 is required"
	[[ $TT_MODE == mock ]] && return 0
	[[ $EUID -eq 0 ]] || die "must be run as root"
	command -v sg_reset >/dev/null ||
		die "sg_reset not found (install sg3_utils) - packages are not installed automatically"
	command -v lsscsi >/dev/null || log "note: lsscsi not installed (optional)"
}

# --------------------------------------------------------------------------
# real device resolution
# --------------------------------------------------------------------------
# tt_resolve <nstN|stN|/dev/...>
tt_resolve() {
	local name sysd h
	name=$(basename "$1")
	name=${name#n}
	[[ $name =~ ^st[0-9]+$ ]] ||
		die "'$1' is not an st device node (expected /dev/nstN or /dev/stN)"
	DEV=/dev/n$name
	REWDEV=/dev/$name
	sysd=/sys/class/scsi_tape/n$name
	[[ -c $DEV && -d $sysd ]] || die "$DEV does not exist"
	HCTL=$(basename "$(readlink -f "$sysd/device")")
	SG=/dev/$(ls "$sysd/device/scsi_generic" 2>/dev/null | head -1)
	[[ -c $SG ]] || die "no sg node for $DEV (is the sg module loaded?)"
	TT_VENDOR=$(tr -s ' ' < "$sysd/device/vendor")
	TT_MODEL=$(tr -s ' ' < "$sysd/device/model")
	TT_REV=$(tr -s ' ' < "$sysd/device/rev")
	TT_SDEV_SYS=$(readlink -f "$sysd/device")
	h=${HCTL%:*}
	PEERS=(); PEER_SGS=()
	local p ph
	for p in /sys/class/scsi_tape/nst*; do
		[[ $(basename "$p") =~ ^nst[0-9]+$ ]] || continue
		[[ $(basename "$p") == "n$name" ]] && continue
		ph=$(basename "$(readlink -f "$p/device")")
		if [[ ${ph%:*} == "$h" ]]; then
			PEERS+=("/dev/$(basename "$p")")
			PEER_SGS+=("/dev/$(ls "$p/device/scsi_generic" | head -1)")
		fi
	done
	export DEV REWDEV SG HCTL
}

# Find the no-rewind node for a given H:C:T:L (names can change on reload).
tt_resolve_hctl() {
	local p
	for p in /sys/class/scsi_tape/nst*; do
		[[ $(basename "$p") =~ ^nst[0-9]+$ ]] || continue
		if [[ $(basename "$(readlink -f "$p/device")") == "$1" ]]; then
			tt_resolve "$(basename "$p")"
			return 0
		fi
	done
	die "no st device at $1 after reloading st"
}

# --------------------------------------------------------------------------
# st module: reload with debug_flag=1 so every run starts from a clean
# driver state with full st debug logging.
# --------------------------------------------------------------------------
ST_DRV=/sys/bus/scsi/drivers/st

tt_reload_st() {
	local err=$TT_RUN/setup/rmmod.err pids
	mkdir -p "$TT_RUN/setup"
	if [[ -d /sys/module/st ]]; then
		if ! modprobe -r st 2> "$err"; then
			pids=$(fuser /dev/st[0-9]* /dev/nst[0-9]* 2>/dev/null | tr -s ' ')
			die "cannot unload st: $(cat "$err")${pids:+ (tape device held by pid(s):$pids)} - close every user of /dev/st* and /dev/nst*, including other paths to the drive"
		fi
	fi
	local lvl=${TT_ST_DEBUG_LEVEL:-1}
	modprobe st debug_flag="$lvl" || die "modprobe st debug_flag=$lvl failed"
	command -v udevadm >/dev/null && udevadm settle
	[[ $(cat $ST_DRV/debug_flag 2>/dev/null) == "$lvl" ]] ||
		die "st debug_flag=$lvl did not take effect after reload"
	[[ $lvl -ne 0 ]] && restore_save st_debug 0	# debugging off again at the end
	TT_ST_RELOADED=1
	log "st reloaded with debug_flag=$lvl"
}

# Apply stinit.conf (if stinit is installed) and enforce scsi2logical.
# Without scsi2logical st uses the device-specific address form for READ
# POSITION / LOCATE, which LTO drives reject: MTIOCPOS and MTSEEK fail.
tt_configure_st() {
	local conf=$TT_ROOT/stinit.conf opts
	TT_STINIT=not-run
	if [[ ${TT_NO_STINIT:-0} -ne 1 ]] && command -v stinit >/dev/null; then
		if stinit -f "$conf" -v "$DEV" > "$TT_RUN/setup/stinit.log" 2>&1; then
			TT_STINIT=applied
		else
			TT_STINIT=failed
			log "note: stinit failed, see $TT_RUN/setup/stinit.log"
		fi
	fi
	tc sysattr "$DEV" options
	opts=${R[value]:-0}
	if ! (( opts & 0x800 )); then
		log "scsi2logical not set by stinit for '$TT_VENDOR' '$TT_MODEL' - setting it directly"
		tc op "$DEV" setbool 0x800
		tc sysattr "$DEV" options
		opts=${R[value]:-0}
		(( opts & 0x800 )) || die "cannot enable scsi2logical on $DEV (options=$opts)"
		TT_STINIT="$TT_STINIT+scsi2logical"
	fi
	TT_ST_OPTIONS=$opts
	TT_ST_DEBUG=$(cat $ST_DRV/debug_flag 2>/dev/null || echo ?)
	export TT_ST_OPTIONS TT_ST_DEBUG TT_STINIT
	if [[ $TT_ST_DEBUG -gt 0 && $TT_MODE == hw ]] && ! grep -q log_buf_len /proc/cmdline; then
		log "note: st debug logging on real hardware is verbose; the kernel ring buffer may wrap during large transfers (consider log_buf_len=16M on the kernel command line; journald keeps the full log)"
	fi
}

# --------------------------------------------------------------------------
# scsi_debug
# --------------------------------------------------------------------------
tt_setup_sdebug() {
	local luns=${1:-2} d
	if [[ -d /sys/module/scsi_debug ]]; then
		[[ ${TT_REUSE_SDEBUG:-0} -eq 1 ]] ||
			die "scsi_debug is already loaded (unload it, or pass --reuse-scsi-debug)"
	else
		modprobe scsi_debug ptype=1 max_luns="$luns" ||
			die "modprobe scsi_debug failed"
		TT_LOADED_SDEBUG=1
		command -v udevadm >/dev/null && udevadm settle
	fi
	# primary device: lowest LUN of the first scsi_debug tape
	local first="" p
	for p in /sys/class/scsi_tape/nst*; do
		[[ $(basename "$p") =~ ^nst[0-9]+$ ]] || continue
		[[ $(cat "$p/device/model") == scsi_debug* ]] || continue
		d=$(basename "$(readlink -f "$p/device")")
		if [[ -z $first ]] || [[ $d < $first ]]; then
			first=$d; TT_PRIMARY=$(basename "$p")
		fi
	done
	[[ -n $first ]] || die "no scsi_debug tape device appeared"
	tt_resolve "$TT_PRIMARY"
	mount | grep -q ' /sys/kernel/debug ' ||
		mount -t debugfs none /sys/kernel/debug 2>/dev/null
}

tt_sdebug_delay() {	# jiffies
	local f=/sys/bus/pseudo/drivers/scsi_debug/delay
	[[ -w $f ]] || return 1
	restore_save sdebug_delay "$(cat $f)"
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		echo "$1" > $f 2>/dev/null && return 0
		sleep 0.2	# -EBUSY while commands are queued
	done
	return 1
}

tt_sdebug_errfile() {	# hctl
	echo "/sys/kernel/debug/scsi_debug/$1/error"
}

# sdebug_inject <hctl> <spec> ; spec as documented in scsi_debug.c
sdebug_inject() {
	local f
	f=$(tt_sdebug_errfile "$1")
	echo "$2" > "$f" || return 1
	echo "$1 $2" >> "$TT_RUN/injections"
}

sdebug_clear_injections() {
	[[ -f $TT_RUN/injections ]] || return 0
	local h spec type cmd
	while read -r h spec; do
		read -r type _ cmd _ <<< "$spec"
		echo "- $type $cmd" > "$(tt_sdebug_errfile "$h")" 2>/dev/null
	done < "$TT_RUN/injections"
	rm -f "$TT_RUN/injections"
}

# --------------------------------------------------------------------------
# mock
# --------------------------------------------------------------------------
tt_setup_mock() {
	local luns=${1:-2} i
	export TT_MOCK_DIR=$TT_RUN/mock
	python3 "$TAPECTL" mock-init "$TT_MOCK_DIR" --luns "$luns" \
		--cap "${TT_MOCK_CAP:-100000}" > /dev/null || die "mock init failed"
	DEV=mock:nst0; REWDEV=mock:st0; SG=mock:sg0; HCTL=0:0:0:0
	TT_VENDOR=MOCK; TT_MODEL=st-emulation; TT_REV=0
	PEERS=(); PEER_SGS=()
	for ((i = 1; i < luns; i++)); do
		PEERS+=("mock:nst$i"); PEER_SGS+=("mock:sg$i")
	done
	export DEV REWDEV SG HCTL
}

# --------------------------------------------------------------------------
# features
# --------------------------------------------------------------------------
tt_features() {
	local v
	HAVE_POS_LOST=0; CAN_PART=0; HAVE_INJECT=0
	v=$(pos_lost "$DEV")
	[[ $v != missing ]] && HAVE_POS_LOST=1
	tc sysattr "$DEV" options
	if [[ ${R[errno]} == 0 ]] && (( ${R[value]} & 0x400 )); then CAN_PART=1; fi
	if [[ $TT_MODE == sdebug && -e $(tt_sdebug_errfile "$HCTL") ]]; then
		HAVE_INJECT=1
	fi
	export HAVE_POS_LOST CAN_PART HAVE_INJECT
}

# --------------------------------------------------------------------------
# things the harness changes and must put back
# --------------------------------------------------------------------------
tt_set_st_debug() {
	local f=$ST_DRV/debug_flag
	[[ -w $f ]] || { log "note: st debug_flag not available"; return; }
	restore_save st_debug "$(cat $f)"
	echo "$1" > $f
}

tt_set_cmd_timeout() {	# seconds, for the primary device's request queue
	local f=$TT_SDEV_SYS/timeout
	[[ -w $f ]] || return 1
	restore_save cmd_timeout "$(cat "$f")"
	echo "$1" > "$f"
}

tt_restore_all() {
	[[ $TT_MODE == sdebug ]] && sdebug_clear_injections
	local v
	if v=$(restore_take sdebug_delay); then
		echo "$v" > /sys/bus/pseudo/drivers/scsi_debug/delay 2>/dev/null ||
			{ sleep 1; echo "$v" > /sys/bus/pseudo/drivers/scsi_debug/delay; }
	fi
	if v=$(restore_take cmd_timeout); then
		echo "$v" > "$TT_SDEV_SYS/timeout"
	fi
}

tt_teardown() {
	tt_restore_all
	local v
	if v=$(restore_take st_debug); then
		echo "$v" > $ST_DRV/debug_flag
	fi
	if [[ $TT_LOADED_SDEBUG -eq 1 ]]; then
		command -v udevadm >/dev/null && udevadm settle
		modprobe -r scsi_debug 2>/dev/null || log "warning: could not unload scsi_debug"
	fi
}

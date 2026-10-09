#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# reset.sh - ways to reset the tape and helpers that make sure the reset
# lands where the test says it does.

# Reset methods that may be used on this system.  bus/host/link resets hit
# every device behind the HBA (possibly the boot disk) so they are opt-in.
reset_methods() {
	local ms=(lu target)
	[[ ${TT_ALLOW_BUS:-0} -eq 1 ]] && ms+=(bus)
	[[ ${TT_ALLOW_HOST:-0} -eq 1 ]] && ms+=(host)
	[[ ${TT_ALLOW_LINK:-0} -eq 1 && -n $(sas_phy_of "$DEV") ]] && ms+=(link)
	echo "${ms[@]}"
}

# The SAS phy (if any) the device is attached through.
sas_phy_of() {
	[[ $TT_MODE == hw ]] || return 0
	local p=$TT_SDEV_SYS
	while [[ $p != / ]]; do
		for f in "$p"/phy-*/sas_phy/*; do
			[[ -e $f/link_reset ]] && { echo "$f"; return 0; }
		done
		p=$(dirname "$p")
	done
}

# Name of the low-level driver of the device's host, for messages.
tt_lld_name() {
	cat "/sys/class/scsi_host/host${HCTL%%:*}/proc_name" 2>/dev/null || echo "this HBA"
}

# A reset method the HBA refused once is not tried again in this run: a
# refused target reset can take minutes and stalls the device's IO meanwhile.
reset_unsupported() {	# method -> 0 if known to be refused here
	grep -qx "$1" "$TT_RUN/reset-unsupported" 2>/dev/null
}
reset_require() {	# method: skip the test if the HBA refused it earlier
	reset_unsupported "$1" &&
		skip_test "$1 reset is not supported by $(tt_lld_name) (refused earlier in this run)"
	return 0
}

# do_reset <method> [sg]   -- issue a reset.  sg_reset runs with --no-esc:
# without it the kernel escalates a refused device or target reset to a bus
# and then a host reset, which hits every device on the HBA - exactly what
# --allow-bus-reset / --allow-host-reset are there to prevent.
# A reset the HBA refuses makes the test SKIP (not FAIL): it says nothing
# about st.  Inside inflight_reset (_RESET_DEFER=1) it returns 2 instead, so
# the caller can reap the background IO first.
do_reset() {
	local m=$1 sg=${2:-$SG} rc out
	reset_require "$m"
	if [[ $TT_MODE == mock ]]; then
		out=$(python3 "$TAPECTL" mock-reset "$sg" --scope "$m" 2>&1); rc=$?
	else
		case "$m" in
		lu)     out=$(sg_reset --no-esc --device "$sg" 2>&1); rc=$? ;;
		target) out=$(sg_reset --no-esc --target "$sg" 2>&1); rc=$? ;;
		bus)    out=$(sg_reset --no-esc --bus "$sg" 2>&1); rc=$? ;;
		host)   out=$(sg_reset --host "$sg" 2>&1); rc=$? ;;
		link)   out=$( { echo 1 > "$(sas_phy_of "$DEV")/link_reset"; } 2>&1); rc=$? ;;
		*)      die "unknown reset method $m" ;;
		esac
	fi
	if [[ $rc -ne 0 ]]; then
		if [[ $m == link || $TT_MODE == mock ]]; then
			fail "$m reset via $sg could not be issued (rc=$rc): $out"
			return 1
		fi
		echo "$m" >> "$TT_RUN/reset-unsupported"
		hba_finding "$m reset via $sg refused by $(tt_lld_name) (rc=$rc): $out; affected tests are skipped, this is not an st result"
		[[ ${_RESET_DEFER:-0} -eq 1 ]] && return 2
		skip_test "$m reset is not supported by $(tt_lld_name)"
	fi
	log "    >>> $m reset issued via $sg"
	[[ $TT_SETTLE -gt 0 ]] && sleep "$TT_SETTLE"
	return 0
}

# reset_and_confirm <method> <description>
# Reset, then prove the driver noticed: MTIOCGET reports an unknown
# position and position_lost_in_reset is 1.
reset_and_confirm() {
	do_reset "$1" || return 1
	if ! status "$DEV"; then
		fail "$2: MTIOCGET after reset failed with ${S[errno]}"
		return 1
	fi
	check_eq "${S[file]}:${S[block]}" "-1:-1" "$2: MTIOCGET reports unknown position after reset"
	check_eq "${S[online]}" 1 "$2: drive online after reset"
	check_pos_lost "$DEV" 1 "$2: reset recognized"
}

# ---------------------------------------------------------------------------
# In-flight IO.  The old suite fired a reset after a fixed sleep and hoped the
# write was still running.  Here the IO reports progress, the reset is only
# issued while it is provably still running, and a lost race is retried.
# ---------------------------------------------------------------------------
_bg_env() {
	# slow the IO down enough to be interrupted reliably on emulated devices
	case "$TT_MODE" in
	sdebug) tt_sdebug_delay "$TT_SDEBUG_INFLIGHT_DELAY" ||
			warn "could not set scsi_debug delay; in-flight window may be short"
		# scsi_debug's reset handlers stop queued commands without completing
		# them (they expect SCSI EH to own them).  After an sg_reset the
		# in-flight command is only reaped by its timeout (st: 900 s), so
		# shorten it; the orphan is then recovered through EH (abort).
		tt_set_cmd_timeout "${TT_SDEBUG_INFLIGHT_CMD_TMO:-15}" ||
			warn "could not shorten the command timeout" ;;
	mock)   export TT_MOCK_DELAY=$TT_MOCK_INFLIGHT_DELAY ;;
	esac
}

_bg_env_restore() {
	case "$TT_MODE" in
	sdebug) local v
		if v=$(restore_take sdebug_delay); then
			tt_sdebug_delay "$v"; restore_take sdebug_delay > /dev/null
		fi
		if v=$(restore_take cmd_timeout); then
			echo "$v" > "$TT_SDEV_SYS/timeout"
		fi ;;
	mock)   unset TT_MOCK_DELAY ;;
	esac
}

# inflight_reset <method> <kind> <tapectl args...>
#   kind: write|read|op  -- the args are a tapectl command that is started in
#   the background.  Sets INFLIGHT=1 if the reset hit the IO while running.
#   Result of the background command is left in R[].
inflight_reset() {
	local m=$1 kind=$2; shift 2
	local prog=$TT_TDIR/progress.$RANDOM
	local args=("$@")
	# fire the reset a quarter of the way into the transfer (INFLIGHT_AT overrides)
	local at=${INFLIGHT_AT:-$((TT_INFLIGHT_BYTES / 4))} rrc
	reset_require "$m"
	[[ $at -lt $TT_BS ]] && at=$TT_BS
	[[ $kind != op ]] && args+=(--progress "$prog" --progress-bytes "$at")
	INFLIGHT=0
	_bg_env
	tc_bg "$TT_TDIR/bg.out" "${args[@]}"
	if [[ $kind == op ]]; then
		sleep "${TT_OP_REACT:-0.5}"
	elif ! wait_file "$prog" "$TT_IO_TMO"; then
		tc_bg_wait
		_bg_env_restore
		fail "background $kind never made progress: errno=${R[errno]}"
		return 1
	fi
	if kill -0 "$BG_PID" 2>/dev/null && [[ ! -e $prog.done ]]; then
		INFLIGHT=1
	fi
	_RESET_DEFER=1 do_reset "$m"; rrc=$?
	tc_bg_wait
	_bg_env_restore
	if [[ $rrc -eq 2 ]]; then
		# the IO ran on unhindered and is not in the layout model
		layout_dirty "$m reset refused during a background $kind"
		skip_test "$m reset is not supported by $(tt_lld_name)"
	fi
	# If the IO finished cleanly the reset missed it.
	if [[ $kind != op && ${R[errno]} == 0 ]]; then INFLIGHT=0; fi
	return 0
}

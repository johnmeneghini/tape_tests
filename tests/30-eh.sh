#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# SCSI error handling as seen by st, driven deterministically through the
# scsi_debug per-device error injection interface
# (/sys/kernel/debug/scsi_debug/<h:c:t:l>/error, see scsi_debug.c):
#   0 <cnt> <op>                      command times out
#   3 <cnt> <op>                      abort of that command fails
#   4 <cnt> <op>                      LU reset fails (escalate to target reset)
#   2 <cnt> <op> <host> <drv> <status> <key> <asc> <ascq>   complete with sense
# A negative count fires that many times.  WRITE(6) is opcode 0x0a.

EH_TMO=${TT_EH_CMD_TIMEOUT:-5}

_eh_write() {	# id -> writes at EOD, leaves result in R
	tc write "$DEV" --src "$(data_file "$1")" --bs "$TT_BS" --max-bytes $((TT_BS * 8)) --pre eod
}

_eh_after() {	# k id description [layout-state]
	local k=$1 id=$2 d=$3 state
	state=$(cat "$TT_SDEV_SYS/state" 2>/dev/null)
	check_eq "$state" running "$d: SCSI device state is running"
	tc sysattr "$DEV" position_lost_in_reset
	[[ ${R[value]} == 1 ]] && expect_ok "$d: rewind" op "$DEV" rewind
	layout_set_partial "$k" "$id" 1 "$TT_BS" "${4:-partial}"
	expect_ok "$d: rewind" op "$DEV" rewind
	layout_verify "$d"
	layout_rewrite_at "$k" "$k"
}

tt_register E01 eh inject "WRITE times out, abort succeeds: write fails, device recovers"
t_E01() {
	local k id=70
	layout_ensure_baseline
	k=$(layout_count)
	tt_set_cmd_timeout "$EH_TMO" || skip_test "cannot set command timeout"
	sdebug_inject "$HCTL" "0 -1 0x0a" || abort_test "injection failed"
	_eh_write "$id"
	check_in "${R[errno]}" "EIO|0" "timed-out write either fails with EIO or was retried successfully"
	note "after abort-only recovery position_lost_in_reset=$(pos_lost "$DEV")"
	# no reset happened, so st may legitimately write the filemark at close
	_eh_after "$k" "$id" "after aborted write" partialany
}

tt_register E02 eh inject "WRITE times out and abort fails: EH LU reset must be recognized by st"
t_E02() {
	local k id=71
	layout_ensure_baseline
	k=$(layout_count)
	tt_set_cmd_timeout "$EH_TMO" || skip_test "cannot set command timeout"
	sdebug_inject "$HCTL" "3 -1 0x0a" || abort_test "injection failed"
	sdebug_inject "$HCTL" "0 -1 0x0a" || abort_test "injection failed"
	_eh_write "$id"
	check_eq "${R[errno]}" EIO "write fails with EIO"
	status "$DEV"
	check_pos_lost "$DEV" 1 "EH escalated to LU reset: position is lost"
	expect_errno EIO "read blocked after EH reset" read "$DEV" --bs "$TT_BS" --one
	_eh_after "$k" "$id" "after EH LU reset"
}

tt_register E03 eh inject,multilun "abort and LU reset fail: EH target reset flags every LUN"
t_E03() {
	local k id=72 p=${PEERS[0]}
	layout_ensure_baseline
	k=$(layout_count)
	expect_ok "peer rewind" op "$p" rewind
	tt_set_cmd_timeout "$EH_TMO" || skip_test "cannot set command timeout"
	sdebug_inject "$HCTL" "4 -1 0x0a" || abort_test "injection failed"
	sdebug_inject "$HCTL" "3 -1 0x0a" || abort_test "injection failed"
	sdebug_inject "$HCTL" "0 -1 0x0a" || abort_test "injection failed"
	_eh_write "$id"
	check_eq "${R[errno]}" EIO "write fails with EIO"
	status "$DEV"; status "$p"
	check_pos_lost "$DEV" 1 "target reset: LUN $DEV flagged"
	check_pos_lost "$p" 1 "target reset: peer LUN $p flagged"
	expect_ok "peer rewind" op "$p" rewind
	_eh_after "$k" "$id" "after EH target reset"
}

tt_register E04 eh inject "unit attention 29/00 returned on a WRITE mid-stream"
t_E04() {
	local k id=73
	layout_ensure_baseline
	k=$(layout_count)
	sdebug_inject "$HCTL" "2 -1 0x0a 0x0 0x0 0x2 0x6 0x29 0x0" || abort_test "injection failed"
	_eh_write "$id"
	check_eq "${R[errno]}" EIO "write that received the UA fails with EIO"
	status "$DEV"
	check_eq "${S[file]}:${S[block]}" "-1:-1" "position unknown"
	check_pos_lost "$DEV" 1 "UA on WRITE treated as reset"
	_eh_after "$k" "$id" "after UA on write"
}

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Edge-of-media and partition behaviour.

tt_register X01 boundary long "write to end of medium: ENOSPC (not EIO), EOT flag, filemark still writable"
t_X01() {
	local k id=90 rep
	layout_ensure_baseline
	k=$(layout_count)
	rep=${TT_EOM_REPEAT:-1000000}
	step "writing until the drive reports end of medium"
	tc write "$DEV" --src "$(data_file $id)" --bs "$TT_BS" --repeat "$rep" --pre eod
	check_eq "${R[errno_write]}" ENOSPC "write at end of medium fails with ENOSPC (${R[bytes]} bytes written)"
	check_eq "${R[eot_at_error]}" 1 "MTIOCGET in the writing fd reports EOT"
	# st_flush() still writes the filemark at close after -ENOSPC, so the
	# partial file is terminated; the extra weof then adds an empty file.
	expect_ok "weof in the early-warning zone" op "$DEV" weof 1
	layout_set_partial "$k" "$id" "$rep" "$TT_BS" partialfm
	layout_load; L_ID+=(-); L_ST+=(full); L_REP+=(1); L_BS+=("$TT_BS"); layout_save
	expect_ok "rewind" op "$DEV" rewind
	layout_verify "after filling the tape"
	layout_rewrite_at "$k" "$k"
	layout_verify "after trimming the tape again"
}

tt_register X02 boundary any "end-of-data read semantics (read_tape): after MTEOM, and after the last filemark"
t_X02() {
	layout_ensure_baseline
	# after MTEOM st knows it is at EOD: no data, straight to EIO
	expect_ok "eod" op "$DEV" eod
	tc read "$DEV" --bs "$TT_BS" --one
	check_eq "${R[errno]}:${R[bytes]}" "EIO:0" "read after MTEOM fails with EIO"
	check_status "$DEV" eod 1 "EOD flag"
	# reading across the last filemark: first blank check returns 0, then EIO
	expect_ok "rewind" op "$DEV" rewind
	expect_ok "fsf $((TT_NFILES - 1))" op "$DEV" fsf $((TT_NFILES - 1))
	tc read "$DEV" --bs "$TT_BS"
	check_eq "${R[errno]}" 0 "read the last file up to its filemark"
	tc read "$DEV" --bs "$TT_BS" --one
	check_eq "${R[errno]}:${R[bytes]}" "0:0" "first read after the last filemark returns 0 (EOD)"
	check_status "$DEV" eod 1 "EOD flag"
	tc read "$DEV" --bs "$TT_BS" --one
	check_eq "${R[errno]}:${R[bytes]}" "EIO:0" "next read past EOD fails with EIO"
	expect_ok "rewind" op "$DEV" rewind
}

tt_register X03 boundary partitions "reset while in partition 1: rewind returns to partition 1"
t_X03() {
	local id=80 f
	f=$(data_file $id)
	expect_ok "enable can-partitions" op "$DEV" setbool 0x400 || return
	expect_ok "rewind" op "$DEV" rewind
	tc op "$DEV" mkpart "${TT_PART1_SIZE:-1}"
	[[ ${R[errno]} == 0 ]] || skip_test "mkpart not supported by this drive/media (${R[errno]})"
	layout_dirty "tape re-partitioned"
	expect_ok "setpart 1" op "$DEV" setpart 1
	tc write "$DEV" --src "$f" --bs "$TT_BS" --pre rewind
	check_eq "${R[errno]}" 0 "write in partition 1"
	check_status "$DEV" partition 1 "MTIOCGET reports partition 1"
	reset_and_confirm lu "reset in partition 1" || return
	expect_ok "rewind" op "$DEV" rewind
	check_status "$DEV" partition 1 "st returned to the selected partition after reset+rewind"
	tc read "$DEV" --bs "$TT_BS" --expect "$f" --verify "$TT_VERIFY" --tape-block "$TT_BS"
	check_eq "${R[verify]}" equal "partition 1 data intact"
	expect_ok "setpart 0" op "$DEV" setpart 0
	expect_ok "rewind" op "$DEV" rewind
	expect_ok "back to one partition" op "$DEV" mkpart 0
	expect_ok "disable can-partitions" op "$DEV" clearbool 0x400
}

tt_register X04 boundary partitions "MTLOAD while in partition 1: st switches to partition 0, MTSETPART 1 switches back"
t_X04() {
	local id=81 f
	f=$(data_file $id)
	expect_ok "enable can-partitions" op "$DEV" setbool 0x400 || return
	expect_ok "rewind" op "$DEV" rewind
	tc op "$DEV" mkpart "${TT_PART1_SIZE:-1}"
	[[ ${R[errno]} == 0 ]] || skip_test "mkpart not supported by this drive/media (${R[errno]})"
	layout_dirty "tape re-partitioned"
	expect_ok "setpart 1" op "$DEV" setpart 1
	tc write "$DEV" --src "$f" --bs "$TT_BS" --pre rewind
	check_eq "${R[errno]}" 0 "write a file in partition 1"
	check_status "$DEV" partition 1 "MTIOCGET reports partition 1"
	# LOAD positions the medium at the beginning of partition 0.  Without a
	# new-medium unit attention st must still record that, or a later
	# MTSETPART 1 is taken as "already there" and I/O goes to partition 0.
	expect_ok "load (medium already loaded, no reset)" op "$DEV" load
	check_status "$DEV" partition 0 "MTIOCGET reports partition 0 after the load"
	expect_ok "setpart 1" op "$DEV" setpart 1
	tc read "$DEV" --bs "$TT_BS" --expect "$f" --verify "$TT_VERIFY" \
		--tape-block "$TT_BS" --pre rewind
	if [[ ${R[errno]} == 0 && ${R[bytes]:-0} -gt 0 ]]; then
		check_eq "${R[verify]}" equal "partition 1 data read after MTSETPART 1 (the switch happened)"
	else
		fail "no partition 1 data after MTSETPART 1 (errno=${R[errno]}, ${R[bytes]:-0} bytes): I/O went to the wrong partition"
	fi
	expect_ok "setpart 0" op "$DEV" setpart 0
	expect_ok "rewind" op "$DEV" rewind
	expect_ok "back to one partition" op "$DEV" mkpart 0
	expect_ok "disable can-partitions" op "$DEV" clearbool 0x400
}

tt_register X05 boundary partitions "write in partition 0, switch to 1, MTLOAD on the same fd: no filemark at BOT of partition 0"
t_X05() {
	local id=82 f
	f=$(data_file $id)
	expect_ok "enable can-partitions" op "$DEV" setbool 0x400 || return
	expect_ok "rewind" op "$DEV" rewind
	tc op "$DEV" mkpart "${TT_PART1_SIZE:-1}"
	[[ ${R[errno]} == 0 ]] || skip_test "mkpart not supported by this drive/media (${R[errno]})"
	layout_dirty "tape re-partitioned"
	tc write "$DEV" --src "$f" --bs "$TT_BS" --pre rewind
	check_eq "${R[errno]}" 0 "write a file in partition 0"
	# One open file: start writing in partition 0 (st state ST_WRITING),
	# switch to partition 1, MTLOAD, close.  If st moves to partition 0
	# after the load without resetting that partition's state, close
	# writes a filemark at the beginning of partition 0.
	# The switch must not go through an ioctl: st_ioctl() resets the rw
	# state of the current partition before switching (and writes a
	# filemark first for MTREW, MTOFFL, MTSEEK, MTBSF, MTBSFM).  A read()
	# or write() switches in rw_checks() and leaves the state of the
	# partition it leaves as it was.
	tc session "$DEV" --bs "$TT_BS" --step op:setpart:0 --step op:rewind \
		--step op:fsf:1 --step write:4 --step op:setpart:1 --step read \
		--step op:load
	note "session: ${R[step1_errno]} ${R[step2_errno]} ${R[step3_errno]} ${R[step4_errno]} ${R[step5_errno]} ${R[step6_errno]} ${R[step7_errno]} close=${R[errno_close]}"
	expect_ok "setpart 0" op "$DEV" setpart 0
	tc read "$DEV" --bs "$TT_BS" --expect "$f" --verify "$TT_VERIFY" \
		--tape-block "$TT_BS" --pre rewind
	if [[ ${R[errno]} == 0 && ${R[verify]} == equal ]]; then
		pass "partition 0 file intact after MTLOAD (no filemark written at BOT)"
	else
		fail "partition 0 file damaged after MTLOAD: errno=${R[errno]} ${R[bytes]:-0} bytes verify=${R[verify]} (filemark written at BOT?)"
	fi
	expect_ok "rewind" op "$DEV" rewind
	expect_ok "back to one partition" op "$DEV" mkpart 0
	expect_ok "disable can-partitions" op "$DEV" clearbool 0x400
}

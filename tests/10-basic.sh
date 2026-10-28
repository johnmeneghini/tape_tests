#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Basic st functionality.  Everything the reset tests depend on is proven here
# first, so a reset test failure can't be a plain I/O or positioning bug.

tt_register B01 basic any "identity, sysfs attributes and required features"
t_B01() {
	log "device: $DEV ($REWDEV) sg=$SG hctl=$HCTL  '$TT_VENDOR' '$TT_MODEL' '$TT_REV'"
	status "$DEV" || abort_test "MTIOCGET failed: ${S[errno]}"
	check_eq "${S[online]}" 1 "drive online with media"
	check_eq "${S[wr_prot]}" 0 "media is not write protected"
	local a
	for a in options defined default_blksize default_density default_compression; do
		tc sysattr "$DEV" "$a"
		check_eq "${R[errno]}" 0 "sysfs attribute '$a' present (${R[value]})"
	done
	if [[ $HAVE_POS_LOST -eq 1 ]]; then
		pass "sysfs position_lost_in_reset present"
		check_pos_lost "$DEV" 0 "clean state at start"
	elif [[ ${TT_LEGACY:-0} -eq 1 ]]; then
		warn "position_lost_in_reset missing: reset flag checks will be UNVERIFIED (--legacy)"
	else
		fail "position_lost_in_reset missing: kernel lacks the st reset-state sysfs attribute (use --legacy for older kernels)"
	fi
	tc sysattr "$DEV" stats/write_cnt
	check_eq "${R[errno]}" 0 "sysfs stats directory present"
	# Without scsi2logical st sends READ POSITION / LOCATE with the
	# device-specific address form (BT=1); modern drives (LTO) need logical
	# block addresses, so MTIOCPOS and MTSEEK fail with EIO.
	tc sysattr "$DEV" options
	if [[ $TT_MODE != mock ]]; then
		if (( ${R[value]:-0} & 0x800 )); then
			pass "st option scsi2logical set (options=${R[value]})"
		else
			fail "st option scsi2logical is not set (options=${R[value]}): MTIOCPOS/MTSEEK fail on LTO drives"
		fi
		note "st debug_flag=$(cat /sys/bus/scsi/drivers/st/debug_flag 2>/dev/null || echo ?) stinit=${TT_STINIT:-?}"
	fi
	[[ $CAN_PART -eq 1 ]] && note "driver option can-partitions is set"
}

tt_register B02 basic any "write files, read them back, check filemarks and file numbers"
t_B02() {
	layout_build || abort_test "writing baseline files failed: ${R[errno]}"
	pass "wrote $TT_NFILES files"
	status "$DEV"
	check_eq "${S[file]}:${S[block]}" "$TT_NFILES:0" "position after last filemark"
	layout_verify "fresh layout"
	local i
	expect_ok "rewind" op "$DEV" rewind
	for ((i = 1; i < TT_NFILES; i++)); do
		expect_ok "fsf 1" op "$DEV" fsf 1
		check_status "$DEV" file "$i" "file number after fsf is $i"
	done
}

tt_register B03 basic any "positioning: fsf/bsf/fsr/bsr/fsfm/bsfm/eod/tell/seek and their error cases"
t_B03() {
	layout_ensure_baseline
	local nblk=$((TT_FILE_BYTES / TT_BS)) f0 f1 T
	f0=$(data_file 0); f1=$(data_file 1)

	expect_ok "rewind" op "$DEV" rewind
	status "$DEV"
	check_eq "${S[file]}:${S[block]}:${S[bot]}" "0:0:1" "at BOT after rewind"

	expect_ok "fsr 3" op "$DEV" fsr 3
	check_status "$DEV" block 3 "block 3 after fsr 3"
	expect_ok "bsr 1" op "$DEV" bsr 1
	check_status "$DEV" block 2 "block 2 after bsr 1"
	tc read "$DEV" --bs "$TT_BS" --expect "$f0" --expect-offset $((2 * TT_BS)) \
		--verify "$TT_VERIFY" --tape-block "$TT_BS"
	check_eq "${R[verify]}" equal "rest of file 0 read from block 2 matches"

	expect_ok "fsf 2 from start of file 1" op "$DEV" fsf 2
	check_status "$DEV" file 3 "file 3 after fsf"
	expect_ok "bsf 1" op "$DEV" bsf 1
	check_status "$DEV" file 2 "file 2 after bsf 1"

	expect_ok "rewind" op "$DEV" rewind
	expect_ok "fsfm 1 (stop before the filemark)" op "$DEV" fsfm 1
	tc read "$DEV" --bs "$TT_BS" --one
	check_eq "${R[errno]}:${R[bytes]}" "0:0" "read at filemark returns 0 bytes"
	check_status "$DEV" file 1 "crossed into file 1"
	expect_ok "bsfm 1" op "$DEV" bsfm 1

	goto_mid
	tc tell "$DEV"
	if [[ ${R[errno]} == EIO ]]; then
		tc sysattr "$DEV" options
		(( ${R[value]:-0} & 0x800 )) ||
			note "MTIOCPOS failed with scsi2logical unset: this is the likely cause (see B01)"
		R[errno]=EIO
	fi
	if check_eq "${R[errno]}" 0 "MTIOCPOS at file 1 block 2"; then
		T=${R[block]}
		expect_ok "rewind" op "$DEV" rewind
		expect_ok "seek $T" op "$DEV" seek "$T"
		tc tell "$DEV"
		check_eq "${R[block]}" "$T" "tell after seek returns $T"
		tc read "$DEV" --bs "$TT_BS" --expect "$f1" --expect-offset $((2 * TT_BS)) \
			--verify "$TT_VERIFY" --tape-block "$TT_BS"
		check_eq "${R[verify]}" equal "data at seek target is file 1 block 2"
	fi

	expect_ok "eod" op "$DEV" eod
	check_status "$DEV" eod 1 "EOD flag after eod"

	# error cases
	expect_errno EIO "fsf past end of data" op "$DEV" fsf 1
	expect_ok "rewind" op "$DEV" rewind
	expect_errno EIO "bsf at BOT" op "$DEV" bsf 1
	expect_ok "rewind" op "$DEV" rewind
	expect_errno EIO "fsr across a filemark" op "$DEV" fsr $((nblk + 1))
	expect_ok "rewind" op "$DEV" rewind
	layout_verify "positioning did not alter data"
}

tt_register B04 basic any "fixed block mode write/read and on-tape block size"
t_B04() {
	layout_ensure_baseline
	local fb=$TT_FIXED_BS id=50 k f
	expect_ok "setblk $fb" op "$DEV" setblk "$fb" || return
	check_status "$DEV" blksize "$fb" "MTIOCGET reports block size $fb"
	k=$(layout_count)
	layout_append "$id" 1 "$fb"
	check_eq "${R[errno]}" 0 "file written in fixed-block mode"
	f=$(data_file "$id")
	tc read "$DEV" --bs $((fb * 4)) --expect "$f" --verify "$TT_VERIFY" \
		--tape-block "$fb" --pre rewind --pre "fsf:$k"
	check_eq "${R[verify]}" equal "fixed-mode read back (4 blocks per read)"
	expect_ok "setblk 0 (variable)" op "$DEV" setblk 0
	tc read "$DEV" --bs "$((fb > TT_BS ? fb : TT_BS))" --expect "$f" --verify "$TT_VERIFY" \
		--tape-block "$fb" --pre rewind --pre "fsf:$k"
	check_eq "${R[verify]}" equal "variable-mode read of the fixed-mode file"
	check_eq "${R[min_block]}:${R[max_block]}" "$fb:$fb" "every block on tape is $fb bytes"
	layout_verify "after fixed-block file"
}

tt_register B05 basic any "rewind-on-close node writes a filemark and rewinds"
t_B05() {
	layout_ensure_baseline
	local id=51 f
	f=$(data_file "$id")
	tc write "$REWDEV" --src "$f" --bs "$TT_BS" --pre eod
	check_eq "${R[errno]}" 0 "write through $REWDEV"
	check_status "$DEV" bot 1 "tape rewound when $REWDEV was closed"
	layout_load; L_ID+=("$id"); L_ST+=(full); L_REP+=(1); L_BS+=("$TT_BS"); layout_save
	layout_verify "file written through the rewind node ends in a filemark"
}

tt_register B06 basic any "exclusive open: second opener gets EBUSY"
t_B06() {
	local rdy=$TT_TDIR/hold.ready
	tc_bg "$TT_TDIR/hold.out" hold "$DEV" 5 --ready "$rdy"
	wait_file "$rdy" 30 || abort_test "holder never opened the device"
	expect_errno EBUSY "second open of $DEV" status "$DEV"
	expect_errno EBUSY "open of $REWDEV while $DEV is open" status "$REWDEV"
	tc_bg_wait 60
	expect_ok "open after holder closed" status "$DEV"
}

tt_register B07 basic any "I/O statistics in sysfs account for the traffic"
t_B07() {
	layout_ensure_baseline
	local b0 b1 w0 w1 r0 r1 k id=52
	tc sysattr "$DEV" stats/write_byte_cnt
	[[ ${R[errno]} == 0 ]] || skip_test "no st stats in sysfs"
	w0=${R[value]}
	tc sysattr "$DEV" stats/read_byte_cnt; r0=${R[value]}
	tc sysattr "$DEV" stats/write_cnt; b0=${R[value]}
	k=$(layout_count)
	layout_append "$id" || abort_test "append failed"
	tc read "$DEV" --bs "$TT_BS" --pre rewind --pre "fsf:$k"
	tc sysattr "$DEV" stats/write_byte_cnt; w1=${R[value]}
	tc sysattr "$DEV" stats/read_byte_cnt; r1=${R[value]}
	tc sysattr "$DEV" stats/write_cnt; b1=${R[value]}
	[[ $((w1 - w0)) -ge $TT_FILE_BYTES ]] && pass "write_byte_cnt grew by $((w1 - w0))" ||
		fail "write_byte_cnt grew by $((w1 - w0)), wrote $TT_FILE_BYTES"
	[[ $((r1 - r0)) -ge $TT_FILE_BYTES ]] && pass "read_byte_cnt grew by $((r1 - r0))" ||
		fail "read_byte_cnt grew by $((r1 - r0)), read $TT_FILE_BYTES"
	[[ $b1 -gt $b0 ]] && pass "write_cnt increased" || fail "write_cnt did not increase"
	tc sysattr "$DEV" stats/in_flight
	check_eq "${R[value]}" 0 "stats/in_flight is 0 when idle"
}

tt_register B08 basic any "empty files: consecutive filemarks keep file numbering"
t_B08() {
	layout_ensure_baseline
	local k
	k=$(layout_count)
	expect_ok "eod" op "$DEV" eod
	expect_ok "weof 2" op "$DEV" weof 2
	check_status "$DEV" file $((k + 2)) "file number after two filemarks"
	layout_load
	L_ID+=(- -); L_ST+=(full full); L_REP+=(1 1); L_BS+=("$TT_BS" "$TT_BS")
	layout_save
	layout_append 53
	layout_verify "empty files between data files"
}

tt_register B09 basic any "MTLOAD of a loaded tape at EOD: position and EOF state are reset, reading works"
t_B09() {
	layout_ensure_baseline
	expect_ok "eod" op "$DEV" eod
	tc read "$DEV" --bs "$TT_BS" --one
	check_eq "${R[errno]}" EIO "read at EOD fails (EOF state is EOD)"
	expect_ok "load (medium already loaded, no reset)" op "$DEV" load
	status "$DEV"
	local fb="${S[file]}:${S[block]}"
	tc tell "$DEV"
	check_eq "${R[errno]}:${R[block]}" "0:0" "drive at BOT after load (MTIOCPOS)"
	# st must not still consider itself at EOD: the first block must be readable
	tc read "$DEV" --bs "$TT_BS" --one --expect "$(data_file 0)" \
		--verify "$TT_VERIFY" --tape-block "$TT_BS"
	if [[ ${R[errno]} == EIO ]]; then
		# Known st behaviour on drives that report no new medium for a loaded
		# cartridge: do_load_unload() does not reset the EOF state.  See
		# docs/st-reset-findings.md, finding 3 (fix posted upstream).
		warn "read after MTLOAD at EOD fails with EIO: st did not reset the EOF state"
	elif check_eq "${R[errno]}" 0 "read after load succeeds (EOF state cleared)"; then
		if [[ ${R[bytes]:-0} -gt 0 ]]; then
			check_in "${R[verify]}" "prefix|equal" "first block after load is file 0 block 0"
		else
			fail "no data read after load, cannot confirm file 0 block 0"
		fi
	fi
	if [[ $fb == 0:0 ]]; then
		pass "MTIOCGET reports BOT (0:0) after load"
	else
		warn "after load MTIOCGET reports $fb although the tape is at BOT"
	fi
	layout_verify "after load at EOD"
}

# --------------------------------------------------------------------------
# B10-B13 close the gaps against the legacy kernel-qe tape tests
# (storage/tape/mt-st, read_write_testing, error_handling_and_recovery):
# compression on/off, explicit door lock, a block size sweep, and I/O that is
# stopped and continued with signals.  Each asserts the result, not just the
# exit status, and the tape is read back afterwards as usual.
# --------------------------------------------------------------------------

tt_register B10 basic any "MTCOMPRESSION on/off: drive compression state follows, data written compressed reads back"
t_B10() {
	layout_ensure_baseline
	local orig="" have_page=0 k id=54
	# The drive's own view: MODE SENSE data compression page (0x0f) via sg
	tc modesense "$SG" --page 0x0f
	if [[ ${R[errno]} == 0 ]]; then
		have_page=1; orig=${R[dce]}
		note "drive compression page: DCE=${R[dce]} DCC=${R[dcc]} DDE=${R[dde]}"
		if [[ ${R[dcc]} != 1 ]]; then
			# st_compression() refuses when the drive can't change it
			expect_errno EIO "MTCOMPRESSION refused: drive reports compression not changeable (DCC=0)" \
				op "$DEV" compression 1
			skip_test "drive cannot change data compression (DCC=0)"
		fi
	elif [[ $TT_MODE != mock ]]; then
		# no compression page readable here: st reads the same page, so it
		# should refuse too; if it does not, carry on without drive readback
		local ms="${R[errno]} ${R[sense_key]:-}"
		tc op "$DEV" compression 1
		if [[ ${R[errno]} == EIO ]]; then
			pass "MTCOMPRESSION refused (EIO): drive has no data compression mode page"
			skip_test "drive has no data compression mode page (MODE SENSE $ms)"
		fi
		note "MODE SENSE page 0x0f failed ($ms) but MTCOMPRESSION returned ${R[errno]}: no drive readback"
	fi
	restore_save compression "${orig:-1}"

	expect_ok "compression 1" op "$DEV" compression 1 || return
	if [[ $have_page -eq 1 ]]; then
		tc modesense "$SG" --page 0x0f
		check_eq "${R[dce]}" 1 "drive reports compression enabled (DCE=1)"
	else
		unverified "drive compression state after MTCOMPRESSION 1 (no MODE SENSE in $TT_MODE mode)"
	fi
	k=$(layout_count)
	layout_append "$id" || abort_test "writing with compression enabled failed: ${R[errno]}"
	pass "file written with compression enabled"

	expect_ok "compression 0" op "$DEV" compression 0
	if [[ $have_page -eq 1 ]]; then
		tc modesense "$SG" --page 0x0f
		check_eq "${R[dce]}" 0 "drive reports compression disabled (DCE=0)"
	fi
	tc read "$DEV" --bs "$TT_BS" --expect "$(data_file "$id")" --verify "$TT_VERIFY" \
		--tape-block "$TT_BS" --pre rewind --pre "fsf:$k"
	check_eq "${R[verify]}" equal "file written compressed reads back with compression off"

	local v
	v=$(restore_take compression)
	expect_ok "restore compression $v" op "$DEV" compression "$v"
	layout_verify "after compression test"
}

tt_register B11 basic any "MTLOCK/MTUNLOCK: explicit door lock succeeds, survives close, unlock releases it"
t_B11() {
	local dbg mark
	dbg=$(cat /sys/bus/scsi/drivers/st/debug_flag 2>/dev/null || echo 0)
	restore_save door_lock 1
	mark=$(kmsg_mark)
	expect_ok "lock" op "$DEV" lock || { restore_take door_lock > /dev/null; return; }
	# st_release() only unlocks an automatic lock: an explicit one stays
	# across close until MTUNLOCK.  Open and close the device in between.
	expect_ok "open/close while locked" status "$DEV"
	expect_ok "a second open sees the drive (lock does not block opens)" status "$DEV"
	local log=""
	[[ $TT_MODE != mock ]] && log=$(kmsg_since "$mark")
	expect_ok "unlock" op "$DEV" unlock && restore_take door_lock > /dev/null
	if [[ $TT_MODE == mock ]]; then
		unverified "door lock state in the st debug log (mock mode)"
	elif [[ $dbg != 1 ]]; then
		unverified "door lock state needs st debug_flag=1 (the st debug log is the only witness)"
	else
		if [[ $log == *"Locking drive door."* ]]; then
			pass "st sent PREVENT MEDIUM REMOVAL (\"Locking drive door.\")"
		else
			fail "st did not log \"Locking drive door.\" for MTLOCK"
		fi
		if [[ $log == *"Unlocking drive door."* ]]; then
			fail "the door was unlocked by close(): an explicit lock must survive until MTUNLOCK"
		else
			pass "explicit lock survived close() (no unlock before MTUNLOCK)"
		fi
		kmsg_expect 'Unlocking drive door\.' "MTUNLOCK sent ALLOW MEDIUM REMOVAL"
	fi
}

tt_register B12 basic any "block size sweep 4k-256k: exact readback, larger buffer gets one block per read, smaller buffer gets ENOMEM"
t_B12() {
	layout_ensure_baseline
	local sizes=(4096 16384 65536 262144) bs k id=60 f b0
	for bs in "${sizes[@]}"; do
		(( TT_FILE_BYTES % bs == 0 )) || { note "bs $bs: file size not a multiple, skipped"; continue; }
		step "variable block size $bs"
		k=$(layout_count)
		layout_append "$id" 1 "$bs" || { fail "write with bs=$bs failed: ${R[errno]}"; id=$((id + 1)); continue; }
		pass "wrote $TT_FILE_BYTES bytes in $bs-byte blocks"
		f=$(data_file "$id")
		tc read "$DEV" --bs "$bs" --expect "$f" --verify "$TT_VERIFY" --tape-block "$bs" \
			--pre rewind --pre "fsf:$k"
		check_eq "${R[verify]}:${R[min_block]}:${R[max_block]}" "equal:$bs:$bs" \
			"bs=$bs: read back exactly, every block $bs bytes"
		tc read "$DEV" --bs $((bs * 4)) --expect "$f" --verify "$TT_VERIFY" --tape-block "$bs" \
			--pre rewind --pre "fsf:$k"
		check_eq "${R[verify]}:${R[max_block]}" "equal:$bs" \
			"bs=$bs: read with a $((bs * 4))-byte buffer returns one $bs-byte block per read"
		if (( bs > 512 )); then
			# st read_tape(): ILI with a negative residual - "Failed to read
			# N byte block with M byte transfer", the block is consumed
			tc read "$DEV" --bs $((bs / 2)) --one --pre rewind --pre "fsf:$k"
			check_eq "${R[errno]}" ENOMEM "bs=$bs: read with a $((bs / 2))-byte buffer fails with ENOMEM"
			status "$DEV"
			b0=${S[block]}
			check_eq "$b0" 1 "bs=$bs: the oversized block was consumed (block 1 after the failed read)"
			tc read "$DEV" --bs "$bs" --one --expect "$f" --expect-offset "$bs" \
				--verify "$TT_VERIFY" --tape-block "$bs"
			check_in "${R[verify]}" "prefix|equal" "bs=$bs: next read returns block 1 of the file"
		fi
		id=$((id + 1))
	done
	layout_verify "after block size sweep"
}

tt_register B13 basic any "read and write stopped with SIGSTOP and continued with SIGCONT complete with correct data"
_b13_stopcont() {	# kind (read|write) -> sets B13_LANDED, R[] from the transfer
	local kind=$1; shift
	local prog=$TT_TDIR/b13.$kind
	rm -f "$prog" "$prog.done"
	B13_LANDED=0
	_bg_env
	tc_bg "$TT_TDIR/b13.$kind.out" "$@" --progress "$prog" --progress-bytes $((TT_FILE_BYTES / 4))
	if ! wait_file "$prog" "$TT_IO_TMO"; then
		tc_bg_wait; _bg_env_restore
		fail "background $kind never made progress: errno=${R[errno]}"
		return 1
	fi
	if kill -0 "$BG_PID" 2>/dev/null && [[ ! -e $prog.done ]]; then
		kill -STOP "$BG_PID" 2>/dev/null
		sleep "${TT_B13_STOP_SECS:-3}"
		[[ ! -e $prog.done ]] && B13_LANDED=1
		kill -CONT "$BG_PID" 2>/dev/null
	fi
	tc_bg_wait
	_bg_env_restore
}
t_B13() {
	layout_ensure_baseline
	local rep=4 id=70 k try
	[[ $TT_MODE != hw ]] && rep=$(( TT_INFLIGHT_BYTES / TT_FILE_BYTES ))
	(( rep < 4 )) && rep=4
	# write
	for try in 1 2 3; do
		k=$(layout_count)
		step "attempt $try: ${rep}x$TT_FILE_BYTES byte write, SIGSTOP/SIGCONT while in flight"
		_b13_stopcont write write "$DEV" --src "$(data_file $id)" --bs "$TT_BS" \
			--repeat "$rep" --pre eod || return
		if check_eq "${R[errno]}" 0 "stopped and continued write completes"; then
			layout_load; L_ID+=("$id"); L_ST+=(full); L_REP+=("$rep"); L_BS+=("$TT_BS"); layout_save
		else
			layout_dirty "stopped write failed with ${R[errno]}"
			return
		fi
		[[ $B13_LANDED -eq 1 ]] && break
		note "write finished before SIGSTOP landed (attempt $try)"
	done
	if [[ $B13_LANDED -eq 1 ]]; then
		pass "write was stopped mid-transfer for ${TT_B13_STOP_SECS:-3} s"
	else
		unverified "could not stop the write mid-transfer (raise --file-mb)"
	fi
	# read the file just written
	for try in 1 2 3; do
		step "attempt $try: read, SIGSTOP/SIGCONT while in flight"
		_b13_stopcont read read "$DEV" --bs "$TT_BS" --expect "$(data_file $id)" \
			--expect-repeat "$rep" --verify "$TT_VERIFY" --tape-block "$TT_BS" \
			--pre rewind --pre "fsf:$k" || return
		check_eq "${R[errno]}:${R[verify]}" "0:equal" "stopped and continued read returns all data correctly"
		[[ $B13_LANDED -eq 1 ]] && break
		note "read finished before SIGSTOP landed (attempt $try)"
	done
	if [[ $B13_LANDED -eq 1 ]]; then
		pass "read was stopped mid-transfer for ${TT_B13_STOP_SECS:-3} s"
	else
		unverified "could not stop the read mid-transfer (raise --file-mb)"
	fi
	layout_verify "after stopped and continued I/O"
}

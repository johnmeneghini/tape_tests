#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Device reset handling in st.
#
# Contract under test (drivers/scsi/st.c):
#  * A power-on/reset unit attention (ASC 0x29) sets pos_unknown.
#  * While set: read/write and every MTIOCTOP except REW, OFFL, LOAD, RETEN,
#    ERASE, SEEK and EOM fail with EIO; MTIOCPOS fails with EIO; MTIOCGET
#    succeeds and reports file/block -1.
#  * One of the allowed operations clears it; REW/SEEK/EOM also re-apply a
#    changed block size/density and return to the selected partition.
#  * An interrupted write leaves a clean prefix and no filemark.
#  * Data acknowledged by write() is either on tape or close() fails.

BLOCKED_OPS="weof wsm fsf bsf fsr bsr fsfm bsfm nop setblk setdensity compression lock unlock unload setpart setbool"

# --------------------------------------------------------------------------
tt_register R01 reset any "LU reset at mid-tape is detected and rewind recovers"
t_R01() {
	layout_ensure_baseline
	goto_mid || abort_test "cannot position"
	check_pos_lost "$DEV" 0 "before reset"
	reset_and_confirm lu "reset at file 1 block 2" || return
	kmsg_expect "Power on/reset recognized" "st logged the reset"
	expect_ok "rewind clears the condition" op "$DEV" rewind
	check_pos_lost "$DEV" 0 "after rewind"
	check_status "$DEV" bot 1 "at BOT after rewind"
	layout_verify "after reset at mid-tape"
}

# --------------------------------------------------------------------------
tt_register R02 reset any "every non-recovery operation is blocked with EIO after reset"
t_R02() {
	layout_ensure_baseline
	goto_mid || abort_test "cannot position"
	reset_and_confirm lu "reset before blocked-op matrix" || return
	local op arg f0
	f0=$(data_file 0)
	expect_errno EIO "read after reset" read "$DEV" --bs "$TT_BS" --one
	expect_errno EIO "write after reset" write "$DEV" --src "$f0" --bs "$TT_BS" --max-bytes "$TT_BS"
	expect_errno EIO "MTIOCPOS (tell) after reset" tell "$DEV"
	for op in $BLOCKED_OPS; do
		case $op in
		setblk)     arg=$TT_FIXED_BS ;;
		setdensity|setpart|setbool) arg=0 ;;
		*)          arg=1 ;;
		esac
		expect_errno EIO "MTIOCTOP $op after reset" op "$DEV" "$op" "$arg"
	done
	check_pos_lost "$DEV" 1 "no blocked operation cleared the condition"
	status "$DEV"
	check_eq "${S[file]}:${S[block]}:${S[blksize]}" "-1:-1:0" "state unchanged by blocked operations"
	expect_ok "rewind" op "$DEV" rewind
	layout_verify "no blocked operation touched the tape"
}

# --------------------------------------------------------------------------
# R03.<op>: each operation that is allowed to clear the condition
for _op in rewind eod seek retension offline load erase; do
	_req=any; [[ $_op == erase ]] && _req=long
	tt_register "R03.$_op" reset "$_req" "reset, then '$_op' clears the condition and data is intact"
done
unset _op _req

t_R03() {
	local op=$1 T
	layout_ensure_baseline
	goto_mid || abort_test "cannot position"
	tc tell "$DEV"; T=${R[block]}
	reset_and_confirm lu "reset before $op" || return
	case $op in
	seek)    expect_ok "seek $T after reset" op "$DEV" seek "$T" ;;
	offline) expect_ok "offline after reset" op "$DEV" offline ;;
	*)       expect_ok "$op after reset" op "$DEV" "$op" ;;
	esac || return
	check_pos_lost "$DEV" 0 "$op cleared the condition"
	case $op in
	rewind|retension)
		status "$DEV"
		check_eq "${S[file]}:${S[block]}:${S[bot]}" "0:0:1" "at BOT after $op" ;;
	eod)
		check_status "$DEV" eod 1 "EOD flag after eod" ;;
	seek)
		tc tell "$DEV"
		check_eq "${R[block]}" "$T" "position after seek"
		tc read "$DEV" --bs "$TT_BS" --expect "$(data_file 1)" --expect-offset $((2 * TT_BS)) \
			--verify "$TT_VERIFY" --tape-block "$TT_BS"
		check_eq "${R[verify]}" equal "data at seek target is file 1 block 2" ;;
	offline)
		status "$DEV"
		check_eq "${S[online]}" 0 "drive offline after offline"
		expect_ok "load" op "$DEV" load
		check_pos_lost "$DEV" 0 "after load"
		check_status "$DEV" online 1 "online after load" ;;
	load)
		status "$DEV"
		local fb="${S[file]}:${S[block]}"
		# Prove where the tape really is, without repositioning it:
		# the logical position and the first block must be file 0 block 0.
		tc tell "$DEV"
		check_eq "${R[errno]}:${R[block]}" "0:0" "drive is at BOT after reset+load (MTIOCPOS)"
		tc read "$DEV" --bs "$TT_BS" --one --expect "$(data_file 0)" \
			--verify "$TT_VERIFY" --tape-block "$TT_BS"
		if [[ ${R[errno]} == 0 && ${R[bytes]:-0} -gt 0 ]]; then
			check_in "${R[verify]}" "prefix|equal" "first block read after load is file 0 block 0"
		else
			fail "reading after reset+load failed (errno=${R[errno]}, ${R[bytes]:-0} bytes): cannot confirm BOT"
		fi
		if [[ $fb == 0:0 ]]; then
			pass "MTIOCGET reports BOT (0:0) after load"
		else
			# st clears pos_unknown via reset_state() (-1/-1) and only a new
			# session resets the counters; a LOAD of a loaded tape may not.
			warn "after reset+load MTIOCGET reports -1:-1 although the tape is at BOT"
		fi ;;
	erase)
		expect_ok "rewind" op "$DEV" rewind
		layout_load; L_ID=(); L_ST=(); L_REP=(); L_BS=(); layout_save
		if [[ $TT_MODE == hw ]]; then
			# whether the drive was at BOT after the reset is drive specific
			layout_dirty "erase after reset"
			tc read "$DEV" --bs "$TT_BS" --one
			note "after reset+erase, first read at BOT returned errno=${R[errno]} bytes=${R[bytes]}"
		else
			layout_verify "tape empty after erase from BOT"
		fi
		return ;;
	esac
	layout_verify "after reset + $op"
}

# --------------------------------------------------------------------------
# R04.<op>: changed block size must be re-applied after reset
for _op in rewind eod seek retension offline load; do
	tt_register "R04.$_op" reset any "block size re-applied to the drive after reset + '$_op'"
done
unset _op

t_R04() {
	local op=$1 fb=$TT_FIXED_BS T id=60
	layout_ensure_baseline
	goto_mid || abort_test "cannot position"
	tc tell "$DEV"; T=${R[block]}
	expect_ok "setblk $fb" op "$DEV" setblk "$fb" || return
	reset_and_confirm lu "reset in fixed-block mode" || return
	case $op in
	seek)    expect_ok "seek $T" op "$DEV" seek "$T" ;;
	offline) expect_ok "offline" op "$DEV" offline && expect_ok "load" op "$DEV" load ;;
	*)       expect_ok "$op" op "$DEV" "$op" ;;
	esac || return
	status "$DEV"
	local drv=${S[blksize]} e
	# Functional check: a fixed-block write only works if the drive agrees.
	layout_append "$id" 1 "$fb"
	e=${R[errno]}
	if [[ " rewind seek eod " == *" $op "* ]]; then
		# st contract: REW/SEEK/EOM re-apply the changed block size
		check_eq "$drv" "$fb" "driver still in fixed mode ($fb) after reset + $op"
		check_eq "$e" 0 "fixed-block write after reset + $op (st re-applied block size)"
	elif [[ $drv == "$fb" && $e == 0 ]]; then
		note "after reset + $op: block size $fb kept by driver and drive"
	elif [[ $drv == "$fb" ]]; then
		warn "after reset + $op: driver in fixed mode ($fb) but the drive is not: write failed with $e"
	elif [[ $drv == 0 && $e == 0 ]]; then
		warn "after reset + $op: MTSETBLK $fb silently discarded - st re-read the drive's block size (variable); subsequent writes use variable blocks"
	else
		fail "after reset + $op: driver block size $drv, write failed with $e (device unusable until MTSETBLK)"
	fi
	expect_ok "setblk 0" op "$DEV" setblk 0
	expect_ok "rewind" op "$DEV" rewind
	layout_verify "after reset in fixed-block mode"
}

# --------------------------------------------------------------------------
for _m in lu target; do
	tt_register "R05.$_m" reset any "$_m reset during a write: EIO, clean prefix, no filemark, earlier files intact"
done
unset _m

t_R05() {
	local m=$1 k id try rep
	rep=$(( (TT_INFLIGHT_BYTES + TT_FILE_BYTES - 1) / TT_FILE_BYTES ))
	layout_ensure_baseline
	for try in 1 2 3; do
		k=$(layout_count); id=$((100 + try))
		step "attempt $try: ${rep}x$TT_FILE_BYTES byte write at EOD, reset while in flight"
		inflight_reset "$m" write write "$DEV" --src "$(data_file $id)" --bs "$TT_BS" \
			--repeat "$rep" --pre eod
		[[ $INFLIGHT -eq 1 ]] && break
		local we=${R[errno]}
		note "race lost on attempt $try (write finished: errno=$we); retrying"
		if [[ $we == 0 ]]; then layout_load; L_ID+=("$id"); L_ST+=(full)
			L_REP+=("$rep"); L_BS+=("$TT_BS"); layout_save
		else
			layout_dirty "write lost the race but failed with $we"
		fi
		expect_ok "rewind" op "$DEV" rewind
	done
	[[ $INFLIGHT -eq 1 ]] || skip_test "could not land a reset during the write (raise --inflight-mb)"
	check_eq "${R[errno]}" EIO "interrupted write reports EIO (write=${R[errno_write]} close=${R[errno_close]}, ${R[bytes]} bytes accepted)"
	layout_set_partial "$k" "$id" "$rep" "$TT_BS"
	status "$DEV"
	check_eq "${S[file]}:${S[block]}" "-1:-1" "position unknown after interrupted write"
	check_pos_lost "$DEV" 1 "after interrupted write"
	expect_ok "rewind" op "$DEV" rewind
	layout_verify "after reset during write"
	layout_rewrite_at "$k" "$k"
	check_eq "${R[errno]}" 0 "overwrite the interrupted file"
	layout_verify "after rewriting the interrupted file"
}

# --------------------------------------------------------------------------
tt_register R06 reset any "LU reset during a read: EIO, data returned so far is correct, tape unharmed"
t_R06() {
	local k id=20 rep try
	rep=$(( (TT_INFLIGHT_BYTES + TT_FILE_BYTES - 1) / TT_FILE_BYTES ))
	layout_ensure_baseline
	k=$(layout_count)
	step "writing a ${rep}x$TT_FILE_BYTES byte file to read back"
	layout_append "$id" "$rep" || abort_test "cannot write the large file (${R[errno]})"
	for try in 1 2 3; do
		inflight_reset lu read read "$DEV" --bs "$TT_BS" --expect "$(data_file $id)" \
			--expect-repeat "$rep" --verify "$TT_VERIFY" --tape-block "$TT_BS" \
			--pre rewind --pre "fsf:$k"
		[[ $INFLIGHT -eq 1 ]] && break
		note "race lost on attempt $try; retrying"
		expect_ok "rewind" op "$DEV" rewind
	done
	[[ $INFLIGHT -eq 1 ]] || skip_test "could not land a reset during the read"
	check_eq "${R[errno]}" EIO "interrupted read reports EIO after ${R[bytes]} bytes"
	check_in "${R[verify]}" "prefix|equal" "data delivered before the reset is correct"
	# st compares the reset counter when a command completes; if the read was
	# reaped by an abort the UA is still pending and the next command sees it.
	status "$DEV"
	check_eq "${S[file]}:${S[block]}" "-1:-1" "position unknown once the next command saw the reset"
	check_pos_lost "$DEV" 1 "after interrupted read"
	expect_ok "rewind" op "$DEV" rewind
	layout_verify "after reset during read"
}

# --------------------------------------------------------------------------
for _n in nst st; do
	tt_register "R07.$_n" reset any "buffered data contract on $_n: acknowledged data is on tape or close() fails"
done
unset _n

t_R07() {
	local node=$DEV k id=30 prog=$TT_TDIR/hold.progress wr cl
	[[ $1 == st ]] && node=$REWDEV
	layout_ensure_baseline
	k=$(layout_count)
	step "write a file through $node, reset after the last write() returns, before close()"
	tc_bg "$TT_TDIR/bg.out" write "$node" --src "$(data_file $id)" --bs "$TT_BS" \
		--pre eod --hold "$TT_HOLD" --progress "$prog" --progress-bytes 1
	wait_file "$prog.done" "$TT_IO_TMO" || { tc_bg_wait; abort_test "writer never finished writing"; }
	do_reset lu
	tc_bg_wait
	wr=${R[errno_write]}; cl=${R[errno_close]}
	check_eq "$wr" 0 "all write() calls returned success before the reset"
	note "close() after reset returned $cl"
	tc sysattr "$DEV" position_lost_in_reset
	[[ ${R[value]} == 1 ]] && expect_ok "rewind (condition set)" op "$DEV" rewind
	tc read "$DEV" --bs "$TT_BS" --expect "$(data_file $id)" --verify "$TT_VERIFY" \
		--tape-block "$TT_BS" --pre rewind --pre "fsf:$k"
	local v=${R[verify]}
	if [[ $cl == 0 ]]; then
		if [[ $v == equal ]]; then
			pass "close() succeeded and all acknowledged data is on tape"
		else
			fail "SILENT DATA LOSS: close() succeeded but tape holds verify=$v (${R[bytes]}/${R[expected_bytes]} bytes)"
		fi
		layout_load; L_ID+=("$id"); L_ST+=(full); L_REP+=(1); L_BS+=("$TT_BS"); layout_save
	else
		pass "close() reported $cl after the reset (loss is not silent)"
		check_in "$v" "equal|prefix" "whatever reached the tape is a clean prefix"
		layout_set_partial "$k" "$id" 1 "$TT_BS"
	fi
	layout_verify "after reset between write() and close()"
}

# --------------------------------------------------------------------------
tt_register R08 reset any "LU reset during a long positioning command (EOD from BOT)"
t_R08() {
	layout_ensure_baseline
	expect_ok "rewind" op "$DEV" rewind
	inflight_reset lu op op "$DEV" eod
	[[ $INFLIGHT -eq 1 ]] || note "eod completed before the reset landed"
	local e=${R[errno]} pl
	check_in "$e" "0|EIO" "eod interrupted by reset returns success or EIO"
	status "$DEV"
	pl=$(pos_lost "$DEV")
	if [[ $e == EIO ]]; then
		[[ $pl == missing ]] || check_eq "$pl" 1 "failed eod leaves the reset condition set"
	fi
	note "after reset during eod: errno=$e position=${S[file]}:${S[block]} pos_lost=$pl"
	expect_ok "rewind" op "$DEV" rewind
	check_pos_lost "$DEV" 0 "after rewind"
	layout_verify "after reset during positioning"
}

# --------------------------------------------------------------------------
tt_register R09 reset any "LU reset with no tape loaded, then load"
t_R09() {
	layout_ensure_baseline
	expect_ok "offline (unload)" op "$DEV" offline || return
	check_status "$DEV" online 0 "no tape online"
	do_reset lu || return
	expect_ok "MTIOCGET without tape after reset" status "$DEV"
	note "position_lost_in_reset without tape: $(pos_lost "$DEV")"
	expect_ok "load" op "$DEV" load
	check_pos_lost "$DEV" 0 "after load"
	check_status "$DEV" online 1 "online after load"
	layout_verify "after reset without tape"
}

# --------------------------------------------------------------------------
tt_register R10.bot reset any "LU reset with the tape at BOT"
t_R10() {
	layout_ensure_baseline
	local k f0
	f0=$(data_file 0)
	if [[ $1 == bot ]]; then
		expect_ok "rewind" op "$DEV" rewind
		reset_and_confirm lu "reset at BOT" || return
		expect_errno EIO "read at BOT after reset" read "$DEV" --bs "$TT_BS" --one
		expect_errno EIO "write at BOT after reset (would destroy the tape)" \
			write "$DEV" --src "$f0" --bs "$TT_BS" --max-bytes "$TT_BS"
		expect_ok "rewind" op "$DEV" rewind
		check_pos_lost "$DEV" 0 "after rewind"
	else
		expect_ok "eod" op "$DEV" eod
		reset_and_confirm lu "reset at EOD" || return
		expect_errno EIO "append after reset without repositioning" \
			write "$DEV" --src "$f0" --bs "$TT_BS" --max-bytes "$TT_BS"
		expect_ok "eod (allowed) after reset" op "$DEV" eod
		check_pos_lost "$DEV" 0 "after eod"
		k=$(layout_count)
		layout_append 40
		check_eq "${R[errno]}" 0 "append file $k after recovering with eod"
	fi
	layout_verify "after reset at $1"
}
tt_register R10.eod reset any "LU reset with the tape at EOD, recover with eod and append"

# --------------------------------------------------------------------------
tt_register R11 reset inject "UA 29/00 without a reset (other initiator) blocks; UA 2A/01 does not"
t_R11() {
	layout_ensure_baseline
	goto_mid || abort_test "cannot position"
	# control: a non-reset unit attention must not set the condition
	sdebug_inject "$HCTL" "2 -1 0x00 0x0 0x0 0x2 0x6 0x2a 0x1" ||
		abort_test "injection failed"
	status "$DEV"
	check_pos_lost "$DEV" 0 "UA 2A/01 (mode parameters changed) is not a reset"
	sdebug_clear_injections
	goto_mid
	sdebug_inject "$HCTL" "2 -1 0x00 0x0 0x0 0x2 0x6 0x29 0x0" ||
		abort_test "injection failed"
	status "$DEV"
	check_eq "${S[file]}:${S[block]}" "-1:-1" "UA 29/00 on TEST UNIT READY: position unknown"
	check_pos_lost "$DEV" 1 "UA 29/00 treated as reset"
	expect_errno EIO "read blocked" read "$DEV" --bs "$TT_BS" --one
	sdebug_clear_injections
	expect_ok "rewind" op "$DEV" rewind
	layout_verify "after injected unit attention"
}

# --------------------------------------------------------------------------
tt_register R12 reset multilun "reset scope: LU reset flags only that LUN, target reset flags all"
t_R12() {
	local p=${PEERS[0]}
	layout_ensure_baseline
	expect_ok "peer $p: rewind" op "$p" rewind
	expect_ok "rewind" op "$DEV" rewind
	do_reset lu || return
	status "$DEV"; status "$p"
	check_pos_lost "$DEV" 1 "LU reset: reset LUN flagged"
	check_pos_lost "$p" 0 "LU reset: other LUN on the target NOT flagged"
	expect_ok "rewind" op "$DEV" rewind
	do_reset target || return
	status "$DEV"; status "$p"
	check_pos_lost "$DEV" 1 "target reset: LUN $DEV flagged"
	check_pos_lost "$p" 1 "target reset: LUN $p flagged"
	expect_ok "rewind" op "$DEV" rewind
	expect_ok "peer rewind" op "$p" rewind
	check_pos_lost "$p" 0 "peer recovered"
	layout_verify "after scoped resets"
}

# --------------------------------------------------------------------------
for _m in lu target bus host link; do
	tt_register "R13.$_m" reset "$_m" "$_m reset at mid-tape: detected, recovered, data intact"
done
unset _m

t_R13() {
	layout_ensure_baseline
	goto_mid || abort_test "cannot position"
	reset_and_confirm "$1" "$1 reset" || return
	expect_ok "rewind" op "$DEV" rewind
	check_pos_lost "$DEV" 0 "after rewind"
	layout_verify "after $1 reset"
}

# --------------------------------------------------------------------------
tt_register R14 stress any "repeated resets at random points (idle, writing, reading)"
t_R14() {
	local n=${TT_ITER:-5} i s k id f=0 rep
	rep=$(( (TT_INFLIGHT_BYTES + TT_FILE_BYTES - 1) / TT_FILE_BYTES ))
	layout_ensure_baseline
	for ((i = 1; i <= n; i++)); do
		s=$((RANDOM % 3))
		step "iteration $i/$n: scenario $s"
		case $s in
		0)	goto_mid
			do_reset lu
			status "$DEV"; check_pos_lost "$DEV" 1 "iter $i idle" ;;
		1)	k=$(layout_count); id=$((200 + i))
			INFLIGHT_AT=$(( (RANDOM % 90 + 5) * TT_INFLIGHT_BYTES / 100 )) \
			inflight_reset lu write write "$DEV" --src "$(data_file $id)" --bs "$TT_BS" \
				--repeat "$rep" --pre eod
			if [[ ${R[errno]} == 0 ]]; then
				layout_load; L_ID+=("$id"); L_ST+=(full); L_REP+=("$rep"); L_BS+=("$TT_BS"); layout_save
			else
				layout_set_partial "$k" "$id" "$rep" "$TT_BS"
			fi ;;
		2)	INFLIGHT_AT=$(( (RANDOM % 90 + 5) * TT_FILE_BYTES / 100 )) \
			inflight_reset lu read read "$DEV" --bs "$TT_BS" --pre rewind ;;
		esac
		expect_ok "iter $i: rewind" op "$DEV" rewind
		layout_verify "iteration $i" || f=$((f + 1))
		layout_load
		if [[ ${L_ST[-1]} == partial ]]; then
			layout_rewrite_at $(( ${#L_ID[@]} - 1 )) 0
		fi
		[[ $f -gt 0 ]] && break
	done
}

# --------------------------------------------------------------------------
# R15.<op>: drive buffering mode set with MTSETDRVBUFFER must survive a reset.
# The drive's own value is read with MODE SENSE through the sg node.
for _op in rewind load retension; do
	tt_register "R15.$_op" reset any "drive buffering mode restored after reset + '$_op' (read from the drive)"
done
unset _op

t_R15() {
	local op=$1 orig want got
	[[ $TT_MODE == mock ]] && skip_test "needs a real device (MODE SENSE via sg)"
	layout_ensure_baseline
	tc modesense "$SG"
	[[ ${R[errno]} == 0 ]] || skip_test "MODE SENSE via $SG failed (${R[errno]})"
	orig=${R[buffered_mode]}
	want=$(( orig == 0 ? 1 : 0 ))
	expect_ok "MTSETDRVBUFFER $want (buffered mode)" op "$DEV" setdrvbuffer "$want" || return
	tc modesense "$SG"
	# keep the result: restoring the original mode below overwrites R[]
	local ms_err=${R[errno]} ms_sense="key=${R[sense_key]} asc=${R[asc]}/${R[ascq]}"
	got=${R[buffered_mode]}
	if [[ $ms_err != 0 ]]; then
		tc op "$DEV" setdrvbuffer "$orig"
		skip_test "MODE SENSE after MTSETDRVBUFFER failed (errno=$ms_err $ms_sense)"
	fi
	if [[ $got != "$want" ]]; then
		tc op "$DEV" setdrvbuffer "$orig"
		skip_test "device does not implement buffered mode: MTSETDRVBUFFER $want accepted, drive still reports $got"
	fi
	pass "drive reports buffered mode $want before the reset"
	goto_mid || abort_test "cannot position"
	reset_and_confirm lu "reset with buffered mode $want" || return
	expect_ok "$op after reset" op "$DEV" "$op"
	tc modesense "$SG"
	got=${R[buffered_mode]}
	if [[ $got == "$want" ]]; then
		pass "drive buffered mode $want restored after reset + $op"
	else
		warn "after reset + $op the drive buffered mode is $got, not the $want set with MTSETDRVBUFFER"
	fi
	expect_ok "back to buffered mode $orig" op "$DEV" setdrvbuffer "$orig"
	expect_ok "rewind" op "$DEV" rewind
	layout_verify "after buffered mode test"
}

# --------------------------------------------------------------------------
# R16: with auto-lock, st locks the door at the first read or write and
# unlocks it at close.  A reset clears the drive's medium removal prevention,
# so st must lock again - on the same open file.  Observed in the st debug
# log ("Locking drive door."), which needs debug_flag=1.
tt_register R16 reset any "auto-lock: door locked again after a reset on the same open file"
t_R16() {
	local rdy=$TT_TDIR/session.ready go=$TT_TDIR/session.go mark
	[[ $TT_MODE == mock ]] && skip_test "needs a real st (kernel debug log)"
	[[ $(cat /sys/bus/scsi/drivers/st/debug_flag 2>/dev/null) == 1 ]] ||
		skip_test "needs st debug_flag=1 (the door lock is seen in the st debug log)"
	layout_ensure_baseline
	expect_ok "enable auto-lock" op "$DEV" setbool 0x40 || return
	# one fd: rewind, read (locks), [reset], rewind (sees the reset),
	# rewind (recovers), read (must lock again)
	tc_bg "$TT_TDIR/session.out" session "$DEV" --bs "$TT_BS" \
		--step op:rewind --step read --step "signal:$rdy" --step "wait:$go" \
		--step op:rewind --step op:rewind --step read
	if ! wait_file "$rdy" 120; then
		touch "$go"; tc_bg_wait
		tc op "$DEV" clearbool 0x40
		abort_test "session did not reach the reset point: ${R[step1_errno]} ${R[step2_errno]}"
	fi
	check_eq "${R[step2_errno]:-0}" 0 "first read on the open file"
	mark=$(kmsg_mark)
	do_reset lu
	touch "$go"
	tc_bg_wait
	check_eq "${R[step6_errno]}" 0 "rewind after the reset recovers"
	check_eq "${R[step7_errno]}" 0 "read after reset and rewind on the same open file"
	if kmsg_since "$mark" | grep -q "Locking drive door"; then
		pass "st locked the door again after the reset"
	else
		warn "st did not lock the door again after the reset (auto-lock state not cleared)"
	fi
	expect_ok "disable auto-lock" op "$DEV" clearbool 0x40
	expect_ok "rewind" op "$DEV" rewind
	layout_verify "after auto-lock test"
}

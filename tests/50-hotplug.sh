#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Device removal racing with opens of the tape node.
#
# st_remove() and st_open() -> scsi_tape_get() meet in st_ref_mutex and
# st_index_idr.  Since the conversion to st_index_idr (6c648d95a6af),
# st_remove() dropped the last reference, freeing the scsi_tape, before it
# removed the index from the idr.  An open waiting on st_ref_mutex could then
# find the freed structure in the idr and kref_get() it:
# "KASAN: slab-use-after-free in st_open" (linux-scsi, 2026-10-07).
#
# The device is removed through sysfs (scsi_device delete) and brought back
# with a scan of the same H:C:T:L, over and over, while several processes open
# and close the no-rewind node as fast as they can.  Every open goes through
# scsi_tape_get()/scsi_tape_put() (an open that then gets EBUSY too), so they
# contend on st_ref_mutex with st_remove().
#
# The race window is a few instructions wide, so a clean run is evidence, not
# proof - and without KASAN a use-after-free is usually silent.  The verdict
# comes from the kernel log (KASAN, refcount_t, BUG, ...).
#
# scsi_debug discards a LUN's tape when the device is removed, so the layout is
# rebuilt by the next test that needs it.

HP_CYCLES=${TT_HOTPLUG_CYCLES:-50}
HP_OPENERS=${TT_HOTPLUG_OPENERS:-4}

_hp_kasan() {	# 0 if the running kernel has KASAN
	local c
	c=/boot/config-$(uname -r)
	if [[ -r $c ]]; then grep -q '^CONFIG_KASAN=y' "$c"; return; fi
	[[ -r /proc/config.gz ]] && zgrep -q '^CONFIG_KASAN=y' /proc/config.gz
}

_hp_node() {	# hctl -> st name (nstN) at that H:C:T:L, empty if none
	local p
	for p in /sys/class/scsi_tape/nst*; do
		[[ $(basename "$p") =~ ^nst[0-9]+$ ]] || continue
		if [[ $(basename "$(readlink -f "$p/device")") == "$1" ]]; then
			basename "$p"
			return
		fi
	done
}

_hp_wait() {	# gone|back hctl seconds
	local want=$1 deadline=$((SECONDS + $3)) n
	while [[ $SECONDS -lt $deadline ]]; do
		n=$(_hp_node "$2")
		[[ $want == gone && -z $n ]] && return 0
		[[ $want == back && -n $n && -c /dev/$n ]] && return 0
		sleep 0.05
	done
	return 1
}

tt_register H01 hotplug sdebug "device removal racing with opens: no use-after-free of the scsi_tape (st_remove vs st_open)"
t_H01() {
	local name scan i ok=0 n pid stop=$TT_TDIR/openers.stop
	local -a pids=() f=()
	local -A errs=()
	local opens=0 opened=0 e
	name=$(basename "$DEV")
	scan=/sys/class/scsi_host/host${HCTL%%:*}/scan
	[[ -w $TT_SDEV_SYS/delete && -w $scan ]] ||
		skip_test "cannot remove/rescan $HCTL through sysfs"

	if _hp_kasan; then
		note "kernel has KASAN: a use-after-free in the race window is reported"
	else
		unverified "kernel without KASAN: a use-after-free in st_open() is only seen if refcount_t happens to catch it (run on a debug kernel)"
	fi

	layout_dirty "H01 removes $HCTL: scsi_debug discards the tape"

	step "$HP_OPENERS processes opening $DEV while $HCTL is removed and re-added $HP_CYCLES times"
	for ((i = 0; i < HP_OPENERS; i++)); do
		python3 "$TAPECTL" openloop "$DEV" --stop "$stop" --ready "$TT_TDIR/opener.$i.ready" \
			--max-seconds "$TT_IO_TMO" > "$TT_TDIR/opener.$i.out" 2>&1 &
		pids+=($!)
	done
	for ((i = 0; i < HP_OPENERS; i++)); do
		wait_file "$TT_TDIR/opener.$i.ready" 30 || { touch "$stop"; abort_test "opener $i did not start"; }
	done

	for ((i = 1; i <= HP_CYCLES; i++)); do
		if ! { echo 1 > "$TT_SDEV_SYS/delete"; } 2>/dev/null; then
			fail "cycle $i: deleting $HCTL failed"; break
		fi
		if ! _hp_wait gone "$HCTL" "$TT_SHORT_TMO"; then
			fail "cycle $i: $name still present after deleting $HCTL"; break
		fi
		if ! { echo "${HCTL#*:}" | tr : ' ' > "$scan"; } 2>/dev/null; then
			fail "cycle $i: scan of $HCTL failed"; break
		fi
		if ! _hp_wait back "$HCTL" "$TT_SHORT_TMO"; then
			fail "cycle $i: $HCTL did not come back after the scan"; break
		fi
		n=$(_hp_node "$HCTL")
		if [[ $n != "$name" ]]; then
			# the parent shell still uses $DEV: nothing after this is valid
			touch "$TT_RUN/abort"
			fail "cycle $i: $HCTL came back as $n, not $name"; break
		fi
		ok=$i
	done
	[[ $ok -eq $HP_CYCLES ]] && pass "$HP_CYCLES remove/add cycles of $HCTL, st name $name kept"

	touch "$stop"
	for ((i = 0; i < HP_OPENERS; i++)); do
		pid=${pids[$i]}
		if ! tt_wait_pid "$pid" 60; then
			tt_hang_report "$pid" "openloop $DEV (opener $i)"
			continue
		fi
		wait "$pid"
		_tt_parse "$TT_TDIR/opener.$i.out"
		if [[ ${R[errno]} != 0 ]]; then
			fail "opener $i: $(head -3 "$TT_TDIR/opener.$i.out" | tr '\n' ' ')"
			continue
		fi
		opens=$((opens + ${R[opens]:-0})); opened=$((opened + ${R[ok]:-0}))
		IFS=, read -ra f <<< "${R[errs]}"
		for e in "${f[@]}"; do
			[[ -n $e ]] && errs[${e%:*}]=$(( ${errs[${e%:*}]:-0} + ${e##*:} ))
		done
	done

	log "opens: $opens attempted, $opened succeeded; failures: $(for e in "${!errs[@]}"; do printf '%s=%s ' "$e" "${errs[$e]}"; done)"
	if [[ $opened -gt 0 ]]; then
		pass "the race was exercised: $opened of $opens opens succeeded"
	else
		fail "no open succeeded: the race was not exercised"
	fi
	for e in "${!errs[@]}"; do
		case $e in
		EBUSY|ENXIO|ENODEV|ENOENT) ;;	# in use, or the device is (being) removed
		*) warn "open/close failed with $e ${errs[$e]} times during removal" ;;
		esac
	done

	if kmsg_since "$(cat "$TT_TDIR/kmsg.mark")" | grep -Eq 'KASAN|refcount_t|use-after-free'; then
		fail "kernel reported a use-after-free / refcount error during the race (kmsg.log)"
	else
		pass "no use-after-free or refcount error reported by the kernel"
	fi

	# the re-added device starts with st defaults: re-apply stinit/scsi2logical
	tt_configure_st > "$TT_TDIR/configure.log" 2>&1
	status "$DEV"
	[[ ${S[online]} == 1 ]] || tc op "$DEV" load
	check_status "$DEV" online 1 "$DEV usable after the last cycle"
}

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# common.sh - result accounting, deadline-guarded execution and assertions.
#
# Tests run in a subshell.  Every assertion appends to files in $TT_TDIR so
# results survive the subshell; the runner turns them into PASS/FAIL/SKIP.

TT_LIB=${TT_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
TAPECTL="$TT_LIB/tapectl.py"

declare -gA R=()     # key=value output of the last tapectl call
declare -gA S=()     # snapshot of the last status call

# --------------------------------------------------------------------------
# logging
# --------------------------------------------------------------------------
ts()   { date '+%H:%M:%S'; }
log()  { printf '%s  %s\n' "$(ts)" "$*"; }
step() { printf '%s  --- %s\n' "$(ts)" "$*"; }
die()  { printf 'tapetest: error: %s\n' "$*" >&2; exit 2; }
vlog() { [[ ${TT_VERBOSE:-0} -gt 0 ]] && printf '%s      %s\n' "$(ts)" "$*"; return 0; }

# --------------------------------------------------------------------------
# result recording (inside a test)
# --------------------------------------------------------------------------
pass()       { printf '%s    ok      %s\n' "$(ts)" "$*"; echo "$*" >> "$TT_TDIR/pass"; }
fail()       { printf '%s    FAIL    %s\n' "$(ts)" "$*"; echo "$*" >> "$TT_TDIR/fail"; }
warn()       { printf '%s    WARN    %s\n' "$(ts)" "$*"; echo "$*" >> "$TT_TDIR/warn"; }
note()       { printf '%s    NOTE    %s\n' "$(ts)" "$*"; echo "$*" >> "$TT_TDIR/note"; }
unverified() { printf '%s    UNVERIFIED %s\n' "$(ts)" "$*"; echo "$*" >> "$TT_TDIR/unverified"; }
skip_test()  { printf '%s    SKIP    %s\n' "$(ts)" "$*"; echo "$*" > "$TT_TDIR/skip"; exit 77; }
# A condition that makes the rest of the test meaningless.
abort_test() { fail "$*"; exit 1; }
nfails()     { [[ -f $TT_TDIR/fail ]] && wc -l < "$TT_TDIR/fail" || echo 0; }

# --------------------------------------------------------------------------
# deadline-guarded execution
# --------------------------------------------------------------------------
tt_timeout_for() {
	# $1 = tapectl subcommand, $3 = op name for "op"
	case "$1" in
	op)
		case "$3" in
		rewind|eod|retension|erase|load|offline|unload|seek|fsf|bsf|fsfm|bsfm|mkpart)
			echo "$TT_LONG_TMO" ;;
		*)	echo "$TT_SHORT_TMO" ;;
		esac ;;
	read|write) echo "$TT_IO_TMO" ;;
	*)	echo "$TT_SHORT_TMO" ;;
	esac
}

# Wait for pid up to $2 seconds. Returns 0 if it exited.
tt_wait_pid() {
	local pid=$1 deadline=$((SECONDS + $2))
	while kill -0 "$pid" 2>/dev/null; do
		[[ $SECONDS -ge $deadline ]] && return 1
		sleep 0.1
	done
	return 0
}

# Collect evidence for a hung tape command, then try to kill it.
tt_hang_report() {
	local pid=$1 what=$2
	local f="$TT_TDIR/hang.$pid"
	fail "HANG: '$what' did not complete within its deadline"
	{
		echo "=== hung command: $what (pid $pid)"
		echo "--- state:";  grep -E '^(State|Name)' "/proc/$pid/status" 2>/dev/null
		echo "--- wchan:";  cat "/proc/$pid/wchan" 2>/dev/null; echo
		echo "--- kernel stack:"; cat "/proc/$pid/stack" 2>/dev/null
	} > "$f"
	cat "$f"
	if [[ ${TT_SYSRQ_ON_HANG:-0} -eq 1 && -w /proc/sysrq-trigger ]]; then
		echo w > /proc/sysrq-trigger
	fi
	kill -KILL "$pid" 2>/dev/null
	if ! tt_wait_pid "$pid" 30; then
		# Stuck in D state: the tape is unusable, the run cannot continue.
		echo "process $pid is unkillable (D state) - aborting run" | tee -a "$f"
		touch "$TT_RUN/abort"
	fi
}

_tt_parse() {
	R=()
	local k v
	while IFS='=' read -r k v; do
		[[ -n $k && $k != *" "* ]] && R[$k]=$v
	done < "$1"
}

# tc <tapectl args...>   run tapectl with a deadline, result in R[]
tc() {
	local of pid rc tmo
	tmo=$(tt_timeout_for "$@")
	of=$(mktemp -p "$TT_TDIR" .tc.XXXXXX)
	python3 "$TAPECTL" "$@" > "$of" 2>&1 &
	pid=$!
	if ! tt_wait_pid "$pid" "$tmo"; then
		tt_hang_report "$pid" "tapectl $*"
		R=([errno]=TIMEOUT)
		rm -f "$of"
		return 124
	fi
	wait "$pid"; rc=$?
	_tt_parse "$of"
	[[ -z ${R[errno]} ]] && { R[errno]=HARNESS; cat "$of"; }
	vlog "tapectl $* -> errno=${R[errno]}"
	rm -f "$of"
	return $rc
}

# tc_bg <out-file> <tapectl args...>   start in background, pid in BG_PID
tc_bg() {
	local of=$1; shift
	# shellcheck disable=SC2034
	BG_OUT=$of
	python3 "$TAPECTL" "$@" > "$of" 2>&1 &
	BG_PID=$!
	vlog "bg[$BG_PID] tapectl $*"
}

# tc_bg_wait <timeout>   wait for BG_PID, parse BG_OUT into R
tc_bg_wait() {
	if ! tt_wait_pid "$BG_PID" "${1:-$TT_IO_TMO}"; then
		tt_hang_report "$BG_PID" "background tapectl"
		R=([errno]=TIMEOUT)
		return 124
	fi
	wait "$BG_PID"
	_tt_parse "$BG_OUT"
	[[ -z ${R[errno]} ]] && { R[errno]=HARNESS; cat "$BG_OUT"; }
	return 0
}

# Wait for a file to appear (progress markers written by tapectl).
wait_file() {
	local f=$1 deadline=$((SECONDS + $2))
	while [[ ! -e $f ]]; do
		[[ $SECONDS -ge $deadline ]] && return 1
		sleep 0.05
	done
	return 0
}

# --------------------------------------------------------------------------
# assertions
# --------------------------------------------------------------------------
# expect_ok "description" <tapectl args...>
expect_ok() {
	local d=$1; shift
	tc "$@"
	if [[ ${R[errno]} == 0 ]]; then pass "$d"; return 0; fi
	fail "$d: expected success, got ${R[errno]}"
	return 1
}

# expect_errno ERRNO "description" <tapectl args...>
expect_errno() {
	local want=$1 d=$2; shift 2
	tc "$@"
	if [[ ${R[errno]} == "$want" ]]; then pass "$d ($want)"; return 0; fi
	fail "$d: expected $want, got ${R[errno]}"
	return 1
}

check_eq() {	# actual expected description
	if [[ "$1" == "$2" ]]; then pass "$3"; return 0; fi
	fail "$3: got '$1', expected '$2'"
	return 1
}

check_in() {	# actual "a|b|c" description
	if [[ "|$2|" == *"|$1|"* ]]; then pass "$3 ($1)"; return 0; fi
	fail "$3: got '$1', expected one of $2"
	return 1
}

# status <dev>: snapshot into S[]; returns non-zero if the ioctl failed
status() {
	tc status "$1"
	S=()
	local k
	for k in "${!R[@]}"; do S[$k]=${R[$k]}; done
	[[ ${S[errno]} == 0 ]]
}

check_status() {	# dev field expected description
	if ! status "$1"; then
		fail "$4: MTIOCGET failed with ${S[errno]}"
		return 1
	fi
	check_eq "${S[$2]}" "$3" "$4"
}

# position_lost_in_reset: never skipped silently.
pos_lost() {	# dev -> echoes value or "missing"
	tc sysattr "$1" position_lost_in_reset
	if [[ ${R[errno]} == 0 ]]; then echo "${R[value]}"; else echo missing; fi
}

check_pos_lost() {	# dev expected description
	local v
	v=$(pos_lost "$1")
	if [[ $v == missing ]]; then
		unverified "position_lost_in_reset not available: $3"
		return 0
	fi
	check_eq "$v" "$2" "position_lost_in_reset=$2: $3"
}

# --------------------------------------------------------------------------
# kernel log
# --------------------------------------------------------------------------
TT_KMSG_BAD='WARNING: CPU|BUG:|Oops|Call Trace|general protection|KASAN|UBSAN|kernel BUG|blocked for more than|list_(add|del) corruption|refcount_t:|use-after-free|soft lockup|hard LOCKUP|rcu.*(stall|self-detected)|INFO: task .* blocked'

kmsg_mark() {
	[[ $TT_MODE == mock ]] && { echo -1; return; }
	python3 "$TAPECTL" kmsg mark 2>/dev/null | sed -n 's/^seq=//p'
}

# kmsg_since <seq> : print kernel messages newer than seq
kmsg_since() {
	[[ $TT_MODE == mock || -z $1 || $1 == -1 ]] && return 0
	python3 "$TAPECTL" kmsg since --since "$1"
}

# kmsg_expect <regex> <description> : check the current test's kernel log
kmsg_expect() {
	if [[ $TT_MODE == mock ]]; then
		unverified "kernel message '$1' (mock mode): $2"
		return 0
	fi
	if kmsg_since "$(cat "$TT_TDIR/kmsg.mark")" | grep -Eq "$1"; then
		pass "kernel logged '$1': $2"
	else
		fail "kernel did not log '$1': $2"
	fi
}

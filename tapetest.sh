#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# tapetest - validation harness for the Linux SCSI tape (st) driver.
#
# Run "tapetest --help" for usage.  See README.md for the test catalogue.

TT_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
TT_LIB=$TT_ROOT/lib
export TT_LIB
# shellcheck source=lib/common.sh
. "$TT_LIB/common.sh"
# shellcheck source=lib/device.sh
. "$TT_LIB/device.sh"
# shellcheck source=lib/layout.sh
. "$TT_LIB/layout.sh"
# shellcheck source=lib/reset.sh
. "$TT_LIB/reset.sh"

TT_VERSION=2.22

declare -ga TT_IDS=()
declare -gA TT_SUITE=() TT_REQ=() TT_DESC=()

tt_register() {	# id suite reqs description
	TT_IDS+=("$1"); TT_SUITE[$1]=$2; TT_REQ[$1]=$3; TT_DESC[$1]=$4
}

usage() {
	cat <<EOF
tapetest $TT_VERSION - Linux st tape driver validation

usage: tapetest [mode] [options]

mode (one of):
  -d, --device DEV        real tape drive (/dev/nstN or /dev/stN)
      --scsi-debug[=N]    load scsi_debug with an emulated tape, N LUNs (default 2)
      --mock[=N]          no kernel involvement: self-test of the harness itself

selection:
  -s, --suite LIST        comma list of suites: basic,reset,eh,boundary,stress
                          (default: basic,reset,eh,boundary)
  -t, --test LIST         comma list of test ids or globs (e.g. R03.*,R05.lu)
  -x, --exclude LIST      exclude test ids or globs
  -l, --list              list tests and whether they would run, then exit

safety / scope:
  -y, --yes               confirm that all data on the tape may be destroyed
      --long              allow hours-long tests on hardware (erase, fill to EOM)
      --allow-bus-reset   allow SCSI bus resets   (affects all devices on the bus)
      --allow-host-reset  allow SCSI host resets  (affects all devices on the HBA)
      --allow-link-reset  allow SAS phy link resets
      --legacy            kernel without position_lost_in_reset: warn, don't fail
      --skip-partitions   hardware with can-partitions=0: acknowledge that the
                          partition tests (X03-X05) will be skipped (without it
                          tapetest asks, or refuses when not on a terminal)

tuning:
      --bs BYTES          I/O and variable block size
      --file-mb N         size of each data file
      --inflight-mb N     size of writes/reads that get interrupted by resets
      --iterations N      stress iterations (default 5)
      --reuse-scsi-debug  use an already loaded scsi_debug

st driver setup (hw and scsi-debug modes; default: all on):
      --no-reload-st      do not "rmmod st; modprobe st debug_flag=1" first
      --no-st-debug       reload st with debug_flag=0 (quiet kernel log)
      --no-stinit         do not apply stinit.conf (scsi2logical is still enforced)
      --st-debug          with --no-reload-st: set st debug_flag at runtime

output:
  -o, --out DIR           results directory (default ./results/<timestamp>)
      --stop-on-fail      stop after the first failing test
  -v, --verbose           log every tapectl call
  -h, --help

exit status: 0 all selected tests passed or skipped, 1 failures, 2 harness error
EOF
}

# ---------------------------------------------------------------------------
TT_MODE=""; TT_DEVARG=""; TT_LUNS=2
SUITES="basic,reset,eh,boundary"; TESTS=""; EXCLUDE=""; LIST=0; YES=0; SKIP_PART=0
STOP=0; STDEBUG=0; OUTDIR=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-d|--device)     TT_MODE=hw; TT_DEVARG=$2; shift ;;
	--scsi-debug)    TT_MODE=sdebug ;;
	--scsi-debug=*)  TT_MODE=sdebug; TT_LUNS=${1#*=} ;;
	--mock)          TT_MODE=mock ;;
	--mock=*)        TT_MODE=mock; TT_LUNS=${1#*=} ;;
	-s|--suite)      SUITES=$2; shift ;;
	-t|--test)       TESTS=$2; shift ;;
	-x|--exclude)    EXCLUDE=$2; shift ;;
	-l|--list)       LIST=1 ;;
	-y|--yes)        YES=1 ;;
	--long)          TT_LONG=1 ;;
	--allow-bus-reset)  TT_ALLOW_BUS=1 ;;
	--allow-host-reset) TT_ALLOW_HOST=1 ;;
	--allow-link-reset) TT_ALLOW_LINK=1 ;;
	--legacy)        TT_LEGACY=1 ;;
	--skip-partitions) SKIP_PART=1 ;;
	--bs)            TT_BS=$2; shift ;;
	--file-mb)       TT_FILE_BYTES=$(( $2 << 20 )); shift ;;
	--inflight-mb)   TT_INFLIGHT_BYTES=$(( $2 << 20 )); shift ;;
	--iterations)    TT_ITER=$2; shift ;;
	--reuse-scsi-debug) TT_REUSE_SDEBUG=1 ;;
	--no-reload-st)  TT_NO_RELOAD_ST=1 ;;
	--no-st-debug)   TT_ST_DEBUG_LEVEL=0 ;;
	--no-stinit)     TT_NO_STINIT=1 ;;
	--st-debug)      STDEBUG=1 ;;
	-o|--out)        OUTDIR=$2; shift ;;
	--stop-on-fail)  STOP=1 ;;
	-v|--verbose)    TT_VERBOSE=1 ;;
	-h|--help)       usage; exit 0 ;;
	*)               usage; die "unknown argument '$1'" ;;
	esac
	shift
done
[[ -n $TT_MODE ]] || { usage; exit 2; }
export TT_MODE TT_LONG TT_ALLOW_BUS TT_ALLOW_HOST TT_ALLOW_LINK TT_LEGACY TT_ITER TT_VERBOSE
[[ $TT_MODE == mock ]] && : "${TT_ITER:=10}"
[[ $TT_MODE == sdebug ]] && : "${TT_ITER:=10}"

# load the test catalogue
for f in "$TT_ROOT"/tests/*.sh; do
	# shellcheck source=/dev/null
	. "$f"
done

# ---------------------------------------------------------------------------
# selection and requirements
# ---------------------------------------------------------------------------
_match_list() {	# id list   (patterns are matched, never glob-expanded)
	local g gs=()
	IFS=, read -ra gs <<< "$2"
	for g in "${gs[@]}"; do
		# shellcheck disable=SC2053
		[[ $1 == $g ]] && return 0
	done
	return 1
}

selected() {
	local id=$1
	if [[ -n $TESTS ]]; then _match_list "$id" "$TESTS" || return 1
	else _match_list "${TT_SUITE[$id]}" "$SUITES" || return 1; fi
	[[ -n $EXCLUDE ]] && _match_list "$id" "$EXCLUDE" && return 1
	return 0
}

# unmet_req <id> : prints the reason a test can't run here, empty if it can
unmet_req() {
	local r IFS=,
	for r in ${TT_REQ[$1]}; do
		case $r in
		any|lu|target) ;;
		hw)      [[ $TT_MODE == hw ]] || { echo "needs real hardware"; return; } ;;
		long)    [[ $TT_MODE != hw || ${TT_LONG:-0} -eq 1 ]] ||
				 { echo "takes hours on hardware (use --long)"; return; } ;;
		bus)     [[ ${TT_ALLOW_BUS:-0} -eq 1 ]] || { echo "needs --allow-bus-reset"; return; } ;;
		host)    [[ ${TT_ALLOW_HOST:-0} -eq 1 ]] || { echo "needs --allow-host-reset"; return; } ;;
		link)    [[ ${TT_ALLOW_LINK:-0} -eq 1 ]] || { echo "needs --allow-link-reset"; return; }
			 [[ -n $(sas_phy_of "$DEV") ]] || { echo "device is not behind a SAS phy"; return; } ;;
		inject)  [[ ${HAVE_INJECT:-0} -eq 1 ]] ||
				 { echo "needs scsi_debug error injection (--scsi-debug, debugfs)"; return; } ;;
		multilun) [[ ${#PEERS[@]} -gt 0 ]] || { echo "needs a second tape LUN on the same target"; return; } ;;
		partitions) [[ $TT_MODE == sdebug || ${CAN_PART:-0} -eq 1 ]] ||
				 { echo "needs partition support (sdebug or can-partitions)"; return; } ;;
		*)       echo "unknown requirement '$r'"; return ;;
		esac
	done
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
TT_RUN=${OUTDIR:-$PWD/results/$(date +%Y%m%d-%H%M%S)}
# A results directory holds per-test state (layout model, restore values,
# appended result files): reusing one would mix two runs.
if [[ $LIST -ne 1 && -d $TT_RUN && -n $(ls -A "$TT_RUN" 2>/dev/null) ]]; then
	die "results directory $TT_RUN is not empty - choose a new -o or remove it"
fi
mkdir -p "$TT_RUN/tests" || die "cannot create $TT_RUN"
TT_RUN=$(cd "$TT_RUN" && pwd)
export TT_RUN
TT_TDIR=$TT_RUN/setup; mkdir -p "$TT_TDIR"

tt_preflight_tools
trap 'tt_teardown' EXIT
RELOAD=0
[[ $TT_MODE != mock && ${TT_NO_RELOAD_ST:-0} -ne 1 && $LIST -ne 1 ]] && RELOAD=1
case $TT_MODE in
mock)   : "${TT_MOCK_CAP:=3000}"; export TT_MOCK_CAP; tt_setup_mock "$TT_LUNS" ;;
sdebug) [[ $RELOAD -eq 1 ]] && tt_reload_st
	tt_setup_sdebug "$TT_LUNS" ;;
hw)     tt_resolve "$TT_DEVARG"
	if [[ $RELOAD -eq 1 ]]; then
		want=$HCTL
		tt_reload_st
		tt_resolve_hctl "$want"
	fi ;;
esac
tt_profile
[[ $TT_NFILES -ge 3 ]] || die "at least 3 baseline files are required"
trap 'echo; log "interrupted"; exit 2' INT TERM

if [[ $TT_MODE != mock ]]; then
	status "$DEV" || die "cannot open $DEV: ${S[errno]}"
	if [[ ${S[online]} != 1 ]]; then
		tc op "$DEV" load
		status "$DEV"
		[[ ${S[online]} == 1 ]] || die "no tape loaded in $DEV"
	fi
	[[ ${S[wr_prot]} == 1 ]] && die "tape in $DEV is write protected"
fi
[[ $(pos_lost "$DEV") == 1 ]] && tc op "$DEV" rewind
[[ $TT_MODE != mock && $LIST -ne 1 ]] && tt_configure_st
tt_features

if [[ $LIST -eq 1 ]]; then
	printf '%-14s %-9s %s\n' ID SUITE DESCRIPTION
	for id in "${TT_IDS[@]}"; do
		r=$(unmet_req "$id")
		s=run; selected "$id" || s=-; [[ -n $r ]] && s="skip: $r"
		printf '%-14s %-9s %s\n%26s[%s]\n' "$id" "${TT_SUITE[$id]}" "${TT_DESC[$id]}" "" "$s"
	done
	exit 0
fi

if [[ $TT_MODE == hw && $YES -ne 1 ]]; then
	echo "All data on the tape in $DEV ($TT_VENDOR $TT_MODEL) will be DESTROYED."
	echo "Re-run with --yes to confirm."
	exit 2
fi
[[ $STDEBUG -eq 1 && ${TT_ST_RELOADED:-0} -ne 1 ]] && tt_set_st_debug 1

# ---------------------------------------------------------------------------
# partition support on hardware
#
# The partition tests need can-partitions, which is normally off for real
# drives in stinit.conf.  A run that silently skips them looks complete, and
# that hid a real st bug (X03) until the tests were run on a drive with
# partitions enabled.  So a hardware run that would skip them has to be
# acknowledged.  The other way round, can-partitions=1 changes how st reports
# some positions (e.g. 0:0 instead of -1:-1 after a reset at BOT, R10.bot), so
# the remaining tests are meant to run with it off: warn about that too.
# ---------------------------------------------------------------------------
PART_NOTE=""
if [[ $TT_MODE == hw ]]; then
	part_ids=(); other_ids=()
	for id in "${TT_IDS[@]}"; do
		selected "$id" || continue
		if _match_list partitions "${TT_REQ[$id]}"; then part_ids+=("$id")
		else other_ids+=("$id"); fi
	done
	if [[ ${CAN_PART:-0} -ne 1 && ${#part_ids[@]} -gt 0 ]]; then
		cat <<EOW

  *** WARNING: can-partitions=0 on $DEV ($TT_VENDOR $TT_MODEL)
  *** The partition tests will be SKIPPED: ${part_ids[*]}
  *** To run them: set can-partitions=1 in the drive's stanza in
  ***   $TT_ROOT/stinit.conf
  *** and run them on their own, e.g.  -t '$(IFS=,; echo "${part_ids[*]}")'
  *** then restore it (git checkout stinit.conf).

EOW
		if [[ $SKIP_PART -eq 1 ]]; then
			log "partition tests skipped (--skip-partitions)"
		elif [[ -t 0 ]]; then
			ans=""
			read -r -p "  Type 'skip' to continue without them, or Ctrl-C to stop: " ans
			[[ $ans == skip ]] || die "not acknowledged - stopping"
			log "partition tests skipped (acknowledged)"
		else
			die "partition tests would be skipped (can-partitions=0): add --skip-partitions, or exclude them with -x"
		fi
		PART_NOTE="partitions: can-partitions=0, skipped by acknowledgement: ${part_ids[*]}"
	elif [[ ${CAN_PART:-0} -eq 1 && ${#other_ids[@]} -gt 0 ]]; then
		cat <<EOW

  *** NOTE: can-partitions=1 on $DEV, and non-partition tests are selected.
  *** Those tests are meant to run with can-partitions=0; some position
  *** checks differ with partitions on (e.g. R10.bot).  Normal practice:
  ***   run X03,X04,X05 alone with can-partitions=1, everything else with 0.

EOW
		PART_NOTE="partitions: can-partitions=1 with non-partition tests selected (results may differ, e.g. R10.bot)"
	fi
fi

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
{
	echo "tapetest $TT_VERSION   $(date)"
	echo "kernel:   $(uname -r)"
	echo "mode:     $TT_MODE"
	echo "device:   $DEV $REWDEV $SG [$HCTL] $TT_VENDOR $TT_MODEL $TT_REV"
	echo "peers:    ${PEERS[*]:-none}"
	echo "features: position_lost_in_reset=$HAVE_POS_LOST can_partitions=$CAN_PART inject=$HAVE_INJECT"
	[[ $TT_MODE != mock ]] &&
	echo "st:       reloaded=${TT_ST_RELOADED:-0} debug_flag=${TT_ST_DEBUG:-?} options=${TT_ST_OPTIONS:-?} stinit=${TT_STINIT:-?}"
	echo "profile:  bs=$TT_BS file=$TT_FILE_BYTES inflight=$TT_INFLIGHT_BYTES fixed_bs=$TT_FIXED_BS verify=$TT_VERIFY"
	echo "resets:   $(reset_methods)"
	[[ -n $PART_NOTE ]] && echo "$PART_NOTE"
	echo "results:  $TT_RUN"
} | tee "$TT_RUN/environment.txt"
echo

# sanitize: bring the device back to a known state between tests
tt_sanitize() {
	local d
	tt_restore_all
	for d in "$DEV" "${PEERS[@]}"; do
		status "$d"
		if [[ ${S[errno]} != 0 || ${S[online]} != 1 ]]; then
			tc op "$d" load
		fi
		[[ $(pos_lost "$d") == 1 ]] && tc op "$d" rewind
		status "$d"
		[[ ${S[blksize]} != 0 ]] && tc op "$d" setblk 0
	done
	status "$DEV"
	[[ ${S[online]} == 1 && $(pos_lost "$DEV") != 1 ]]
}

RESULTS=$TT_RUN/results.txt; : > "$RESULTS"
TAP=$TT_RUN/results.tap
declare -a RUN_IDS=()
for id in "${TT_IDS[@]}"; do selected "$id" && RUN_IDS+=("$id"); done
[[ ${#RUN_IDS[@]} -gt 0 ]] || die "no tests match the selection (suite '$SUITES' test '$TESTS')"
echo "1..${#RUN_IDS[@]}" > "$TAP"

n=0; npass=0; nfail=0; nskip=0; nerr=0
for id in "${RUN_IDS[@]}"; do
	n=$((n + 1))
	[[ -e $TT_RUN/abort ]] && { echo "not ok $n $id # SKIP run aborted" >> "$TAP"; nerr=$((nerr + 1)); continue; }
	TT_TDIR=$TT_RUN/tests/$id; mkdir -p "$TT_TDIR"; export TT_TDIR
	reason=$(unmet_req "$id")
	echo "=== [$n/${#RUN_IDS[@]}] $id: ${TT_DESC[$id]}"
	t0=$SECONDS
	if [[ -n $reason ]]; then
		rc=77; echo "$reason" > "$TT_TDIR/skip"
		log "    SKIP    $reason"
	else
		fn=t_${id%%.*}; arg=""
		[[ $id == *.* ]] && arg=${id#*.}
		kmsg_mark > "$TT_TDIR/kmsg.mark"
		# shellcheck disable=SC2086
		# Only an explicit exit (skip_test / abort_test) sets the status;
		# a function's final return value is not a verdict.
		( $fn $arg; exit 0 ) 2>&1 | tee "$TT_TDIR/log"
		rc=${PIPESTATUS[0]}
		kmsg_since "$(cat "$TT_TDIR/kmsg.mark")" > "$TT_TDIR/kmsg.log"
		if grep -Eq "$TT_KMSG_BAD" "$TT_TDIR/kmsg.log"; then
			grep -E "$TT_KMSG_BAD" "$TT_TDIR/kmsg.log" | head -5 | while read -r l; do
				fail "kernel: $l"
			done | tee -a "$TT_TDIR/log"
		fi
		if ! tt_sanitize >> "$TT_TDIR/sanitize.log" 2>&1; then
			echo "device could not be returned to a known state after $id" |
				tee -a "$TT_TDIR/fail" "$TT_RUN/abort"
		fi
	fi
	dt=$((SECONDS - t0))
	nf=$( [[ -f $TT_TDIR/fail ]] && wc -l < "$TT_TDIR/fail" || echo 0)
	np=$( [[ -f $TT_TDIR/pass ]] && wc -l < "$TT_TDIR/pass" || echo 0)
	if [[ $rc -eq 77 ]]; then
		res=SKIP; nskip=$((nskip + 1))
		echo "ok $n $id # SKIP $(cat "$TT_TDIR/skip")" >> "$TAP"
	elif [[ $nf -gt 0 || $rc -ne 0 ]]; then
		res=FAIL; nfail=$((nfail + 1))
		[[ $nf -eq 0 ]] && echo "test exited with status $rc" >> "$TT_TDIR/fail"
		echo "not ok $n $id - ${TT_DESC[$id]}" >> "$TAP"
		sed 's/^/  # /' "$TT_TDIR/fail" >> "$TAP"
	else
		res=PASS; npass=$((npass + 1))
		echo "ok $n $id - ${TT_DESC[$id]}" >> "$TAP"
	fi
	echo "$id|$res|$dt|$np|$nf|${TT_DESC[$id]}" >> "$RESULTS"
	printf '=== %s %s (%ds, %d checks, %d failed)\n\n' "$id" "$res" "$dt" "$np" "$nf"
	[[ $res == FAIL && $STOP -eq 1 ]] && { log "stopping on first failure"; break; }
done

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
junit() {
	local x=$TT_RUN/junit.xml id res dt np nf desc
	{
		echo '<?xml version="1.0" encoding="UTF-8"?>'
		echo "<testsuite name=\"tapetest\" tests=\"$n\" failures=\"$nfail\" skipped=\"$nskip\" errors=\"$nerr\">"
		while IFS='|' read -r id res dt np nf desc; do
			desc=${desc//&/&amp;}; desc=${desc//</&lt;}; desc=${desc//\"/&quot;}
			echo "  <testcase classname=\"tapetest.${TT_SUITE[$id]}\" name=\"$id\" time=\"$dt\">"
			case $res in
			SKIP) echo "    <skipped message=\"$(sed 's/[&<"]/_/g' "$TT_RUN/tests/$id/skip")\"/>" ;;
			FAIL) echo "    <failure message=\"$desc\"><![CDATA["
			      cat "$TT_RUN/tests/$id/fail"
			      echo "]]></failure>" ;;
			esac
			echo "  </testcase>"
		done < "$RESULTS"
		echo "</testsuite>"
	} > "$x"
}
junit

{
	echo
	echo "==================================================================="
	printf 'tapetest summary: %d run, %d passed, %d FAILED, %d skipped' "$n" "$npass" "$nfail" "$nskip"
	[[ $nerr -gt 0 ]] && printf ', %d not run (aborted)' "$nerr"
	echo
	echo "==================================================================="
	while IFS='|' read -r id res dt np nf desc; do
		printf '  %-5s %-12s %s\n' "$res" "$id" "$desc"
	done < "$RESULTS"
	for kind in fail warn unverified note; do
		files=$(ls "$TT_RUN"/tests/*/"$kind" 2>/dev/null)
		[[ -z $files ]] && continue
		echo
		case $kind in
		fail) echo "failures:" ;;
		warn) echo "warnings (behaviour worth a look):" ;;
		unverified) echo "checks that could NOT be verified on this system:" ;;
		note) echo "observations:" ;;
		esac
		for f in $files; do
			t=$(basename "$(dirname "$f")")
			sed "s/^/  [$t] /" "$f"
		done
	done
	echo
	echo "results: $TT_RUN  (summary.txt, results.tap, junit.xml, tests/<id>/{log,kmsg.log})"
} | tee "$TT_RUN/summary.txt"

[[ -e $TT_RUN/abort ]] && exit 2
[[ $nfail -gt 0 ]] && exit 1
exit 0

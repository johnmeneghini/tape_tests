#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# release-check - run the complete st validation for a kernel release and
# produce one report with one verdict.
#
# Stages (in order):
#   selftest    harness self-test against the mock st        (always)
#   sdebug      full suite on a scsi_debug tape               (always)
#   hw-basic    basic suite on the real drive                 (with -d)
#   hw-reset    reset + boundary suites on the real drive     (with -d)
#   hw-stress   random-reset stress                           (with -d --stress N)
#
# Verdict / exit status:
#   0 PASS        every stage passed; only known warnings
#   1 FAIL        at least one test failed
#   2 INCOMPLETE  a stage could not run or aborted
#   3 REVIEW      no failures, but warnings not in expected-warnings.txt

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

usage() {
	cat <<EOF
usage: release-check [-d DEV --yes] [options]

  -d, --device DEV      real drive (/dev/nstN); without it only the
                        selftest and scsi_debug stages run
  -y, --yes             confirm that all data on the tape may be destroyed
      --library         drive is in a library: skip tests that unload
                        (R03.offline, R04.offline, R09)
      --long            include hours-long hardware tests (erase, fill to EOM)
      --stress N        add a hardware stress stage with N iterations
      --allow-bus-reset / --allow-host-reset / --allow-link-reset
                        passed to the hardware stages
      --no-st-debug     reload st with debug_flag=0 in every stage (quiet log)
      --luns N          scsi_debug LUNs (default 2)
      --skip STAGE      skip a stage (repeatable): selftest sdebug hw-basic hw-reset
      --compare DIR     previous release-check directory to diff verdicts against
  -o, --out DIR         output directory (default ./release/<kernel>-<timestamp>)
      --mock            replace every kernel stage by a mock run (tests this
                        script; proves nothing about the kernel)
  -h, --help

exit: 0 PASS, 1 FAIL, 2 INCOMPLETE, 3 REVIEW (new warnings)
EOF
}

die() { echo "release-check: error: $*" >&2; exit 2; }

DEV=""; YES=0; LIBRARY=0; LONG=0; STRESS=0; LUNS=2; OUT=""; COMPARE=""; MOCK=0
declare -a SKIP=() HWOPTS=() STOPTS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	-d|--device)   DEV=$2; shift ;;
	-y|--yes)      YES=1 ;;
	--library)     LIBRARY=1 ;;
	--long)        LONG=1 ;;
	--stress)      STRESS=$2; shift ;;
	--allow-bus-reset|--allow-host-reset|--allow-link-reset) HWOPTS+=("$1") ;;
	--luns)        LUNS=$2; shift ;;
	--no-st-debug) STOPTS+=(--no-st-debug) ;;
	--skip)        SKIP+=("$2"); shift ;;
	--compare)     COMPARE=$2; shift ;;
	-o|--out)      OUT=$2; shift ;;
	--mock)        MOCK=1 ;;
	-h|--help)     usage; exit 0 ;;
	*)             usage; die "unknown argument '$1'" ;;
	esac
	shift
done

[[ -x $ROOT/tapetest.sh ]] || die "tapetest.sh not found next to release-check.sh"
if [[ $MOCK -eq 0 ]]; then
	[[ $EUID -eq 0 ]] || die "must be run as root"
	[[ -n $DEV && $YES -ne 1 ]] && die "hardware stages destroy the tape in $DEV: add --yes"
fi
[[ -n $COMPARE && ! -f $COMPARE/stages.txt ]] && die "--compare: $COMPARE is not a release-check directory"
[[ $STRESS =~ ^[0-9]+$ ]] || die "--stress needs a number"

KERNEL=$(uname -r)
OUT=${OUT:-$PWD/release/$KERNEL-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT" || die "cannot create $OUT"
OUT=$(cd "$OUT" && pwd)
: > "$OUT/stages.txt"

skipped() { local s; for s in "${SKIP[@]}"; do [[ $s == "$1" ]] && return 0; done; return 1; }

# run_stage NAME KIND cmd...    (KIND: tapetest | selftest)
run_stage() {
	local name=$1 kind=$2 t0 rc; shift 2
	if skipped "$name"; then
		echo "$name skipped 0 $kind" >> "$OUT/stages.txt"
		printf '\n##### stage %s: skipped\n' "$name"
		return
	fi
	printf '\n##### stage %s: %s\n' "$name" "$*"
	t0=$SECONDS
	"$@" 2>&1 | tee "$OUT/$name.log"
	rc=${PIPESTATUS[0]}
	echo "$name $rc $((SECONDS - t0)) $kind" >> "$OUT/stages.txt"
	printf '##### stage %s: exit %d after %ds\n' "$name" "$rc" "$((SECONDS - t0))"
}

# ---------------------------------------------------------------------------
# environment
# ---------------------------------------------------------------------------
{
	echo "date:       $(date -Is)"
	echo "host:       $(hostname)"
	echo "kernel:     $KERNEL"
	echo "cmdline:    $(cat /proc/cmdline)"
	echo "harness:    $(sed -n 's/^TT_VERSION=//p' "$ROOT/tapetest.sh")$(git -C "$ROOT" describe --always --dirty 2>/dev/null | sed 's/^/ git /')"
	echo "st module:  $(modinfo -F srcversion st 2>/dev/null || echo ?) ($(modinfo -F filename st 2>/dev/null || echo ?))"
	echo "sg3_utils:  $(command -v sg_reset >/dev/null && sg_reset -V 2>&1 | head -1 || echo 'not installed')"
	echo "python:     $(python3 -V 2>&1)"
	echo "device:     ${DEV:-none}$([[ $LIBRARY -eq 1 ]] && echo ' (library)')"
	echo "options:    long=$LONG stress=$STRESS ${HWOPTS[*]} ${STOPTS[*]} mock=$MOCK"
} > "$OUT/environment.txt"
cat "$OUT/environment.txt"

# ---------------------------------------------------------------------------
# stages
# ---------------------------------------------------------------------------
run_stage selftest selftest "$ROOT/selftest.sh" "$OUT/selftest"

if [[ $MOCK -eq 1 ]]; then
	run_stage sdebug tapetest "$ROOT/tapetest.sh" --mock="$LUNS" -o "$OUT/sdebug"
else
	run_stage sdebug tapetest "$ROOT/tapetest.sh" --scsi-debug="$LUNS" "${STOPTS[@]}" -o "$OUT/sdebug"
fi

if [[ -n $DEV || $MOCK -eq 1 ]]; then
	# release-check runs unattended: the boundary suite's partition tests
	# skip with can-partitions=0 (the run header records it)
	declare -a target=(-d "$DEV" --yes --skip-partitions "${STOPTS[@]}")
	[[ $MOCK -eq 1 ]] && target=(--mock)
	declare -a excl=()
	[[ $LIBRARY -eq 1 ]] && excl=(-x 'R03.offline,R04.offline,R09')
	declare -a long=()
	[[ $LONG -eq 1 ]] && long=(--long)

	run_stage hw-basic tapetest "$ROOT/tapetest.sh" "${target[@]}" -s basic \
		-o "$OUT/hw-basic"
	run_stage hw-reset tapetest "$ROOT/tapetest.sh" "${target[@]}" -s reset,boundary \
		"${excl[@]}" "${long[@]}" "${HWOPTS[@]}" -o "$OUT/hw-reset"
	if [[ $STRESS -gt 0 ]]; then
		run_stage hw-stress tapetest "$ROOT/tapetest.sh" "${target[@]}" -s stress \
			--iterations "$STRESS" "${HWOPTS[@]}" -o "$OUT/hw-stress"
	fi
fi

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
declare -a cmp=()
[[ -n $COMPARE ]] && cmp=(--compare "$COMPARE")
python3 "$ROOT/lib/release_report.py" --out "$OUT" \
	--expected "$ROOT/expected-warnings.txt" "${cmp[@]}"
rc=$?
echo
cat "$OUT/VERDICT"
echo "report: $OUT/REPORT.md"
exit $rc

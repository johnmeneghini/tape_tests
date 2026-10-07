#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# selftest.sh - prove the harness detects driver regressions.
#
# Runs the harness against the mock st emulation, first clean (everything must
# pass), then with emulated driver bugs injected one at a time; each bug must be
# caught by the tests listed for it.  No hardware or root needed.

cd "$(dirname "$(readlink -f "$0")")" || exit 2
out=${1:-/tmp/tapetest-selftest}
rm -rf "$out"; mkdir -p "$out"
rc=0

run() {	# name bugs tests expect(pass|fail)
	local name=$1 bugs=$2 tests=$3 want=$4 got
	TT_MOCK_BUGS=$bugs ./tapetest.sh --mock -t "$tests" -o "$out/$name" > "$out/$name.log" 2>&1
	case $? in 0) got=pass ;; 1) got=fail ;; *) got=error ;; esac
	if [[ $got == "$want" ]]; then
		printf '  ok    %-14s %-34s -> %s\n' "$name" "${bugs:-<none>}" "$got"
	else
		printf '  BAD   %-14s %-34s -> %s (expected %s), see %s\n' \
			"$name" "${bugs:-<none>}" "$got" "$want" "$out/$name.log"
		rc=1
	fi
	[[ $want == fail ]] && grep -h '^\s*\[' "$out/$name/summary.txt" | grep -v '\] kernel message' |
		sed -n '/failures:/,$p;' | head -0
	[[ $want == fail ]] && sed -n '/^failures:/,/^$/p' "$out/$name/summary.txt" | sed -n '2,3p' | cut -c1-150
}

echo "tapetest self-test (mock st emulation)"
run clean        ""             "*"                                  pass
run nodetect     nodetect       "R01,R05.lu"                         fail
run noblock      noblock        "R02,R10.bot"                        fail
run norestore    norestore      "R04.rewind,R04.eod,R04.seek"        fail
run silentloss   silentloss     "R07.nst"                            fail
run fmafterreset fmafterreset   "R05.lu"                             fail
run corrupt      corrupt        "B02"                                fail
exit $rc

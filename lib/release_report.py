#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# release_report.py - turn a release-check directory into REPORT.md + VERDICT.
# Python 3.6 compatible.

import argparse
import fnmatch
import os
import re
import sys

VERDICT_EXIT = {"PASS": 0, "FAIL": 1, "INCOMPLETE": 2, "REVIEW": 3}


def read_lines(path):
    try:
        with open(path) as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except (IOError, OSError):
        return []


def load_expected(path):
    exp = []
    for line in read_lines(path):
        if line.lstrip().startswith("#"):
            continue
        glob, _, rx = line.partition("\t")
        if rx:
            exp.append((glob.strip(), re.compile(rx.strip()), "%s: %s" % (glob.strip(), rx.strip())))
    return exp


def load_stages(out):
    stages = []
    for line in read_lines(os.path.join(out, "stages.txt")):
        name, rc, secs, kind = line.split()
        stages.append(dict(name=name, rc=rc, secs=int(secs), kind=kind))
    return stages


def load_results(stagedir):
    """results.txt: id|res|dt|np|nf|desc"""
    res = {}
    for line in read_lines(os.path.join(stagedir, "results.txt")):
        f = line.split("|", 5)
        if len(f) == 6:
            res[f[0]] = dict(res=f[1], secs=f[2], desc=f[5])
    return res


def test_lines(stagedir, tid, kind):
    return read_lines(os.path.join(stagedir, "tests", tid, kind))


def fmt_secs(s):
    return "%dm%02ds" % (s // 60, s % 60)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--expected", required=True)
    ap.add_argument("--compare")
    a = ap.parse_args()

    out = a.out
    expected = load_expected(a.expected)
    stages = load_stages(out)
    used_expect = set()

    rows, failures, new_warn, exp_warn, unverified, notes = [], [], [], [], [], []
    incomplete = []
    totals = dict(PASS=0, FAIL=0, SKIP=0)

    for st in stages:
        name, rc = st["name"], st["rc"]
        sd = os.path.join(out, name)
        if rc == "skipped":
            rows.append((name, "skipped", "", fmt_secs(0)))
            continue
        if st["kind"] == "selftest":
            ok = rc == "0"
            rows.append((name, "PASS" if ok else "FAIL", "harness detects all emulated regressions" if ok
                         else "see %s.log" % name, fmt_secs(st["secs"])))
            if not ok:
                failures.append((name, "-", "harness self-test failed: the harness itself is not trustworthy"))
            continue
        res = load_results(sd)
        if not res:
            incomplete.append("%s: no results (exit %s), see %s.log" % (name, rc, name))
            rows.append((name, "INCOMPLETE", "exit %s" % rc, fmt_secs(st["secs"])))
            continue
        if rc == "2" or os.path.exists(os.path.join(sd, "abort")):
            incomplete.append("%s: run aborted (exit %s), see %s/summary.txt" % (name, rc, name))
        c = dict(PASS=0, FAIL=0, SKIP=0)
        for tid, r in res.items():
            c[r["res"]] = c.get(r["res"], 0) + 1
            for msg in test_lines(sd, tid, "fail"):
                failures.append((name, tid, msg))
            for msg in test_lines(sd, tid, "warn"):
                hit = None
                for glob, rx, raw in expected:
                    if fnmatch.fnmatchcase(tid, glob) and rx.search(msg):
                        hit = raw
                        break
                if hit:
                    used_expect.add(hit)
                    exp_warn.append((name, tid, msg))
                else:
                    new_warn.append((name, tid, msg))
            for msg in test_lines(sd, tid, "unverified"):
                unverified.append((name, tid, msg))
            for msg in test_lines(sd, tid, "note"):
                notes.append((name, tid, msg))
        for k in totals:
            totals[k] += c.get(k, 0)
        verdict = "FAIL" if c["FAIL"] else "PASS"
        rows.append((name, verdict, "%d passed, %d failed, %d skipped" % (c["PASS"], c["FAIL"], c["SKIP"]),
                     fmt_secs(st["secs"])))

    if incomplete or not stages:
        verdict = "INCOMPLETE"
    elif failures:
        verdict = "FAIL"
    elif new_warn:
        verdict = "REVIEW"
    else:
        verdict = "PASS"
    if verdict == "INCOMPLETE" and failures:
        verdict = "FAIL"      # a real failure outranks an incomplete stage

    # expected warnings that no longer occur (only meaningful where the test ran)
    ran = set()
    for st in stages:
        for tid, r in load_results(os.path.join(out, st["name"])).items():
            if r["res"] != "SKIP":
                ran.add(tid)
    vanished = [raw for glob, rx, raw in expected
                if raw not in used_expect and any(fnmatch.fnmatchcase(t, glob) for t in ran)]

    # comparison with a previous release-check
    changes = []
    if a.compare:
        for st in stages:
            old = load_results(os.path.join(a.compare, st["name"]))
            new = load_results(os.path.join(out, st["name"]))
            for tid in sorted(set(old) | set(new)):
                o = old.get(tid, {}).get("res", "-")
                n = new.get(tid, {}).get("res", "-")
                if o != n:
                    changes.append((st["name"], tid, o, n))

    env = read_lines(os.path.join(out, "environment.txt"))
    L = []
    L.append("# st release check: %s" % verdict)
    L.append("")
    L.append("```")
    L.extend(env)
    L.append("```")
    L.append("")
    L.append("| Stage | Result | Tests | Duration |")
    L.append("|---|---|---|---|")
    for r in rows:
        L.append("| %s | %s | %s | %s |" % r)
    L.append("")
    L.append("Totals: %d passed, %d failed, %d skipped." % (totals["PASS"], totals["FAIL"], totals["SKIP"]))
    L.append("")

    def section(title, items, fmt, empty=None):
        L.append("## %s" % title)
        L.append("")
        if not items:
            L.append(empty or "None.")
        for it in items:
            L.append(fmt(it))
        L.append("")

    if incomplete:
        section("Incomplete stages", incomplete, lambda s: "* %s" % s)
    section("Failures", failures, lambda f: "* **%s / %s**: %s" % f)
    section("New warnings (not in expected-warnings.txt)", new_warn,
            lambda w: "* **%s / %s**: %s" % w)
    section("Expected warnings (known st behaviour)", exp_warn, lambda w: "* %s / %s: %s" % w)
    if vanished:
        section("Expected warnings that no longer occur", vanished,
                lambda v: "* `%s` - st behaviour may have changed; review and update expected-warnings.txt" % v)
    if a.compare:
        section("Changes since %s" % a.compare, changes,
                lambda c: "* %s / %s: %s -> %s" % c, "No verdict changes.")
    section("Checks that could not be verified", unverified, lambda u: "* %s / %s: %s" % u)
    section("Observations", notes, lambda n: "* %s / %s: %s" % n)
    L.append("Per-stage details: `<stage>/summary.txt`, `<stage>/tests/<id>/log`, `<stage>/tests/<id>/kmsg.log`.")

    with open(os.path.join(out, "REPORT.md"), "w") as f:
        f.write("\n".join(L) + "\n")
    with open(os.path.join(out, "VERDICT"), "w") as f:
        f.write("release check %s: %d failures, %d new warnings, %d expected warnings%s\n" % (
            verdict, len(failures), len(new_warn), len(exp_warn),
            (", %d incomplete stage(s)" % len(incomplete)) if incomplete else ""))
    return VERDICT_EXIT[verdict]


if __name__ == "__main__":
    sys.exit(main())

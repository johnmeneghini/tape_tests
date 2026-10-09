# Changes

## 2.23

* Resets are issued with sg_reset --no-esc.  Without it the kernel
  escalates a refused device or target reset to a bus and then a host
  reset, hitting every device on the HBA without --allow-bus-reset /
  --allow-host-reset.  Seen on smartpqi (HPE E208e-p), which refuses a
  target reset: each attempt took minutes, stalled the tape's IO (hung
  task warnings in st_write) and R05.target retried three times.
* A reset the HBA refuses makes the test SKIP with the driver's name
  instead of FAIL, and later tests using that method skip at once.  A
  refusal during background IO reaps the IO first and marks the layout
  for a rebuild.
* Preflight requires an sg_reset that supports --no-esc.
* New summary section "HBA / low-level driver findings": a refused
  reset is reported there (HBA line in the log) with the driver's name,
  separate from st failures, warnings and observations.

## 2.22

* Hardware runs with can-partitions=0 that select a partition test
  (X03-X05) stop with a warning naming the tests and how to enable
  partitions.  On a terminal, type 'skip' to continue without them (Ctrl-C
  stops); otherwise --skip-partitions is required.  The skip is recorded in
  the run header.  A silent skip hid a real st bug: X03 had only ever
  passed on scsi_debug.
* With can-partitions=1 and non-partition tests selected, a note warns
  that some results differ with partitions on (e.g. R10.bot reports 0:0).
* release-check passes --skip-partitions to its hardware stages.

## 2.21

* X05: switch partitions with a read().  Every MTIOCTOP except a few
  setting operations resets the current partition's rw state before a
  partition switch, so neither MTREW (2.19) nor MTEOM (2.20) could leave a
  stale ST_WRITING state; read() and write() switch in rw_checks() and do.

## 2.20

* X05: switch partitions with MTEOM instead of MTREW.  st terminates a
  pending write (filemark, state reset) before MTREW, so the previous
  sequence could not leave a stale ST_WRITING state and passed on v3.

## 2.19

* X05: write in partition 0, switch to partition 1 and MTLOAD on one open
  file; partition 0 must be intact afterwards (a stale ST_WRITING state
  made close write a filemark at BOT - Sashiko on the v3 st patch 2).
  tapectl session gains a write:COUNT step.

## 2.18

* R15: the skip message lost the value it reports (R[] was overwritten when
  the original mode was restored).  scsi_debug accepts MTSETDRVBUFFER but
  does not implement buffered mode (always reports 0), so R15 skips there
  with that reason; it runs on real drives.

## 2.17

* tapectl modesense retries on a unit attention: scsi_debug reports "mode
  parameters changed" after MTSETDRVBUFFER, which made R15 skip there.
  R15 now reports the errno and sense data when MODE SENSE fails.

## 2.16

* R15.{rewind,load,retension}: the drive buffering mode set with
  MTSETDRVBUFFER must be restored after a reset.  The drive's own value is
  read with MODE SENSE through the sg node (new tapectl `modesense`).
* R16: with auto-lock, st must lock the door again after a reset on the same
  open file (new tapectl `session`: several steps on one fd).  Needs
  debug_flag=1.
* Both are known st behaviour on unpatched kernels (review comments by Kai
  Makisara): listed in expected-warnings.txt.

## 2.15

* X04: MTLOAD while in partition 1 must leave st in partition 0, so that a
  later MTSETPART 1 really switches (review comment by Kai Makisara on the
  st patch series).  Needs partition support (scsi_debug, or can-partitions).

## 2.14

* B09: the EIO after MTLOAD at EOD is a known st behaviour on drives that
  report no new medium (fix posted upstream).  It is now a warning listed in
  expected-warnings.txt, so release-check on unpatched kernels still gives
  PASS and a fixed kernel shows it as "no longer occurs".
* docs: finding 3 (EOF state after MTLOAD), status of the posted patches,
  B09 in the manual.

## 2.13

* B09, R03.load: a failed read after the load no longer passes the "file 0
  block 0" check (zero bytes was accepted as a prefix).

## 2.12

* B09: MTLOAD of an already loaded tape at EOD must reset the position and
  the EOF state (reads after the load must work).  Fails on unpatched st with
  drives that report no new medium for a loaded cartridge.

## 2.11

* Refuse to run into a non-empty results directory: result files are
  appended, so reusing `-o DIR` mixed two runs in the summary.
* patches/: v2 of 0001 (check_tape() before the restore after MTRETEN).

## 2.10

* R03.load proves the tape position after reset + MTLOAD (MTIOCPOS is 0 and
  the first block read is file 0 block 0) instead of relying on MTIOCGET.
* docs/st-reset-findings.md: analysis of the known st warnings.
* patches/: prototype st fixes for the MTLOAD/MTRETEN findings (not upstream).

## 2.9

* `--no-st-debug` (tapetest and release-check): st is still reloaded,
  configured by stinit and checked for scsi2logical, but with `debug_flag=0`.

## 2.8

* `release-check`: runs every stage for a kernel release (self-test,
  scsi_debug, hardware basic, reset + boundary, optional stress/long) into one
  directory and writes `REPORT.md` with a single verdict: PASS, FAIL,
  INCOMPLETE or REVIEW.
* `expected-warnings.txt`: known st behaviour is reported as expected; any
  other warning needs review; expected warnings that stop occurring are
  reported too.
* `--compare DIR` lists per-test verdict changes against a previous release.

## 2.7

* Every hardware and scsi_debug run reloads st with `debug_flag=1` (restored
  to 0 at exit), applies `stinit.conf` and enforces `scsi2logical`; the drive
  is re-found by H:C:T:L after the reload.  `--no-reload-st`, `--no-stinit`.
* B01 fails if `scsi2logical` is missing; `environment.txt` records the st
  setup.

## 2.6

* `stinit.conf`: IBM ULTRIUM-TD5 entry.
* B01/B03 diagnose MTIOCPOS failures caused by a missing `scsi2logical`.

## 2.5

* Layout verification: an empty file terminated by a filemark (abort-only
  recovery) is recognized as end of data.

## 2.4

* Blank-check semantics of `read_tape()`: 0 then EIO distinguishes "no
  filemark" from "stray filemark" (0 then 0) for zero-length interrupted
  files.
* X01 samples MTIOCGET in the writing file descriptor (EOT is per-open
  state).  X02 asserts the exact end-of-data sequence.
* scsi_debug: 10 s not-ready poll.

## 2.3

* An interrupted file ends in EIO (blank check not after a filemark); this
  is now the proof that no filemark was written.
* R06 issues a command before checking `position_lost_in_reset` (st updates
  it on command completion).

## 2.2

* scsi_debug: in-flight tests shorten the command timeout so commands
  orphaned by a non-EH reset are reaped by EH abort.
* A blank tape at BOT may read as EIO.
* R04 asserts block-size restore only for REW/SEEK/EOM and reports the
  behaviour of the other recovery operations.

## 2.1

* ioctl paths open with O_NONBLOCK: a blocking open of a drive without a
  ready tape sleeps 120 s in `test_ready()` and then fails, which also made
  MTLOAD after MTOFFL impossible.

## 2.0

* Rewrite of the previous `tape_reset_*.sh` scripts: Python ioctl helper
  with exact errno reporting, layout model with full readback, in-flight
  reset synchronization, scsi_debug error injection, kernel log scanning,
  hang forensics, TAP/JUnit output, mock st and mutation self-test.

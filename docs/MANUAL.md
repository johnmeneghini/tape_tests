# tapetest user manual

tapetest validates the Linux SCSI tape driver (`st`): normal I/O and
positioning, and above all how st behaves when the device is reset or SCSI
error handling intervenes.  Every test that touches the tape ends by reading
the whole tape back and comparing it byte for byte with what should be there.

This manual covers version 2.14.

1. [Requirements](#1-requirements)
2. [Quick start](#2-quick-start)
3. [Modes](#3-modes)
4. [st driver setup](#4-st-driver-setup)
5. [Safety](#5-safety)
6. [Running tests](#6-running-tests)
7. [Reading the results](#7-reading-the-results)
8. [Test catalogue](#8-test-catalogue)
9. [Known st behaviours](#9-known-st-behaviours)
10. [Troubleshooting](#10-troubleshooting)
11. [How it works](#11-how-it-works)
12. [Extending the suite](#12-extending-the-suite)
13. [Self-test](#13-self-test)
14. [Kernel release validation](#14-kernel-release-validation)

---

## 1. Requirements

| | |
|---|---|
| Privileges | root (not needed for `--mock`) |
| Shell | bash 4.2 or later |
| Python | python3 3.6 or later; RHEL 8 platform-python is sufficient (code is 3.2-compatible) |
| Packages | `sg3_utils` (sg_reset).  Optional: `mt-st` (stinit), `lsscsi`, `psmisc` (fuser, for diagnostics) |
| scsi_debug mode | the `scsi_debug` module; debugfs (mounted automatically) for the error-injection tests |

`mt` is **not** used.  All tape operations go through `lib/tapectl.py`, which
issues `MTIOCTOP`, `MTIOCGET` and `MTIOCPOS` directly and reports the exact
errno of every step.  Nothing is installed automatically.

---

## 2. Quick start

```bash
# 1. Emulated tape: proves the harness and the kernel paths, no hardware
./tapetest.sh --scsi-debug=2

# 2. Real drive, basic suite first (DESTROYS the data on the tape)
./tapetest.sh -d /dev/nst0 --yes -s basic

# 3. Real drive, reset and boundary suites
./tapetest.sh -d /dev/nst0 --yes -s reset,boundary
```

Each run writes a results directory (default `./results/<timestamp>`) and
exits 0 if every selected test passed or was skipped, 1 on failures, 2 on a
harness error or aborted run.

---

## 3. Modes

Exactly one mode is required.

### `-d DEV` - real drive

`DEV` is `/dev/nstN` or `/dev/stN` (either works; both nodes are used).  The
matching sg node and H:C:T:L are found through sysfs.  `--yes` is required
because the tape is overwritten.  Other tape LUNs on the same H:C:T are
detected as *peers* and used by the scope tests.

Profile: 256 MiB data files, 256 KiB variable blocks, 8 GiB in-flight
transfers, 64 KiB fixed-block tests, full byte-for-byte verification.

### `--scsi-debug[=N]` - emulated tape

Loads `scsi_debug ptype=1 max_luns=N` (default 2), runs against the emulated
tape and unloads the module at the end.  Refuses to run if scsi_debug is
already loaded unless `--reuse-scsi-debug`.

The real st driver runs; only the device is emulated.  This mode also runs
the tests that need deterministic fault injection (E01-E04, R11) and a
second LUN (R12, E03).

Limits of the emulation:

* only the first 4 bytes of each block are stored, so verification compares
  those 4 bytes of every block (`verify=first4`);
* the tape holds 10 000 blocks, so data files are 1 MiB;
* a reset stops in-flight commands **without completing them** (scsi_debug
  expects SCSI EH to own them).  The harness shortens the command timeout to
  15 s during in-flight tests so the orphan is reaped by EH abort;
* after UNLOAD it reports NOT READY without "medium not present", so
  no-tape checks poll for up to `TT_READY_WAIT` (10 s in this mode).

### `--mock[=N]` - harness self-test

No kernel involvement: a Python model of st's reset state machine.  Used by
`selftest.sh` to prove the harness detects regressions.  It proves nothing
about the kernel.

---

## 4. st driver setup

In hardware and scsi_debug modes every run begins by preparing the driver:

1. **Reload st with debugging**: `modprobe -r st; modprobe st debug_flag=1`.
   This gives a clean driver state and full st debug output in the kernel
   log.  The drive is found again by H:C:T:L afterwards, since node names can
   change.  `debug_flag` is set back to 0 when the run ends (the module
   stays loaded).
2. **Apply `stinit.conf`** with `stinit -f stinit.conf -v <dev>`, if stinit
   is installed.
3. **Enforce `scsi2logical`** (st option 0x800).  If stinit did not set it,
   the harness sets it directly; if it cannot be set, the run stops.  B01
   fails if it is missing.

Why `scsi2logical` matters: without it st sends READ POSITION and LOCATE
with the *device-specific* address form (BT=1).  LTO drives need logical
block addresses and fail these commands, so `MTIOCPOS` and `MTSEEK` return
EIO.  A drive with no matching `stinit.conf` entry is unusable for
positioning until the option is set.

The result is recorded in `environment.txt`, for example:

```
st:       reloaded=1 debug_flag=1 options=0x0000090f stinit=applied
```

`0x90f` = buffer-writes, async-writes, read-ahead, debugging, can-bsr,
scsi2logical.

Options:

| Option | Effect |
|---|---|
| `--no-reload-st` | keep the loaded st module and its settings |
| `--no-st-debug` | reload st with `debug_flag=0`: clean state and stinit, but a quiet kernel log |
| `--no-stinit` | skip stinit; `scsi2logical` is still enforced |
| `--st-debug` | with `--no-reload-st`: set `debug_flag` at runtime |

**The reload fails if any process holds a tape node open**, including a
second path to the same drive.  The error names the holding PIDs.

**Kernel log volume**: with debugging on, large hardware transfers log a lot.
If the ring buffer wraps, a message could fall out before the per-test scan
reads it.  Consider `log_buf_len=16M` on the kernel command line; journald
keeps the complete log regardless.

### stinit.conf

Shipped entries: IBM ULTRIUM-TD4, IBM ULTRIUM-TD5, IBM ULTRIUM-HH9,
QUANTUM ULTRIUM 4, and scsi_debug.  All set `can-bsr scsi2logical
drive-buffering`, `async-writes=1`, `timeout=3600`, `long-timeout=14400` and
a mode 1 with drive-default block size and density.  Add an entry for any new
drive model; the vendor and model strings must match the INQUIRY data
(`cat /sys/class/scsi_tape/nst0/device/{vendor,model}`).

Note that `timeout=3600` sets the request timeout for READ/WRITE to one hour.
If a transport ever leaves a command orphaned after a reset, st waits that
long before EH reaps it; the harness allows up to 3 hours per I/O on
hardware.

---

## 5. Safety

* **All data on the tape is destroyed.**  Hardware runs require `--yes`.
  The run prints the drive identity before starting.
* **Bus and host resets** (`--allow-bus-reset`, `--allow-host-reset`) affect
  every device on that bus or HBA, possibly the boot disk.  Only enable them
  when the HBA serves nothing but the tape (check with `lsscsi -g`).
* **Link resets** (`--allow-link-reset`) currently support SAS phys only; the
  test skips on FC.
* **Tape libraries**: `MTOFFL` may eject the cartridge to the library, after
  which `MTLOAD` cannot bring it back.  Exclude the tests that unload:

  ```
  -x 'R03.offline,R04.offline,R09'
  ```

  If a cartridge is ejected anyway, reload it with the changer, e.g.
  `mtx -f /dev/sgN load <slot> <drive>`.  The run stops cleanly if the drive
  cannot be returned to a known state.
* **Changer on the same target**: many libraries present the changer as
  another LUN of the drive's target.  Target resets (R05.target,
  R13.target) also reset the changer; harmless, but the library may log it.
* **Dual paths**: if the drive is visible through two HBA ports (two st and
  sg nodes with the same serial number - compare `sg_inq` output), nothing
  may use the second path during a run.  I/O or resets through it hit the
  drive under test as another initiator.
* The harness never runs `dmesg -C` and never kills other users' processes.

---

## 6. Running tests

### Selection

| Option | |
|---|---|
| `-s, --suite LIST` | `basic,reset,eh,boundary,stress` (default: all but `stress`) |
| `-t, --test LIST` | test ids or globs, e.g. `-t 'R03.*,R05.lu'` |
| `-x, --exclude LIST` | ids or globs to skip |
| `-l, --list` | show every test and whether/why it would be skipped, then exit |
| `--long` | allow hours-long tests on hardware (R03.erase, X01) |

Always check `--list` on a new system: it shows exactly which tests will be
skipped and why.

### Tuning

| Option | Default (hw / sdebug) | |
|---|---|---|
| `--bs BYTES` | 262144 / 32768 | write size = variable block size |
| `--file-mb N` | 256 / 1 | size of each baseline file |
| `--inflight-mb N` | 8192 / 12 | size of transfers interrupted by resets |
| `--iterations N` | 5 / 10 | stress iterations (R14) |

Environment overrides: `TT_READY_WAIT` (not-ready poll, seconds),
`TT_SDEBUG_INFLIGHT_CMD_TMO` (scsi_debug in-flight command timeout),
`TT_EH_CMD_TIMEOUT` (EH tests), `TT_SYSRQ_ON_HANG=1` (dump blocked tasks
with sysrq-w when a command hangs).

### Output

| Option | |
|---|---|
| `-o, --out DIR` | results directory |
| `--stop-on-fail` | stop after the first failing test |
| `-v, --verbose` | log every tapectl call |

### Recommended sequence for a new drive or kernel

1. `./tapetest.sh --scsi-debug=2` - must be clean except the known warnings.
2. `./tapetest.sh -d DEV --list` - review the skips.
3. `./tapetest.sh -d DEV --yes -s basic`
4. `./tapetest.sh -d DEV --yes -s reset,boundary` (plus library exclusions)
5. Optionally `--long`, `--allow-*-reset`, and `-s stress`.

### Run time

On an LTO-5 (about 140 MB/s): basic suite about 8 minutes, reset and boundary
suites about 30 minutes.  The scsi_debug run takes about 5 minutes.

---

## 7. Reading the results

```
results/<ts>/environment.txt        kernel, device, st setup, features, profile
results/<ts>/summary.txt            verdicts, then failures, warnings,
                                    unverified checks and observations
results/<ts>/results.tap            TAP
results/<ts>/junit.xml              JUnit, for CI
results/<ts>/setup/                 stinit output, reload errors
results/<ts>/tests/<id>/log         full test log
results/<ts>/tests/<id>/kmsg.log    kernel messages logged during the test
results/<ts>/tests/<id>/hang.<pid>  state, wchan and kernel stack of a hung command
results/<ts>/tests/<id>/sanitize.log  cleanup after the test
```

### Verdicts

| Verdict | Meaning |
|---|---|
| **PASS** | every check in the test passed |
| **FAIL** | a contract was violated, the test hung, or the kernel logged a warning/BUG/Oops/lockup/hung task during it |
| **SKIP** | requirements not met on this system (the reason is printed) |

Within a test:

| Line | Meaning |
|---|---|
| `ok` | a check passed |
| `FAIL` | a check failed |
| `WARN` | behaviour worth a look that is not a defined contract (section 9) |
| `UNVERIFIED` | a check could not be made here, e.g. a sysfs attribute is missing. Never silently skipped |
| `NOTE` | observed behaviour recorded for the report |

### Hangs

Every tape command runs under a deadline.  On expiry the harness records the
process state, wchan and `/proc/<pid>/stack`, then kills it.  If the process
is stuck in D state the run aborts, since the drive is unusable.  The stack
usually identifies the cause directly (see section 10 for examples).

### Kernel log

Messages are read from `/dev/kmsg` by sequence number, so only messages
logged during the test are considered and nothing is cleared.  Any match of
WARNING, BUG, Oops, KASAN, UBSAN, hung task, soft/hard lockup, RCU stall,
list corruption or refcount errors fails the test.

---

## 8. Test catalogue

Requirements: `any` runs everywhere; `long` needs `--long` on hardware;
`inject` needs scsi_debug; `multilun` needs a second tape LUN on the same
target; `partitions` needs scsi_debug or a drive with can-partitions;
`bus`/`host`/`link` need the corresponding `--allow-*` option.

Resets are sent with `sg_reset --no-esc`, so a device or target reset the
HBA refuses is not escalated by the kernel to a bus or host reset.  A
refused method makes its test SKIP, naming the driver (e.g. smartpqi does
not do target resets), and later tests using it skip at once.

Partition tests on hardware: can-partitions is normally 0 in stinit.conf,
so X03-X05 would skip.  A hardware run that selects them with
can-partitions=0 stops with a warning; type `skip` to go on without them
(Ctrl-C stops), or pass `--skip-partitions` when not on a terminal.  To run
them, set can-partitions=1 in the drive's stinit.conf stanza, run
`-t 'X03,X04,X05'` on their own, then restore stinit.conf.  Run everything
else with can-partitions=0: with partitions on, st reports some positions
differently (R10.bot sees 0:0 after a reset at BOT), and tapetest notes it.

### basic

| ID | Proves |
|---|---|
| B01 | drive online and writable; sysfs attributes (options, defaults, `position_lost_in_reset`, stats) present; `scsi2logical` set |
| B02 | baseline files written and read back exactly; filemarks and file numbers |
| B03 | fsf/bsf/fsr/bsr/fsfm/bsfm/eod/tell/seek, including EIO for fsf past EOD, bsf at BOT and fsr across a filemark |
| B04 | fixed-block mode: write, read back in fixed and variable mode; every block on tape has the fixed size |
| B05 | the rewind node writes a filemark on close and rewinds |
| B06 | a second open returns EBUSY (both nodes) |
| B07 | sysfs I/O statistics account for the traffic |
| B08 | consecutive filemarks produce empty files and keep file numbering |
| B09 | MTLOAD of an already loaded tape at EOD resets the position and the EOF state: reading works afterwards (warning on unpatched st, finding 3) |

### reset

| ID | Proves |
|---|---|
| R01 | LU reset at mid-tape: MTIOCGET reports -1/-1, `position_lost_in_reset=1`, st logs "Power on/reset recognized"; rewind recovers |
| R02 | after a reset, read, write, MTIOCPOS and every MTIOCTOP except the recovery set fail with EIO, leave the condition set and do not touch the tape |
| R03.* | each allowed recovery op (rewind, eod, seek, retension, offline+load, load, erase) clears the condition; position and data correct |
| R04.* | block size after reset: REW/SEEK/EOM must re-apply it; for the others the actual behaviour is reported |
| R05.lu/target | reset during an 8 GiB write: EIO, the accepted data is a clean prefix, no filemark, earlier files intact |
| R06 | reset during a read: EIO, data delivered before the reset correct, tape unharmed |
| R07.nst/st | reset between the last `write()` and `close()`: acknowledged data is on tape or `close()` fails ("SILENT DATA LOSS" otherwise) |
| R08 | reset during a long locate to EOD |
| R09 | reset with no tape loaded, then load |
| R10.bot/eod | reset at BOT and at EOD; a write before repositioning is refused |
| R11 | injected UA 29/00 (reset by another initiator) is treated as a reset; UA 2A/01 is not |
| R12 | LU reset flags only that LUN; target reset flags all LUNs |
| R13.* | detection and recovery for each reset method (lu, target, bus, host, link) |
| R15.* | the drive buffering mode set with MTSETDRVBUFFER is restored after reset + rewind/load/retension (drive value read with MODE SENSE via sg) |
| R16 | with auto-lock, st locks the door again after a reset on the same open file (st debug log; needs debug_flag=1) |

### eh (scsi_debug error injection)

| ID | Proves |
|---|---|
| E01 | WRITE times out and the abort succeeds: write fails, device recovers, no reset condition |
| E02 | the abort fails, EH escalates to LU reset: st recognizes it (`position_lost_in_reset=1`) and blocks I/O |
| E03 | the LU reset fails too, EH escalates to target reset: every LUN on the target is flagged |
| E04 | UA 29/00 returned on a WRITE is treated as a reset |

### boundary

| ID | Proves |
|---|---|
| X01 | writing to end of medium fails with ENOSPC (not EIO), EOT is reported, a filemark can still be written |
| X02 | end-of-data read semantics: EIO directly after MTEOM; 0 then EIO after reading across the last filemark |
| X03 | reset while in partition 1: rewind returns to partition 1 and its data is intact |
| X05 | write in partition 0, switch to 1, MTLOAD on the same file: no filemark written at the beginning of partition 0 |
| X04 | MTLOAD while in partition 1: st records partition 0, and a later MTSETPART 1 really switches back |

### stress

| ID | Proves |
|---|---|
| R14 | repeated resets at random points (idle, during a write, during a read), full verification after each |

Full list with requirements for the current system: `./tapetest.sh <mode> --list`.

---

## 9. Known st behaviours

Behaviour observed on RHEL 9.8 kernels with scsi_debug, an IBM ULTRIUM-TD5
and an IBM ULT3580-TDA over FC.  These appear as WARN or NOTE, not FAIL.
The code-level analysis, upstream history and possible fixes are in
[st-reset-findings.md](st-reset-findings.md).

**MTSETBLK is discarded after reset + RETEN/OFFL/LOAD (R04, WARN).**
After a reset, st re-applies a changed block size only on REW, SEEK and EOM.
After LOAD, `check_tape()` starts a new session (new-media unit attention):
`blksize_changed` is cleared and the mode defaults are applied.  RETEN and
OFFL+LOAD end up in the same state.  An application that had set fixed-block mode silently continues
in variable mode.  Seen on scsi_debug and on real hardware.

**read() fails with EIO after MTLOAD of a loaded tape at EOD (B09, WARN, hardware).**
`do_load_unload()` does not reset the EOF state that MTREW resets, so after
reading to EOD and reloading the cartridge st still believes it is at EOD.
Drives that report a new medium on LOAD (scsi_debug) are not affected.

**Position reported as -1/-1 at BOT after reset + LOAD (R03.load, WARN, hardware).**
LOAD of an already loaded cartridge raises no new-media unit attention, so st
does not start a new session and keeps the -1/-1 set when the reset was
recognized, although the tape is at BOT.  The position is not blocked, only
unknown until the next rewind.  scsi_debug does start a new session and
reports 0/0.

**`position_lost_in_reset` is updated on the next command completion (R06).**
st compares the SCSI core's power-on/reset counter in `st_chk_result()`.  If
an in-flight command is reaped by an abort (no TUR), the unit attention is
still pending when it completes, so the attribute reads 0 until the next
command receives the UA.  Nothing is exposed: that next command, even a WRITE,
fails with the UA.

**Interrupted write: data is safe but the file is unterminated (R07, NOTE).**
With a reset between the last `write()` and `close()`, all data reached the
tape, `close()` returned EIO and no filemark was written.  The application is
told something went wrong; the file needs a filemark before further files
are appended.

**Abort-only recovery leaves an empty file (E01, NOTE).**
A timed-out WRITE whose abort succeeds involves no reset, so st writes the
filemark at close: an empty file appears on tape.

**MTIOCPOS/MTSEEK need `scsi2logical` (section 4).**
Without it st uses the device-specific address form, which LTO drives do not
accept.

**Reset timing on FC (R05, R06).**
With qla2xxx, the in-flight command completed with EIO within seconds of the
LUN reset.  With scsi_debug it is only reaped by the command timeout.

**LTO-5 keeps its physical position across a LUN reset.**
Inferred from timing (rewind after reset takes several seconds, a seek back
to the prior block is immediate).  st still, correctly, treats the position
as unknown.

---

## 10. Troubleshooting

**"no tape loaded in /dev/nstN"** - the drive is empty.  In a library, load a
cartridge with the changer.  A cartridge sitting unloaded in the drive is
loaded by the harness automatically.

**"cannot unload st: ... held by pid(s)"** - something has a tape node open
(a backup agent, a shell, the second path).  Close it, or use
`--no-reload-st`.

**"scsi_debug is already loaded"** - `modprobe -r scsi_debug`, or
`--reuse-scsi-debug`.  If unloading fails, a process still holds one of its
devices (see next item).

**A test hangs in `st_do_scsi` / hung-task messages on scsi_debug** - an
in-flight command orphaned by a reset, waiting for its timeout.  The harness
shortens the timeout in scsi_debug mode; if you see this, check that
`TT_SDEBUG_INFLIGHT_CMD_TMO` was not raised.  The process unblocks when the
timeout expires.

**A command hangs in `test_ready` / `msleep_interruptible` via `st_open`** -
a blocking open of a drive that is not ready.  st sleeps up to 120 s
(`ST_BLOCK_SECONDS`) and then fails.  tapectl opens ioctl paths with
O_NONBLOCK to avoid this; seeing it means something opened the device in
blocking mode with no ready tape.

**MTIOCPOS or MTSEEK fail with EIO on a real drive** - `scsi2logical` is not
set; check `options` in `environment.txt` (bit 0x800).  Since v2.7 the
harness enforces it and stops if it cannot be set, so this points to an
older harness version or to the drive rejecting READ POSITION itself (run
with debugging and check the sense data in `kmsg.log`).

**"reading file N failed with EIO" on an interrupted file** - expected and
handled: st returns EIO for a blank check that does not directly follow a
filemark.  If this appears as a failure, the layout model and the tape
disagree; check the test log.

**R08 notes "eod completed before the reset landed"** - locate to EOD was
faster than the reset.  Normal on scsi_debug; on hardware increase the data
on tape (`--file-mb`).

**Run aborted: "device could not be returned to a known state"** - after a
test the drive could not be loaded, rewound or set to variable mode.  Check
`tests/<id>/sanitize.log`, fix the drive state manually and re-run from that
test with `-t`.

---

## 11. How it works

### Components

```
tapetest.sh         runner: options, registry, requirement gating, per-test
                    isolation, kernel log scan, sanitize, TAP/JUnit/summary
lib/tapectl.py      ioctls, verified read/write, kmsg access, data generator,
                    mock st
lib/common.sh       logging, result recording, deadline execution, assertions
lib/device.sh       device discovery, profiles, st reload/stinit, scsi_debug
                    and mock setup, state restore
lib/layout.sh       model of the tape contents and full readback
lib/reset.sh        reset methods, reset confirmation, in-flight reset
tests/*.sh          the tests
selftest.sh         mutation self-test
```

### tapectl.py

Each invocation opens the device once, performs one operation (optionally
after `--pre` positioning ops on the same file descriptor) and prints
`key=value` lines, always including `errno=`.  ioctl numbers are computed per
architecture (generic and powerpc/mips/sparc encodings).

ioctl paths open with O_NONBLOCK, as mt does, and poll for up to
`TT_READY_WAIT` seconds if a tape is present but becoming ready.  Reads and
writes open blocking.  `write` reports the errno of the open, pre-ops,
writes and close separately, and samples MTIOCGET in the writing file
descriptor when a write fails (EOT is per-open state).  `read` verifies
against the expected stream while reading and classifies the result as
`equal`, `prefix`, `mismatch` or `overlong`.

### The layout model

`$RESULTS/layout` holds one line per tape file: data id, state, repeat count,
block size.  Every data id is a different seed, so misordered or duplicated
files are detected, not only corrupted bytes.

| State | Must read back as |
|---|---|
| `full` | exactly the expected data, then a filemark |
| `partial` | a byte-exact prefix, then **blank tape** (no filemark) |
| `partialfm` | a prefix terminated by a filemark |
| `partialany` | a prefix; filemark optional |
| `-` (id) | an empty file (just a filemark) |

The end of an unterminated file is recognized from st's blank-check
semantics (`read_tape()`): a blank check directly after a filemark returns 0,
anywhere else EIO.  So data followed by EIO proves there is no filemark;
with no data at all, 0 then EIO means no filemark, 0 then 0 means one.

After the last file the verifier requires end of data.  Tests keep the
model current; if they cannot, they mark it dirty and the next test rebuilds
the baseline.

### In-flight resets

A background transfer writes a progress marker after a set amount of data (a
quarter of the transfer; random for stress).  The reset is issued only while
the transfer is provably still running.  If it completes anyway the race is
counted as lost and retried, up to three times.

### Isolation

Each test runs in a subshell; results are written to files in
`tests/<id>/`.  Only an explicit `skip_test` or `abort_test` sets the exit
status, never a function's last return value.  Between tests the runner
removes injections, restores timeouts and the scsi_debug delay, reloads and
rewinds the drive and returns it to variable block mode.

---

## 12. Extending the suite

Tests live in `tests/NN-name.sh` and are registered with
`tt_register ID SUITE REQUIREMENTS DESCRIPTION`.  An id of the form
`X.param` calls `t_X param`.

```bash
tt_register R99 reset any "one line: what the test proves"
t_R99() {
	layout_ensure_baseline            # known tape contents
	goto_mid                          # file 1, block 2
	reset_and_confirm lu "why"        # reset, then prove st noticed
	expect_errno EIO "fsf is blocked" op "$DEV" fsf 1
	expect_ok "rewind recovers" op "$DEV" rewind
	layout_verify "after ..."         # read the whole tape back
}
```

Useful helpers:

| Helper | |
|---|---|
| `tc <tapectl args>` | run tapectl with a deadline; result in `R[...]` |
| `status DEV` | MTIOCGET into `S[...]` (`file block blksize eod eot online ...`) |
| `expect_ok`, `expect_errno`, `check_eq`, `check_in` | assertions |
| `check_pos_lost DEV 0/1` | `position_lost_in_reset`, UNVERIFIED if missing |
| `do_reset METHOD [SG]`, `reset_and_confirm` | resets |
| `inflight_reset METHOD KIND <tapectl args>` | reset during background I/O; sets `INFLIGHT` |
| `layout_append`, `layout_set_partial`, `layout_rewrite_at`, `layout_verify` | layout model |
| `sdebug_inject HCTL SPEC` | scsi_debug error injection (cleared automatically) |
| `kmsg_expect REGEX DESC` | kernel message logged during this test |
| `pass`, `fail`, `warn`, `note`, `unverified`, `skip_test`, `abort_test` | results |

Requirement keywords: `any hw long bus host link inject multilun partitions`.

Before committing a change, run `shellcheck -x -e SC2034,SC2154 tapetest
lib/*.sh tests/*.sh` and `./selftest.sh`.

---

## 13. Self-test

`selftest.sh` runs the suite against the mock st (it must pass), then re-runs
selected tests with an emulated driver regression injected through
`TT_MOCK_BUGS`; each must fail.

| Emulated bug | Caught by |
|---|---|
| `nodetect` - reset unit attention ignored | R01, R05 |
| `noblock` - operations not blocked after a reset | R02, R10.bot |
| `norestore` - block size not re-applied on REW/SEEK/EOM | R04 |
| `silentloss` - close succeeds, buffered data dropped | R07.nst |
| `fmafterreset` - filemark written after the position was lost | R05 |
| `corrupt` - one byte flipped on read | B02 |

It needs no root and takes about three minutes.  Run it after every harness
change.

---

## 14. Kernel release validation

`release-check` runs everything a kernel release needs and produces one
report with one verdict.

```bash
./release-check.sh -d /dev/nst0 --yes --library \
    --compare release/<previous-kernel-dir>
```

### Stages

| Stage | What runs | When |
|---|---|---|
| `selftest` | `selftest.sh` - the harness itself is trustworthy | always |
| `sdebug` | full suite on scsi_debug, including EH injection | always |
| `hw-basic` | basic suite on the drive | with `-d` |
| `hw-reset` | reset + boundary suites on the drive | with `-d` |
| `hw-stress` | random-reset stress, N iterations | with `-d --stress N` |

Without `-d` only the selftest and scsi_debug stages run.  Every stage runs
even if an earlier one failed, so one report shows the whole picture.

### Options

| Option | |
|---|---|
| `-d DEV --yes` | real drive; the tape is destroyed |
| `--library` | exclude the tests that unload (R03.offline, R04.offline, R09) |
| `--long` | include hours-long hardware tests (R03.erase, X01) |
| `--stress N` | add the stress stage |
| `--allow-bus-reset`, `--allow-host-reset`, `--allow-link-reset` | passed to the hardware stages |
| `--no-st-debug` | reload st with `debug_flag=0` in every stage (much quieter kernel log) |
| `--luns N` | scsi_debug LUNs (default 2) |
| `--skip STAGE` | skip a stage (repeatable) |
| `--compare DIR` | a previous release-check directory; per-test verdict changes are listed |
| `-o DIR` | output directory (default `./release/<kernel>-<timestamp>`) |
| `--mock` | replace every kernel stage by a mock run - tests the wrapper only |

### Output

```
release/<kernel>-<ts>/REPORT.md        the report
release/<kernel>-<ts>/VERDICT          one line: verdict and counts
release/<kernel>-<ts>/environment.txt  kernel, cmdline, harness version (git
                                       describe if in a repo), st module
                                       srcversion, sg3_utils, python, options
release/<kernel>-<ts>/stages.txt       stage, exit status, duration
release/<kernel>-<ts>/<stage>.log      console output of each stage
release/<kernel>-<ts>/<stage>/         normal tapetest results directory
```

`REPORT.md` contains the stage table, failures, new warnings, expected
warnings, expected warnings that no longer occur, changes since the compared
release, unverified checks and observations.

### Verdict

| Verdict | Exit | Meaning |
|---|---|---|
| **PASS** | 0 | every stage passed; any warnings are listed in `expected-warnings.txt` |
| **FAIL** | 1 | at least one test failed, or the harness self-test failed |
| **INCOMPLETE** | 2 | a stage produced no results or aborted |
| **REVIEW** | 3 | no failures, but a warning that is not in `expected-warnings.txt` |

### expected-warnings.txt

Known st behaviour (section 9) produces warnings on every run.  They are
listed in `expected-warnings.txt` as `<test-id glob><TAB><regex>` and
reported separately as *expected*.  Any other warning makes the verdict
REVIEW.

If an expected warning stops occurring in a test that ran, the report says
so: st's behaviour may have changed (for example a fix for the MTSETBLK
discard).  Review the change and update the file deliberately; never add an
entry just to turn a REVIEW into a PASS.

### Recommended practice

* Keep every release directory; pass the previous one to `--compare`.
* Archive `REPORT.md` with the kernel build.
* On a new drive model, run the individual suites first (section 6), add a
  `stinit.conf` entry, and only then use `release-check`.

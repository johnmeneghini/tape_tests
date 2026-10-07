# st: drive settings, position and EOF state after reset and MTLOAD

Findings from tapetest runs, September 2026.  Three behaviours of the SCSI
tape driver (`drivers/scsi/st.c`): two after a device reset, one after
MTLOAD of an already loaded cartridge.  They were reproduced on an emulated
tape (scsi_debug) and on two generations of IBM LTO drives over FC, and are
reported by tapetest as warnings (R04, R03.load, B09).  This note explains
the mechanism in the code, the practical impact, and the fixes.

## Status

Fixes for all three findings were posted to linux-scsi; see
[../patches/README.md](../patches/README.md).  Until they are merged the
findings show up in tapetest as warnings listed in `expected-warnings.txt`
(R04.retension, R04.load, R03.load, B09).  R04.offline is not changed by the
patches.

## Test systems

| Host | Kernel | Drive | Transport |
|---|---|---|---|
| rhel95 | 5.14.0-687.44.1.el9_8 | scsi_debug tape (ptype=1) | - |
| rhel95 | 5.14.0-687.44.1.el9_8 | IBM ULTRIUM-TD5 (LTO-5), fw G9N0 | FC, qla2xxx |
| rhel-storage-115 | 5.14.0-687.50.1.el9_8 | IBM ULT3580-TDA, fw S57A | FC |
| (upstream) | **7.3-rc2** | IBM LTO drive, 3573-TL library | FC |

The same warnings occurred on all of them, including current upstream: this
is upstream st behaviour, not a RHEL backport artefact.  Everything else in the reset
contract passed on all three: detection, the EIO matrix, recovery by every
allowed operation, interrupted I/O, and the buffered-data contract.

## Background: the reset handling in st

| Commit | Summary |
|---|---|
| 9604eea5bd3a | "scsi: st: Add third party poweron reset handling": a power-on/reset UA seen by the SCSI core sets `pos_unknown` |
| 3d882cca73be | "scsi: st: Fix input/output error on empty drive reset" (RHEL-28791) |
| 0b120edb37dc | "scsi: st: Add MTIOCGET and MTLOAD to ioctls allowed after device reset".  The commit message states: *"The tape location is known after MTLOAD."* |
| 7081dc75df79 | "scsi: st: Restore some drive settings after reset".  The commit message states: *"reset sets partition, density and block size to drive default values. These should be restored to the values before reset."* |

After a reset, st blocks everything except MTREW, MTOFFL, MTLOAD, MTRETEN,
MTERASE, MTSEEK and MTEOM.  Any of these clears `pos_unknown`.  Only three of
them, MTREW, MTSEEK and MTEOM, restore the saved settings.

---

## Finding 1: MTSETBLK is silently discarded after reset + MTRETEN / MTLOAD / MTOFFL

### Observed (tapetest R04.*)

1. `MTSETBLK 65536` (fixed-block mode); MTIOCGET reports block size 65536.
2. LU reset.
3. Recovery with one of the allowed operations.
4. MTIOCGET block size, then a fixed-block write at EOD.

| Recovery op | Block size after | Fixed-block write |
|---|---|---|
| MTREW, MTSEEK, MTEOM | 65536 (restored) | works |
| MTRETEN, MTLOAD, MTOFFL+MTLOAD | **0 (variable)** | writes variable-length blocks; no error |

On 7.3-rc2 all three non-restoring paths, MTRETEN, MTOFFL+MTLOAD and MTLOAD,
were confirmed on real hardware.

No error or kernel message is produced.  Every subsequent write uses
variable-length blocks.

### Mechanism

Four pieces of st interact:

1. **MTSETBLK remembers the change.**  `st_int_ioctl()` sets
   `STp->blksize_changed = 1` and `STp->changed_blksize = arg`.
2. **The reset returns the drive to its default block size.**  SSC drives
   do this, and so does scsi_debug (`scsi_tape_reset_clear()` sets
   `TAPE_DEF_BLKSIZE`).
3. **Every open re-reads the drive's block size.**  `check_tape()` issues
   MODE SENSE on every `st_open()`, not only for a new session, and sets
   `STp->block_size` from the block descriptor:

   ```c
   STp->block_size = (STp->buffer)->b_data[9] * 65536 +
       (STp->buffer)->b_data[10] * 256 + (STp->buffer)->b_data[11];
   ```

   So the first open after the reset already sets the driver's view to the
   drive's default (0).  Normally this is harmless because the drive
   remembers MTSETBLK.  After a reset it no longer does.
4. **Only three recovery ops restore the saved value.**  The recovery branch
   of `st_ioctl()`, added by 7081dc75df79:

   ```c
   reset_state(STp); /* Clears pos_unknown */

   /* Fix the device settings after reset, ignore errors */
   if (mtc.mt_op == MTREW || mtc.mt_op == MTSEEK ||
       mtc.mt_op == MTEOM) {
           if (STp->can_partitions) { ... switch_partition(STp); }
           if (STp->density_changed)
                   st_int_ioctl(STp, MTSETDENSITY, STp->changed_density);
           if (STp->blksize_changed)
                   st_int_ioctl(STp, MTSETBLK, STp->changed_blksize);
   }
   ```

   MTRETEN, MTLOAD, MTOFFL and MTERASE clear `pos_unknown` without restoring
   anything.  `blksize_changed` is left set but nothing re-applies it.  After
   a load that starts a new session (new-media UA), `check_tape()` also
   clears `blksize_changed` and applies the mode defaults.

The same reasoning applies to density (`density_changed`) and, with
`can-partitions`, to the selected partition.  tapetest currently exercises
only block size (R04) and partition with REW (X03).

### Impact

An application that works in fixed-block mode, for example a backup product
configured for 64 KiB or 256 KiB blocks, and recovers from a reset with
MTLOAD, MTRETEN or unload+load continues writing without an error.  But the
data is written as variable-length blocks.  Library software commonly
recovers this way.  The result is a tape whose block format changes partway
through, which the application may later fail to read in fixed-block mode.
No data is lost at write time, but the change is silent.

### Fixes considered

* **(a) Extend the restore to MTLOAD and MTRETEN.**  Both leave the same
  cartridge at BOT, so the "only the position changed" reasoning of
  7081dc75df79 applies to them.

  ```c
  if (mtc.mt_op == MTREW || mtc.mt_op == MTSEEK ||
      mtc.mt_op == MTEOM || mtc.mt_op == MTLOAD ||
      mtc.mt_op == MTRETEN) {
  ```

  Caveat: the restore runs **before** the operation.  If a LOAD makes the
  drive report new media, `check_tape()` starts a new session and applies the
  mode defaults afterwards.  Whether the MODE SELECT survives the LOAD is
  drive dependent, so this needs testing on real drives.  R04.load and
  R04.retension would be the acceptance tests.
* **(b) Restore after the operation**, or on the first open after
  `pos_unknown` was cleared, whenever `blksize_changed` / `density_changed`
  are still set.
* **MTOFFL**: the cartridge is unloaded.  If the same cartridge is reloaded,
  (b) would cover it.  If a different cartridge is loaded, the new-session
  path correctly applies defaults instead.
* **(c) At minimum, make the loss visible**: log a warning when
  `pos_unknown` is cleared by an operation that does not restore a changed
  block size or density.

**Posted fix (patch 1):** (b) for MTLOAD and MTRETEN.  The changed values are
saved before the operation; after it `check_tape()` runs first (it already
does for MTLOAD; it is called explicitly after MTRETEN, except in immediate
mode) and the values are then re-applied, density and block size
independently.  This covers drives that report a new medium after the load
(scsi_debug) and drives that do not (IBM LTO).

---

## Finding 2: MTIOCGET reports file/block -1/-1 at BOT after reset + MTLOAD

### Observed (tapetest R03.load)

After a reset, MTLOAD clears `position_lost_in_reset`, and the tape is at
BOT.  But MTIOCGET reports `mt_fileno = -1`, `mt_blkno = -1` on both IBM
drives.  On scsi_debug it reports 0/0.

Commit 0b120edb37dc added MTLOAD to the recovery set with the rationale
*"The tape location is known after MTLOAD"*.  Only on some devices does st
actually record that position.

### Mechanism

* `reset_state()`, called when the recovery op clears `pos_unknown`, sets
  `drv_file = drv_block = -1`.
* `do_load_unload()` sets no position on a successful load.  It only sets -1
  on failure:

  ```c
  if (!retval) {  /* SCSI command successful */
          if (!load_code) { ... }
          else {
                  STp->rew_at_close = STp->autorew_dev;
                  retval = check_tape(STp, filp);
                  ...
          }
  } else {
          STps->drv_file = STps->drv_block = (-1);
  }
  ```

* `check_tape()` sets `drv_file = drv_block = 0` only for
  `CHKRES_NEW_SESSION`, which requires a new-media UA (ASC 0x28).
  scsi_debug reports one after LOAD; the IBM drives do not report one when the
  cartridge was already loaded.  So st keeps -1/-1.

MTRETEN does report 0/0 on the same drives (R03.retension), because the
retension path records BOT.

### Impact

Mostly cosmetic.  The position is not blocked, only unknown to the driver
until the next rewind.  But software that checks `mt_fileno`/`mt_blkno` or
`GMT_BOT` after recovering (`mt status` shows no BOT) may conclude that the
position is still lost.

### Posted fix (patch 2)

In `do_load_unload()`, after a successful `check_tape()` on partition 0,
set the position to BOT and reset the EOF state as MTREW does
(`drv_file = drv_block = 0`, `eof = ST_NOEOF`, `at_sm = 0`,
`last_block_valid = 0`).  This also fixes finding 3.

---

## Finding 3: read() fails with EIO after MTLOAD of a loaded tape at EOD

### Observed (tapetest B09)

No reset involved.  Position the tape at EOD (a read then fails with EIO,
correctly), MTLOAD the cartridge that is already in the drive, and read
again: the tape is at BOT, but `read()` still fails with EIO.

| Device | Unpatched | Patched |
|---|---|---|
| IBM ULT3580-TDA | read() EIO | read returns file 0 block 0 |
| scsi_debug | read works | read works |

### Mechanism

`st_read()` refuses to read while `STps->eof >= ST_EOD_1`.  MTREW resets
`eof` (via `chg_eof` in `st_int_ioctl()`), but `do_load_unload()` does not.
A new session in `check_tape()` does reset it, which is why scsi_debug (new
medium after LOAD) is not affected; drives that report no new medium for an
already loaded cartridge keep the stale `ST_EOD`.  After a reset,
`reset_state()` clears `eof`, so R03.load is not affected either.

### Impact

An application that reads to the end, reloads the cartridge with MTLOAD and
reads again gets EIO until it rewinds.  Found by Sashiko on the v1 posting
of patch 2, which set the position to BOT without resetting the EOF state.

---

## Related observations

These are consistent with the code and are not considered defects, but they
are worth knowing when testing st.

* **`position_lost_in_reset` is updated only on command completion.**
  `st_chk_result()` compares `scsi_get_ua_por_ctr()` whenever a command
  completes.  If an in-flight command is reaped by an async abort (no TUR),
  the UA is still pending when it completes, so the attribute reads 0 until
  the next command.  That next command, even a WRITE, receives the UA and
  fails, so nothing is exposed (R06).
* **`scsi2logical` is not the default.**  Without it, `get_location()` and
  `set_location()` send READ POSITION / LOCATE with the device-specific
  address form (BT=1).  LTO drives reject that form, so MTIOCPOS and MTSEEK
  fail with EIO until stinit or MTSETDRVBUFFER sets the option.  This is
  long-standing, documented behaviour, but a freshly attached LTO drive has
  no working positioning.
* **Reset with a buffered write pending (R07).**  All data reached the tape,
  `close()` returned EIO, and no filemark was written.  This is the safe
  direction; the file is unterminated.
* **scsi_debug and `sg_reset` during I/O.**  scsi_debug's reset handlers stop
  queued commands without completing them, because they expect SCSI EH to own
  them.  After an `sg_reset` from userspace the in-flight command stays
  outstanding until its timeout (900 s for st, or stinit's `timeout=`).
  qla2xxx completes it promptly.  This is a scsi_debug limitation, not an st
  issue.

## Reproducing

```bash
./tapetest.sh -d /dev/nstN --yes -t 'B09,R03.load,R04.*' -o results/reset-settings
./tapetest.sh --scsi-debug=2 -t 'B09,R03.load,R04.*' -o results/reset-settings-sdebug
```

In a library, skip the unload tests with `-x R04.offline`.  With `--st-debug`
(the default reload uses `debug_flag=1`), `tests/<id>/kmsg.log` shows st's
view of the block size (`Block size: ...` from `check_tape()`) on every open.

## Upstream kernels

The findings reproduce unchanged on v7.3-rc2: this is upstream st behaviour,
not a RHEL backport artefact.  With the patches applied, `release-check`
lists the corresponding entries under "Expected warnings that no longer
occur"; once the patches are merged, remove them from
`expected-warnings.txt`.

# st patches

Fixes for the findings in [../docs/st-reset-findings.md](../docs/st-reset-findings.md),
posted to linux-scsi.  Based on `drivers/scsi/st.c` as of 7.3-rc2/rc4 (the
file is identical in both).

* v1: https://marc.info/?l=linux-scsi&m=179051462299046&w=2
* v2: https://marc.info/?l=linux-scsi&m=179060186958028&w=2  (the files in this directory)

| Patch | Fixes | Acceptance tests |
|---|---|---|
| 0001 Restore changed drive settings after reset also for MTLOAD and MTRETEN | finding 1: MTSETBLK / MTSETDENSITY silently discarded after reset + MTLOAD / MTRETEN | R04.load, R04.retension: no warning; R04.rewind/eod/seek unchanged |
| 0002 Record the tape position after a successful MTLOAD | findings 2 and 3: MTIOCGET -1/-1 at BOT after reset + MTLOAD; read() EIO after MTLOAD at EOD | R03.load: MTIOCGET 0:0, MTIOCPOS 0, first block correct; B09: read after the load works |

Not changed, by design:

* **MTOFFL**: the medium is unloaded and a different one may be loaded next,
  for which the mode defaults apply.  R04.offline keeps its warning.
* **Immediate mode** (MT_ST_NOWAIT): MTRETEN returns before the retension
  completes, so patch 1 does not wait for the drive and does not restore the
  settings there.

## Testing

v7.3-rc2 + patches, with `-t 'B09,R03.load,R04.*'`:

| Device | Result |
|---|---|
| scsi_debug (two hosts) | all fixed; only the R04.offline warning |
| IBM ULT3580-TDA | all fixed; only the R04.offline warning |
| IBM ULTRIUM-TD5 (LTO-5) | patch 1 and the position part of patch 2 verified (the EOF part was added in v2) |

scsi_debug reports a new medium after MTLOAD and MTRETEN, the IBM drives do
not; both code paths are covered.  B09 fails on unpatched kernels only with
drives of the second kind (the new session started by scsi_debug's
new-medium unit attention resets the EOF state).

## Review history

* Patch 1: restores density and block size independently, each retried once
  (a failing density restore no longer skips the block size) - Sashiko,
  before v1.  Skips the MTRETEN restore in immediate mode - Sashiko, before v1.
* Patch 2 v2: also resets the EOF state (and at_sm, last_block_valid) after
  the load, as MTREW does - Sashiko on the v1 posting; reproduced with B09 on
  the ULT3580-TDA.

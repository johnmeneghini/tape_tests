# The st contract under test

What the tests assert, and where in `drivers/scsi/st.c` the behaviour comes
from.  Function names refer to upstream st.c; line numbers are deliberately
omitted because they move.

## Reset detection

| Behaviour | st.c | Tests |
|---|---|---|
| Every command completion compares the SCSI core power-on/reset counter (`scsi_get_ua_por_ctr()`) with the driver's copy; a change sets `pos_unknown` and logs "Power on/reset recognized" | `st_chk_result()` | R01, R11, E02-E04 |
| The counter is incremented by the SCSI core for UA ASC 0x29 from any source: explicit reset, SCSI EH reset, another initiator | SCSI core `scsi_check_sense()` | R11, E02, E03, E04 |
| A non-reset UA (e.g. 2A/01) does not set `pos_unknown` | same | R11 (control) |
| A new-media UA starts a new session and clears `pos_unknown` | `check_tape()` (`CHKRES_NEW_SESSION`) | R03.load, R09 |
| `pos_unknown` is visible as `/sys/class/scsi_tape/nstN/position_lost_in_reset` | `position_lost_in_reset_show()` | all reset tests |

Because detection happens on command completion, the attribute changes only
after st has sent a command that saw the unit attention (R06).

## While the position is unknown

| Behaviour | st.c | Tests |
|---|---|---|
| `read()` and `write()` fail with EIO | `rw_checks()` | R02, R10 |
| `MTIOCTOP` fails with EIO for every op except MTREW, MTOFFL, MTLOAD, MTRETEN, MTERASE, MTSEEK, MTEOM - including MTNOP, MTUNLOAD, MTSETBLK, MTSETPART, MTSETDRVBUFFER | `st_ioctl()` | R02 |
| `MTIOCPOS` fails with EIO | `st_ioctl()` via `flush_buffer()` | R02 |
| `MTIOCGET` succeeds and reports file and block -1 | `st_ioctl()`, `reset_state()` | R01, R02, R05 |
| Blocked operations leave the condition set and do not touch the tape | - | R02 (readback) |

## Recovery

| Behaviour | st.c | Tests |
|---|---|---|
| An allowed op clears `pos_unknown` (`reset_state()`) | `st_ioctl()` | R03.* |
| MTREW, MTSEEK and MTEOM re-apply a changed density / block size and switch back to the selected partition | `st_ioctl()` (`density_changed`, `blksize_changed`, `switch_partition()`) | R04.rewind/eod/seek, X03 |
| Other recovery ops do not re-apply settings; LOAD starts a new session with mode defaults | `check_tape()` | R04.retension/offline/load (reported, not asserted) |

## Close and filemarks

| Behaviour | st.c | Tests |
|---|---|---|
| `close()` after writing skips the filemark when the position is lost, and fails | `st_flush()` | R05, R07, E02-E04 |
| `close()` after -ENOSPC still writes the filemark | `st_flush()` | X01 |
| The rewind node rewinds on close | `st_release()` | B05 |

## End of data and blank check

| Behaviour | st.c | Tests |
|---|---|---|
| A blank check directly after a filemark returns 0 (EOD_2); anywhere else EIO | `read_tape()` | X02, layout verification |
| After MTEOM the first read fails with EIO | `st_read()` (`eof >= ST_EOD_1`) | X02 |
| Writing at end of medium fails with ENOSPC and reports EOT in MTIOCGET | `st_write()`, `st_ioctl()` | X01 |

## Positioning

| Behaviour | st.c | Tests |
|---|---|---|
| MTIOCPOS / MTSEEK use READ POSITION / LOCATE with the device-specific address form unless `scsi2logical` is set | `get_location()`, `set_location()` | B03 (requires scsi2logical on LTO) |
| fsf past EOD, bsf at BOT and fsr across a filemark fail with EIO | `st_int_ioctl()` | B03 |

## Opening

| Behaviour | st.c | Tests |
|---|---|---|
| A second opener gets EBUSY | `st_open()` | B06 |
| A blocking open of a drive that is not ready waits up to `ST_BLOCK_SECONDS` in `test_ready()`, then fails | `st_open()`, `check_tape()`, `test_ready()` | (harness uses O_NONBLOCK for ioctls) |
| Mode defaults are applied only when a new session starts, not on every open | `check_tape()` | B04, R04 |

## Timeouts

READ and WRITE use the request queue timeout (`rq_timeout`, set through
`/sys/class/scsi_device/H:C:T:L/device/timeout` or stinit `timeout=`); other
commands use `STp->timeout` / `long_timeout`.  The EH tests shorten the queue
timeout to provoke EH quickly.

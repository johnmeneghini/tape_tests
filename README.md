# tapetest

## Authors
This repo was built leveraging what John Meneghini had already created in
https://github.com/johnmeneghini/tape_tests

Laurence Oberman <loberman@redhat.com>, developed with the assistance of
John Meneghini  <jmeneghi@redhat.com>
Claude (Anthropic).  stinit.conf is based on the original tape_tests suite.


Validation harness for the Linux SCSI tape driver (`st`): I/O, positioning,
and above all device reset and SCSI error handling, with byte-exact readback
of the whole tape after every test.

```bash
./tapetest --scsi-debug=2                         # emulated tape, no hardware
./tapetest -d /dev/nst0 --yes -s basic            # real drive (destroys tape data)
./tapetest -d /dev/nst0 --yes -s reset,boundary   # real drive, reset handling
./tapetest -d /dev/nst0 --list                    # what would run here, and why not
./selftest.sh                                     # prove the harness catches regressions

# everything for a kernel release, one report and one verdict
./release-check -d /dev/nst0 --yes --library --compare release/<previous>
```

Requires root, bash, python3 >= 3.6 and sg3_utils.  Hardware and scsi_debug
runs reload st with `debug_flag=1`, apply `stinit.conf` and enforce the
`scsi2logical` option before testing.

* [User manual](docs/MANUAL.md) - setup, safety, running, results, catalogue,
  troubleshooting, extending
* [st contract](docs/st-contract.md) - what is asserted and where in st.c it
  comes from
* [st reset findings](docs/st-reset-findings.md) - analysis of the known
  warnings: mechanism in st.c, impact, possible fixes
* [st patches](patches/README.md) - fixes for the findings, posted to
  linux-scsi, with test results
* [Reference results](docs/results/README.md) - scsi_debug and IBM LTO
  baselines
* [Changes](CHANGELOG.md)

**All data on the tape under test is destroyed.**  Read the safety section
of the manual before running on a drive in a library or behind a shared HBA.

Exit status: 0 all selected tests passed or skipped, 1 failures, 2 harness
error.

License: GPL-2.0 (see LICENSE).

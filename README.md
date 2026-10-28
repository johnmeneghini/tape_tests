# Red Hat Tape Tests

This repository contains scripts and instructions to assit in the testing of
the Linux st tape driver. The deployment of these tests require a Fedora
or Centos-stream-9/10 linux platform with a physical tape drive. If a physical
tape drive is not available the scsi_debug tape emulator can be used.

## Authors
John Meneghini  <jmeneghi@redhat.com>
Laurence Oberman <loberman@redhat.com>

## Documentation

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

NOTE: The scripts and tests in this repository are all designed to be run from a
root account. It is not advised to run these scripts on a production machine
unless you know what you are doing. These scripts will modify destroy the data
on your tape drive.

## Tests - tapetests.sh

The `tapetests.sh` utility is a validation harness for the Linux SCSI tape
driver (`st`). This utility runs a collection of I/O stress, tape positioning
and error handling tests, with device resets. Each test does data validation
with a byte-exact readback of the whole tape after every test.

Examples:

```bash
./tapetest.sh --scsi-debug=2                         # emulated tape, no hardware
./tapetest.sh -d /dev/nst0 --yes -s basic            # real drive (destroys tape data)
./tapetest.sh -d /dev/nst0 --yes -s reset,boundary   # real drive, reset handling
./tapetest.sh -d /dev/nst0 --list                    # what would run here, and why not
./selftest.sh                                     # prove the harness catches regressions

# everything for a kernel release, one report and one verdict
./release-check.sh -d /dev/nst0 --yes --library --compare release/<previous>
```

The `tapetests.sh` utility must be run as root and requires: bash, python3 >=
3.6 and sg3_utils.  Hardware and scsi_debug runs reload st with `debug_flag=1`,
apply `stinit.conf` and enforce the `scsi2logical` option before testing.

**All data on the tape under test is destroyed.**  Read the safety section
of the manual before running on a drive in a library or behind a shared HBA.

Exit status: 0 all selected tests passed or skipped, 1 failures, 2 harness
error.

## Legacy Tests

The following legacy test scripts are included in this repository:

1. tape_reset_test_debug.sh - a stand-alone scsi_debug test: no hardware required
2. tape_reset_test.sh  - a stand-alone tape drive test: hardware required
3. run_tests.sh - calls either `tape_reset_test.sh` or `tape_reset_test_debug.sh`

NOTE: These tests are no longer under development and are included only to
suppport legacy applications that may still be using this repository for
running these legacy tests.

### Quick start

Example:

```
  sudo dnf install -y git lsscsi mt-st sg3_utils
  git clone https://github.com/johnmeneghini/tape_tests.git
  cd tape_tests
  sudo ./run_tests.sh /dev/nst0 /dev/sg1 0 0 0 6 1
  sudo ./tape_reset_test.sh /dev/nst0 /dev/sg1 0 0 0 2>&1 | tee -a tape_reset_test.log
  sudo ./tape_reset_test_debug.sh /dev/nst1 /dev/sg3 0 0 0 6 1 2>&1 | tee -a tape_reset_test_debug.log
```

### Help

The `run_tests.sh` script determines whether to run `tape_reset_test.sh` or
`tape_reset_test_degug.sh` based upon the `st_device` and `sg_device`
specified.

To run your test against a scsi_debug driver simply provide the `/dev/nst` and
`/dev/sg` device names after loading the scsi_debug drivers with the command:

  `modprobe scsi_debug ptype=1 dev_size_mb=10000`

#### run_tests.sh

```
# ./run_tests.sh

 Usage: run_tests.sh <st_device> <sg_device> <debug> <dmesg> <stop_on_error> <scsi_level> [number]

     <st_device> : e.g.(/dev/nst1)
     <sg_device> : e.g (/dev/sg3)
         <debug> : 1 = debug on | 0 = debug off
         <dmesg> : 1 = dmesg on | 0 = dmesg off
 <stop_on_error> : 1 =  stop on | 0 = stop off
    <scsi_level> : 1 to 8 - see: /usr/src/kernels/6.18.0-rc1_mstr/include/scsi/scsi.h
       [number]  : optional: number of tape devices (defaults to 4)

  Example:

      run_tests.sh /dev/nst3 /dev/sg4 1 0 1 6   # /dev/nst3 /dev/sg4 debug nodmesg stop SCSI_SPC_3
      run_tests.sh /dev/nst1 /dev/sg3 1 1 0 2 1 # /dev/nst1 /dev/sg3 debug dmesg nostop SCSI_2 [1 tape device]
      run_tests.sh /dev/nst0 /dev/sg1 0 0 0 8 2 # /dev/nst0 /dev/sg1 nodebug nodmesg nostop SCSI_SPC_5 [2 tape devices]

[0:0:0:0]    disk    ATA      Samsung SSD 840  4B0Q  /dev/sda   3500253855022021d  /dev/sg0
[6:0:0:0]    tape    QUANTUM  ULTRIUM 4        U53F  /dev/st0   -  /dev/sg1
[6:0:1:0]    enclosu LSI      virtualSES       02    -          -  /dev/sg2
[8:0:0:0]    tape    Linux    scsi_debug       0191  /dev/st1   -  /dev/sg3
```

#### tape_reset_test.sh

```
# ./tape_reset_test.sh

 usage: tape_reset_test.sh <st_device> <sg_device> <debug> <dmesg> <stop_on_error>

    <st_device> : name of st device e.g.:(/dev/st1)
    <sg_device> : name of corresponding sg device e.g.: (/dev/sg3)
        <debug> : 1 = debug on | 0 = debug off
        <dmesg> : 1 = dmesg on | 0 = dmesg off
<stop_on_error> : 1 =  stop on | 0 = stop off

  These tests were developed with a QUANTUM ULTRIUM 4 U53F tape drive
  and is designed to be used with real hardware.

  Example:

      tape_reset_test.sh /dev/nst3 /dev/sg4 1 0 1  # /dev/nst3 /dev/sg4 debug nodmesg stop
      tape_reset_test.sh /dev/nst1 /dev/sg3 1 1 0  # /dev/nst1 /dev/sg3 debug dmesg nostop
      tape_reset_test.sh /dev/nst0 /dev/sg1 0 0 0  # /dev/nst0 /dev/sg1 nodebug nodmesg nostop

[0:0:0:0]    disk    ATA      Samsung SSD 840  4B0Q  /dev/sda   3500253855022021d  /dev/sg0
[6:0:0:0]    tape    QUANTUM  ULTRIUM 4        U53F  /dev/st0   -  /dev/sg1
[6:0:1:0]    enclosu LSI      virtualSES       02    -          -  /dev/sg2
[8:0:0:0]    tape    Linux    scsi_debug       0191  /dev/st1   -  /dev/sg3
```
Example run:

```
sudo ./tape_reset_test.sh /dev/nst0 /dev/sg2 0 2 1  2>&1 | tee -a tape_reset_test.log
```

#### tape_reset_test_debug.sh

Tape debug tests require no tape drive.

```
./tape_reset_test_debug.sh

 Usage: tape_reset_test_debug.sh <st_device> <sg_device> <debug> <dmesg> <stop_on_error> <scsi_level> [number]

     <st_device> : e.g.(/dev/nst1)
     <sg_device> : e.g (/dev/sg3)
         <debug> : 1 = debug on | 0 = debug off
         <dmesg> : 1 = dmesg on | 0 = dmesg off
 <stop_on_error> : 1 =  stop on | 0 = stop off
    <scsi_level> : 1 to 8 - see: /usr/src/kernels/6.18.0-rc1_mstr/include/scsi/scsi.h
       [number]  : optional: number of tape devices (defaults to 4)

  Example:

      tape_reset_test_debug.sh /dev/nst3 /dev/sg4 1 0 1 6   # /dev/nst3 /dev/sg4 debug nodmesg stop SCSI_SPC_3
      tape_reset_test_debug.sh /dev/nst1 /dev/sg3 1 1 0 2 1 # /dev/nst1 /dev/sg3 debug dmesg nostop SCSI_2 [1 tape device]
      tape_reset_test_debug.sh /dev/nst0 /dev/sg1 0 0 0 8 2 # /dev/nst0 /dev/sg1 nodebug nodmesg nostop SCSI_SPC_5 [2 tape devices]

[0:0:0:0]    disk    ATA      Samsung SSD 840  4B0Q  /dev/sda   3500253855022021d  /dev/sg0
[6:0:0:0]    tape    QUANTUM  ULTRIUM 4        U53F  /dev/st0   -  /dev/sg1
[6:0:1:0]    enclosu LSI      virtualSES       02    -          -  /dev/sg2
[8:0:0:0]    tape    Linux    scsi_debug       0191  /dev/st1   -  /dev/sg3
```

Example run:

```
sudo ./tape_reset_test_debug.sh /dev/nst1 /dev/sg3 0 0 1 6 2>&1 | tee -a tape_reset_test_debug.log

```
License: GPL-2.0 (see LICENSES).

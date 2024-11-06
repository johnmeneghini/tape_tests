# Red Hat Tape Tests

This repository contains scripts and instructions to assit in the testing of
the Linux st tape driver. Set up and deployment of these tests require a Fedora
or Centos-stream-9 linux hardware platform with a physical tape drive.  At the
time of this writing three scripts are included:

1. tape_reset.sh - called by other tests to reset the tape device with sg_reset.
2. tape_reset_test.sh - use to test sg_reset with a physical tape drive.
3. tape_reset_eod.sh - reset tape while at eod and then write
4. tape_reset_load.sh - reset and then load tape
5. tape_reset_status.sh - reset and then send status
6. tape_reset_debug.sh - used to test the st driver with scsi_debug

*NOTE: The scripts used in this repository are all designed to be run from a
root account. It is not advised to run these scripts on a production machine
unless you know what you are doing. These scripts will modify destroy the data
on your tape drive.

*NOTE: tests 1. to .5 require a physical tape drive.

## Quick start

Example:

```
  dnf install -y git, lsscsi, mt-st, sg3_utils
  git clone https://github.com/johnmeneghini/tape_tests.git
  cd tape_tests
  ./tape_reset_status.sh /dev/nst0 /dev/sg1 0 2>&1 | tee -a tape_reset_status.log
  ./tape_reset_test.sh /dev/nst0 /dev/sg1 0 2>&1 | tee -a tape_reset_test.log
  ./tape_reset_load.sh /dev/nst0 /dev/sg1 0 2>&1 | tee -a tape_reset_load.log
  ./tape_reset_eod.sh /dev/nst0 /dev/sg1 0 2>&1 | tee -a tape_reset_eod.log
  grep ^-- *.log
```

## Help

```
# ./tape_reset_test.sh

 usage: tape_reset_test.sh <st_device> <sg_device> <0|1|2>

  This test was developed with a QUANTUM ULTRIUM 4 U53F tape drive
  and is designed to be used with real hardware.

  example:

      tape_reset_test.sh /dev/nst0 /dev/sg1 0 # debug off
      tape_reset_test.sh /dev/nst1 /dev/sg2 1 # debug on
      tape_reset_test.sh /dev/st0 /dev/sg1 2  # debug on, display dmesgs

[0:0:0:0]    disk    ATA      Samsung SSD 840  4B0Q  /dev/sda   3500253855022021d  /dev/sg0
[6:0:0:0]    tape    QUANTUM  ULTRIUM 4        U53F  /dev/st0   -  /dev/sg1
[6:0:1:0]    enclosu LSI      virtualSES       02    -          -  /dev/sg2
```

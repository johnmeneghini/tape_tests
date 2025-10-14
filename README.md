# Red Hat Tape Tests

This repository contains scripts and instructions to assit in the testing of
the Linux st tape driver. Set up and deployment of these tests require a Fedora
or Centos-stream-9/10 linux hardware platform with a physical tape drive. At the
time of this writing the following scripts are included:

1. tape_reset_test_debug.sh - test using scsi_debug: no hardware required
2. tape_reset_test.sh       - test using a tape drive: hardware required

Other files:

 tape_reset_lib.sh - libraray used  by tests
 tape_reset.sh     - reset function called by other tests
 stinit.conf       - initialization file used by tests

NOTE: The scripts used in this repository are all designed to be run from a
root account. It is not advised to run these scripts on a production machine
unless you know what you are doing. These scripts will modify destroy the data
on your tape drive.

## Quick start

Example:

```
  dnf install -y git, lsscsi, mt-st, sg3_utils
  git clone https://github.com/johnmeneghini/tape_tests.git
  cd tape_tests
  ./tape_reset_test.sh /dev/nst0 /dev/sg1 0 0 2>&1 | tee -a tape_reset_test.log
  ./tape_reset_test_debug.sh /dev/nst1 /dev/sg3 0 0 6 2>&1 | tee -a tape_reset_test_debuglog
```

## Help

```
# ./tape_reset_test.sh

 usage: tape_reset_test.sh <st_device> <sg_device>  <debug> <dmesg>

    <st_device> : name of st device               e.g.:(/dev/st1)
    <sg_device> : name of corresponding sg device e.g.: (/dev/sg3)
    <debug>  : 1 = debug on | 0 = debug off
    <dmesg>  : 1 = dmesg on | 0 = dmesg off

  These tests were developed with a QUANTUM ULTRIUM 4 U53F tape drive
  and is designed to be used with real hardware.

  Example:

      tape_reset_test.sh /dev/nst0 /dev/sg1 0 0
      tape_reset_test.sh /dev/nst1 /dev/sg2 1 0
      tape_reset_test.sh /dev/st0 /dev/sg1 1 1

[0:0:0:0]    disk    ATA      Samsung SSD 840  4B0Q  /dev/sda   3500253855022021d  /dev/sg0
[7:0:0:0]    tape    QUANTUM  ULTRIUM 4        U53F  /dev/st0   -  /dev/sg1
[7:0:1:0]    enclosu LSI      virtualSES       02    -          -  /dev/sg2
[N:0:0:1]    disk    INTEL SSDPEDMW400G4__1                     /dev/nvme0n1  -
```


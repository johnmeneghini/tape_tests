# Red Hat Tape Tests

This repository contains scripts and instructions to assit in the testing of
the Linux st tape driver. Set up and deployment of these tests require a Fedora
or Centos-stream-9/10 linux hardware platform with a physical tape drive. At the
time of this writing the following scripts are included:

Tests that require no hardware:

1. tape_reset_debug_sg.sh - test using scsi_debug: no hardware required

Tests that require a physical tape drive:

2. tape_reset.sh - called by other tests to reset the tape device with sg_reset
3. tape_reset_test.sh - various tests that run sg_reset at different times
4. tape_reset_eod.sh - reset tape while at eod and then try read and write
5. tape_reset_load.sh - reset tape and then eject and load tape to clear
6. tape_reset_status.sh - reset tape and then send try mt status
7. run_tests.sh - run all tests that require a physical tape drive

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
  ./tape_reset_status.sh /dev/nst0 /dev/sg1 0 0 2>&1 | tee -a tape_reset_status.log
  ./tape_reset_test.sh /dev/nst0 /dev/sg1 0 0 2>&1 | tee -a tape_reset_test.log
  ./tape_reset_load.sh /dev/nst0 /dev/sg1 0 0 2>&1 | tee -a tape_reset_load.log
  ./tape_reset_eod.sh /dev/nst0 /dev/sg1 0 0 2>&1 | tee -a tape_reset_eod.log
```

NOTE: this sequence can be done for you by running:

```
  ./run_tests.sh /dev/nst0 /dev/sg1 0 0
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

# ./tape_reset_debug_sg.sh

 Usage: tape_reset_debug.sh <st_num> <sg_num> <debug> <dmesg>

    <st_num> : /dev/st<st_num> e.g.(/dev/st1 = 1)
    <sg_num> : /dev/sg<sg_num> e.g (/dev/sg3 = 3)
    <debug>  : 1 = debug on | 0 = debug off
    <dmesg>  : 1 = dmesg on | 0 = dmesg off

  Example:

      tape_reset_debug.sh 1 3 1 1    # /dev/st1 /dev/sg3 debug dmesg
      tape_reset_debug.sh 1 3 0 0    # /dev/st1 /dev/sg3 nodebug nodmesg

[0:0:0:0]    disk    ATA      Samsung SSD 840  4B0Q  /dev/sda   3500253855022021d  /dev/sg0
[7:0:0:0]    tape    QUANTUM  ULTRIUM 4        U53F  /dev/st0   -  /dev/sg1
[7:0:1:0]    enclosu LSI      virtualSES       02    -          -  /dev/sg2
[8:0:0:0]    tape    Linux    scsi_debug       0191  /dev/st1   -  /dev/sg3
[N:0:0:1]    disk    INTEL SSDPEDMW400G4__1                     /dev/nvme0n1  -
```

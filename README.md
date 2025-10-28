# Red Hat Tape Tests

This repository contains scripts and instructions to assit in the testing of
the Linux st tape driver. Set up and deployment of these tests require a Fedora
or Centos-stream-9/10 linux platform with a physical tape drive. If a physical
tape drive is not available the scsi_debug tape emulator can be used. The time
of this writing the following scripts are included:

1. tape_reset_test_debug.sh - test using scsi_debug: no hardware required
2. tape_reset_test.sh       - test using a tape drive: hardware required

Other files:

 run_tests.sh      - calls either `tape_reset_test.sh` or `tape_reset_test_debug.sh`
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
  sudo ./run_tests.sh /dev/nst0 /dev/sg1 0 0 0 6 1
  sudo ./tape_reset_test.sh /dev/nst0 /dev/sg1 0 0 0 2>&1 | tee -a tape_reset_test.log
  sudo ./tape_reset_test_debug.sh /dev/nst1 /dev/sg3 0 0 0 6 1 2>&1 | tee -a tape_reset_test_debug.log
```

## Help

The `run_tests.sh` script determines whether to run `tape_reset_test.sh` or
`tape_reset_test_degug.sh` based upon the `st_device` and `sg_device`
specified.

To run your test against a scsi_debug driver simply provide the `/dev/nst` and
`/dev/sg` device names after loading the scsi_debug drivers with the command:

  `modprobe scsi_debug ptype=1 dev_size_mb=10000`

### run_tests.sh

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

### tape_reset_test.sh

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

### tape_reset_test_debug.sh

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

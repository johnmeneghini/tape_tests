#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# tapectl.py - low level helper for the st tape validation harness.
#
# Every operation is performed with a single open file descriptor and the
# exact errno returned by the kernel is reported, so the shell harness can
# assert on *why* something failed, not just *that* it failed.
#
# Output format: one "key=value" per line.  Every command prints "errno=<NAME>"
# ("errno=0" on success).  Exit status: 0 success, 1 operation failed with an
# errno, 2 usage / harness error.
#
# Must stay compatible with python 3.6 (RHEL 8 platform-python).
#
# A "mock:" device prefix selects an in-process emulation of the st driver's
# reset/position state machine (modelled on drivers/scsi/st.c).  It exists only
# so the harness logic itself can be exercised without hardware; it proves
# nothing about the kernel.

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import random
import struct
import sys
import time

# --------------------------------------------------------------------------
# ioctl encoding (include/uapi/asm-generic/ioctl.h, powerpc/mips/sparc differ)
# --------------------------------------------------------------------------
_MACH = os.uname().machine
if _MACH.startswith(("ppc", "powerpc", "mips", "sparc")):
    _IOC_NONE, _IOC_WRITE, _IOC_READ = 1, 4, 2
    _IOC_SIZEBITS = 13
else:
    _IOC_NONE, _IOC_WRITE, _IOC_READ = 0, 1, 2
    _IOC_SIZEBITS = 14
_IOC_NRSHIFT = 0
_IOC_TYPESHIFT = 8
_IOC_SIZESHIFT = 16
_IOC_DIRSHIFT = _IOC_SIZESHIFT + _IOC_SIZEBITS


def _ioc(d, t, nr, size):
    return (d << _IOC_DIRSHIFT) | (ord(t) << _IOC_TYPESHIFT) | \
           (nr << _IOC_NRSHIFT) | (size << _IOC_SIZESHIFT)


MTOP_FMT = "hi"          # struct mtop { short mt_op; int mt_count; }
MTGET_FMT = "lllllii"    # struct mtget
MTPOS_FMT = "l"          # struct mtpos
MTIOCTOP = _ioc(_IOC_WRITE, "m", 1, struct.calcsize(MTOP_FMT))
MTIOCGET = _ioc(_IOC_READ, "m", 2, struct.calcsize(MTGET_FMT))
MTIOCPOS = _ioc(_IOC_READ, "m", 3, struct.calcsize(MTPOS_FMT))

# include/uapi/linux/mtio.h
MTOPS = {
    "reset": 0, "fsf": 1, "bsf": 2, "fsr": 3, "bsr": 4, "weof": 5,
    "rewind": 6, "offline": 7, "nop": 8, "retension": 9, "bsfm": 10,
    "fsfm": 11, "eod": 12, "erase": 13, "setblk": 20, "setdensity": 21,
    "seek": 22, "tell_op": 23, "setdrvbuffer": 24, "fss": 25, "bss": 26,
    "wsm": 27, "lock": 28, "unlock": 29, "load": 30, "unload": 31,
    "compression": 32, "setpart": 33, "mkpart": 34, "weofi": 35,
}
MT_ST_BOOLEANS = 0x10000000
MT_ST_SETBOOLEANS = 0x30000000
MT_ST_CLEARBOOLEANS = 0x40000000
MT_ST_TIMEOUTS = 0x70000000
MT_ST_SET_LONG_TIMEOUT = MT_ST_TIMEOUTS | 0x100000
MT_ST_CAN_PARTITIONS = 0x400

GMT = {
    "eof": 0x80000000, "bot": 0x40000000, "eot": 0x20000000,
    "sm": 0x10000000, "eod": 0x08000000, "wr_prot": 0x04000000,
    "online": 0x01000000, "dr_open": 0x00040000, "im_rep_en": 0x00010000,
    "cln": 0x00008000,
}
MT_ST_BLKSIZE_MASK = 0xffffff
MT_ST_DENSITY_SHIFT = 24

# Operations the st driver permits while pos_unknown is set (st_ioctl()).
ST_ALLOWED_AFTER_RESET = ("rewind", "offline", "load", "retension",
                          "erase", "seek", "eod")
# Operations for which st re-applies changed density / block size and the
# selected partition when they clear pos_unknown.
ST_RESTORES_SETTINGS = ("rewind", "seek", "eod")


def ename(e):
    return errno.errorcode.get(e, str(e)) if e else "0"


def out(**kw):
    for k, v in kw.items():
        print("%s=%s" % (k, v))
    sys.stdout.flush()


def touch(path, text=""):
    if path:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.rename(tmp, path)


# --------------------------------------------------------------------------
# Real device backend
# --------------------------------------------------------------------------
class RealTape(object):
    def __init__(self, path, nonblock=False, readonly=False):
        self.path = path
        flags = os.O_RDONLY if readonly else os.O_RDWR
        if nonblock:
            flags |= os.O_NONBLOCK
        try:
            self.fd = os.open(path, flags)
        except OSError as e:
            if e.errno in (errno.EACCES, errno.EROFS) and not readonly:
                self.fd = os.open(path, (flags & ~os.O_RDWR) | os.O_RDONLY)
            else:
                raise

    def op(self, name, count=1):
        fcntl.ioctl(self.fd, MTIOCTOP, struct.pack(MTOP_FMT, MTOPS[name], count))

    def status(self):
        buf = fcntl.ioctl(self.fd, MTIOCGET, b"\0" * struct.calcsize(MTGET_FMT))
        t, resid, dsreg, gstat, erreg, fileno, blkno = struct.unpack(MTGET_FMT, buf)
        return dict(type=t, resid=resid, dsreg=dsreg, gstat=gstat & 0xffffffff,
                    erreg=erreg, file=fileno, block=blkno)

    def tell(self):
        buf = fcntl.ioctl(self.fd, MTIOCPOS, b"\0" * struct.calcsize(MTPOS_FMT))
        return struct.unpack(MTPOS_FMT, buf)[0]

    def write(self, data):
        return os.write(self.fd, data)

    def read(self, n):
        return os.read(self.fd, n)

    def close(self):
        fd, self.fd = self.fd, None
        os.close(fd)


def real_sysattr(dev, attr):
    name = os.path.basename(dev)
    if not name.startswith("n"):
        name = "n" + name
    p = os.path.join("/sys/class/scsi_tape", name, attr)
    with open(p) as f:
        return f.read().strip()


# --------------------------------------------------------------------------
# Mock backend (harness self-test only)
# --------------------------------------------------------------------------
class MockState(object):
    """Global JSON state protected by a flock."""

    def __init__(self):
        self.dir = os.environ.get("TT_MOCK_DIR")
        if not self.dir:
            raise OSError(errno.ENODEV, "TT_MOCK_DIR not set")
        self.lockf = os.path.join(self.dir, "state.lock")
        self.statef = os.path.join(self.dir, "state.json")

    def __enter__(self):
        self.lfd = os.open(self.lockf, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(self.lfd, fcntl.LOCK_EX)
        with open(self.statef) as f:
            self.s = json.load(f)
        return self.s

    def __exit__(self, *a):
        tmp = self.statef + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.s, f)
        os.rename(tmp, self.statef)
        fcntl.flock(self.lfd, fcntl.LOCK_UN)
        os.close(self.lfd)


def mock_new_lun():
    return dict(loaded=True, entries=[], p=0, dev_blksize=0, drv_blksize=0,
                blksize_changed=0, changed_blksize=0, ua=False,
                pos_unknown=0, rw="idle", eof="", eot=False,
                options=0x100 | 0x800,
                stats=dict(read_cnt=0, read_byte_cnt=0, write_cnt=0,
                           write_byte_cnt=0, other_cnt=0, io_ns=0,
                           read_ns=0, write_ns=0, in_flight=0, resid_cnt=0))


def mock_init(d, luns, cap):
    os.makedirs(d, exist_ok=True)
    st = dict(cap=cap, luns={})
    for i in range(luns):
        st["luns"][str(i)] = mock_new_lun()
        os.makedirs(os.path.join(d, "lun%d" % i), exist_ok=True)
    with open(os.path.join(d, "state.json"), "w") as f:
        json.dump(st, f)


def mock_parse(dev):
    # mock:nst0 / mock:st0 / mock:sg0
    name = dev.split(":", 1)[1]
    rew = name.startswith("st")
    lun = "".join(c for c in name if c.isdigit())
    return lun, rew


def mock_bug(name):
    """Harness self-test: emulate a driver regression (TT_MOCK_BUGS=a,b)."""
    return name in os.environ.get("TT_MOCK_BUGS", "").split(",")


def mock_delay():
    d = float(os.environ.get("TT_MOCK_DELAY", "0"))
    if d:
        time.sleep(d)


class MockTape(object):
    """Emulates the parts of st.c the harness asserts on."""

    def __init__(self, path, nonblock=False, readonly=False):
        self.path = path
        self.lun, self.rew_at_close = mock_parse(path)
        self.ms = MockState()
        self.dir = os.path.join(self.ms.dir, "lun" + self.lun)
        # st allows a single opener: emulate with a per-lun flock
        self.ofd = os.open(os.path.join(self.dir, "open.lock"),
                           os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(self.ofd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(self.ofd)
            raise OSError(errno.EBUSY, "busy")
        with self.ms as s:
            L = s["luns"][self.lun]
            # st_open -> check_tape -> TEST UNIT READY consumes a pending UA
            if L["ua"]:
                L["ua"] = False
                L["pos_unknown"] = 0 if mock_bug("nodetect") else 1
            L["rw"] = "idle"

    # helpers --------------------------------------------------------------
    def _cmd(self, L):
        """A SCSI command is sent: a pending UA fails it and sets pos_unknown."""
        if L["ua"]:
            L["ua"] = False
            if mock_bug("nodetect"):
                return
            L["pos_unknown"] = 1
            raise OSError(errno.EIO, "UA")

    def _blk(self, i):
        return os.path.join(self.dir, "blk_%d" % i)

    @staticmethod
    def _pos(L):
        f = b = 0
        for e in L["entries"][:L["p"]]:
            if e[0] == "F":
                f += 1
                b = 0
            else:
                b += 1
        return f, b

    # ioctls ---------------------------------------------------------------
    def op(self, name, count=1):
        mock_delay()
        with self.ms as s:
            L = s["luns"][self.lun]
            if name == "setdrvbuffer":
                if L["pos_unknown"]:
                    raise OSError(errno.EIO, "pos_unknown")
                if (count & 0xf0000000) == MT_ST_SETBOOLEANS:
                    L["options"] |= count & 0xfffffff
                elif (count & 0xf0000000) == MT_ST_CLEARBOOLEANS:
                    L["options"] &= ~(count & 0xfffffff)
                return
            if L["pos_unknown"] and mock_bug("noblock"):
                L["pos_unknown"] = 0
            if L["pos_unknown"]:
                if name not in ST_ALLOWED_AFTER_RESET:
                    raise OSError(errno.EIO, "pos_unknown")
                L["pos_unknown"] = 0
                if name in ST_RESTORES_SETTINGS and L["blksize_changed"] \
                        and not mock_bug("norestore"):
                    L["dev_blksize"] = L["changed_blksize"]
            self._close_write(L)
            if not L["loaded"] and name not in ("load", "nop"):
                raise OSError(errno.EIO, "no medium")
            L["stats"]["other_cnt"] += 1
            if name in ("nop", "lock", "unlock", "compression", "setdensity"):
                return
            if name == "load":
                self._cmd(L)
                L.update(loaded=True, p=0, eof="", eot=False)
                return
            self._cmd(L)
            E = L["entries"]
            if name == "rewind" or name == "retension":
                L.update(p=0, eof="", eot=False)
            elif name in ("offline", "unload"):
                L.update(p=0, loaded=False, eof="")
            elif name == "eod":
                L.update(p=len(E), eof="eod")
            elif name == "seek":
                if count > len(E):
                    raise OSError(errno.EIO, "seek past eod")
                L.update(p=count, eof="")
            elif name == "setblk":
                L.update(drv_blksize=count, dev_blksize=count,
                         blksize_changed=1, changed_blksize=count)
            elif name == "erase":
                del E[L["p"]:]
            elif name in ("weof", "wsm"):
                if name == "wsm":
                    raise OSError(errno.EIO, "setmarks unsupported")
                del E[L["p"]:]
                for _ in range(count):
                    E.append(["F"])
                L["p"] = len(E)
            elif name in ("fsf", "fsfm"):
                n = count
                while n:
                    if L["p"] >= len(E):
                        L["eof"] = "eod"
                        raise OSError(errno.EIO, "eod")
                    if E[L["p"]][0] == "F":
                        n -= 1
                    L["p"] += 1
                if name == "fsfm":
                    L["p"] -= 1
                L["eof"] = ""
            elif name in ("bsf", "bsfm"):
                n = count
                while n:
                    if L["p"] == 0:
                        raise OSError(errno.EIO, "bot")
                    L["p"] -= 1
                    if E[L["p"]][0] == "F":
                        n -= 1
                if name == "bsfm":
                    L["p"] += 1
                L["eof"] = ""
            elif name == "fsr":
                for _ in range(count):
                    if L["p"] >= len(E) or E[L["p"]][0] == "F":
                        raise OSError(errno.EIO, "fm/eod")
                    L["p"] += 1
            elif name == "bsr":
                for _ in range(count):
                    if L["p"] == 0 or E[L["p"] - 1][0] == "F":
                        raise OSError(errno.EIO, "fm/bot")
                    L["p"] -= 1
            elif name == "setpart" or name == "mkpart":
                raise OSError(errno.EINVAL, "no partitions")
            else:
                raise OSError(errno.EINVAL, "unsupported in mock")

    def status(self):
        with self.ms as s:
            L = s["luns"][self.lun]
            g = 0
            if L["loaded"]:
                g |= GMT["online"]
            else:
                g |= GMT["dr_open"]
            if L["pos_unknown"] or not L["loaded"]:
                f = b = -1
                if not L["loaded"]:
                    f = b = 0 if not L["pos_unknown"] else -1
            else:
                f, b = self._pos(L)
                if b == 0:
                    g |= GMT["bot"] if f == 0 else GMT["eof"]
                if L["eof"] in ("eod", "eod2"):
                    g |= GMT["eod"]
                if L["eot"]:
                    g |= GMT["eot"]
            return dict(type=0x72, resid=0, dsreg=L["drv_blksize"] & MT_ST_BLKSIZE_MASK,
                        gstat=g, erreg=0, file=f, block=b)

    def tell(self):
        with self.ms as s:
            L = s["luns"][self.lun]
            if L["pos_unknown"]:
                raise OSError(errno.EIO, "pos_unknown")
            return L["p"]

    def write(self, data):
        mock_delay()
        with self.ms as s:
            L = s["luns"][self.lun]
            if L["pos_unknown"] and not mock_bug("noblock"):
                raise OSError(errno.EIO, "pos_unknown")
            if not L["loaded"]:
                raise OSError(errno.EIO, "no medium")
            self._cmd(L)
            bs = L["drv_blksize"]
            if bs and len(data) % bs:
                raise OSError(errno.EINVAL, "not multiple")
            if L["dev_blksize"] != bs:
                raise OSError(errno.EIO, "block size mismatch on device")
            E = L["entries"]
            del E[L["p"]:]          # writing sets a new end of data
            if len(E) >= s["cap"]:
                L["eot"] = True
                raise OSError(errno.ENOSPC, "eom")
            chunks = [data[i:i + bs] for i in range(0, len(data), bs)] if bs else [data]
            for c in chunks:
                with open(self._blk(len(E)), "wb") as f:
                    f.write(c)
                E.append(["D", len(c)])
            L["p"] = len(E)
            L["rw"] = "writing"
            L["eof"] = ""
            L["stats"]["write_cnt"] += 1
            L["stats"]["write_byte_cnt"] += len(data)
            return len(data)

    def read(self, n):
        mock_delay()
        with self.ms as s:
            L = s["luns"][self.lun]
            if L["pos_unknown"]:
                raise OSError(errno.EIO, "pos_unknown")
            if not L["loaded"]:
                raise OSError(errno.EIO, "no medium")
            self._cmd(L)
            if L["dev_blksize"] != L["drv_blksize"]:
                raise OSError(errno.EIO, "block size mismatch on device")
            E = L["entries"]
            bs = L["drv_blksize"]
            want = (n // bs) if bs else 1
            buf = b""
            while want:
                if L["p"] >= len(E):
                    if not buf:
                        # BLANK CHECK: 0 only for the first one after a
                        # filemark was crossed by reading (read_tape())
                        if L["eof"] != "fm":
                            L["eof"] = "eod"
                            raise OSError(errno.EIO, "blank check")
                        L["eof"] = "eod2"
                    break
                e = E[L["p"]]
                if e[0] == "F":
                    if not buf:
                        L["p"] += 1
                        L["eof"] = "fm"
                    break
                if not bs and e[1] > n:
                    raise OSError(errno.ENOMEM, "block larger than request")
                with open(self._blk(L["p"]), "rb") as f:
                    blk = f.read()
                if mock_bug("corrupt") and L["p"] == 5 and len(blk) > 100:
                    blk = blk[:100] + bytes([blk[100] ^ 0xff]) + blk[101:]
                buf += blk
                L["p"] += 1
                want -= 1
            if buf:
                L["eof"] = ""          # data read: no longer at a filemark
            L["rw"] = "reading"
            L["stats"]["read_cnt"] += 1
            L["stats"]["read_byte_cnt"] += len(buf)
            return buf

    def _close_write(self, L):
        if L["rw"] == "writing":
            L["rw"] = "idle"
            if L["pos_unknown"]:
                return
            E = L["entries"]
            del E[L["p"]:]
            E.append(["F"])
            L["p"] = len(E)

    def close(self):
        err = None
        with self.ms as s:
            L = s["luns"][self.lun]
            try:
                if L["rw"] == "writing" and L["ua"] and mock_bug("silentloss"):
                    L["ua"] = False
                    L["pos_unknown"] = 1
                    E = L["entries"]
                    if E and E[-1][0] == "D":
                        E.pop()            # drop buffered data, report success
                    L["rw"] = "idle"
                if L["rw"] == "writing" and mock_bug("fmafterreset") and \
                        (L["ua"] or L["pos_unknown"]):
                    L["ua"] = False
                    L["pos_unknown"] = 1
                    L["entries"].append(["F"])
                    L["rw"] = "idle"
                if L["rw"] == "writing":
                    if L["ua"]:
                        L["ua"] = False
                        L["pos_unknown"] = 1
                        L["rw"] = "idle"
                        raise OSError(errno.EIO, "UA on filemark")
                    if L["pos_unknown"]:
                        L["rw"] = "idle"
                        raise OSError(errno.EIO, "pos_unknown")
                    self._close_write(L)
                if self.rew_at_close and L["loaded"] and not L["pos_unknown"]:
                    L.update(p=0, eof="")
            except OSError as e:
                err = e
            L["rw"] = "idle"
        fcntl.flock(self.ofd, fcntl.LOCK_UN)
        os.close(self.ofd)
        if err:
            raise err


def mock_reset(dev, scope):
    lun, _ = mock_parse(dev)
    with MockState() as s:
        targets = s["luns"].keys() if scope in ("target", "bus", "host") else [lun]
        for k in targets:
            L = s["luns"][k]
            # Like scsi_debug/most drives: position to BOT, forget block size.
            L.update(ua=True, p=0, dev_blksize=0, eof="")


def mock_sysattr(dev, attr):
    lun, _ = mock_parse(dev)
    with MockState() as s:
        L = s["luns"][lun]
        if attr == "position_lost_in_reset":
            return str(L["pos_unknown"])
        if attr == "options":
            return "0x%x" % L["options"]
        if attr.startswith("stats/"):
            return str(L["stats"][attr[6:]])
        if attr in ("default_blksize", "default_density", "default_compression"):
            return "-1"
        if attr == "defined":
            return "1"
    raise OSError(errno.ENOENT, attr)


# --------------------------------------------------------------------------
def open_tape(path, nonblock=False, readonly=False):
    if path.startswith("mock:"):
        return MockTape(path, nonblock, readonly)
    return RealTape(path, nonblock, readonly)


# Operations that must be issued even when no tape is ready.
NO_READY_WAIT = ("load", "offline", "unload", "nop")


def open_ready(path, readonly=False, wait_ready=True):
    """Open for ioctls the way mt does: O_NONBLOCK.

    A blocking open of st with no ready medium sleeps in test_ready() for
    ST_BLOCK_SECONDS (120 s) and then fails, so MTLOAD after MTOFFL would be
    impossible and MTIOCGET on an empty drive would take two minutes.  With
    O_NONBLOCK, st reports "no tape" (DR_OPEN) at once.  If a tape is present
    but still becoming ready (e.g. right after a reset), poll for up to
    TT_READY_WAIT seconds so tests see the settled state.
    """
    deadline = time.time() + float(os.environ.get("TT_READY_WAIT", "60"))
    while True:
        t = open_tape(path, nonblock=True, readonly=readonly)
        if not wait_ready:
            return t
        g = t.status()["gstat"]
        if g & GMT["online"] or g & GMT["dr_open"] or time.time() >= deadline:
            return t
        t.close()
        time.sleep(1)


def do_preops(t, preops):
    for p in preops or []:
        name, _, cnt = p.partition(":")
        t.op(name, int(cnt) if cnt else 1)


class Expect(object):
    """Expected byte stream: <src> repeated <repeat> times, from <offset>."""

    def __init__(self, src, repeat=1, offset=0):
        with open(src, "rb") as f:
            self.data = f.read()
        self.total = len(self.data) * repeat - offset
        self.offset = offset

    def slice(self, pos, n):
        n = max(0, min(n, self.total - pos))
        out_b = b""
        a = pos + self.offset
        L = len(self.data)
        while n > 0:
            i = a % L
            c = self.data[i:i + n]
            out_b += c
            n -= len(c)
            a += len(c)
        return out_b


def cmd_op(a):
    t = None
    e = 0
    try:
        t = open_ready(a.dev, wait_ready=a.name not in NO_READY_WAIT)
        count = a.count
        if a.name == "setbool":
            a.name, count = "setdrvbuffer", MT_ST_SETBOOLEANS | count
        elif a.name == "clearbool":
            a.name, count = "setdrvbuffer", MT_ST_CLEARBOOLEANS | count
        elif a.name == "settimeout":
            a.name, count = "setdrvbuffer", MT_ST_TIMEOUTS | count
        elif a.name == "setlongtimeout":
            a.name, count = "setdrvbuffer", MT_ST_SET_LONG_TIMEOUT | count
        t.op(a.name, count)
    except OSError as ex:
        e = ex.errno
    finally:
        if t:
            try:
                t.close()
            except OSError as ex:
                e = e or ex.errno
    out(errno=ename(e))
    return 1 if e else 0


def fmt_status(st):
    g = st["gstat"]
    d = dict(file=st["file"], block=st["block"],
             blksize=st["dsreg"] & MT_ST_BLKSIZE_MASK,
             density="0x%x" % ((st["dsreg"] >> MT_ST_DENSITY_SHIFT) & 0xff),
             partition=st["resid"], gstat="0x%08x" % g, type="0x%x" % st["type"])
    for k, v in GMT.items():
        d[k] = 1 if g & v else 0
    return d


def cmd_status(a):
    t = None
    e = 0
    d = {}
    try:
        t = open_ready(a.dev, readonly=True)
        d = fmt_status(t.status())
    except OSError as ex:
        e = ex.errno
    finally:
        if t:
            try:
                t.close()
            except OSError:
                pass
    out(errno=ename(e), **d)
    return 1 if e else 0


def cmd_tell(a):
    t = None
    e = 0
    blk = -1
    try:
        t = open_ready(a.dev, readonly=True)
        blk = t.tell()
    except OSError as ex:
        e = ex.errno
    finally:
        if t:
            try:
                t.close()
            except OSError:
                pass
    out(errno=ename(e), block=blk)
    return 1 if e else 0


def cmd_write(a):
    with open(a.src, "rb") as f:
        data = f.read()
    if a.max_bytes:
        total = a.max_bytes
    else:
        total = len(data) * a.repeat
    e_open = e_write = e_close = e_pre = 0
    written = blocks = 0
    t = None
    progressed = False
    at_err = {}
    try:
        t = open_tape(a.dev)
    except OSError as ex:
        e_open = ex.errno
    if t:
        try:
            do_preops(t, a.pre)
        except OSError as ex:
            e_pre = ex.errno
        if not e_pre:
            pos = 0
            L = len(data)
            while pos < total:
                n = min(a.bs, total - pos)
                i = pos % L
                chunk = data[i:i + n]
                if len(chunk) < n:
                    chunk += data[:n - len(chunk)]
                try:
                    w = t.write(chunk)
                except OSError as ex:
                    e_write = ex.errno
                    try:
                        at_err = fmt_status(t.status())
                    except OSError:
                        at_err = {}
                    break
                written += w
                blocks += 1
                pos += w
                if w != n:
                    e_write = errno.EIO   # short write on tape == error
                    break
                if a.progress and not progressed and written >= a.progress_bytes:
                    touch(a.progress, str(written))
                    progressed = True
            if a.progress:
                touch(a.progress + ".done", str(written))
            if a.hold and not e_write:
                time.sleep(a.hold)
        try:
            t.close()
        except OSError as ex:
            e_close = ex.errno
    first = e_open or e_pre or e_write or e_close
    out(errno=ename(first), errno_open=ename(e_open), errno_pre=ename(e_pre),
        errno_write=ename(e_write), errno_close=ename(e_close),
        bytes=written, blocks=blocks,
        eot_at_error=at_err.get("eot", -1), eod_at_error=at_err.get("eod", -1))
    return 1 if first else 0


def cmd_read(a):
    exp = Expect(a.expect, a.expect_repeat, a.expect_offset) if a.expect else None
    stride = a.tape_block or a.bs
    e_open = e_read = e_close = e_pre = 0
    got = blocks = 0
    bmin = bmax = 0
    mismatch_at = -1
    h = hashlib.sha256()
    t = None
    progressed = False
    try:
        t = open_tape(a.dev)
    except OSError as ex:
        e_open = ex.errno
    if t:
        try:
            do_preops(t, a.pre)
        except OSError as ex:
            e_pre = ex.errno
        while not e_pre:
            if a.max_bytes and got >= a.max_bytes:
                break
            try:
                b = t.read(a.bs)
            except OSError as ex:
                e_read = ex.errno
                break
            if not b:
                break
            blocks += 1
            bmin = len(b) if not bmin else min(bmin, len(b))
            bmax = max(bmax, len(b))
            h.update(b)
            if exp is not None and mismatch_at < 0:
                want = exp.slice(got, len(b))
                if a.verify == "full":
                    if b[:len(want)] != want or len(b) > len(want):
                        for i in range(min(len(b), len(want))):
                            if b[i] != want[i]:
                                mismatch_at = got + i
                                break
                        else:
                            mismatch_at = got + len(want)
                elif a.verify == "first4":
                    if len(b) > len(want):
                        mismatch_at = got + len(want)
                    for off in range(0, len(b), stride):
                        if b[off:off + 4] != want[off:off + 4]:
                            mismatch_at = got + off
                            break
            got += len(b)
            if a.progress and not progressed and got >= a.progress_bytes:
                touch(a.progress, str(got))
                progressed = True
            if a.one:
                break
        if a.progress:
            touch(a.progress + ".done", str(got))
        try:
            t.close()
        except OSError as ex:
            e_close = ex.errno
    verify = "none"
    if exp is not None:
        if mismatch_at >= 0:
            verify = "mismatch"
        elif got == exp.total:
            verify = "equal"
        elif got < exp.total:
            verify = "prefix"
        else:
            verify = "overlong"
    first = e_open or e_pre or e_read or e_close
    out(errno=ename(first), errno_open=ename(e_open), errno_pre=ename(e_pre),
        errno_read=ename(e_read), errno_close=ename(e_close), bytes=got,
        blocks=blocks, min_block=bmin, max_block=bmax, verify=verify,
        mismatch_at=mismatch_at, expected_bytes=exp.total if exp else -1,
        sha256=h.hexdigest())
    return 1 if first else 0


# --------------------------------------------------------------------------
# MODE SENSE(6) through the sg node: reads the drive's own settings (buffered
# mode, density, block length), not st's copy of them.
# --------------------------------------------------------------------------
class SgIoHdr(ctypes.Structure):
    _fields_ = [("interface_id", ctypes.c_int), ("dxfer_direction", ctypes.c_int),
                ("cmd_len", ctypes.c_ubyte), ("mx_sb_len", ctypes.c_ubyte),
                ("iovec_count", ctypes.c_ushort), ("dxfer_len", ctypes.c_uint),
                ("dxferp", ctypes.c_void_p), ("cmdp", ctypes.c_void_p),
                ("sbp", ctypes.c_void_p), ("timeout", ctypes.c_uint),
                ("flags", ctypes.c_uint), ("pack_id", ctypes.c_int),
                ("usr_ptr", ctypes.c_void_p), ("status", ctypes.c_ubyte),
                ("masked_status", ctypes.c_ubyte), ("msg_status", ctypes.c_ubyte),
                ("sb_len_wr", ctypes.c_ubyte), ("host_status", ctypes.c_ushort),
                ("driver_status", ctypes.c_ushort), ("resid", ctypes.c_int),
                ("duration", ctypes.c_uint), ("info", ctypes.c_uint)]


SG_IO = 0x2285
SG_DXFER_FROM_DEV = -3


def cmd_modesense(a):
    if a.sg.startswith("mock:"):
        out(errno="EOPNOTSUPP")
        return 1
    try:
        fd = os.open(a.sg, os.O_RDWR | os.O_NONBLOCK)
    except OSError as ex:
        out(errno=ename(ex.errno))
        return 1
    cdb = (ctypes.c_ubyte * 6)(0x1a, 0, 0, 0, 12, 0)
    buf = (ctypes.c_ubyte * 12)()
    sense = (ctypes.c_ubyte * 32)()
    # A pending unit attention (e.g. 2A/01 "mode parameters changed" after
    # a MODE SELECT through st) fails the first command: retry.
    for _ in range(4):
        h = SgIoHdr(interface_id=ord("S"), dxfer_direction=SG_DXFER_FROM_DEV,
                    cmd_len=6, mx_sb_len=32, dxfer_len=12,
                    dxferp=ctypes.cast(buf, ctypes.c_void_p),
                    cmdp=ctypes.cast(cdb, ctypes.c_void_p),
                    sbp=ctypes.cast(sense, ctypes.c_void_p), timeout=60000)
        try:
            fcntl.ioctl(fd, SG_IO, h)
        except OSError as ex:
            os.close(fd)
            out(errno=ename(ex.errno))
            return 1
        if not (h.status and (sense[2] & 0xf) == 6):
            break
    os.close(fd)
    if h.status or h.host_status or h.driver_status:
        out(errno="EIO", status="0x%x" % h.status, sense_key="0x%x" % (sense[2] & 0xf),
            asc="0x%x" % sense[12], ascq="0x%x" % sense[13])
        return 1
    out(errno="0", buffered_mode=(buf[2] >> 4) & 7, wr_prot=buf[2] >> 7,
        density="0x%x" % buf[4], blksize=(buf[9] << 16) | (buf[10] << 8) | buf[11])
    return 0


# --------------------------------------------------------------------------
# A sequence of steps on ONE open file descriptor, with handshake files so
# the harness can act (e.g. reset) between steps.
#   op:NAME[:COUNT]   MTIOCTOP        read   read one block
#   write:COUNT       write COUNT blocks (pattern data)
#   signal:FILE       create FILE     wait:FILE  wait for FILE (600 s)
# --------------------------------------------------------------------------
def cmd_session(a):
    try:
        t = open_tape(a.dev)
    except OSError as ex:
        out(errno=ename(ex.errno))
        return 1
    res = {}
    for i, st in enumerate(a.step, 1):
        kind, _, rest = st.partition(":")
        e = 0
        try:
            if kind == "op":
                name, _, cnt = rest.partition(":")
                t.op(name, int(cnt, 0) if cnt else 1)
            elif kind == "read":
                t.read(a.bs)
            elif kind == "write":
                for n in range(int(rest or 1)):
                    t.write(bytes([n & 0xff]) * a.bs)
            elif kind == "signal":
                touch(rest, "1")
            elif kind == "wait":
                deadline = time.time() + 600
                while not os.path.exists(rest) and time.time() < deadline:
                    time.sleep(0.1)
        except OSError as ex:
            e = ex.errno
        res["step%d_errno" % i] = ename(e)
    e_close = 0
    try:
        t.close()
    except OSError as ex:
        e_close = ex.errno
    out(errno="0", errno_close=ename(e_close), **res)
    return 0


def cmd_hold(a):
    try:
        t = open_tape(a.dev, a.nonblock, readonly=True)
    except OSError as ex:
        out(errno=ename(ex.errno))
        return 1
    touch(a.ready, "1")
    time.sleep(a.seconds)
    try:
        t.close()
    except OSError:
        pass
    out(errno="0")
    return 0


def cmd_sysattr(a):
    try:
        if a.dev.startswith("mock:"):
            v = mock_sysattr(a.dev, a.attr)
        else:
            v = real_sysattr(a.dev, a.attr)
    except (OSError, IOError) as ex:
        out(errno=ename(ex.errno or errno.ENOENT))
        return 1
    out(errno="0", value=v)
    return 0


def cmd_gendata(a):
    rnd = random.Random(a.seed)
    left = a.bytes
    with open(a.file, "wb") as f:
        while left:
            n = min(left, 1 << 20)
            f.write(rnd.getrandbits(n * 8).to_bytes(n, "little"))
            left -= n
    out(errno="0", bytes=a.bytes)
    return 0


# --------------------------------------------------------------------------
# /dev/kmsg: record a sequence number, later fetch everything newer.  This
# avoids "dmesg -C", which destroys evidence on a shared test system.
# --------------------------------------------------------------------------
def _kmsg_records():
    fd = os.open("/dev/kmsg", os.O_RDONLY | os.O_NONBLOCK)
    try:
        while True:
            try:
                rec = os.read(fd, 16384)
            except OSError as ex:
                if ex.errno == errno.EAGAIN:
                    break
                if ex.errno == errno.EPIPE:     # overwritten, skip ahead
                    continue
                raise
            txt = rec.decode("utf-8", "replace")
            hdr, _, msg = txt.partition(";")
            f = hdr.split(",")
            try:
                yield int(f[1]), int(f[2]), msg.split("\n", 1)[0]
            except (IndexError, ValueError):
                continue
    finally:
        os.close(fd)


def cmd_kmsg(a):
    if a.mode == "mark":
        seq = -1
        try:
            for s, _, _ in _kmsg_records():
                seq = s
        except OSError as ex:
            out(errno=ename(ex.errno), seq=-1)
            return 1
        out(errno="0", seq=seq)
        return 0
    try:
        with open(a.out, "a") if a.out else sys.stdout as fo:
            for s, us, m in _kmsg_records():
                if s > a.since:
                    fo.write("[%12.6f] %s\n" % (us / 1e6, m))
    except OSError as ex:
        print("errno=%s" % ename(ex.errno), file=sys.stderr)
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(prog="tapectl")
    sub = ap.add_subparsers(dest="cmd")

    p = sub.add_parser("op")
    p.add_argument("dev")
    p.add_argument("name", choices=sorted(list(MTOPS) + ["setbool", "clearbool",
                                                          "settimeout", "setlongtimeout"]))
    p.add_argument("count", nargs="?", type=lambda x: int(x, 0), default=1)
    p.add_argument("--nonblock", action="store_true")

    for n in ("status", "tell"):
        p = sub.add_parser(n)
        p.add_argument("dev")
        p.add_argument("--nonblock", action="store_true")

    p = sub.add_parser("write")
    p.add_argument("dev")
    p.add_argument("--src", required=True)
    p.add_argument("--bs", type=int, default=65536)
    p.add_argument("--repeat", type=int, default=1)
    p.add_argument("--max-bytes", type=int, default=0)
    p.add_argument("--pre", action="append", help="op[:count] before writing")
    p.add_argument("--hold", type=float, default=0,
                   help="seconds to keep the fd open after the last write")
    p.add_argument("--progress")
    p.add_argument("--progress-bytes", type=int, default=1)

    p = sub.add_parser("read")
    p.add_argument("dev")
    p.add_argument("--bs", type=int, default=65536)
    p.add_argument("--max-bytes", type=int, default=0)
    p.add_argument("--pre", action="append")
    p.add_argument("--expect")
    p.add_argument("--expect-repeat", type=int, default=1)
    p.add_argument("--expect-offset", type=int, default=0)
    p.add_argument("--verify", choices=("full", "first4"), default="full")
    p.add_argument("--tape-block", type=int, default=0)
    p.add_argument("--one", action="store_true", help="read a single block")
    p.add_argument("--progress")
    p.add_argument("--progress-bytes", type=int, default=1)

    p = sub.add_parser("modesense")
    p.add_argument("sg")

    p = sub.add_parser("session")
    p.add_argument("dev")
    p.add_argument("--bs", type=int, default=65536)
    p.add_argument("--step", action="append", default=[])

    p = sub.add_parser("hold")
    p.add_argument("dev")
    p.add_argument("seconds", type=float)
    p.add_argument("--ready")
    p.add_argument("--nonblock", action="store_true")

    p = sub.add_parser("sysattr")
    p.add_argument("dev")
    p.add_argument("attr")

    p = sub.add_parser("gendata")
    p.add_argument("file")
    p.add_argument("--bytes", type=int, required=True)
    p.add_argument("--seed", type=int, default=1)

    p = sub.add_parser("kmsg")
    p.add_argument("mode", choices=("mark", "since"))
    p.add_argument("--since", type=int, default=-1)
    p.add_argument("--out")

    p = sub.add_parser("mock-init")
    p.add_argument("dir")
    p.add_argument("--luns", type=int, default=1)
    p.add_argument("--cap", type=int, default=100000, help="capacity in blocks")

    p = sub.add_parser("mock-reset")
    p.add_argument("dev")
    p.add_argument("--scope", default="lu")

    a = ap.parse_args()
    fn = {"op": cmd_op, "status": cmd_status, "tell": cmd_tell,
          "write": cmd_write, "read": cmd_read, "hold": cmd_hold,
          "sysattr": cmd_sysattr, "gendata": cmd_gendata, "kmsg": cmd_kmsg,
          "modesense": cmd_modesense, "session": cmd_session}
    if a.cmd in fn:
        return fn[a.cmd](a)
    if a.cmd == "mock-init":
        mock_init(a.dir, a.luns, a.cap)
        out(errno="0")
        return 0
    if a.cmd == "mock-reset":
        mock_reset(a.dev, a.scope)
        out(errno="0")
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)

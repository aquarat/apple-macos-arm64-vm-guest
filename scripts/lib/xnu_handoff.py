# SPDX-License-Identifier: GPL-2.0-or-later
"""XNU hand-off editor for vmapple guests under KVM, run inside GDB.

scripts/inject-xnu-kvm.sh runs this file with ``gdb -batch -x``. GDB connects
to QEMU's gdbstub (QEMU started paused), stops at the boot loader's hand-off
to XNU, and then:

1. writes the boot arguments into ``boot_args.CommandLine``;
2. optionally sets the SIP configuration: the ``lp-sip0`` property of the
   device tree's ``/chosen/asmb`` node (renaming ``lp-stng`` if needed);
3. optionally rewrites the one pre-indexed GIC store in XNU's GIC setup
   that older host kernels cannot emulate;

and finally removes its breakpoint and detaches, which lets the guest run.

Large reads of guest physical memory go through QMP ``pmemsave`` into a
temporary file (the gdbstub is slow for 128 MiB); writes, which are a few
bytes each, go through the gdbstub. All checks happen before the first
write, so a refusal leaves guest memory untouched.

Settings come from the environment (set by inject-xnu-kvm.sh):
  XNU_HANDOFF_GDB_PORT    gdbstub port on 127.0.0.1
  XNU_HANDOFF_BOOT_ARGS   boot arguments
  XNU_HANDOFF_CSR         SIP configuration (integer, base prefix allowed);
                          empty = leave the device tree alone
  XNU_HANDOFF_MMIO_PATCH  1 = apply the GIC store correction, 0 = skip
  XNU_HANDOFF_QMP         QMP socket path (empty: read through the gdbstub)
  XNU_HANDOFF_STATUS      file that receives "ok" on success
  VMAPPLE_HANDOFF_PC      hand-off address [0xACA00000]

Layouts:
- boot_args (XNU pexpert/pexpert/arm64/boot.h, little-endian): Revision u16
  @0, Version u16 @2, virtBase u64 @8, physBase u64 @16, memSize u64 @24,
  topOfKernelData u64 @32, Boot_Video (6 x u64) @40, machineType u32 @88,
  deviceTreeP u64 @96, deviceTreeLength u32 @104, CommandLine char[608] @108.
- Apple device tree: a node is u32 property count, u32 child count, the
  properties, then the child nodes. A property is a 32-byte NUL-padded name,
  a u32 whose low 24 bits are the value's size, and the value padded to a
  multiple of 4 bytes. A node's name is its "name" property.

The pure functions below (parse_boot_args, plan_csr_edit, find_gic_store,
...) need no GDB and are what the offline tests exercise.
"""

import json
import os
import socket
import struct
import sys
import tempfile

DEFAULT_HANDOFF_PC = 0xACA00000

COMMAND_LINE_OFFSET = 108
COMMAND_LINE_SIZE = 608
BOOT_ARGS_SIZE = COMMAND_LINE_OFFSET + COMMAND_LINE_SIZE
MAX_DEVICE_TREE = 4 * 1024 * 1024

GIC_SEARCH_SIZE = 128 * 1024 * 1024
# movk w9, #0x7e00, lsl #16 ; str w9, [x8, #128]! ; mov w9, #0x8000000 ;
# str w9, [x8, #128]   -- the second store relies on the first's write-back.
GIC_SEQUENCE = (0x12AFC009, 0xB8080D09, 0x52A10009, 0xB9008109)
# The pre-indexed store becomes a plain one, and the second store gets the
# offset the write-back would have added: same two addresses, no write-back.
GIC_REPLACEMENT = {1: 0xB9008109, 3: 0xB9010109}

ADT_NAME_SIZE = 32
ADT_PROP_HEADER = ADT_NAME_SIZE + 4
ADT_SIZE_MASK = 0x00FFFFFF
ADT_MAX_COUNT = 1 << 16

MASK64 = (1 << 64) - 1


class HandoffError(Exception):
    """A refusal or failure, with a message for the user."""


# --------------------------------------------------------------------------
# boot_args

class BootArgs:
    def __init__(self, revision, version, virt_base, phys_base, mem_size,
                 device_tree_p, device_tree_length):
        self.revision = revision
        self.version = version
        self.virt_base = virt_base
        self.phys_base = phys_base
        self.mem_size = mem_size
        self.device_tree_p = device_tree_p
        self.device_tree_length = device_tree_length

    @property
    def device_tree_phys(self):
        return (self.device_tree_p - self.virt_base + self.phys_base) & MASK64

    def device_tree_plausible(self):
        return (self.virt_base <= self.device_tree_p < self.virt_base + self.mem_size
                and 0 < self.device_tree_length < MAX_DEVICE_TREE)

    def describe(self):
        return (f"revision {self.revision}, version {self.version}, "
                f"virtBase {self.virt_base:#x}, physBase {self.phys_base:#x}, "
                f"memSize {self.mem_size:#x}, deviceTreeP {self.device_tree_p:#x}, "
                f"deviceTreeLength {self.device_tree_length:#x}")


def parse_boot_args(raw):
    """Decode and check the boot_args header (at least 108 bytes)."""
    if len(raw) < COMMAND_LINE_OFFSET:
        raise HandoffError(f"boot_args read returned {len(raw)} bytes")
    revision, version = struct.unpack_from("<HH", raw, 0)
    virt_base, phys_base, mem_size = struct.unpack_from("<QQQ", raw, 8)
    (device_tree_p,) = struct.unpack_from("<Q", raw, 96)
    (device_tree_length,) = struct.unpack_from("<I", raw, 104)
    ba = BootArgs(revision, version, virt_base, phys_base, mem_size,
                  device_tree_p, device_tree_length)
    if (revision, version) == (2, 2):
        return ba  # macOS 13
    if (revision, version) == (3, 2):
        # macOS 26: accepted only while the revision-2 layout still fits.
        if not ba.device_tree_plausible():
            raise HandoffError(
                "boot_args revision 3 does not match the known layout "
                f"(device tree outside guest memory or bad length): {ba.describe()}")
        return ba
    raise HandoffError(f"unsupported boot_args: {ba.describe()} "
                       "(known: revision 2 version 2, revision 3 version 2)")


def encode_command_line(text):
    """The CommandLine field's 608 bytes: text, NUL, zero padding."""
    data = os.fsencode(text)
    if b"\0" in data:
        raise HandoffError("boot arguments contain a NUL byte")
    if len(data) >= COMMAND_LINE_SIZE:
        raise HandoffError(f"boot arguments are {len(data)} bytes; "
                           f"they must be shorter than {COMMAND_LINE_SIZE}")
    return data.ljust(COMMAND_LINE_SIZE, b"\0")


# --------------------------------------------------------------------------
# Apple device tree

class AdtProperty:
    def __init__(self, name, offset, size):
        self.name = name        # str
        self.offset = offset    # offset of the property header in the tree
        self.size = size        # value size (low 24 bits of the size word)

    @property
    def value_offset(self):
        return self.offset + ADT_PROP_HEADER


class AdtNode:
    def __init__(self, offset):
        self.offset = offset
        self.properties = []
        self.children = []
        self.name = None

    def prop(self, name):
        for p in self.properties:
            if p.name == name:
                return p
        return None

    def child(self, name):
        for c in self.children:
            if c.name == name:
                return c
        return None


def _u32(tree, off, what):
    if off < 0 or off + 4 > len(tree):
        raise HandoffError(f"device tree truncated reading {what} at offset {off:#x}")
    return struct.unpack_from("<I", tree, off)[0]


def parse_adt(tree, offset=0, depth=0):
    """Parse the node at offset; returns (node, offset just past its subtree)."""
    if depth > 64:
        raise HandoffError("device tree nested too deeply (corrupt?)")
    node = AdtNode(offset)
    nprops = _u32(tree, offset, "a property count")
    nchildren = _u32(tree, offset + 4, "a child count")
    if nprops > ADT_MAX_COUNT or nchildren > ADT_MAX_COUNT:
        raise HandoffError(f"implausible device tree node at {offset:#x} "
                           f"({nprops} properties, {nchildren} children)")
    off = offset + 8
    for _ in range(nprops):
        if off + ADT_PROP_HEADER > len(tree):
            raise HandoffError(f"device tree truncated in a property at {off:#x}")
        raw_name = bytes(tree[off:off + ADT_NAME_SIZE]).split(b"\0", 1)[0]
        size = _u32(tree, off + ADT_NAME_SIZE, "a property size") & ADT_SIZE_MASK
        if off + ADT_PROP_HEADER + size > len(tree):
            raise HandoffError(f"device tree property at {off:#x} runs past the end")
        prop = AdtProperty(raw_name.decode("ascii", "replace"), off, size)
        node.properties.append(prop)
        if prop.name == "name":
            value = bytes(tree[prop.value_offset:prop.value_offset + size])
            node.name = value.split(b"\0", 1)[0].decode("ascii", "replace")
        off += ADT_PROP_HEADER + ((size + 3) & ~3)
    for _ in range(nchildren):
        child, off = parse_adt(tree, off, depth + 1)
        node.children.append(child)
    return node, off


def plan_csr_edit(tree, csr):
    """Edits that put csr into /chosen/asmb lp-sip0.

    Returns (edits, note): edits is a list of (offset in tree, bytes)."""
    if not 0 <= csr <= MASK64:
        raise HandoffError(f"CSR configuration {csr:#x} does not fit in 64 bits")
    root, _ = parse_adt(tree)
    chosen = root.child("chosen")
    if chosen is None:
        raise HandoffError("device tree has no /chosen node")
    asmb = chosen.child("asmb")
    if asmb is None:
        names = ", ".join(c.name or "?" for c in chosen.children) or "none"
        raise HandoffError(f"device tree has no /chosen/asmb node (children: {names})")
    target = asmb.prop("lp-sip0")
    renamed = False
    if target is None:
        target = asmb.prop("lp-stng")
        renamed = True
        if target is None:
            raise HandoffError("/chosen/asmb has neither lp-sip0 nor lp-stng")
    if target.size != 8:
        raise HandoffError(f"/chosen/asmb {target.name} is {target.size} bytes, expected 8")
    edits = []
    if renamed:
        edits.append((target.offset, b"lp-sip0".ljust(ADT_NAME_SIZE, b"\0")))
    edits.append((target.value_offset, struct.pack("<Q", csr)))
    note = "lp-stng renamed to lp-sip0" if renamed else "lp-sip0 replaced"
    return edits, note


# --------------------------------------------------------------------------
# GIC store

def gic_sequence_bytes():
    return struct.pack("<4I", *GIC_SEQUENCE)


def find_gic_store(memory):
    """Offset of the single occurrence of the GIC store sequence."""
    pattern = gic_sequence_bytes()
    found = []
    start = 0
    while True:
        i = memory.find(pattern, start)
        if i < 0:
            break
        found.append(i)
        start = i + 1
    if len(found) != 1:
        raise HandoffError(f"GIC store sequence found {len(found)} times in the first "
                           f"{len(memory) // (1024 * 1024)} MiB of guest memory; "
                           "expected exactly 1")
    if found[0] % 4:
        raise HandoffError(f"GIC store sequence at unaligned offset {found[0]:#x}")
    return found[0]


def gic_edits(offset):
    """(offset, bytes) writes that apply the correction at offset."""
    return [(offset + 4 * word, struct.pack("<I", value))
            for word, value in sorted(GIC_REPLACEMENT.items())]


def parse_int(text, what):
    try:
        return int(text, 0)
    except (TypeError, ValueError):
        raise HandoffError(f"{what} is not an integer (base prefix allowed): {text!r}") from None


# --------------------------------------------------------------------------
# QMP

class Qmp:
    """Minimal QMP client: greeting, qmp_capabilities, commands; skips events."""

    def __init__(self, path, timeout=120):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        try:
            self.sock.connect(path)
        except OSError as e:
            self.sock.close()
            raise HandoffError(f"cannot connect to QMP socket {path}: {e}") from None
        self.stream = self.sock.makefile("rwb")
        greeting = self._receive()
        if "QMP" not in greeting:
            self.close()
            raise HandoffError(f"unexpected QMP greeting: {greeting!r}")
        self.command("qmp_capabilities")

    def _receive(self):
        try:
            line = self.stream.readline()
        except OSError as e:
            raise HandoffError(f"QMP read failed: {e}") from None
        if not line:
            raise HandoffError("QMP connection closed")
        try:
            return json.loads(line)
        except ValueError:
            raise HandoffError(f"QMP sent something that is not JSON: {line[:200]!r}") from None

    def command(self, name, arguments=None):
        message = {"execute": name}
        if arguments is not None:
            message["arguments"] = arguments
        try:
            self.stream.write(json.dumps(message).encode() + b"\n")
            self.stream.flush()
        except OSError as e:
            raise HandoffError(f"QMP write failed: {e}") from None
        while True:
            reply = self._receive()
            if "event" in reply:
                continue
            if "error" in reply:
                err = reply["error"]
                raise HandoffError(f"QMP {name} failed: {err.get('desc', err)}")
            if "return" in reply:
                return reply["return"]

    def close(self):
        try:
            self.stream.close()
        finally:
            self.sock.close()


def qmp_read_physical(qmp, address, size):
    """Guest physical memory via pmemsave into a private temporary file."""
    fd, path = tempfile.mkstemp(prefix="xnu-handoff-", suffix=".bin")
    os.close(fd)
    try:
        qmp.command("pmemsave", {"val": address, "size": size, "filename": path})
        with open(path, "rb") as f:
            data = f.read()
    finally:
        os.unlink(path)
    if len(data) != size:
        raise HandoffError(f"pmemsave at {address:#x} returned {len(data)} of {size} bytes")
    return data


# --------------------------------------------------------------------------
# GDB driver

def _say(message):
    print(f"xnu-handoff: {message}", flush=True)


class Settings:
    def __init__(self, env):
        port = env.get("XNU_HANDOFF_GDB_PORT", "")
        if not port.isdigit():
            raise HandoffError(f"bad gdbstub port {port!r}")
        self.port = int(port)
        self.boot_args = env.get("XNU_HANDOFF_BOOT_ARGS", "")
        self.command_line = encode_command_line(self.boot_args)
        csr = env.get("XNU_HANDOFF_CSR", "")
        self.csr = parse_int(csr, "CSR_CONFIG") if csr != "" else None
        if self.csr is not None and not 0 <= self.csr <= MASK64:
            raise HandoffError(f"CSR_CONFIG {csr} does not fit in 64 bits")
        mmio = env.get("XNU_HANDOFF_MMIO_PATCH", "1")
        if mmio not in ("0", "1"):
            raise HandoffError(f"KVM_MMIO_PATCH must be 0 or 1, not {mmio!r}")
        self.mmio_patch = mmio == "1"
        self.qmp = env.get("XNU_HANDOFF_QMP", "")
        self.status_file = env.get("XNU_HANDOFF_STATUS", "")
        pc = env.get("VMAPPLE_HANDOFF_PC", "")
        self.handoff_pc = parse_int(pc, "VMAPPLE_HANDOFF_PC") if pc else DEFAULT_HANDOFF_PC


class GdbSession:
    def __init__(self, gdb):
        self.gdb = gdb

    def run(self, command):
        try:
            return self.gdb.execute(command, to_string=True)
        except self.gdb.error as e:
            raise HandoffError(f"gdb '{command}' failed: {e}") from None

    def register(self, name):
        try:
            return int(self.gdb.parse_and_eval(f"(unsigned long long)${name}")) & MASK64
        except self.gdb.error as e:
            raise HandoffError(f"cannot read register {name}: {e}") from None

    def read(self, address, size):
        try:
            return bytes(self.gdb.selected_inferior().read_memory(address, size))
        except self.gdb.error as e:
            raise HandoffError(f"cannot read {size} bytes at {address:#x}: {e}") from None

    def write(self, address, data):
        try:
            self.gdb.selected_inferior().write_memory(address, data)
        except self.gdb.error as e:
            raise HandoffError(f"cannot write {len(data)} bytes at {address:#x}: {e}") from None
        if self.read(address, len(data)) != data:
            raise HandoffError(f"write at {address:#x} did not stick")

    def read_large(self, address, size, chunk=1 << 16):
        parts = []
        for off in range(0, size, chunk):
            parts.append(self.read(address + off, min(chunk, size - off)))
        return b"".join(parts)


def connect(session, port, timeout=15):
    # GDB itself retries a refused connection until "tcp connect-timeout"
    # expires (tcp auto-retry), so one attempt with a bounded timeout is all
    # that is needed; a loop around it would multiply the wait.
    session.run("set tcp auto-retry on")
    session.run(f"set tcp connect-timeout {timeout}")
    try:
        session.gdb.execute(f"target remote 127.0.0.1:{port}", to_string=True)
    except session.gdb.error as e:
        raise HandoffError(f"cannot connect to QEMU's gdbstub on 127.0.0.1:{port} "
                           f"within {timeout} s: {e}") from None


def run_handoff(gdb, settings):
    s = GdbSession(gdb)
    for command in ("set pagination off", "set confirm off", "set width 0",
                    "set remotetimeout 60"):
        s.run(command)
    connect(s, settings.port)
    _say(f"connected to 127.0.0.1:{settings.port}; waiting for the second "
         f"arrival at the hand-off {settings.handoff_pc:#x}")
    s.run(f"hbreak *{settings.handoff_pc:#x}")
    # The hand-off address is executed once before the real hand-off.
    for arrival in (1, 2):
        s.run("continue")
        pc = s.register("pc")
        if pc != settings.handoff_pc:
            raise HandoffError(f"guest stopped at {pc:#x} (arrival {arrival}), "
                               f"not at the hand-off {settings.handoff_pc:#x}")

    boot_args_addr = s.register("x1")
    ba = parse_boot_args(s.read(boot_args_addr, BOOT_ARGS_SIZE))
    _say(f"boot_args at {boot_args_addr:#x}: {ba.describe()}")

    qmp = None

    def read_physical(address, size):
        nonlocal qmp
        if not settings.qmp:
            return s.read_large(address, size)
        if qmp is None:
            qmp = Qmp(settings.qmp)
        return qmp_read_physical(qmp, address, size)

    # Plan every write first; only then touch guest memory.
    writes = []   # (address, bytes, description)
    writes.append((boot_args_addr + COMMAND_LINE_OFFSET, settings.command_line,
                   f"boot-args: '{settings.boot_args}'"))
    try:
        csr_line = "csr: not changed (CSR_CONFIG empty)"
        if settings.csr is not None:
            if not ba.device_tree_plausible():
                raise HandoffError(f"device tree location implausible: {ba.describe()}")
            dt_phys = ba.device_tree_phys
            tree = read_physical(dt_phys, ba.device_tree_length)
            edits, note = plan_csr_edit(tree, settings.csr)
            for off, data in edits:
                # The gdbstub sees guest-virtual memory; at the hand-off the
                # MMU is off, so it must show the same bytes as pmemsave.
                if s.read(dt_phys + off, len(data)) != tree[off:off + len(data)]:
                    raise HandoffError("gdbstub and physical views of the device tree "
                                       "differ (MMU on at the hand-off?)")
                writes.append((dt_phys + off, data, None))
            csr_line = (f"csr: /chosen/asmb lp-sip0 = {settings.csr:#x} ({note}, "
                        f"device tree at {dt_phys:#x}, {ba.device_tree_length} bytes)")

        mmio_line = "mmio: GIC store correction skipped (KVM_MMIO_PATCH=0)"
        if settings.mmio_patch:
            memory = read_physical(ba.phys_base, GIC_SEARCH_SIZE)
            off = find_gic_store(memory)
            address = ba.phys_base + off
            if s.read(address, 16) != gic_sequence_bytes():
                raise HandoffError(f"gdbstub view at {address:#x} does not show the "
                                   "GIC store sequence (MMU on at the hand-off?)")
            for edit_off, data in gic_edits(off):
                writes.append((ba.phys_base + edit_off, data, None))
            mmio_line = (f"mmio: GIC store sequence found once at {address:#x}; "
                         "patched (pre-indexed str w9,[x8,#128]! -> str w9,[x8,#128]; "
                         "str w9,[x8,#128] -> str w9,[x8,#256])")
    finally:
        if qmp is not None:
            qmp.close()

    for address, data, description in writes:
        s.write(address, data)
        if description:
            _say(description)
    _say(csr_line)
    _say(mmio_line)

    s.run("delete")
    s.run("detach")
    _say("breakpoint removed, gdbstub detached; the guest is running")


def gdb_main():
    import gdb  # only available inside GDB

    status_file = os.environ.get("XNU_HANDOFF_STATUS", "")
    try:
        settings = Settings(os.environ)
        run_handoff(gdb, settings)
    except HandoffError as e:
        print(f"error: {e}", file=sys.stderr, flush=True)
        return
    except Exception as e:  # report anything unexpected the same way
        print(f"error: unexpected {type(e).__name__}: {e}", file=sys.stderr, flush=True)
        return
    if status_file:
        with open(status_file, "w") as f:
            f.write("ok\n")


if __name__ == "__main__":
    try:
        import gdb  # noqa: F401
    except ImportError:
        print("error: this file is run inside GDB by scripts/inject-xnu-kvm.sh", file=sys.stderr)
        sys.exit(2)
    gdb_main()

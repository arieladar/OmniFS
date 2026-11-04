#!/usr/bin/env python3
"""Builds the OmniFS guest VM (Linux kernel + initramfs) from Alpine Linux aarch64 packages.

The guest mounts the attached partition with the Linux kernel's own filesystem drivers
(ntfs3, ext4, btrfs, xfs, f2fs, udf, OpenZFS) and shares it with macOS over SMB (Samba with vfs_fruit).
Runs on macOS without Docker.

Usage: scripts/build_vm_image.py [output_dir]   (default: .build/vm)
"""
import gzip
import io
import os
import shutil
import struct
import subprocess
import sys
import tarfile
import urllib.request
import zlib

ALPINE = "https://dl-cdn.alpinelinux.org/alpine/v3.24"
REPOS = ["main", "community"]
ARCH = "aarch64"

PACKAGES = ["linux-virt", "busybox", "musl", "kmod", "e2fsprogs", "ntfs-3g-progs", "btrfs-progs", "xfsprogs", "zfs", "zfs-virt", "f2fs-tools", "udftools", "samba-server", "samba-common-tools"]
# Dependencies that are irrelevant inside the guest
SKIP = {"python3", "initramfs-generator", "/bin/sh"}
MODULES = ["virtio_blk", "virtio_net", "virtio-rng", "af_packet", "ext4", "btrfs", "xfs", "ntfs3", "f2fs", "udf"]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "vm")
CACHE = os.path.join(ROOT, ".build", "vm-cache")


def fetch(url, dest, attempts=4):
    if not os.path.exists(dest):
        print(f"  downloading {url.rsplit('/', 1)[-1]}")
        for attempt in range(1, attempts + 1):
            try:
                with urllib.request.urlopen(url, timeout=60) as r, open(dest + ".part", "wb") as f:
                    shutil.copyfileobj(r, f)
                break
            except OSError as error:
                if attempt == attempts:
                    raise
                print(f"    retrying ({error})")
        os.rename(dest + ".part", dest)
    return dest


def load_index():
    packages, provides = {}, {}
    for repo in REPOS:
        path = fetch(f"{ALPINE}/{repo}/{ARCH}/APKINDEX.tar.gz", os.path.join(CACHE, f"APKINDEX-{repo}.tar.gz"))
        with tarfile.open(path) as t:
            text = t.extractfile("APKINDEX").read().decode()
        for block in text.strip().split("\n\n"):
            fields = {}
            for line in block.splitlines():
                key, _, value = line.partition(":")
                fields.setdefault(key, value)
            pkg = {"name": fields["P"], "version": fields["V"], "repo": repo,
                   "deps": fields.get("D", "").split(), "provides": fields.get("p", "").split()}
            if pkg["name"] in packages:
                continue
            packages[pkg["name"]] = pkg
            for p in pkg["provides"]:
                provides.setdefault(p.split("=")[0], pkg["name"])
    return packages, provides


def resolve(packages, provides):
    wanted, queue = set(), list(PACKAGES)
    while queue:
        dep = queue.pop()
        if dep.startswith("!"):
            continue
        name = dep.split(">")[0].split("<")[0].split("=")[0].split("~")[0]
        if name in SKIP:
            continue
        name = name if name in packages else provides.get(name)
        if name is None:
            sys.exit(f"error: cannot resolve dependency {dep}")
        if name not in wanted:
            wanted.add(name)
            queue.extend(packages[name]["deps"])
    return sorted(wanted)


def extract_kernel(vmlinuz, dest):
    """Unwraps the EFI zboot (zimg) container into the raw arm64 Image Virtualization.framework boots."""
    data = open(vmlinuz, "rb").read()
    if data[4:8] == b"zimg":
        offset, size = struct.unpack_from("<II", data, 8)
        data = zlib.decompress(data[offset:offset + size], 16 + zlib.MAX_WBITS)
    if data[0x38:0x3C] != b"ARM\x64":
        sys.exit("error: kernel is not an arm64 Image")
    open(dest, "wb").write(data)


def prune_modules(rootfs):
    """Keeps only the modules OmniFS needs, plus crypto/lib helpers the kernel requests by name at
    runtime (e.g. crc32c for ext4/btrfs). The guest regenerates the module indexes with depmod at boot."""
    (kver,) = os.listdir(os.path.join(rootfs, "lib", "modules"))
    moddir = os.path.join(rootfs, "lib", "modules", kver)
    deps = {}
    for line in open(os.path.join(moddir, "modules.dep")):
        mod, _, rest = line.partition(":")
        deps[mod] = rest.split()

    by_name = {os.path.basename(m).split(".ko")[0].replace("-", "_"): m for m in deps}
    keep = set()
    for name in MODULES:
        path = by_name[name.replace("-", "_")]
        keep.add(path)
        keep.update(deps[path])

    runtime = ("kernel/crypto/", "kernel/lib/", "kernel/arch/")
    for mod in deps:
        if mod.startswith(runtime):
            keep.add(mod)
            keep.update(deps[mod])

    for dirpath, _, files in os.walk(moddir, topdown=False):
        for f in files:
            rel = os.path.relpath(os.path.join(dirpath, f), moddir)
            if rel.startswith("kernel/") and rel not in keep:
                os.remove(os.path.join(dirpath, f))
        if not os.listdir(dirpath):
            os.rmdir(dirpath)


def strip_module_debug_info(path):
    """Drops debug sections from a gzipped out-of-tree kernel module (zfs.ko ships ~100 MB of DWARF).

    No objcopy for Linux ELF exists on a stock Mac, so the .debug_* sections and their relocations keep their
    headers (section indexes stay valid for symbols and relocations) but get size 0 and their bytes are dropped.
    The kernel never loads or relocates non-allocated sections. The module signature is lost; this kernel does not
    enforce signatures, it only marks itself tainted.
    """
    elf = bytearray(gzip.open(path).read())
    if elf[:4] != b"\x7fELF" or elf[4] != 2 or elf[5] != 1:  # 64-bit little-endian only
        return
    shoff, = struct.unpack_from("<Q", elf, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", elf, 0x3A)
    headers = [list(struct.unpack_from("<IIQQQQIIQQ", elf, shoff + i * shentsize)) for i in range(shnum)]
    strtab_offset = headers[shstrndx][4]

    def name(h):
        start = strtab_offset + h[0]
        return bytes(elf[start:elf.index(b"\0", start)]).decode()

    out = bytearray(elf[:0x40])
    for h in headers:
        sh_type, size = h[1], h[5]
        if name(h).startswith((".debug", ".rela.debug", ".rel.debug")):
            h[4], h[5] = 0, 0
        elif sh_type != 8 and size:  # SHT_NOBITS has no file data
            align = max(h[8], 1)
            out += b"\0" * (-len(out) % align)
            data = elf[h[4]:h[4] + size]
            h[4] = len(out)
            out += data
    out += b"\0" * (-len(out) % 8)
    struct.pack_into("<Q", out, 0x28, len(out))
    for h in headers:
        out += struct.pack("<IIQQQQIIQQ", *h)
    with gzip.open(path, "wb", compresslevel=9) as f:
        f.write(out)


def main():
    os.makedirs(CACHE, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    print("[1/4] Resolving Alpine packages...")
    packages, provides = load_index()
    names = resolve(packages, provides)
    print(f"  {len(names)} packages: {' '.join(names)}")

    print("[2/4] Extracting packages...")
    rootfs = os.path.join(CACHE, "rootfs")
    shutil.rmtree(rootfs, ignore_errors=True)
    os.makedirs(rootfs)
    for name in names:
        pkg = packages[name]
        filename = f"{name}-{pkg['version']}.apk"
        apk = fetch(f"{ALPINE}/{pkg['repo']}/{ARCH}/{filename}", os.path.join(CACHE, filename))
        # An .apk is concatenated gzip tar segments (signature, control, data) that read as one tar stream
        with tarfile.open(fileobj=io.BytesIO(gzip.open(apk).read())) as t:
            members = [m for m in t.getmembers() if not m.name.startswith(".")]
            t.extractall(rootfs, members=members, filter="tar")

    print("[3/4] Preparing kernel and modules...")
    extract_kernel(os.path.join(rootfs, "boot", "vmlinuz-virt"), os.path.join(OUT, "Image"))
    shutil.rmtree(os.path.join(rootfs, "boot"))
    prune_modules(rootfs)
    for dirpath, _, files in os.walk(os.path.join(rootfs, "lib", "modules")):
        for f in files:
            if f.endswith(".ko.gz") and "/extra" in dirpath:
                strip_module_debug_info(os.path.join(dirpath, f))
    for d in ["usr/share/man", "usr/share/doc", "usr/include", "usr/share/apk", "lib/apk"]:
        shutil.rmtree(os.path.join(rootfs, d), ignore_errors=True)
    for d in ["proc", "sys", "dev", "run", "tmp", "exports", "etc"]:
        os.makedirs(os.path.join(rootfs, d), exist_ok=True)
    # Samba authenticates the Mac as "omnifs" (it needs a Unix account) and serves files as root ("force user")
    with open(os.path.join(rootfs, "etc", "passwd"), "w") as f:
        f.write("root:x:0:0:root:/root:/bin/sh\nomnifs:x:1000:1000:OmniFS:/:/sbin/nologin\n"
                "nobody:x:65534:65534:nobody:/:/sbin/nologin\n")
    with open(os.path.join(rootfs, "etc", "group"), "w") as f:
        f.write("root:x:0:\nomnifs:x:1000:\nnobody:x:65534:\n")
    # ZFS records the importing host's ID in the pool; a fixed ID keeps pools imported by one OmniFS VM
    # importable by the next instead of looking "in use from another system"
    with open(os.path.join(rootfs, "etc", "hostid"), "wb") as f:
        f.write(struct.pack("<I", 0x0F5F5F01))
    shutil.copy(os.path.join(ROOT, "Resources", "vm", "init"), os.path.join(rootfs, "init"))
    os.chmod(os.path.join(rootfs, "init"), 0o755)

    print("[4/4] Packing initramfs...")
    initramfs = os.path.join(OUT, "initramfs.cpio.gz")
    with open(initramfs, "wb") as out:
        cpio = subprocess.Popen(["bsdtar", "--format", "newc", "--uid", "0", "--gid", "0", "-cf", "-", "-C", rootfs, "."],
                                stdout=subprocess.PIPE)
        subprocess.run(["gzip", "-9"], stdin=cpio.stdout, stdout=out, check=True)
        if cpio.wait() != 0:
            sys.exit("error: bsdtar failed")
    for f in ("Image", "initramfs.cpio.gz"):
        print(f"  {os.path.join(OUT, f)}  ({os.path.getsize(os.path.join(OUT, f)) // (1 << 20)} MB)")


if __name__ == "__main__":
    main()

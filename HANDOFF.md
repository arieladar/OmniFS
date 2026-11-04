# OmniFS — session handoff (2026-11-03)

State of the work at the end of the session, so it can be resumed after a macOS update.
Nothing below is committed yet; everything is in the working tree (see "Uncommitted changes").

## Where things stand

**Read & write for NTFS works**, verified on the real drive (Samsung T7 Shield, `disk4s1`, "Ariel Adar"):
mounted read-write from the System Settings pane with a single macOS authorization, files written,
read back and deleted.

Architecture (no FUSE, no kext, nothing runs as root):

1. `MountManager` unmounts macOS's own read-only NTFS mount, then launches `omnifs-vmd` as the user.
2. `omnifs-vmd` (Sources/OmniFSVMHelper) opens the raw partition. macOS 27 refuses `chown` of
   `/dev/disk*` even for root, so the device is opened via `/usr/libexec/authopen` (one macOS
   authorization dialog), which passes the descriptor back over SCM_RIGHTS.
3. It boots a tiny Alpine Linux VM (Virtualization.framework) with the partition attached as virtio-blk.
   The guest (`Resources/vm/init`) mounts it with the Linux kernel driver (ntfs3 / ext4 / btrfs / xfs)
   and exports it over NFSv3 as `/exports/<volume name>` (Finder names the volume after this path).
4. `MountManager` mounts the export with `mount_nfs ... noowners` at
   `~/Library/Application Support/OmniFS/Volumes/<name>` (`/Volumes` is root-only). Finder lists it
   like any disk.
5. Unmount/eject (OmniFS ⏏, Finder, `omnifs unmount`) is detected by the helper, which shuts the guest
   down cleanly (sync + umount) and exits.

State files: `$TMPDIR/OmniFS/` — `<bsd>.json` (helper state), `<bsd>.log` (guest console),
`omnifs.log` (persistent step-by-step trace of every VM mount attempt; read this first when debugging).

## What works (verified)

| Area | Status |
|---|---|
| Native mounts (FAT/exFAT, NTFS read-only) | ✅ (was broken: `-mountPoint` into root-only `/Volumes`) |
| NTFS read-write via VM | ✅ real drive + images |
| ext4 read-write via VM | ✅ images (format, write, 100 MB checksum across VM restart) |
| ext2, ext3, Btrfs, XFS | ✅ integration tests (images); VM includes btrfs-progs and xfsprogs |
| Finder copy in/out, move within volume | ✅ |
| Finder **Move to Trash** | ❌ macOS gives network (NFS) volumes no Trash: `trashItem` → "volume doesn't have one" (dirNFErr). Workaround: ⌥⌘⌫ Delete Immediately |
| Pane auto-refresh, drive-type icons (NVMe/SSD/HDD/flash/SD/image), MSR partition hidden | ✅ |
| Unit tests | ✅ 11/11 (needs the CLT workaround below) |

## Open decision: FSKit (needed for a real Trash)

A real Trash, `/Volumes` placement, disk icons and no `._` files need OmniFS volumes to be **local**
volumes, i.e. an FSKit module (`UnaryFileSystemExtension`, generic-URL resource like Apple's
`com.apple.fskit.ftp`) that forwards file operations to the VM instead of NFS.

Experiment done this session (test module since removed):
- FSKit headers/Swift module are in the Command Line Tools SDK; a minimal module compiled with `swiftc`.
- macOS registered the ad-hoc-signed module (`lsregister -f -R -trusted <app>` + pluginkit) and fskitd
  recognised it, but reported "Module … is disabled!" and the **System Settings toggle is greyed out**:
  enabling requires a real Apple signing certificate. This Mac has none
  (`security find-identity -v -p codesigning` → 0).
- Next step if pursued: install Xcode, sign in with an Apple ID (free personal team → development
  certificate), re-run the probe to see whether the toggle can be enabled. Distribution to other Macs
  needs the paid Developer Program (Developer ID + notarization).

Follow-up (after the macOS 27.3 update): Xcode 27.2 installed, Apple ID added as a **Personal Team**
(team `T97X889J99`). The Apple Development certificate only became valid after importing Apple's
WWDR G3 intermediate into the login keychain. Building the probe as an Xcode project with automatic
signing then failed with Apple's own verdict: *"Personal development teams … do not support the FSKit
Module capability."* **FSKit requires a paid Apple Developer Program membership.**

**Decision (user): not enrolling.** The Linux VM stays. If FSKit is revisited later, the user wants an
FSKit-only design (no VM/FUSE/kext) starting with read-only support for all filesystems — which means
writing NTFS/ext4/Btrfs/XFS implementations in Swift.

## Deep review (later the same day)

A high-effort review found 10 issues, all fixed:
- Per-partition cross-process operation lock (`VMMountRegistry.acquireOperationLock`, flock on
  `$TMPDIR/OmniFS/<bsd>.lock`): a second mount from the pane/app/CLI could otherwise start a second VM on
  the same device (two kernels writing one filesystem).
- `wasMountedNatively` computed before tearing down an existing VM mount (RO→RW remount of a VM volume).
- Native RO path: refuses if the VM mount can't be torn down; re-inspects the partition afterwards.
- `mount_nfs` failure / start timeout: waits for the helper to release the device before remounting natively.
- Helper force-unmounts the NFS mount if the guest dies (no hung Finder); NFS mounted with `intr`.
- `unmountVM` is async (`Task.sleep`), waits longer than the helper's 30 s force-stop.
- AutoMountService never "upgrades" volumes the user VM-mounted read-only.
- DiskScanner's whole-disk cache is per scan (BSD names get reused).
- Guest reports its real export path in `OMNIFS_READY ip=… export=…`.
- Pane refresh: newest scan wins; background polling compares a cheap storage signature
  (`VMMountRegistry.storageSignature`) and only rescans on change.

## Tests

- Unit tests: `swift test` (works directly now that Xcode is installed).
- Integration tests (real NTFS, ext2, ext3, ext4, Btrfs and XFS disk images through the VM — detection, copy in/out, move, rename,
  delete, ownership, persistence across remount, read-only, external eject, concurrent-mount lock, Trash as
  a known issue; ~150 s): sign the helper after building, then
  `OMNIFS_INTEGRATION=1 swift test --filter VolumeIntegrationTests`. All passing on all six filesystems.

## Other known limitations

- macOS writes `._name` AppleDouble files for files with extended attributes (NFS has no xattrs).
- NTFS volumes left dirty by Windows hibernation / Fast Startup are refused read-write (message explains).
- If `omnifs-vmd` crashes while mounted, Finder can hang on that volume until force-unmounted (hard NFS mount).
- Mount Options tab toggles are not persisted or wired up; `AutoMountService` is never started.
- Before rebooting / updating macOS, **eject VM-served volumes** so the guest unmounts NTFS cleanly
  (an abrupt stop leaves the NTFS volume dirty, and it will then only mount read-only until repaired).

## Development notes

- Build guest VM: `python3 -I scripts/build_vm_image.py` → `.build/vm/{Image,initramfs.cpio.gz}`
  (Alpine v3.24 aarch64 packages: Linux 6.18 LTS `linux-virt`, built on macOS, no Docker; Alpine ships only LTS kernels for VMs, mainline 7.x would need a self-built kernel). Debug guest boot with `OMNIFS_DEBUG=1`.
- After every `swift build`, sign the dev helper or the VM won't start:
  `codesign -s - -f --entitlements Resources/vm/omnifs-vmd.entitlements .build/debug/omnifs-vmd`
  (`install.sh` / `build_dmg.sh` sign automatically; never use `--deep`, it drops the entitlement).
- Tests with Command Line Tools only (not needed now that Xcode is installed):
  ```
  F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  swift test -Xswiftc -F -Xswiftc $F -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F
  ```
- Safe test volumes: raw image files attached with
  `hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount <img>` (user-owned `/dev/diskN`,
  no authorization needed), then `omnifs mount diskN --rw [--mountpoint <dir>]`.
  `omnifs-vmd --format` creates ext4/NTFS test volumes (image files only).
- `install.sh` quits System Settings / its legacyLoader (a loaded pref pane keeps old code) and removes
  binaries before copying (overwriting a running `omnifs-vmd` in place could crash a live mount).

## Uncommitted changes

Modified: Package.swift, build_dmg.sh, install.sh, Sources/OmniFSCLI/main.swift,
Sources/OmniFSCore/{AutoMountService,DiskPartition,DiskScanner,MountManager,SettingsViews}.swift,
Sources/OmniFSPrefPane/OmniFSPrefPane.swift, Sources/OmniFSSettings/main.swift, Tests/OmniFSTests/OmniFSTests.swift.

New: HANDOFF.md, Resources/Info-{App,PrefPane}.plist, Resources/vm/{init,omnifs-vmd.entitlements},
Sources/OmniFSCore/{DriveKind,VMMountRegistry}.swift, Sources/OmniFSVMHelper/main.swift,
scripts/build_vm_image.py.

## ZFS, Btrfs subvolumes, Check & Repair (later the same day)

- **ZFS** (OpenZFS 2.4.4, Alpine `zfs` + `zfs-virt`): detected by the uberblock magic at 128 KB (pool name from
  the label's XDR nvlist) or the "ZFS" partition type; the guest imports the pool (`-o readonly=on` for RO,
  retries with `-f` only for "in use from another system"), mounts all datasets, rbinds the root dataset to the
  export path and exports child datasets with `nohide`; eject runs `zpool export`. Fixed `/etc/hostid`. ARC
  capped at 256 MB. zfs.ko ships ~100 MB of DWARF: `build_vm_image.py` zero-sizes `.debug*` sections (no
  objcopy for ELF on macOS); the unsigned module only taints the kernel (MODULE_SIG_FORCE is off).
  Encrypted datasets are not supported. ZFS's 8 MB reserved partition (6A945A3B-…) is hidden like MSR.
- **Btrfs** is mounted at the top level (`subvolid=5`): every subvolume/snapshot is a folder.
- **Check & Repair** (`MountManager.repair`, pane: Mount menu / right-click, CLI `omnifs repair <disk>`):
  unmounts, runs the checker in the guest (`omnifs.action=repair`; helper `--repair`), remounts as before.
  e2fsck -f -y; ntfsfix -d (clears dirty; full repair still needs chkdsk); xfs_repair (log replayed by a
  mount first); btrfs check --readonly only (btrfs repair is unsafe); zpool scrub.
- Dev builds: with Xcode installed SwiftPM builds into `.build/out/Products/Debug`; the helper now finds
  `.build/vm` by walking up to `.build` (it had silently fallen back to the *installed* VM image).
- Not supported, by design/feasibility: "NFS" is a network protocol, not a disk format (macOS mounts NFS shares
  natively); QFS / SAM-FS have no Linux driver.
- Btrfs/XFS/ZFS/ext tested on images only; only NTFS has been tested on a physical drive.
- **F2FS** (kernel `f2fs`, `f2fs-tools`): detected by magic 0xF2F52010 at 1 KB (label: UTF-16 at sb+124);
  read & write via the VM; Check & Repair with `fsck.f2fs -f -y`.
- **UDF** (kernel `udf`, `udftools`): detected by the NSR02/NSR03 volume recognition sequence at 32 KB;
  read-only via macOS's own driver, read & write (UDF ≤ 2.01) via the VM. No checker exists, so no Check & Repair.
- Not possible: ReFS (no free driver); SMB/CIFS, S3FS, HDFS are network storage, not disk formats.

## Transport switched from NFS to SMB (2026-11-03, late)

**Supersedes the NFS details above** (mount_nfs, `noowners`/locking notes, ~/Library/Application Support mount
points, `._` files).
- Finder could not delete on mount_nfs mounts; NetFS (Connect to Server) mounts can, but NetFS NFS mounts
  always use NLM network locking, and NLM between the Mac and the guest stalls the first open ~95 s or hangs
  forever on hard mounts (a stuck mount even wedged a diskarbitrationd thread until a reboot).
- Now: guest runs in-kernel **ksmbd** (`ksmbd-tools`); one share per volume named after it, `force user = root`,
  per-VM random password (helper → guest over the console, → MountManager via the
  0600 state file). MountManager mounts `smb://<ip>/<share>` through NetFS into /Volumes (MNT_IGNORE_OWNERSHIP).
  NFS server, rpcbind and statd were removed from the image.
- Measured on an M4 / NTFS test disk: mount 1.4 s, first open 0.01 s, 400 MB write+fsync 688 MB/s, unmount
  incl. VM shutdown 1.9 s. Finder delete: "delete immediately"
  prompt (network volumes have no Trash).
- VM: all cores (`activeProcessorCount`), memory = 1/4 of RAM (1–8 GB), ZFS ARC = half of guest RAM.
- Unmount of mount points uses `umount` (~1 s) before diskutil (~6 s).
- Tests: `diskutil image attach` (hdiutil was ~2 min/attach while diskarbitrationd was wedged); cases run in
  parallel; 3-minute per-test limit; always run with a stall watchdog.
- No `streams_xattr`: ksmbd marks the whole inode delete-pending while a stream is deleted, so macOS copies
  (copyfile replaces the new file's auto-added com.apple.provenance stream) failed with EACCES
  (STATUS_DELETE_PENDING). Without streams macOS uses `._` files again. Samba with vfs_fruit would avoid this
  but roughly doubles the image.

## Final transport: Samba (2026-11-04)

**Supersedes the ksmbd details above.** ksmbd broke macOS: deleting a file's stream marks the whole file
delete-pending (copies with xattrs failed EACCES) and it refuses renaming folders whose files the Mac still has
open. Now the guest runs **Samba 4.23 with `vfs_fruit`** (`catia fruit streams_xattr`, `fruit:metadata=stream`,
`fruit:posix_rename`), so Mac metadata is stored natively (no `._` files, except on UDF, whose share disables
streams). Image: 33 MB (adds `samba-server`, `samba-common-tools`).
- Guest needs a resolvable hostname (`hostname omnifs` + /etc/hosts): Samba looks itself up on every connection
  and each lookup otherwise waited 5 s, so macOS gave up connecting.
- `smb2 leases = no`: with leases the Mac reuses a file's lease key after its folder is renamed, Samba rejects
  it, and writes in a just-renamed folder fail (EINVAL). Without leases a folder rename can be refused for ~1 s
  right after its files were used; retrying works (tests retry for up to 5 s).
- MAC addresses come from a per-user pool of 64 slots (least recently used first): random MACs exhausted the
  NAT's 253 DHCP leases (~1 h each) after a few parallel test runs, and reusing a slot the instant its VM exited
  sometimes got no DHCP answer.
- MountManager retries unmounts that report busy (up to 10 s) and NetFS mounts reset by a just-started Samba.
- Measured on M4: write 400 MB + fsync ~650–750 MB/s, mount ~1.5 s, unmount incl. VM shutdown ~2 s.
- Integration suite: all 10 tests (9 filesystems) pass in ~2.5 min with at most 5 disks at a time.


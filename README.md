# OmniFS
### Read & write Linux, Windows and Unix filesystems on macOS (Apple Silicon)

OmniFS mounts foreign filesystems **read & write** on macOS, with no kernel extensions, no FUSE and no
reduced system security:

* **Windows**: `NTFS` (macOS itself only reads NTFS)
* **Linux**: `ext2`, `ext3`, `ext4`, `Btrfs` (every subvolume and snapshot appears as a folder), `XFS`
* **Linux & Unix**: `ZFS` (OpenZFS pools from Linux, FreeBSD, TrueNAS, illumos/Solaris; all datasets)
* **Universal**: `exFAT` and `FAT32` are handed to macOS's own drivers

Requires macOS 15+ on Apple Silicon.

---

## How it works

macOS has no drivers for these filesystems, and third-party drivers would need kernel extensions, FUSE or
an FSKit module (FSKit requires a paid Apple Developer Program membership). OmniFS instead uses the
filesystem drivers of the Linux kernel itself:

1. `omnifs-vmd` opens the partition (one macOS authorization dialog, through `authopen`) and boots a tiny
   Alpine Linux VM (Linux 6.18 LTS, Apple Virtualization framework) with the partition attached.
2. The guest mounts it with the kernel driver (`ntfs3`, `ext4`, `btrfs`, `xfs`, OpenZFS) and shares it
   over NFS on a private virtual network.
3. macOS mounts that share. The volume appears in Finder under its own name. Ejecting it shuts the guest
   down cleanly (`umount`, `zpool export`) before the drive is released.

The same VM runs each filesystem's own checker for **Check & Repair** (`e2fsck`, `ntfsfix`, `xfs_repair`,
`btrfs check`, `zpool scrub`).

Known limitations:
* macOS gives network-style volumes no Trash; delete with ⌥⌘⌫ (Delete Immediately).
* macOS writes `._` files next to files with extended attributes.
* NTFS volumes left dirty by Windows (hibernation / Fast Startup) are refused read & write until checked;
  encrypted ZFS datasets are not supported.

---

## Project Structure

```
OmniFS/
├── Sources/
│   ├── OmniFSCore/          # Detection (superblock sniffer, disk scanner), MountManager, VM state, SwiftUI views
│   ├── OmniFSVMHelper/      # omnifs-vmd: boots the Linux guest for one partition
│   ├── OmniFSCLI/           # omnifs command-line tool
│   ├── OmniFSSettings/      # Standalone settings app
│   └── OmniFSPrefPane/      # System Settings pane
├── Resources/vm/            # Guest init script, helper entitlements
├── scripts/build_vm_image.py  # Builds the guest kernel + initramfs from Alpine packages (no Docker)
└── Tests/OmniFSTests/       # Unit tests + opt-in integration tests on real disk images
```

---

## CLI Usage (`omnifs`)

```bash
omnifs list                          # Disks, partitions, filesystems and devices
omnifs mount disk4s1 --rw            # Mount read & write (or --ro)
omnifs mount disk4s1 --rw --mountpoint ~/mnt/data
omnifs unmount disk4s1               # Or the mount point
omnifs repair disk4s1                # Check & Repair (unmounted during the check, then remounted)
omnifs inspect /dev/rdisk4s1         # Dump superblock metadata of a device or image
```

---

## Building & Installing

```bash
./install.sh         # Builds everything (including the VM image), installs the pane, app and CLI
./build_dmg.sh       # Builds a distributable OmniFS.dmg
```

The VM image is built by `scripts/build_vm_image.py` into `.build/vm`. After a plain `swift build`, sign the
development helper so it may use the Virtualization framework:

```bash
codesign -s - -f --entitlements Resources/vm/omnifs-vmd.entitlements .build/debug/omnifs-vmd
```

---

## Testing

```bash
swift test                                                         # Unit tests
OMNIFS_INTEGRATION=1 swift test --filter VolumeIntegrationTests    # Real disks through the VM (several minutes)
```

The integration tests create NTFS, ext2/3/4, Btrfs, XFS and ZFS disk images, attach them as devices and check
detection, copying in and out, moving, renaming, deleting, persistence, read-only mounts, eject, Btrfs
subvolumes, ZFS datasets and Check & Repair (including an NTFS volume left dirty by a crash).

---

## License

MIT License. See [LICENSE](LICENSE) for details.

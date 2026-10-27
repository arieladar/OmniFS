# OmniFS 🚀
### Universal Filesystem Engine & Settings Interface for macOS on Apple Silicon

OmniFS brings true **Read & Write** capabilities to macOS for foreign filesystems across Linux and Windows:

* **Linux**: `ext2`, `ext3`, `ext4` (with journaling and extents), `Btrfs`, and `XFS`.
* **Windows**: `NTFS` (full read & write, eliminating macOS's native read-only barrier).
* **Universal**: `exFAT` and `FAT32` (VFAT) with automatic volume detection and management.

Designed natively for Apple Silicon (ARM64) and modern macOS (macOS 15+ / Darwin 27).

---

## Key Features

1. **Native Apple Silicon**: Built in Swift 6.4 specifically for Apple M-series chips.
2. **System Settings Interface**: Designed faithfully using SwiftUI and `NavigationSplitView` matching the look, sidebar, and layout of macOS System Settings.
3. **Pure User-Space Architecture**: Eliminates legacy Kernel Extensions (`.kext`) and avoids requiring users to reduce system security in Recovery Mode.
4. **Superblock Sniffer**: Fast byte-level parser capable of identifying raw filesystem superblocks (magic offsets, UUIDs, volume labels, block sizes, clean/dirty states) from block devices and raw disk images.
5. **DiskArbitration Integration**: Automatic detection of connected external USB drives, SD cards, and partitions.
6. **Automation CLI (`omnifs`)**: Full command-line support for scriptable mounting, unmounting, inspection, and background auto-mounting.

---

## Project Structure

```
OmniFS/
├── Sources/
│   ├── OmniFSCore/          # Core filesystem sniffer, disk scanner, mount manager
│   │   ├── FileSystemType.swift
│   │   ├── SuperblockMetadata.swift
│   │   ├── SuperblockSniffer.swift
│   │   ├── DiskPartition.swift
│   │   ├── DiskScanner.swift
│   │   ├── MountOptions.swift
│   │   ├── MountManager.swift
│   │   └── AutoMountService.swift
│   ├── OmniFSCLI/           # 'omnifs' command-line executable
│   │   └── main.swift
│   └── OmniFSSettings/      # System Settings style SwiftUI interface
│       └── main.swift
├── Tests/
│   └── OmniFSTests/         # Superblock parsers & unit test suite
└── Package.swift
```

---

## CLI Usage (`omnifs`)

```bash
# List all disks, partitions, and detected Linux/Windows filesystems
swift run omnifs list

# Mount a partition in Read-Write mode
swift run omnifs mount disk3s1 --rw

# Mount a partition in Read-Only mode
swift run omnifs mount disk3s1 --ro

# Unmount a partition or mount point
swift run omnifs unmount /Volumes/LinuxData

# Deep inspect a block device or raw image superblock
swift run omnifs inspect /dev/disk3s1
```

---

## Launching the Settings App

To run the OmniFS Settings interface:

```bash
swift run OmniFSSettings
```

---

## Testing

Run the test suite:

```bash
swift test
```

---

## License

MIT License. See [LICENSE](file:///Users/arieladar/.gemini/antigravity-ide/scratch/OmniFS/LICENSE) for details.

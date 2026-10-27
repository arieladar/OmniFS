import Foundation

/// Represents a disk volume or partition detected on macOS.
public struct DiskPartition: Identifiable, Sendable, Hashable {
    public var id: String { bsdName }

    /// BSD Name, e.g. "disk3s1"
    public let bsdName: String

    /// Device path, e.g. "/dev/disk3s1"
    public var devicePath: String {
        return "/dev/\(bsdName)"
    }

    /// Raw character device path for fast block I/O, e.g. "/dev/rdisk3s1"
    public var rawDevicePath: String {
        return "/dev/r\(bsdName)"
    }

    /// Size in bytes
    public let totalSizeBytes: UInt64

    /// Partition or Volume Name
    public let volumeName: String

    /// Filesystem type identified
    public let fileSystemType: FileSystemType

    /// Superblock metadata if probed
    public let metadata: SuperblockMetadata?

    /// Current mount point, if mounted
    public let mountPoint: String?

    /// Whether this partition is currently mounted in macOS VFS
    public var isMounted: Bool {
        guard let mp = mountPoint else { return false }
        return !mp.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether mounted as read-only
    public let isReadOnly: Bool

    /// Whether the underlying device is removable / external (USB, SD Card, etc.)
    public let isRemovable: Bool

    /// Whether the underlying device is a built-in internal Mac drive
    public let isInternal: Bool

    /// Whether this partition can be mounted with write support via OmniFS
    public var canOmniFSMountReadWrite: Bool {
        return fileSystemType.requiresOmniFSDriver || fileSystemType.isNativeWritableOnMacOS
    }

    /// Whether this is a valid foreign or external partition suitable for OmniFS management
    /// (strictly excludes built-in Mac APFS/HFS system disks and internal recovery/EFI partitions).
    public var isForeignOrRemovable: Bool {
        // Exclude internal Apple APFS / HFS system partitions
        if isInternal && (fileSystemType.family == .apple || fileSystemType == .apfs || fileSystemType == .hfsplus) {
            return false
        }
        let lowerName = volumeName.lowercased()
        if lowerName.contains("macintosh hd") || lowerName == "recovery" || lowerName == "preboot" || lowerName == "vm" || lowerName == "update" || lowerName == "hardware" || lowerName == "xart" || lowerName == "iboot" {
            return false
        }
        // Exclude raw unknown partitions on internal fixed drives
        if isInternal {
            switch fileSystemType {
            case .ext2, .ext3, .ext4, .ntfs, .btrfs, .xfs:
                return true
            default:
                return false
            }
        }
        // For external/removable devices: show all non-Apple partitions or universal formats
        return fileSystemType.family != .apple
    }

    public init(
        bsdName: String,
        totalSizeBytes: UInt64,
        volumeName: String,
        fileSystemType: FileSystemType,
        metadata: SuperblockMetadata? = nil,
        mountPoint: String? = nil,
        isReadOnly: Bool = false,
        isRemovable: Bool = true,
        isInternal: Bool = false
    ) {
        self.bsdName = bsdName
        self.totalSizeBytes = totalSizeBytes
        self.volumeName = volumeName
        self.fileSystemType = fileSystemType
        self.metadata = metadata
        self.mountPoint = mountPoint
        self.isReadOnly = isReadOnly
        self.isRemovable = isRemovable
        self.isInternal = isInternal
    }

    /// Formatted human-readable size (e.g. "64.0 GB")
    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(totalSizeBytes))
    }

    // MARK: - Sample & Demo Partitions

    public static let sampleExt4 = DiskPartition(
        bsdName: "disk4s2",
        totalSizeBytes: 128 * 1024 * 1024 * 1024,
        volumeName: "Ubuntu_Linux",
        fileSystemType: .ext4,
        metadata: SuperblockMetadata(
            fileSystemType: .ext4,
            volumeName: "Ubuntu_Linux",
            uuid: "a4f8e219-c09a-4e89-b789-8d193fa09823",
            blockSize: 4096,
            totalBlocks: 31457280,
            freeBlocks: 18239010,
            isClean: true,
            lastMountTime: Date(),
            featuresDescription: "has_journal, extents, 64bit, flex_bg, dir_index, large_dir"
        ),
        mountPoint: "/Volumes/Ubuntu_Linux",
        isReadOnly: false,
        isRemovable: true
    )

    public static let sampleNTFS = DiskPartition(
        bsdName: "disk5s1",
        totalSizeBytes: 500 * 1024 * 1024 * 1024,
        volumeName: "Windows_Data",
        fileSystemType: .ntfs,
        metadata: SuperblockMetadata(
            fileSystemType: .ntfs,
            volumeName: "Windows_Data",
            uuid: "3C82-9B14-829A-40D1",
            blockSize: 4096,
            totalBlocks: 122070312,
            freeBlocks: 64102930,
            isClean: true,
            lastMountTime: Date().addingTimeInterval(-86400),
            featuresDescription: "MFT Journal, Sparse Files, Reparse Points, USN Journal"
        ),
        mountPoint: nil,
        isReadOnly: false,
        isRemovable: true
    )

    public static let sampleBtrfs = DiskPartition(
        bsdName: "disk6s1",
        totalSizeBytes: 64 * 1024 * 1024 * 1024,
        volumeName: "Arch_CoW",
        fileSystemType: .btrfs,
        metadata: SuperblockMetadata(
            fileSystemType: .btrfs,
            volumeName: "Arch_CoW",
            uuid: "d9e8c7b6-a5f4-4321-b012-3456789abcde",
            blockSize: 4096,
            totalBlocks: 15625000,
            freeBlocks: 8901234,
            isClean: true,
            lastMountTime: Date().addingTimeInterval(-172800),
            featuresDescription: "mixed_groups, extref, skinny_metadata, subvolumes"
        ),
        mountPoint: "/Volumes/Arch_CoW",
        isReadOnly: true,
        isRemovable: true
    )

    public static let samples: [DiskPartition] = [sampleExt4, sampleNTFS, sampleBtrfs]
}

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

    /// Kind of physical device (NVMe, SSD, HDD, flash drive, SD card, disk image)
    public let driveKind: DriveKind

    /// Device model as reported by macOS, e.g. "Samsung PSSD T7 Shield"
    public let deviceModel: String?

    /// Connection type as reported by macOS, e.g. "USB", "Thunderbolt"
    public let connection: String?

    /// Human-readable device summary, e.g. "NVMe SSD · Realtek RTL9210B-CG · USB"
    public var deviceSummary: String {
        ([driveKind.description, deviceModel, connection] as [String?])
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Whether OmniFS can check and repair this filesystem (with its Linux tool, inside the VM)
    public var supportsRepair: Bool {
        // udftools has no checker
        return fileSystemType.requiresOmniFSDriver && fileSystemType != .udf
    }

    /// Whether this partition can be mounted with write support (natively or via the OmniFS Linux VM)
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
            case .ext2, .ext3, .ext4, .ntfs, .btrfs, .xfs, .zfs, .f2fs, .udf:
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
        isInternal: Bool = false,
        driveKind: DriveKind = .unknown,
        deviceModel: String? = nil,
        connection: String? = nil
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
        self.driveKind = driveKind
        self.deviceModel = deviceModel
        self.connection = connection
    }

    /// Formatted human-readable size (e.g. "64.0 GB")
    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(totalSizeBytes))
    }
}

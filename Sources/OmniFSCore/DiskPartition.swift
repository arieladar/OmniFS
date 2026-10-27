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

    /// Whether the underlying device is removable (USB, SD Card, etc.)
    public let isRemovable: Bool

    /// Whether this partition can be mounted with write support via OmniFS
    public var canOmniFSMountReadWrite: Bool {
        return fileSystemType.requiresOmniFSDriver || fileSystemType.isNativeWritableOnMacOS
    }

    public init(
        bsdName: String,
        totalSizeBytes: UInt64,
        volumeName: String,
        fileSystemType: FileSystemType,
        metadata: SuperblockMetadata? = nil,
        mountPoint: String? = nil,
        isReadOnly: Bool = false,
        isRemovable: Bool = true
    ) {
        self.bsdName = bsdName
        self.totalSizeBytes = totalSizeBytes
        self.volumeName = volumeName
        self.fileSystemType = fileSystemType
        self.metadata = metadata
        self.mountPoint = mountPoint
        self.isReadOnly = isReadOnly
        self.isRemovable = isRemovable
    }

    /// Formatted human-readable size (e.g. "64.0 GB")
    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(totalSizeBytes))
    }
}

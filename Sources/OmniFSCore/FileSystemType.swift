import Foundation

/// Supported filesystem types across Linux, Windows, and macOS ecosystems.
public enum FileSystemType: Hashable, Sendable, CustomStringConvertible {
    case ext2
    case ext3
    case ext4
    case ntfs
    case btrfs
    case xfs
    case vfat
    case exfat
    case apfs
    case hfsplus
    case unknown(magic: String)

    public var description: String {
        switch self {
        case .ext2: return "ext2"
        case .ext3: return "ext3"
        case .ext4: return "ext4"
        case .ntfs: return "NTFS"
        case .btrfs: return "Btrfs"
        case .xfs: return "XFS"
        case .vfat: return "FAT32 (VFAT)"
        case .exfat: return "exFAT"
        case .apfs: return "APFS"
        case .hfsplus: return "HFS+"
        case .unknown(let magic): return "Unknown (\(magic))"
        }
    }

    public var family: FileSystemFamily {
        switch self {
        case .ext2, .ext3, .ext4, .btrfs, .xfs:
            return .linux
        case .ntfs:
            return .windows
        case .vfat, .exfat:
            return .universal
        case .apfs, .hfsplus:
            return .apple
        case .unknown:
            return .other
        }
    }

    /// Whether macOS natively supports read operations out of the box.
    public var isNativeReadableOnMacOS: Bool {
        switch self {
        case .ntfs, .vfat, .exfat, .apfs, .hfsplus:
            return true
        default:
            return false
        }
    }

    /// Whether macOS natively supports write operations out of the box.
    public var isNativeWritableOnMacOS: Bool {
        switch self {
        case .vfat, .exfat, .apfs, .hfsplus:
            return true
        default:
            // NTFS is read-only natively on macOS. Linux filesystems have no native driver.
            return false
        }
    }

    /// Whether OmniFS provides extended read-write support for this filesystem.
    public var requiresOmniFSDriver: Bool {
        switch self {
        case .ext2, .ext3, .ext4, .ntfs, .btrfs, .xfs:
            return true
        case .vfat, .exfat, .apfs, .hfsplus, .unknown:
            return false
        }
    }

    public var iconName: String {
        switch family {
        case .linux:
            return "externaldrive.badge.person.crop"
        case .windows:
            return "pc"
        case .universal:
            return "externaldrive.fill"
        case .apple:
            return "apple.logo"
        case .other:
            return "questionmark.folder"
        }
    }
}

public enum FileSystemFamily: String, Hashable, Sendable {
    case linux = "Linux"
    case windows = "Windows"
    case universal = "Universal (FAT/exFAT)"
    case apple = "Apple Native"
    case other = "Other"
}

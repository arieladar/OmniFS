import Foundation

/// The physical kind of storage device a partition lives on, inferred from what macOS reports about it.
public enum DriveKind: String, Sendable, Hashable, CaseIterable {
    case nvme
    case ssd
    case hdd
    case flashDrive
    case sdCard
    case diskImage
    case unknown

    public var description: String {
        switch self {
        case .nvme: return "NVMe SSD"
        case .ssd: return "SSD"
        case .hdd: return "Hard Drive"
        case .flashDrive: return "USB Flash Drive"
        case .sdCard: return "SD Card"
        case .diskImage: return "Disk Image"
        case .unknown: return "Drive"
        }
    }

    public var iconName: String {
        switch self {
        case .nvme: return "memorychip.fill"
        case .ssd: return "externaldrive.fill"
        case .hdd: return "internaldrive.fill"
        case .flashDrive: return "mediastick"
        case .sdCard: return "sdcard.fill"
        case .diskImage: return "doc.fill"
        case .unknown: return "externaldrive.fill.badge.questionmark"
        }
    }

    /// USB-to-NVMe bridge chips report their own name instead of the drive's (e.g. "RTL9210B-CG")
    private static let nvmeMarkers = ["NVME", "RTL9210", "RTL9220", "JMS583", "ASM2362", "ASM2364", "ASM246"]
    private static let sdMarkers = ["SDXC", "SDHC", "SD CARD", "SD/MMC", "CARD READER", "MICROSD", "MMC"]
    private static let flashMarkers = ["FLASH", "CRUZER", "DATATRAVELER", "JUMPDRIVE", "ULTRA FIT", "USB DISK", "PEN DRIVE", "THUMB"]

    /// Classifies a drive from `diskutil info` of its whole disk.
    public static func classify(model: String, busProtocol: String, solidState: Bool?, isVirtual: Bool, removableMedia: Bool) -> DriveKind {
        let name = model.uppercased()
        let bus = busProtocol.uppercased()

        if isVirtual || bus == "DISK IMAGE" {
            return .diskImage
        }
        if bus.contains("SECURE DIGITAL") || sdMarkers.contains(where: name.contains) {
            return .sdCard
        }
        if bus.contains("PCI") || bus.contains("NVME") || bus == "APPLE FABRIC" || nvmeMarkers.contains(where: name.contains) {
            return .nvme
        }
        if name.contains("SSD") {
            return .ssd
        }
        if flashMarkers.contains(where: name.contains) {
            return .flashDrive
        }
        switch solidState {
        case true?: return .ssd
        case false?: return removableMedia ? .flashDrive : .hdd
        case nil: return removableMedia ? .flashDrive : .unknown
        }
    }
}

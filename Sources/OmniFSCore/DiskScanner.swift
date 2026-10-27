import Foundation
import DiskArbitration

/// Scans, discovers, and interrogates disks and partitions on macOS.
public actor DiskScanner {
    private let sniffer = SuperblockSniffer()

    public init() {}

    /// Discovers all disks and partitions currently attached to the system,
    /// inspecting foreign partitions with SuperblockSniffer.
    public func scanPartitions() async -> [DiskPartition] {
        var results: [DiskPartition] = []

        // Run diskutil info -all or parse plist to query the system
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["list", "-plist"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               let allDisksAndPartitions = plist["AllDisksAndPartitions"] as? [[String: Any]] {

                for diskEntry in allDisksAndPartitions {
                    if let partitions = diskEntry["Partitions"] as? [[String: Any]] {
                        for part in partitions {
                            if let partition = await parsePartitionEntry(part) {
                                results.append(partition)
                            }
                        }
                    } else if let diskIdentifier = diskEntry["DeviceIdentifier"] as? String {
                        // Whole disk without partition map
                        if let single = await inspectDisk(bsdName: diskIdentifier) {
                            results.append(single)
                        }
                    }
                }
            }
        } catch {
            print("Failed to run diskutil: \(error)")
        }

        return results
    }

    private func parsePartitionEntry(_ dict: [String: Any]) async -> DiskPartition? {
        guard let bsdName = dict["DeviceIdentifier"] as? String else {
            return nil
        }
        return await inspectDisk(bsdName: bsdName, hintDict: dict)
    }

    /// Interrogates a specific BSD device identifier (e.g. "disk3s1").
    public func inspectDisk(bsdName: String, hintDict: [String: Any]? = nil) async -> DiskPartition? {
        let devicePath = "/dev/\(bsdName)"
        let rawPath = "/dev/r\(bsdName)"

        // Query diskutil info -plist for detailed metadata
        let infoDict = fetchDiskInfo(bsdName: bsdName) ?? hintDict ?? [:]

        let sizeBytes = (infoDict["Size"] as? NSNumber)?.uint64Value
            ?? (infoDict["TotalSize"] as? NSNumber)?.uint64Value
            ?? 0

        var volumeName = (infoDict["VolumeName"] as? String) ?? ""
        let mountPoint = infoDict["MountPoint"] as? String
        let isReadOnly = (infoDict["Writable"] as? Bool == false)
        let isRemovable = (infoDict["Removable"] as? Bool)
            ?? (infoDict["RemovableMedia"] as? Bool)
            ?? true

        // Let's sniff the superblock to identify foreign filesystems
        var meta = sniffer.probe(devicePath: rawPath)
        if meta == nil {
            meta = sniffer.probe(devicePath: devicePath)
        }

        let detectedType: FileSystemType
        if let meta = meta {
            detectedType = meta.fileSystemType
            if volumeName.isEmpty, let name = meta.volumeName {
                volumeName = name
            }
        } else if let fsName = infoDict["FilesystemType"] as? String ?? infoDict["FilesystemName"] as? String {
            detectedType = mapSystemFSType(fsName)
        } else {
            detectedType = .unknown(magic: "unrecognized")
        }

        if volumeName.isEmpty {
            volumeName = bsdName
        }

        return DiskPartition(
            bsdName: bsdName,
            totalSizeBytes: sizeBytes,
            volumeName: volumeName,
            fileSystemType: detectedType,
            metadata: meta,
            mountPoint: mountPoint,
            isReadOnly: isReadOnly,
            isRemovable: isRemovable
        )
    }

    private func fetchDiskInfo(bsdName: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", bsdName]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func mapSystemFSType(_ name: String) -> FileSystemType {
        let lower = name.lowercased()
        if lower.contains("ext4") { return .ext4 }
        if lower.contains("ext3") { return .ext3 }
        if lower.contains("ext2") { return .ext2 }
        if lower.contains("ntfs") { return .ntfs }
        if lower.contains("btrfs") { return .btrfs }
        if lower.contains("xfs") { return .xfs }
        if lower.contains("exfat") { return .exfat }
        if lower.contains("msdos") || lower.contains("fat") { return .vfat }
        if lower.contains("apfs") { return .apfs }
        if lower.contains("hfs") { return .hfsplus }
        return .unknown(magic: name)
    }
}

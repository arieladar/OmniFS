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
        // BSD names are reused when drives are swapped, so drive details are only cached within one scan
        wholeDiskCache.removeAll()

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
                    let parentContent = (diskEntry["Content"] as? String) ?? ""
                    
                    if let partitions = diskEntry["Partitions"] as? [[String: Any]] {
                        for part in partitions {
                            if let partition = await parsePartitionEntry(part) {
                                if partition.isForeignOrRemovable {
                                    results.append(partition)
                                }
                            }
                        }
                    } else if let diskIdentifier = diskEntry["DeviceIdentifier"] as? String {
                        // Skip whole Apple APFS synthetic containers or GUID partition schemes
                        if parentContent.contains("APFS") || parentContent.contains("GUID") {
                            continue
                        }
                        if let single = await inspectDisk(bsdName: diskIdentifier) {
                            if single.isForeignOrRemovable {
                                results.append(single)
                            }
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

        let isInternal = (infoDict["Internal"] as? Bool) ?? false
        let isRemovable = (infoDict["Removable"] as? Bool)
            ?? (infoDict["RemovableMedia"] as? Bool)
            ?? (infoDict["Ejectable"] as? Bool)
            ?? false

        let content = (infoDict["Content"] as? String) ?? ""
        let busProtocol = (infoDict["BusProtocol"] as? String) ?? ""

        // Fast exclusion: If it's the internal Mac bus or Apple system container, skip immediately unless probed foreign
        let isAppleFabricOrInternal = isInternal || busProtocol.contains("Apple Fabric") || busProtocol.contains("Internal")

        let sizeBytes = (infoDict["Size"] as? NSNumber)?.uint64Value
            ?? (infoDict["TotalSize"] as? NSNumber)?.uint64Value
            ?? 0

        var volumeName = (infoDict["VolumeName"] as? String) ?? ""
        var mountPoint = infoDict["MountPoint"] as? String
        var isReadOnly = (infoDict["Writable"] as? Bool == false)

        // Volumes served by the OmniFS Linux VM are unknown to diskutil
        if let vmMount = VMMountRegistry.activeRecord(bsdName: bsdName), VMMountRegistry.isMountPoint(vmMount.mountPoint) {
            mountPoint = vmMount.mountPoint
            isReadOnly = vmMount.readOnly
        }

        // Sniff the superblock to identify foreign filesystems (ext2/3/4, NTFS, Btrfs, XFS)
        // Only touch devices this user may read: opening others fails anyway and triggers a macOS privacy prompt
        var meta: SuperblockMetadata?
        if access(rawPath, R_OK) == 0 {
            meta = sniffer.probe(devicePath: rawPath)
        }
        if meta == nil && access(devicePath, R_OK) == 0 {
            meta = sniffer.probe(devicePath: devicePath)
        }

        // System-only partitions with no user files (e.g. the 16 MB Microsoft Reserved partition Windows puts on GPT
        // disks, or the 8 MB reserved partition ZFS adds when it is given a whole disk)
        let systemPartitionTypes = ["Microsoft Reserved", "EFI", "Linux Swap", "Linux_Swap", "Apple_Boot",
                                    "6A945A3B-1DD2-11B2-99A6-080020736631"]
        if meta == nil && systemPartitionTypes.contains(content) {
            return nil
        }

        // If internal Mac drive and no foreign superblock was detected, ignore it
        if isAppleFabricOrInternal && meta == nil {
            if content.starts(with: "Apple_") || content == "EFI" || content.isEmpty {
                return nil
            }
        }

        let detectedType: FileSystemType
        if let meta = meta {
            detectedType = meta.fileSystemType
            if volumeName.isEmpty, let name = meta.volumeName {
                volumeName = name
            }
        } else if let fsName = infoDict["FilesystemType"] as? String ?? infoDict["FilesystemName"] as? String {
            detectedType = mapSystemFSType(fsName)
        } else if content.localizedCaseInsensitiveContains("ZFS") {
            // ZFS partition type GUIDs (Solaris/illumos, FreeBSD, OpenZFS on Linux): readable without the superblock
            detectedType = .zfs
        } else if content.localizedCaseInsensitiveContains("Linux") && !content.localizedCaseInsensitiveContains("swap") {
            // Superblocks can only be read as root; the partition type still tells us it's a Linux filesystem
            detectedType = .unknown(magic: "Linux")
        } else {
            detectedType = .unknown(magic: "unrecognized")
        }

        // Never expose internal Mac APFS or HFS system partitions
        if isAppleFabricOrInternal && (detectedType.family == .apple || detectedType == .apfs || detectedType == .hfsplus) {
            return nil
        }

        if volumeName.isEmpty {
            volumeName = bsdName
        }

        // The device model is only reported on the whole disk (e.g. "Realtek RTL9210B-CG Media")
        let wholeDisk = (infoDict["ParentWholeDisk"] as? String) ?? bsdName
        let wholeInfo = wholeDisk == bsdName ? infoDict : (wholeDiskInfo(wholeDisk) ?? infoDict)
        var model = (wholeInfo["IORegistryEntryName"] as? String) ?? (wholeInfo["MediaName"] as? String) ?? ""
        if model.hasSuffix(" Media") {
            model = String(model.dropLast(" Media".count))
        }
        let driveKind = DriveKind.classify(
            model: model.isEmpty ? (wholeInfo["MediaName"] as? String ?? "") : model,
            busProtocol: busProtocol,
            solidState: wholeInfo["SolidState"] as? Bool,
            isVirtual: (wholeInfo["VirtualOrPhysical"] as? String) == "Virtual",
            removableMedia: (wholeInfo["RemovableMedia"] as? Bool) ?? false
        )

        return DiskPartition(
            bsdName: bsdName,
            totalSizeBytes: sizeBytes,
            volumeName: volumeName,
            fileSystemType: detectedType,
            metadata: meta,
            mountPoint: mountPoint,
            isReadOnly: isReadOnly,
            isRemovable: isRemovable,
            isInternal: isInternal,
            driveKind: driveKind,
            deviceModel: model.isEmpty ? nil : model,
            connection: busProtocol.isEmpty ? nil : busProtocol
        )
    }

    private var wholeDiskCache: [String: [String: Any]] = [:]

    private func wholeDiskInfo(_ bsdName: String) -> [String: Any]? {
        if let cached = wholeDiskCache[bsdName] {
            return cached
        }
        let info = fetchDiskInfo(bsdName: bsdName)
        wholeDiskCache[bsdName] = info
        return info
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
        if lower.contains("zfs") { return .zfs }
        if lower.contains("f2fs") { return .f2fs }
        if lower.contains("udf") { return .udf }
        if lower.contains("exfat") { return .exfat }
        if lower.contains("msdos") || lower.contains("fat") { return .vfat }
        if lower.contains("apfs") { return .apfs }
        if lower.contains("hfs") { return .hfsplus }
        return .unknown(magic: name)
    }
}

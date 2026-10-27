import Foundation

/// Fast byte-level parser for identifying filesystems from block devices and raw disk images.
public struct SuperblockSniffer: Sendable {

    public init() {}

    /// Sniffs the filesystem from an open FileHandle at the current or specified offset.
    public func probe(fileHandle: FileHandle) -> SuperblockMetadata? {
        // Read the first 128KB to cover sector 0 (NTFS, XFS, FAT/exFAT, APFS),
        // sector 2 (ext2/3/4 at 1024), and 64KB (Btrfs at 65536).
        do {
            try fileHandle.seek(toOffset: 0)
            guard let headerData = try fileHandle.read(upToCount: 131072), headerData.count >= 1024 else {
                return nil
            }
            return probe(data: headerData)
        } catch {
            return nil
        }
    }

    /// Sniffs the filesystem from a raw device path (e.g. /dev/disk3s1 or /dev/rdisk3s1).
    public func probe(devicePath: String) -> SuperblockMetadata? {
        guard let handle = FileHandle(forReadingAtPath: devicePath) else {
            return nil
        }
        defer { try? handle.close() }
        return probe(fileHandle: handle)
    }

    /// Sniffs filesystem metadata from an in-memory buffer containing the first 128KB of the disk/partition.
    public func probe(data: Data) -> SuperblockMetadata? {
        // 1. Check ext2 / ext3 / ext4 (Offset 1024, length 1024)
        if let ext = probeExt(data: data) {
            return ext
        }

        // 2. Check NTFS (Offset 0, OEM ID "NTFS    ")
        if let ntfs = probeNTFS(data: data) {
            return ntfs
        }

        // 3. Check Btrfs (Offset 65536, Magic "_BHRfS_M")
        if let btrfs = probeBtrfs(data: data) {
            return btrfs
        }

        // 4. Check XFS (Offset 0, Magic "XFSB")
        if let xfs = probeXFS(data: data) {
            return xfs
        }

        // 5. Check exFAT (Offset 3, "EXFAT   ")
        if let exfat = probeExFAT(data: data) {
            return exfat
        }

        // 6. Check VFAT / FAT32 (Offset 54 / 82)
        if let vfat = probeVFAT(data: data) {
            return vfat
        }

        return nil
    }

    // MARK: - Ext2 / Ext3 / Ext4 Sniffer

    private func probeExt(data: Data) -> SuperblockMetadata? {
        let sbOffset = 1024
        guard data.count >= sbOffset + 1024 else { return nil }

        // Magic 0xEF53 at offset 0x38 in superblock (0x438 = 1080)
        let magicOffset = sbOffset + 0x38
        let magic0 = data[magicOffset]
        let magic1 = data[magicOffset + 1]
        guard magic0 == 0x53 && magic1 == 0xEF else {
            return nil
        }

        // Feature flags
        let compatOffset = sbOffset + 0x5C
        let incompatOffset = sbOffset + 0x60
        let compat = readUInt32LE(data: data, offset: compatOffset)
        let incompat = readUInt32LE(data: data, offset: incompatOffset)

        // EXT3_FEATURE_COMPAT_HAS_JOURNAL = 0x0004
        let hasJournal = (compat & 0x0004) != 0

        // EXT4_FEATURE_INCOMPAT_EXTENTS = 0x0040
        // EXT4_FEATURE_INCOMPAT_64BIT = 0x0080
        // EXT4_FEATURE_INCOMPAT_FLEX_BG = 0x0200
        let isExt4 = (incompat & 0x0040) != 0 || (incompat & 0x0080) != 0 || (incompat & 0x0200) != 0

        let fsType: FileSystemType
        if isExt4 {
            fsType = .ext4
        } else if hasJournal {
            fsType = .ext3
        } else {
            fsType = .ext2
        }

        // Block size: 1024 << s_log_block_size
        let logBlockSize = readUInt32LE(data: data, offset: sbOffset + 0x18)
        let blockSize = UInt32(1024) << min(logBlockSize, 6)

        // Total blocks (s_blocks_count_lo)
        let totalBlocksLo = UInt64(readUInt32LE(data: data, offset: sbOffset + 0x04))
        var totalBlocks = totalBlocksLo
        if (incompat & 0x0080) != 0 && data.count >= sbOffset + 0x154 {
            let totalBlocksHi = UInt64(readUInt32LE(data: data, offset: sbOffset + 0x150))
            totalBlocks |= (totalBlocksHi << 32)
        }

        // Free blocks
        let freeBlocksLo = UInt64(readUInt32LE(data: data, offset: sbOffset + 0x0C))

        // State (1 = clean, 2 = errors)
        let state = readUInt16LE(data: data, offset: sbOffset + 0x3A)
        let isClean = (state == 1)

        // Volume name (16 bytes at 0x78)
        let nameData = data.subdata(in: (sbOffset + 0x78)..<(sbOffset + 0x78 + 16))
        let volumeName = cleanString(from: nameData)

        // UUID (16 bytes at 0x68)
        let uuidData = data.subdata(in: (sbOffset + 0x68)..<(sbOffset + 0x68 + 16))
        let uuid = formatUUID(uuidData)

        // Last mount time (epoch seconds at 0x2C)
        let lastMountSeconds = readUInt32LE(data: data, offset: sbOffset + 0x2C)
        let lastMountDate = lastMountSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(lastMountSeconds)) : nil

        return SuperblockMetadata(
            fileSystemType: fsType,
            volumeName: volumeName,
            uuid: uuid,
            blockSize: blockSize,
            totalBlocks: totalBlocks,
            freeBlocks: freeBlocksLo,
            isClean: isClean,
            lastMountTime: lastMountDate,
            featuresDescription: "Compat: 0x\(String(compat, radix: 16)), Incompat: 0x\(String(incompat, radix: 16))"
        )
    }

    // MARK: - NTFS Sniffer

    private func probeNTFS(data: Data) -> SuperblockMetadata? {
        guard data.count >= 512 else { return nil }

        // OEM ID at offset 3 (8 bytes: "NTFS    ")
        let oemData = data.subdata(in: 3..<11)
        guard let oem = String(data: oemData, encoding: .ascii), oem == "NTFS    " else {
            return nil
        }

        let bytesPerSector = readUInt16LE(data: data, offset: 0x0B)
        let sectorsPerCluster = UInt32(data[0x0D])
        let blockSize = UInt32(bytesPerSector) * sectorsPerCluster
        let totalSectors = readUInt64LE(data: data, offset: 0x28)
        let serialNumber = readUInt64LE(data: data, offset: 0x48)
        let serialStr = String(format: "%016llX", serialNumber)

        return SuperblockMetadata(
            fileSystemType: .ntfs,
            volumeName: nil, // Stored in MFT $Volume attribute
            uuid: serialStr,
            blockSize: blockSize,
            totalBlocks: totalSectors / UInt64(max(sectorsPerCluster, 1)),
            freeBlocks: nil,
            isClean: true,
            lastMountTime: nil,
            featuresDescription: "Sector: \(bytesPerSector)B, Cluster: \(blockSize)B"
        )
    }

    // MARK: - Btrfs Sniffer

    private func probeBtrfs(data: Data) -> SuperblockMetadata? {
        let sbOffset = 65536
        guard data.count >= sbOffset + 4096 else { return nil }

        // Magic "_BHRfS_M" at offset 0x40 in superblock (0x10040)
        let magicOffset = sbOffset + 0x40
        let magicData = data.subdata(in: magicOffset..<(magicOffset + 8))
        guard let magic = String(data: magicData, encoding: .ascii), magic == "_BHRfS_M" else {
            return nil
        }

        // UUID at 0x20 (16 bytes)
        let uuidData = data.subdata(in: (sbOffset + 0x20)..<(sbOffset + 0x20 + 16))
        let uuid = formatUUID(uuidData)

        // Total bytes at 0x70 (uint64)
        let totalBytes = readUInt64LE(data: data, offset: sbOffset + 0x70)

        // Sector size at 0x90 (uint32)
        let sectorSize = readUInt32LE(data: data, offset: sbOffset + 0x90)

        // Volume label at 0x12B (256 bytes)
        let labelData = data.subdata(in: (sbOffset + 0x12B)..<(sbOffset + 0x12B + 256))
        let volumeName = cleanString(from: labelData)

        return SuperblockMetadata(
            fileSystemType: .btrfs,
            volumeName: volumeName,
            uuid: uuid,
            blockSize: sectorSize > 0 ? sectorSize : 4096,
            totalBlocks: sectorSize > 0 ? (totalBytes / UInt64(sectorSize)) : 0,
            freeBlocks: nil,
            isClean: true,
            lastMountTime: nil,
            featuresDescription: "Btrfs Subvolume/Tree filesystem"
        )
    }

    // MARK: - XFS Sniffer

    private func probeXFS(data: Data) -> SuperblockMetadata? {
        guard data.count >= 512 else { return nil }

        // Magic "XFSB" at offset 0 (0x58, 0x46, 0x53, 0x42)
        let magicData = data.subdata(in: 0..<4)
        guard let magic = String(data: magicData, encoding: .ascii), magic == "XFSB" else {
            return nil
        }

        // XFS fields are Big-Endian!
        let blockSize = readUInt32BE(data: data, offset: 0x04)
        let totalBlocks = readUInt64BE(data: data, offset: 0x08)
        let freeBlocks = readUInt64BE(data: data, offset: 0x18)

        // UUID at 0x20 (16 bytes)
        let uuidData = data.subdata(in: 0x20..<0x30)
        let uuid = formatUUID(uuidData)

        // Volume name at 0x6C (12 bytes)
        let labelData = data.subdata(in: 0x6C..<0x78)
        let volumeName = cleanString(from: labelData)

        return SuperblockMetadata(
            fileSystemType: .xfs,
            volumeName: volumeName,
            uuid: uuid,
            blockSize: blockSize,
            totalBlocks: totalBlocks,
            freeBlocks: freeBlocks,
            isClean: true,
            lastMountTime: nil,
            featuresDescription: "XFS Big-Endian superblock"
        )
    }

    // MARK: - exFAT Sniffer

    private func probeExFAT(data: Data) -> SuperblockMetadata? {
        guard data.count >= 512 else { return nil }

        let nameData = data.subdata(in: 3..<11)
        guard let name = String(data: nameData, encoding: .ascii), name == "EXFAT   " else {
            return nil
        }

        let bytesPerSecShift = data[0x6C]
        let secPerClusShift = data[0x6D]
        let blockSize = (UInt32(1) << min(bytesPerSecShift, 16)) * (UInt32(1) << min(secPerClusShift, 16))
        let volumeLength = readUInt64LE(data: data, offset: 0x48)
        let serial = readUInt32LE(data: data, offset: 0x64)

        return SuperblockMetadata(
            fileSystemType: .exfat,
            volumeName: nil,
            uuid: String(format: "%08X", serial),
            blockSize: blockSize,
            totalBlocks: volumeLength,
            freeBlocks: nil,
            isClean: true,
            lastMountTime: nil,
            featuresDescription: "Native macOS supported"
        )
    }

    // MARK: - VFAT (FAT12 / FAT16 / FAT32) Sniffer

    private func probeVFAT(data: Data) -> SuperblockMetadata? {
        guard data.count >= 512 else { return nil }

        // FAT32 file system label at offset 82 (8 bytes)
        let fat32Data = data.subdata(in: 82..<90)
        if let sig = String(data: fat32Data, encoding: .ascii), sig.hasPrefix("FAT32") {
            let labelData = data.subdata(in: 71..<82)
            let volLabel = cleanString(from: labelData)
            let serial = readUInt32LE(data: data, offset: 67)

            return SuperblockMetadata(
                fileSystemType: .vfat,
                volumeName: volLabel,
                uuid: String(format: "%08X", serial),
                blockSize: 512,
                totalBlocks: nil,
                freeBlocks: nil,
                isClean: true,
                lastMountTime: nil,
                featuresDescription: "FAT32 - Native macOS supported"
            )
        }

        // FAT12 / FAT16 label at offset 54 (8 bytes)
        let fat16Data = data.subdata(in: 54..<62)
        if let sig = String(data: fat16Data, encoding: .ascii), (sig.hasPrefix("FAT12") || sig.hasPrefix("FAT16")) {
            let labelData = data.subdata(in: 43..<54)
            let volLabel = cleanString(from: labelData)
            let serial = readUInt32LE(data: data, offset: 39)

            return SuperblockMetadata(
                fileSystemType: .vfat,
                volumeName: volLabel,
                uuid: String(format: "%08X", serial),
                blockSize: 512,
                totalBlocks: nil,
                freeBlocks: nil,
                isClean: true,
                lastMountTime: nil,
                featuresDescription: "FAT16/12 - Native macOS supported"
            )
        }

        return nil
    }

    // MARK: - Binary Helper Utilities

    private func readUInt16LE(data: Data, offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else { return 0 }
        return data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    private func readUInt32LE(data: Data, offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    private func readUInt64LE(data: Data, offset: Int) -> UInt64 {
        guard data.count >= offset + 8 else { return 0 }
        return data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
    }

    private func readUInt32BE(data: Data, offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
    }

    private func readUInt64BE(data: Data, offset: Int) -> UInt64 {
        guard data.count >= offset + 8 else { return 0 }
        return data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian
        }
    }

    private func cleanString(from data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let cleaned = raw.trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        return cleaned.isEmpty ? nil : cleaned
    }

    private func formatUUID(_ data: Data) -> String? {
        guard data.count == 16 else { return nil }
        return String(format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                      data[0], data[1], data[2], data[3],
                      data[4], data[5],
                      data[6], data[7],
                      data[8], data[9],
                      data[10], data[11], data[12], data[13], data[14], data[15])
    }
}

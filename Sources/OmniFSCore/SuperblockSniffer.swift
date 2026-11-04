import Foundation

/// Fast byte-level parser for identifying filesystems from block devices and raw disk images.
public struct SuperblockSniffer: Sendable {

    public init() {}

    /// Sniffs the filesystem from an open FileHandle at the current or specified offset.
    public func probe(fileHandle: FileHandle) -> SuperblockMetadata? {
        // Read the first 256KB to cover sector 0 (NTFS, XFS, FAT/exFAT, APFS), sector 2 (ext2/3/4 at 1024),
        // 64KB (Btrfs at 65536) and the first ZFS label (pool config at 16KB, uberblocks from 128KB).
        do {
            try fileHandle.seek(toOffset: 0)
            guard let headerData = try fileHandle.read(upToCount: 262144), headerData.count >= 1024 else {
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
        // 0. Check F2FS (Offset 1024, magic 0xF2F52010); before ext, which also has its superblock at 1024
        if let f2fs = probeF2FS(data: data) {
            return f2fs
        }

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

        // 4. Check ZFS (uberblock magic 0x00bab10c from offset 128KB)
        if let zfs = probeZFS(data: data) {
            return zfs
        }

        // 5. Check XFS (Offset 0, Magic "XFSB")
        if let xfs = probeXFS(data: data) {
            return xfs
        }

        // 6. Check UDF (volume recognition sequence at 32KB, "NSR02"/"NSR03")
        if let udf = probeUDF(data: data) {
            return udf
        }

        // 7. Check exFAT (Offset 3, "EXFAT   ")
        if let exfat = probeExFAT(data: data) {
            return exfat
        }

        // 8. Check VFAT / FAT32 (Offset 54 / 82)
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

    // MARK: - F2FS Sniffer

    private func probeF2FS(data: Data) -> SuperblockMetadata? {
        let sb = 1024
        guard data.count >= sb + 124 + 1024, readUInt32LE(data: data, offset: sb) == 0xF2F52010 else { return nil }
        let logBlockSize = readUInt32LE(data: data, offset: sb + 16)
        let blockSize: UInt32 = logBlockSize < 32 ? 1 << logBlockSize : 4096
        // volume_name: 512 UTF-16LE code units at offset 124
        let nameData = data.subdata(in: (sb + 124)..<(sb + 124 + 1024))
        let name = String(data: nameData, encoding: .utf16LittleEndian)?
            .split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        return SuperblockMetadata(
            fileSystemType: .f2fs,
            volumeName: name?.isEmpty == false ? name : nil,
            uuid: formatUUID(data.subdata(in: (sb + 108)..<(sb + 124))),
            blockSize: blockSize,
            totalBlocks: readUInt64LE(data: data, offset: sb + 36),
            freeBlocks: nil,
            isClean: nil,
            lastMountTime: nil,
            featuresDescription: "F2FS \(readUInt16LE(data: data, offset: sb + 4)).\(readUInt16LE(data: data, offset: sb + 6))"
        )
    }

    // MARK: - UDF Sniffer

    private func probeUDF(data: Data) -> SuperblockMetadata? {
        // Volume recognition sequence: 2048-byte descriptors from 32KB, identifier at byte 1 of each
        var offset = 32 * 1024
        var revision: String?
        while offset + 6 <= data.count && offset < 32 * 1024 + 16 * 2048 {
            guard let identifier = String(data: data.subdata(in: (offset + 1)..<(offset + 6)), encoding: .ascii) else { break }
            if identifier == "NSR02" || identifier == "NSR03" {
                revision = identifier
                break
            }
            guard ["BEA01", "CD001", "CDW02", "BOOT2"].contains(identifier) else { break }
            offset += 2048
        }
        guard let revision else { return nil }
        return SuperblockMetadata(
            fileSystemType: .udf,
            featuresDescription: revision == "NSR03" ? "UDF 2.00 or later" : "UDF 1.50 or earlier"
        )
    }

    // MARK: - ZFS Sniffer

    private func probeZFS(data: Data) -> SuperblockMetadata? {
        // Uberblock ring of label 0 starts at 128KB; slots are 1KB (ashift 9) up to 8KB (ashift 13), any may be in use
        let ringStart = 128 * 1024
        let magic: UInt64 = 0x00bab10c
        var found = false
        var offset = ringStart
        while offset + 8 <= data.count && offset < ringStart + 128 * 1024 {
            if readUInt64LE(data: data, offset: offset) == magic || readUInt64BE(data: data, offset: offset) == magic {
                found = true
                break
            }
            offset += 1024
        }
        guard found else { return nil }

        let config = parseZFSConfig(data: data)
        return SuperblockMetadata(
            fileSystemType: .zfs,
            volumeName: config.name,
            uuid: config.poolGUID.map { String(format: "%016llX", $0) },
            blockSize: nil,
            totalBlocks: nil,
            freeBlocks: nil,
            isClean: config.state.map { $0 == 1 },  // POOL_STATE_EXPORTED
            lastMountTime: nil,
            featuresDescription: "ZFS pool" + (config.state == 0 ? " (last used without export)" : "")
        )
    }

    /// Reads "name", "pool_guid" and "state" from the label's XDR-encoded nvlist at offset 16KB.
    private func parseZFSConfig(data: Data) -> (name: String?, poolGUID: UInt64?, state: UInt64?) {
        let start = 16 * 1024
        let end = min(data.count, 128 * 1024)
        // 4-byte header (encoding 1 = XDR), then nvlist version and flags
        guard end > start + 12, data[start] == 1 else { return (nil, nil, nil) }
        var offset = start + 12
        var name: String?
        var guid: UInt64?
        var state: UInt64?

        func int32() -> Int? {
            guard offset + 4 <= end else { return nil }
            defer { offset += 4 }
            return Int(Int32(bitPattern: readUInt32BE(data: data, offset: offset)))
        }
        func string() -> String? {
            guard let length = int32(), length >= 0, offset + length <= end else { return nil }
            defer { offset += (length + 3) & ~3 }
            return String(data: data.subdata(in: offset..<(offset + length)), encoding: .utf8)
        }

        while let encodedSize = int32(), encodedSize > 0 {
            let pairStart = offset - 4
            guard int32() != nil, let key = string(), let type = int32(), int32() != nil else { break }
            if key == "name" && type == 9 {  // DATA_TYPE_STRING
                name = string()
            } else if (key == "pool_guid" || key == "state") && type == 8, offset + 8 <= end {  // DATA_TYPE_UINT64
                let value = readUInt64BE(data: data, offset: offset)
                if key == "pool_guid" { guid = value } else { state = value }
            }
            offset = pairStart + encodedSize
            if name != nil && guid != nil && state != nil { break }
        }
        return (name, guid, state)
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

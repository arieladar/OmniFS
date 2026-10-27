import Foundation

/// Detailed metadata extracted directly from the filesystem superblock on disk.
public struct SuperblockMetadata: Sendable, Hashable {
    public let fileSystemType: FileSystemType
    public let volumeName: String?
    public let uuid: String?
    public let blockSize: UInt32?
    public let totalBlocks: UInt64?
    public let freeBlocks: UInt64?
    public let isClean: Bool?
    public let lastMountTime: Date?
    public let featuresDescription: String?

    public init(
        fileSystemType: FileSystemType,
        volumeName: String? = nil,
        uuid: String? = nil,
        blockSize: UInt32? = nil,
        totalBlocks: UInt64? = nil,
        freeBlocks: UInt64? = nil,
        isClean: Bool? = nil,
        lastMountTime: Date? = nil,
        featuresDescription: String? = nil
    ) {
        self.fileSystemType = fileSystemType
        self.volumeName = volumeName
        self.uuid = uuid
        self.blockSize = blockSize
        self.totalBlocks = totalBlocks
        self.freeBlocks = freeBlocks
        self.isClean = isClean
        self.lastMountTime = lastMountTime
        self.featuresDescription = featuresDescription
    }
}

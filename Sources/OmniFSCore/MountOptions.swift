import Foundation

public struct MountOptions: Sendable, Hashable {
    public var isReadOnly: Bool
    public var allowOther: Bool
    public var uid: UInt32?
    public var gid: UInt32?
    public var customMountPoint: String?
    public var cachingEnabled: Bool
    public var ignorePermissions: Bool

    public init(
        isReadOnly: Bool = false,
        allowOther: Bool = true,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        customMountPoint: String? = nil,
        cachingEnabled: Bool = true,
        ignorePermissions: Bool = false
    ) {
        self.isReadOnly = isReadOnly
        self.allowOther = allowOther
        self.uid = uid
        self.gid = gid
        self.customMountPoint = customMountPoint
        self.cachingEnabled = cachingEnabled
        self.ignorePermissions = ignorePermissions
    }

    public static let standardReadWrite = MountOptions(isReadOnly: false)
    public static let standardReadOnly = MountOptions(isReadOnly: true)
}

public struct MountResult: Sendable {
    public let success: Bool
    public let mountPoint: String
    public let fileSystemType: FileSystemType
    public let isReadOnly: Bool
    public let message: String

    public init(success: Bool, mountPoint: String, fileSystemType: FileSystemType, isReadOnly: Bool, message: String) {
        self.success = success
        self.mountPoint = mountPoint
        self.fileSystemType = fileSystemType
        self.isReadOnly = isReadOnly
        self.message = message
    }
}

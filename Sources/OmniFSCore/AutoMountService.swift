import Foundation
import DiskArbitration

public struct AutoMountConfig: Codable, Sendable {
    public var isEnabled: Bool
    public var mountReadOnly: Bool
    public var baseMountDirectory: String
    public var notifyOnMount: Bool
    public var autoFsckCheck: Bool

    public init(
        isEnabled: Bool = true,
        mountReadOnly: Bool = false,
        baseMountDirectory: String = "/Volumes",
        notifyOnMount: Bool = true,
        autoFsckCheck: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.mountReadOnly = mountReadOnly
        self.baseMountDirectory = baseMountDirectory
        self.notifyOnMount = notifyOnMount
        self.autoFsckCheck = autoFsckCheck
    }
}

public actor AutoMountService {
    public static let shared = AutoMountService()

    public private(set) var config: AutoMountConfig
    private var isMonitoring = false
    private let scanner = DiskScanner()
    private let mountManager = MountManager.shared

    public init(config: AutoMountConfig = AutoMountConfig()) {
        self.config = config
    }

    public func updateConfig(_ newConfig: AutoMountConfig) {
        self.config = newConfig
    }

    /// Evaluates attached partitions and automatically mounts any foreign partitions matching criteria.
    public func processConnectedPartitions() async -> [MountResult] {
        guard config.isEnabled else { return [] }

        var results: [MountResult] = []
        let partitions = await scanner.scanPartitions()

        for partition in partitions {
            // If it's a supported foreign filesystem that isn't already mounted
            if partition.fileSystemType.requiresOmniFSDriver && !partition.isMounted {
                let options = MountOptions(
                    isReadOnly: config.mountReadOnly,
                    customMountPoint: "\(config.baseMountDirectory)/\(partition.volumeName)"
                )
                if let result = try? await mountManager.mount(partition: partition, options: options) {
                    results.append(result)
                }
            }
        }
        return results
    }
}

import Foundation

/// State shared between `MountManager` and the `omnifs-vmd` helper for a volume served by the Linux VM.
public struct VMMountRecord: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ready, mounted, failed, repaired
    }

    public var pid: Int32
    public var status: Status
    public var ip: String?
    /// NFS export path in the guest, e.g. "/exports/Ariel Adar"
    public var exportPath: String?
    public var mountPoint: String
    public var readOnly: Bool
    public var message: String?

    public init(pid: Int32, status: Status, ip: String?, exportPath: String? = nil, mountPoint: String, readOnly: Bool, message: String?) {
        self.pid = pid
        self.status = status
        self.ip = ip
        self.exportPath = exportPath
        self.mountPoint = mountPoint
        self.readOnly = readOnly
        self.message = message
    }
}

/// A helper's state file plus its stop-request file (`<state>.stop`), which the unprivileged
/// app can create to ask the root helper to shut its VM down.
public struct VMMountState: Sendable {
    public let stateFile: URL

    public init(stateFile: URL) {
        self.stateFile = stateFile
    }

    public var stopFile: URL { stateFile.appendingPathExtension("stop") }

    /// Created by the app once its NFS mount succeeded, so the helper notices even a very quick unmount.
    public var mountedFile: URL { stateFile.appendingPathExtension("mounted") }

    public var stopRequested: Bool { FileManager.default.fileExists(atPath: stopFile.path) }

    public var mountConfirmed: Bool { FileManager.default.fileExists(atPath: mountedFile.path) }

    public func read() -> VMMountRecord? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(VMMountRecord.self, from: data)
    }

    public func write(_ record: VMMountRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: stateFile, options: .atomic)
        chmod(stateFile.path, 0o644)
    }

    public func update(_ body: (inout VMMountRecord) -> Void) {
        guard var record = read() else { return }
        body(&record)
        write(record)
    }

    public func requestStop() {
        FileManager.default.createFile(atPath: stopFile.path, contents: nil)
    }

    public func confirmMounted() {
        FileManager.default.createFile(atPath: mountedFile.path, contents: nil)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: stateFile)
        try? FileManager.default.removeItem(at: stopFile)
        try? FileManager.default.removeItem(at: mountedFile)
    }
}

public enum VMMountRegistry {
    private final class BundleToken {}

    /// User-owned folder holding the mount points of VM-served volumes (Finder lists them like /Volumes mounts).
    public static var volumesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OmniFS/Volumes", isDirectory: true)
    }

    /// Per-user directory holding one state file per partition served by a VM.
    public static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OmniFS", isDirectory: true)
    }

    public static func state(bsdName: String) -> VMMountState {
        VMMountState(stateFile: directory.appendingPathComponent("\(bsdName).json"))
    }

    /// Takes the per-partition operation lock (shared by the pane, the app and the CLI). Returns the lock's file
    /// descriptor, or nil if another mount or unmount of this partition is in progress. Release with `releaseLock`.
    public static func acquireOperationLock(bsdName: String) -> Int32? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("\(bsdName).lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    public static func releaseLock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// The live VM mount for a partition, if its helper is still running.
    public static func activeRecord(bsdName: String) -> VMMountRecord? {
        let state = state(bsdName: bsdName)
        guard let record = state.read(), record.status == .ready || record.status == .mounted else { return nil }
        // The helper runs as root, so EPERM still means it is alive
        guard kill(record.pid, 0) == 0 || errno == EPERM else {
            state.remove()
            return nil
        }
        return record
    }

    /// The bsd name of the partition served at a mount point, if any.
    public static func bsdName(forMountPoint mountPoint: String) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where file.hasSuffix(".json") {
            let bsdName = String(file.dropLast(".json".count))
            if activeRecord(bsdName: bsdName)?.mountPoint == mountPoint {
                return bsdName
            }
        }
        return nil
    }

    /// Cheap snapshot of attached disks, mounts and VM state: changes whenever a rescan could show something new.
    public static func storageSignature() -> String {
        let disks = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("disk") }.sorted()
        var mounts: [String] = []
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        if let buffer {
            for i in 0..<Int(count) {
                var fs = buffer[i]
                let onName = withUnsafeBytes(of: &fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                mounts.append("\(onName):\(fs.f_flags & UInt32(MNT_RDONLY))")
            }
        }
        let states = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { "\($0.lastPathComponent)@\((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0)" }
            .sorted()
        return (disks + mounts.sorted() + states).joined(separator: "|")
    }

    /// Whether `path` is itself the root of a mounted filesystem.
    public static func isMountPoint(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0, let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        let mountedOn = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == String(cString: resolved)
    }

    /// Kernel and initramfs built by scripts/build_vm_image.py.
    public static func vmAssetsDirectory() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["OMNIFS_VM_DIR"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let resources = Bundle(for: BundleToken.self).resourceURL {
            candidates.append(resources.appendingPathComponent("vm"))
        }
        if let exeDir = executableDirectory {
            candidates.append(exeDir.appendingPathComponent("vm"))
            // Development builds live somewhere below .build (.build/<triple>/debug, .build/out/Products/Debug, ...);
            // the VM image is built into .build/vm
            var dir = exeDir
            while dir.pathComponents.count > 1 {
                if dir.lastPathComponent == ".build" {
                    candidates.append(dir.appendingPathComponent("vm"))
                    break
                }
                dir.deleteLastPathComponent()
            }
        }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OmniFS/vm"))
        candidates.append(URL(fileURLWithPath: "/Library/Application Support/OmniFS/vm"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Image").path) }
    }

    /// The `omnifs-vmd` helper, next to the running executable or inside the app / pref pane bundle.
    public static func helperExecutable() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["OMNIFS_VMD"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        candidates.append(Bundle(for: BundleToken.self).bundleURL.appendingPathComponent("Contents/MacOS/omnifs-vmd"))
        if let exeDir = executableDirectory {
            candidates.append(exeDir.appendingPathComponent("omnifs-vmd"))
        }
        candidates.append(URL(fileURLWithPath: "/Library/Application Support/OmniFS/omnifs-vmd"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static var executableDirectory: URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    }
}

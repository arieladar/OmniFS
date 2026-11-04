import Foundation
import NetFS

public actor MountManager {
    public static let shared = MountManager()

    public init() {}

    /// Mounts a partition with the specified options.
    ///
    /// FAT/exFAT (and NTFS read-only) use the macOS drivers. ext2/3/4, NTFS read & write, Btrfs and XFS
    /// are served by the OmniFS Linux VM (`omnifs-vmd`) and mounted over NFS. The partition's current
    /// mount is restored if the new mount fails, so a failed remount never strands the volume.
    public func mount(partition: DiskPartition, options: MountOptions = .standardReadWrite) async throws -> MountResult {
        // One operation per partition at a time, across the pane, the app and the CLI: two helpers on one device
        // would mean two kernels writing the same filesystem
        guard let lock = VMMountRegistry.acquireOperationLock(bsdName: partition.bsdName) else {
            return failure(partition, options, "Another OmniFS operation on \(partition.bsdName) is in progress.")
        }
        defer { VMMountRegistry.releaseLock(lock) }

        var partition = partition
        let fsType = partition.fileSystemType
        let result: MountResult

        if fsType.isNativeWritableOnMacOS || (fsType.isNativeReadableOnMacOS && options.isReadOnly) {
            if VMMountRegistry.activeRecord(bsdName: partition.bsdName) != nil {
                // macOS must never mount the partition while the VM still has it open
                guard try await unmountVM(bsdName: partition.bsdName) else {
                    return failure(partition, options, "Could not unmount \(partition.bsdName); close any open files and try again.")
                }
                partition = await DiskScanner().inspectDisk(bsdName: partition.bsdName) ?? partition
            }
            result = try mountNative(partition: partition, options: options)
        } else if let vmFS = vmFilesystemName(for: fsType) {
            result = try await mountWithVM(partition: partition, filesystem: vmFS, options: options)
        } else {
            result = failure(partition, options, unsupportedMessage(for: fsType))
        }

        return result
    }

    /// Unmounts a mounted partition or mount point.
    public func unmount(bsdNameOrMountPoint: String, force: Bool = false) async throws -> Bool {
        let success: Bool
        if let bsdName = VMMountRegistry.activeRecord(bsdName: bsdNameOrMountPoint) != nil
            ? bsdNameOrMountPoint
            : VMMountRegistry.bsdName(forMountPoint: bsdNameOrMountPoint) {
            guard let lock = VMMountRegistry.acquireOperationLock(bsdName: bsdName) else { return false }
            defer { VMMountRegistry.releaseLock(lock) }
            success = try await unmountVM(bsdName: bsdName, force: force)
        } else {
            success = try unmountSync(bsdNameOrMountPoint, force: force)
        }
        return success
    }

    // MARK: - Driver Dispatchers

    private func mountNative(partition: DiskPartition, options: MountOptions) throws -> MountResult {
        if partition.isMounted && VMMountRegistry.activeRecord(bsdName: partition.bsdName) == nil {
            if partition.isReadOnly == options.isReadOnly, let mp = partition.mountPoint {
                return MountResult(
                    success: true,
                    mountPoint: mp,
                    fileSystemType: partition.fileSystemType,
                    isReadOnly: partition.isReadOnly,
                    message: "Already mounted at \(mp)"
                )
            }
            guard try unmountSync(partition.bsdName, force: false) else {
                return failure(partition, options, "Could not unmount \(partition.bsdName); close any open files and try again.")
            }
        }

        // Let DiskArbitration create the mount point under /Volumes; only an explicit custom path is passed through
        var args = ["mount"]
        if options.isReadOnly {
            args.append("readOnly")
        }
        if let custom = options.customMountPoint {
            try? FileManager.default.createDirectory(atPath: custom, withIntermediateDirectories: true)
            args += ["-mountPoint", custom]
        }
        args.append(partition.bsdName)

        let (status, output) = try run("/usr/sbin/diskutil", args)
        guard status == 0 else {
            return failure(partition, options, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let mountPoint = currentMountPoint(bsdName: partition.bsdName) ?? options.customMountPoint ?? ""
        return MountResult(
            success: true,
            mountPoint: mountPoint,
            fileSystemType: partition.fileSystemType,
            isReadOnly: options.isReadOnly,
            message: "Mounted natively at \(mountPoint)"
        )
    }

    private func mountWithVM(partition: DiskPartition, filesystem: String, options: MountOptions) async throws -> MountResult {
        guard let helper = VMMountRegistry.helperExecutable(), let vmDir = VMMountRegistry.vmAssetsDirectory() else {
            return failure(partition, options, "The OmniFS Linux VM is not installed. Build it with scripts/build_vm_image.py and reinstall OmniFS.")
        }

        // Decided before any existing VM mount is torn down below: afterwards the partition snapshot still says
        // "mounted" with no VM record, which would look like a native macOS mount
        let wasMountedNatively = partition.isMounted && VMMountRegistry.activeRecord(bsdName: partition.bsdName) == nil

        if let existing = VMMountRegistry.activeRecord(bsdName: partition.bsdName) {
            if VMMountRegistry.isMountPoint(existing.mountPoint) && existing.readOnly == options.isReadOnly {
                return MountResult(
                    success: true,
                    mountPoint: existing.mountPoint,
                    fileSystemType: partition.fileSystemType,
                    isReadOnly: existing.readOnly,
                    message: "Already mounted at \(existing.mountPoint)"
                )
            }
            guard try await unmountVM(bsdName: partition.bsdName) else {
                return failure(partition, options, "Could not unmount \(existing.mountPoint); close any open files and try again.")
            }
        }

        // Release the partition from macOS (e.g. its read-only NTFS mount) so the VM can open the device
        if wasMountedNatively {
            guard try unmountSync(partition.bsdName, force: false) else {
                return failure(partition, options, "Could not unmount \(partition.bsdName); close any open files and try again.")
            }
        }
        trace("\(partition.bsdName): mount \(filesystem) \(options.isReadOnly ? "ro" : "rw") via VM (was mounted natively: \(wasMountedNatively))")

        let mountName = partition.volumeName.isEmpty ? partition.bsdName : partition.volumeName
        // NetFS picks the final /Volumes path (e.g. "Name-1" if the name is taken); the helper watches the path
        // recorded in the state file once mounted
        let targetDir = options.customMountPoint ?? "/Volumes/\(mountName)"
        if let custom = options.customMountPoint {
            try? FileManager.default.createDirectory(atPath: custom, withIntermediateDirectories: true)
        }

        try? FileManager.default.createDirectory(at: VMMountRegistry.directory, withIntermediateDirectories: true)
        let state = VMMountRegistry.state(bsdName: partition.bsdName)
        state.remove()

        func fail(_ message: String) -> MountResult {
            trace("\(partition.bsdName): failed: \(message)")
            if let custom = options.customMountPoint {
                rmdir(custom)
            }
            if wasMountedNatively {
                _ = try? run("/usr/sbin/diskutil", ["mount", partition.bsdName])
            }
            return failure(partition, options, message)
        }
        let logURL = VMMountRegistry.directory.appendingPathComponent("\(partition.bsdName).log")
        try? FileManager.default.removeItem(at: logURL)

        // The helper runs as the current user and reports progress via the state file
        var helperArgs = [
            helper.path,
            "--disk", partition.devicePath,
            "--fs", filesystem,
            "--mountpoint", targetDir,
            "--state", state.stateFile.path,
            "--vm-dir", vmDir.path,
            "--name", mountName,
        ]
        if options.isReadOnly {
            helperArgs.append("--ro")
        }
        guard let helperPID = try startHelper(helperArgs, log: logURL) else {
            state.remove()
            return fail("Could not start the OmniFS VM.")
        }
        trace("\(partition.bsdName): helper started (pid \(helperPID))")
        func helperAlive() -> Bool { kill(helperPID, 0) == 0 }
        // Before macOS may remount the partition, the guest must have released it
        func stopHelper() async {
            state.requestStop()
            for _ in 0..<80 where helperAlive() {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if helperAlive() {
                kill(helperPID, SIGKILL)
            }
            state.remove()
        }

        var record: VMMountRecord?
        // Up to 3 minutes: the user may still be answering the authorization dialog
        for _ in 0..<360 {
            if let current = state.read() {
                record = current
                break
            }
            if !helperAlive() {
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard let record, record.status == .ready, let ip = record.ip else {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let reason = log.split(separator: "\n").last { $0.hasPrefix("omnifs-vmd:") || $0.hasPrefix("OMNIFS_ERROR") }
                ?? log.split(separator: "\n").last
            await stopHelper()
            return fail(record?.message ?? reason.map { "The OmniFS VM failed: \($0)" } ?? "The OmniFS VM did not start in time.")
        }

        let mounted = mountExport(host: ip, path: record.exportPath ?? "/exports/\(mountName)", at: options.customMountPoint)
        guard let mountPoint = mounted.mountPoint else {
            await stopHelper()
            return fail("Could not mount the volume from the OmniFS VM: \(mounted.error)")
        }
        state.update { $0.mountPoint = mountPoint }
        state.confirmMounted()
        trace("\(partition.bsdName): mounted at \(mountPoint)")

        let mode = options.isReadOnly ? "read-only" : "read & write"
        return MountResult(
            success: true,
            mountPoint: mountPoint,
            fileSystemType: partition.fileSystemType,
            isReadOnly: options.isReadOnly,
            message: "Mounted \(partition.fileSystemType) (\(mode)) via the OmniFS Linux VM at \(mountPoint)"
        )
    }

    /// Mounts the guest's NFS export through NetFS, the framework behind Finder's Connect to Server. Mounting with
    /// mount_nfs instead leaves Finder unable to delete (it reports items "had to be skipped"); NetFS also mounts into
    /// /Volumes without administrator rights. Without `directory`, NetFS chooses /Volumes/<export name>.
    private func mountExport(host: String, path: String, at directory: String?) -> (mountPoint: String?, error: String) {
        var components = URLComponents()
        components.scheme = "nfs"
        components.host = host
        components.path = path
        guard let url = components.url else { return (nil, "invalid export path \(path)") }

        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
        let mountOptions = NSMutableDictionary()
        // The guest serves every file as root, which Finder would treat as someone else's and refuse to modify;
        // show them as the current user (the guest still performs the operations as root)
        mountOptions[kNetFSMountFlagsKey] = Int(MNT_IGNORE_OWNERSHIP | MNT_NOSUID | MNT_NODEV)
        if directory != nil {
            mountOptions[kNetFSMountAtMountDirKey] = true
        }
        // NetFS refuses mount directories reached through a symlink (ELOOP), e.g. /var/folders -> /private/var/folders.
        // realpath, not resolvingSymlinksInPath, which strips the "/private" it resolves to
        let mountDirectory = directory.map { path -> URL in
            guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path) }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
        var mountPoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(
            url as CFURL, mountDirectory.map { $0 as CFURL }, nil, nil, openOptions, mountOptions, &mountPoints
        )
        let mountPoint = (mountPoints?.takeRetainedValue() as? [String])?.first
        guard status == 0, let mountPoint else {
            return (nil, status > 0 ? String(cString: strerror(status)) : "NetFS error \(status)")
        }
        // NetFS mounts with network (NLM) file locking, and lock requests to the guest never complete: every open
        // with a lock (Finder and copyfile take them) would hang. Only this Mac uses the volume, so keep locks local.
        // NetFS takes no NFS options, so update the mount right away; flags not repeated here are dropped.
        let update = try? run("/sbin/mount", ["-u", "-o", "locallocks,noowners,nodev,nosuid", mountPoint])
        guard update?.status == 0 else {
            _ = try? unmountSync(mountPoint, force: true)
            return (nil, "could not switch the mount to local file locking: \(update?.output ?? "")")
        }
        return (mountPoint, "")
    }

    /// Checks and repairs a partition with its Linux tool inside the VM (e2fsck, ntfsfix, xfs_repair, btrfs check,
    /// zpool scrub). The partition is unmounted for the check and mounted again the way it was afterwards.
    public func repair(partition: DiskPartition) async throws -> MountResult {
        let options = MountOptions(isReadOnly: partition.isReadOnly)
        guard let lock = VMMountRegistry.acquireOperationLock(bsdName: partition.bsdName) else {
            return failure(partition, options, "Another OmniFS operation on \(partition.bsdName) is in progress.")
        }
        defer { VMMountRegistry.releaseLock(lock) }

        guard partition.supportsRepair, let filesystem = vmFilesystemName(for: partition.fileSystemType) else {
            return failure(partition, options, "Check & Repair supports NTFS, ext2/3/4, Btrfs, XFS, ZFS and F2FS. For \(partition.fileSystemType), use Disk Utility's First Aid or the tools of the system that created it.")
        }
        guard let helper = VMMountRegistry.helperExecutable(), let vmDir = VMMountRegistry.vmAssetsDirectory() else {
            return failure(partition, options, "The OmniFS Linux VM is not installed. Build it with scripts/build_vm_image.py and reinstall OmniFS.")
        }

        // Remember how the volume was mounted so it can be restored afterwards
        let vmMount = VMMountRegistry.activeRecord(bsdName: partition.bsdName)
        let wasMountedNatively = partition.isMounted && vmMount == nil
        if vmMount != nil {
            guard try await unmountVM(bsdName: partition.bsdName) else {
                return failure(partition, options, "Could not unmount \(partition.bsdName); close any open files and try again.")
            }
        } else if wasMountedNatively {
            guard try unmountSync(partition.bsdName, force: false) else {
                return failure(partition, options, "Could not unmount \(partition.bsdName); close any open files and try again.")
            }
        }
        trace("\(partition.bsdName): check & repair \(filesystem)")

        let state = VMMountRegistry.state(bsdName: partition.bsdName)
        state.remove()
        let logURL = VMMountRegistry.directory.appendingPathComponent("\(partition.bsdName).log")
        try? FileManager.default.removeItem(at: logURL)
        let helperArgs = [
            helper.path, "--disk", partition.devicePath, "--fs", filesystem,
            "--state", state.stateFile.path, "--vm-dir", vmDir.path, "--repair",
        ]

        var report: VMMountRecord?
        if let helperPID = try startHelper(helperArgs, log: logURL) {
            // No time limit: checking a large drive can take a long time, and interrupting it is what does damage
            while kill(helperPID, 0) == 0 {
                try await Task.sleep(for: .seconds(1))
            }
            report = state.read()
            state.remove()
        }
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let succeeded = report?.status == .repaired
        var message = report?.message
            ?? log.split(separator: "\n").last { $0.hasPrefix("omnifs-vmd:") || $0.hasPrefix("OMNIFS_ERROR") }.map(String.init)
            ?? "The check could not be run."
        trace("\(partition.bsdName): check & repair \(succeeded ? "done" : "failed"): \(message)")

        // Mount the volume again the way it was
        var mountPoint = ""
        if let vmMount {
            let current = await DiskScanner().inspectDisk(bsdName: partition.bsdName) ?? partition
            let remount = try await mountWithVM(
                partition: current, filesystem: filesystem,
                // NetFS removes its /Volumes mount points on unmount; let it choose again
                options: MountOptions(
                    isReadOnly: vmMount.readOnly,
                    customMountPoint: vmMount.mountPoint.hasPrefix("/Volumes/") ? nil : vmMount.mountPoint
                )
            )
            mountPoint = remount.success ? remount.mountPoint : ""
            if !remount.success {
                message += " The volume could not be mounted again: \(remount.message)"
            }
        } else if wasMountedNatively {
            _ = try? run("/usr/sbin/diskutil", ["mount", partition.bsdName])
            mountPoint = currentMountPoint(bsdName: partition.bsdName) ?? ""
        }
        return MountResult(
            success: succeeded,
            mountPoint: mountPoint,
            fileSystemType: partition.fileSystemType,
            isReadOnly: vmMount?.readOnly ?? partition.isReadOnly,
            message: message
        )
    }

    /// Launches omnifs-vmd in the background with its output going to `log`; returns its process ID.
    private func startHelper(_ arguments: [String], log: URL) throws -> Int32? {
        // Backgrounded with its output redirected so the launching shell returns at once
        let command = arguments.map(shellQuote).joined(separator: " ") + " </dev/null > \(shellQuote(log.path)) 2>&1 & echo $!"
        let (status, output) = try run("/bin/sh", ["-c", command])
        guard status == 0, let pid = Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    /// Unmounts a VM-served volume and waits for the helper to shut the VM down and release the partition.
    private func unmountVM(bsdName: String, force: Bool = false) async throws -> Bool {
        guard let record = VMMountRegistry.activeRecord(bsdName: bsdName) else { return true }
        if VMMountRegistry.isMountPoint(record.mountPoint) {
            guard try unmountSync(record.mountPoint, force: force) else { return false }
        }
        VMMountRegistry.state(bsdName: bsdName).requestStop()
        // Longer than the helper's own 30 s force-stop, so a slow guest shutdown still counts as success
        for _ in 0..<80 where VMMountRegistry.activeRecord(bsdName: bsdName) != nil {
            try await Task.sleep(for: .milliseconds(500))
        }
        return VMMountRegistry.activeRecord(bsdName: bsdName) == nil
    }

    private func vmFilesystemName(for type: FileSystemType) -> String? {
        switch type {
        case .ext2, .ext3, .ext4: return "ext4"
        case .ntfs: return "ntfs"
        case .btrfs: return "btrfs"
        case .xfs: return "xfs"
        case .zfs: return "zfs"
        case .f2fs: return "f2fs"
        case .udf: return "udf"
        default: return nil
        }
    }

    private func unsupportedMessage(for type: FileSystemType) -> String {
        switch type {
        case .unknown(let magic) where magic == "Linux" && geteuid() != 0:
            return "This Linux partition could not be identified without administrator access. Run `sudo omnifs inspect /dev/<disk>` to identify it."
        default:
            return "No compatible driver found for \(type)"
        }
    }

    // MARK: - Process Helpers

    /// Appends to a persistent diagnostics log (the per-mount helper log is replaced on every attempt).
    private func trace(_ message: String) {
        let url = VMMountRegistry.directory.appendingPathComponent("omnifs.log")
        let line = Data("\(Date().formatted(.iso8601)) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }


    private func unmountSync(_ target: String, force: Bool) throws -> Bool {
        var args = ["unmount"]
        if force {
            args.append("force")
        }
        args.append(target)
        if try run("/usr/sbin/diskutil", args).status == 0 {
            return true
        }
        // Fall back to umount for mounts that diskutil does not manage
        return try run("/sbin/umount", (force ? ["-f"] : []) + [target]).status == 0
    }

    private func currentMountPoint(bsdName: String) -> String? {
        guard let (status, output) = try? run("/usr/sbin/diskutil", ["info", "-plist", bsdName]), status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(output.utf8), options: [], format: nil) as? [String: Any],
              let mp = plist["MountPoint"] as? String, !mp.isEmpty else {
            return nil
        }
        return mp
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func failure(_ partition: DiskPartition, _ options: MountOptions, _ message: String) -> MountResult {
        MountResult(
            success: false,
            mountPoint: partition.mountPoint ?? "",
            fileSystemType: partition.fileSystemType,
            isReadOnly: options.isReadOnly,
            message: message
        )
    }
}

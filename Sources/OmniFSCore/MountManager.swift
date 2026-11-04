import Foundation

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
            if existing.status == .mounted && existing.readOnly == options.isReadOnly {
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
        // /Volumes is root-only and macOS 27 refuses to hand disk devices to users, so VM-served volumes mount in a
        // user-owned folder (Finder still lists them by name) and the helper opens the partition through authopen:
        // a single macOS authorization dialog, no root shell
        let targetDir = options.customMountPoint ?? uniqueVolumePath(for: mountName, in: VMMountRegistry.volumesDirectory.path)
        try? FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        try? FileManager.default.createDirectory(at: VMMountRegistry.directory, withIntermediateDirectories: true)
        let state = VMMountRegistry.state(bsdName: partition.bsdName)
        state.remove()

        func fail(_ message: String) -> MountResult {
            trace("\(partition.bsdName): failed: \(message)")
            rmdir(targetDir)
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

        let (mountStatus, mountOutput) = try run("/sbin/mount_nfs", [
            // noowners: the guest serves every file as root, which Finder would treat as someone else's and refuse
            // to trash or modify; show them as the current user (the guest still performs the operations as root)
            "-o", "vers=3,tcp,port=2049,mountport=20048,nolocks,locallocks,noowners,intr",
            "\(ip):\(record.exportPath ?? "/mnt/volume")", targetDir,
        ])
        guard mountStatus == 0 else {
            await stopHelper()
            return fail("Could not mount the volume from the OmniFS VM: \(mountOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        state.confirmMounted()
        trace("\(partition.bsdName): mounted at \(targetDir)")

        let mode = options.isReadOnly ? "read-only" : "read & write"
        return MountResult(
            success: true,
            mountPoint: targetDir,
            fileSystemType: partition.fileSystemType,
            isReadOnly: options.isReadOnly,
            message: "Mounted \(partition.fileSystemType) (\(mode)) via the OmniFS Linux VM at \(targetDir)"
        )
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
                options: MountOptions(isReadOnly: vmMount.readOnly, customMountPoint: vmMount.mountPoint)
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

    private func uniqueVolumePath(for name: String, in directory: String) -> String {
        var path = "\(directory)/\(name)"
        var suffix = 1
        while FileManager.default.fileExists(atPath: path) && !isEmptyDirectory(path) {
            path = "\(directory)/\(name) \(suffix)"
            suffix += 1
        }
        return path
    }

    private func isEmptyDirectory(_ path: String) -> Bool {
        !VMMountRegistry.isMountPoint(path) && ((try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty ?? false)
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

import CryptoKit
import Foundation
import Testing
@testable import OmniFSCore

// End-to-end tests against real disks: raw disk images formatted by the Linux guest, attached as /dev/diskN
// devices and mounted read & write through the OmniFS Linux VM, exactly as the app does.
//
// They boot VMs and attach disk images, so they only run on request:
//   OMNIFS_INTEGRATION=1 swift test --filter VolumeIntegrationTests
// Prerequisites: the VM image (scripts/build_vm_image.py) and a signed .build/debug/omnifs-vmd.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let helper = repoRoot.appendingPathComponent(".build/debug/omnifs-vmd")
private let vmDir = repoRoot.appendingPathComponent(".build/vm")

private let integrationEnabled = ProcessInfo.processInfo.environment["OMNIFS_INTEGRATION"] == "1"
    && FileManager.default.isExecutableFile(atPath: helper.path)
    && FileManager.default.fileExists(atPath: vmDir.appendingPathComponent("Image").path)

/// Limits how many test disks (each with its VMs) exist at once: all of them at once (40+ VMs) overloaded macOS's
/// disk services. Half the cores keeps every core busy without that.
private actor DiskSlots {
    static let shared = DiskSlots(limit: max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// A formatted raw disk image attached (without mounting) as a user-owned /dev/diskN.
private final class TestDisk {
    let image: URL
    let bsdName: String
    let wholeDisk: String
    let workDir: URL

    var devicePath: String { "/dev/\(bsdName)" }

    /// `windowsDirty` sets the NTFS "volume is dirty" flag the way Windows leaves it after hibernation, Fast Startup
    /// or an unclean shutdown. (Linux's ntfs3 driver never sets it in normal use, so a guest crash does not.)
    init(filesystem: String, sizeMB: Int = 512, windowsDirty: Bool = false) async throws {
        await DiskSlots.shared.acquire()
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("omnifs-it-\(UUID().uuidString)")
        let image = workDir.appendingPathComponent("\(filesystem).img")
        var attached: String?
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try run("/usr/sbin/mkfile", ["-n", "\(sizeMB)m", image.path])
            try await Self.format(image: image, filesystem: filesystem, workDir: workDir)
            if windowsDirty {
                try Self.setNTFSDirtyFlag(image: image)
            }

            // diskutil image, not the deprecated hdiutil (whose attaches took ~2 minutes each on macOS 27.3)
            let output = try run("/usr/sbin/diskutil", ["image", "attach", "--noMount", image.path])
            guard let device = output.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }) else {
                throw TestError("diskutil image attach printed no device: \(output)")
            }
            let whole = String(device.dropFirst("/dev/".count))
            attached = whole
            // Filesystems formatted on the raw image are the whole disk; ZFS partitions a whole disk itself (like on a
            // real drive), so its pool is the first partition other than ZFS's reserved one
            let list = try PropertyListSerialization.propertyList(
                from: Data(try run("/usr/sbin/diskutil", ["list", "-plist", whole]).utf8), format: nil
            ) as? [String: Any]
            let partitions = ((list?["AllDisksAndPartitions"] as? [[String: Any]])?.first?["Partitions"] as? [[String: Any]]) ?? []
            self.bsdName = partitions.first { !(($0["Content"] as? String) ?? "").hasPrefix("6A945A3B") }?["DeviceIdentifier"] as? String
                ?? whole
            self.wholeDisk = whole
            self.workDir = workDir
            self.image = image
        } catch {
            // No TestDisk means no detach(): clean up and give the slot back here, or later tests wait forever
            if let attached {
                _ = try? run("/usr/sbin/diskutil", ["eject", "/dev/\(attached)"])
            }
            try? FileManager.default.removeItem(at: workDir)
            await DiskSlots.shared.release()
            throw error
        }
    }

    /// Formats the image inside the guest (`omnifs-vmd --format`), then shuts the VM down cleanly.
    private static func format(image: URL, filesystem: String, workDir: URL) async throws {
        let state = VMMountState(stateFile: workDir.appendingPathComponent("format.json"))
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            "--disk", image.path, "--fs", filesystem, "--format", "--name", "OMNIFS",
            "--mountpoint", workDir.appendingPathComponent("format-mnt").path,
            "--state", state.stateFile.path, "--vm-dir", vmDir.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let ready = try await waitUntil(seconds: 60) { state.read() != nil || !process.isRunning }
        let record = state.read()
        guard ready, record?.status == .ready else {
            process.terminate()
            throw TestError("formatting \(filesystem) failed: \(record?.message ?? "helper exited")")
        }
        state.requestStop()
        _ = try await waitUntil(seconds: 40) { !process.isRunning }
    }

    /// Sets VOLUME_IS_DIRTY in $Volume's $VOLUME_INFORMATION, in both the MFT and $MFTMirr.
    private static func setNTFSDirtyFlag(image: URL) throws {
        let file = try FileHandle(forUpdating: image)
        defer { try? file.close() }
        let boot = try #require(try file.read(upToCount: 512))
        func u16(_ d: Data, _ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u64(_ d: Data, _ o: Int) -> Int { (0..<8).reduce(0) { $0 | Int(d[o + $1]) << (8 * $1) } }
        let bytesPerSector = u16(boot, 0x0B)
        let cluster = bytesPerSector * Int(boot[0x0D])
        let clustersPerRecord = Int(Int8(bitPattern: boot[0x40]))
        let recordSize = clustersPerRecord > 0 ? cluster * clustersPerRecord : 1 << -clustersPerRecord

        for lcn in [u64(boot, 0x30), u64(boot, 0x38)] {  // $MFT, $MFTMirr
            let offset = UInt64(lcn * cluster + 3 * recordSize)  // record 3 = $Volume
            try file.seek(toOffset: offset)
            var record = try #require(try file.read(upToCount: recordSize))
            guard record.prefix(4) == Data("FILE".utf8) else { throw TestError("no $Volume record at \(offset)") }
            // Undo the update-sequence fixups (each sector's last two bytes), edit, then redo them
            let usa = u16(record, 4), usaCount = u16(record, 6)
            let usn = record.subdata(in: usa..<(usa + 2))
            for i in 1..<usaCount {
                record.replaceSubrange((i * bytesPerSector - 2)..<(i * bytesPerSector), with: record.subdata(in: (usa + 2 * i)..<(usa + 2 * i + 2)))
            }
            var attribute = u16(record, 0x14)
            while true {
                let type = u16(record, attribute) | u16(record, attribute + 2) << 16
                guard type != 0xFFFF_FFFF else { throw TestError("no $VOLUME_INFORMATION attribute") }
                if type == 0x70 {
                    let flagsAt = attribute + u16(record, attribute + 0x14) + 10
                    record[flagsAt] |= 0x01  // VOLUME_IS_DIRTY
                    break
                }
                attribute += u16(record, attribute + 4) | u16(record, attribute + 6) << 16
            }
            for i in 1..<usaCount {
                let end = i * bytesPerSector - 2
                record.replaceSubrange((usa + 2 * i)..<(usa + 2 * i + 2), with: record.subdata(in: end..<(end + 2)))
                record.replaceSubrange(end..<(end + 2), with: usn)
            }
            try file.seek(toOffset: offset)
            try file.write(contentsOf: record)
        }
    }

    /// Also tears down a VM mount a failed test left behind, so failures do not leak mounts and VMs
    func detach() {
        if let record = VMMountRegistry.activeRecord(bsdName: bsdName) {
            _ = try? run("/sbin/umount", ["-f", record.mountPoint])
            VMMountRegistry.state(bsdName: bsdName).requestStop()
            let deadline = Date().addingTimeInterval(40)
            while VMMountRegistry.activeRecord(bsdName: bsdName) != nil && Date() < deadline {
                usleep(250_000)
            }
        }
        _ = try? run("/usr/sbin/diskutil", ["eject", "/dev/\(wholeDisk)"])
        Task { await DiskSlots.shared.release() }
        try? FileManager.default.removeItem(at: workDir)
    }
}

/// Every filesystem OmniFS serves through the VM.
private let allFilesystems = ProcessInfo.processInfo.environment["OMNIFS_TEST_FILESYSTEMS"]
    .map { $0.split(separator: ",").map(String.init) }  // e.g. OMNIFS_TEST_FILESYSTEMS=ntfs,ext4 for a quick run
    ?? ["ntfs", "ext2", "ext3", "ext4", "btrfs", "xfs", "zfs", "f2fs", "udf"]

/// Filesystems with a checker (udftools has none)
private let repairableFilesystems = allFilesystems.filter { $0 != "udf" }

private func expectedType(_ filesystem: String) -> FileSystemType {
    switch filesystem {
    case "ntfs": return .ntfs
    case "ext2": return .ext2
    case "ext3": return .ext3
    case "ext4": return .ext4
    case "btrfs": return .btrfs
    case "zfs": return .zfs
    case "f2fs": return .f2fs
    case "udf": return .udf
    default: return .xfs
    }
}

private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw TestError("\(executable) \(arguments.joined(separator: " ")) failed: \(output)")
    }
    return output
}

private func waitUntil(seconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(250))
    }
    return condition()
}

/// Renaming or deleting a folder right after its files were used can be refused for a moment: macOS's SMB client
/// is still closing them (see the smb.conf comment in Resources/vm/init). Programs have to retry, as here.
private func retryingBusy<T>(_ body: () throws -> T) throws -> T {
    let deadline = Date().addingTimeInterval(5)
    while true {
        do {
            return try body()
        } catch let error as NSError where Date() < deadline {
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? error.code
            guard [Int(EACCES), Int(EBUSY), Int(EPERM)].contains(posix) || error.code == NSFileWriteNoPermissionError else { throw error }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func makeRandomFile(at url: URL, bytes: Int) throws {
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
    try data.write(to: url)
}

// Every case has its own disk image and VM, so cases run in parallel across all cores. A hang fails the test
// instead of stalling the run.
@Suite("Volume integration (real disks through the OmniFS VM)", .enabled(if: integrationEnabled), .timeLimit(.minutes(3)))
struct VolumeIntegrationTests {
    init() {
        setenv("OMNIFS_VMD", helper.path, 1)
        setenv("OMNIFS_VM_DIR", vmDir.path, 1)
    }

    /// Mounts the disk read & write (or read-only) at a fresh mount point and returns that path.
    private func mount(_ disk: TestDisk, readOnly: Bool = false, manager: MountManager = MountManager()) async throws -> String {
        let partition = try #require(await DiskScanner().inspectDisk(bsdName: disk.bsdName))
        let mountPoint = disk.workDir.appendingPathComponent("mnt-\(UUID().uuidString.prefix(8))").path
        let result = try await manager.mount(
            partition: partition,
            options: MountOptions(isReadOnly: readOnly, customMountPoint: mountPoint)
        )
        #expect(result.success, "mount failed: \(result.message)")
        #expect(VMMountRegistry.isMountPoint(mountPoint))
        return mountPoint
    }

    private func unmount(_ disk: TestDisk, manager: MountManager = MountManager()) async throws {
        #expect(try await manager.unmount(bsdNameOrMountPoint: disk.bsdName))
        // The helper must have shut the guest down and released the partition
        #expect(VMMountRegistry.activeRecord(bsdName: disk.bsdName) == nil)
    }

    // MARK: - Connecting drives

    @Test("A newly connected drive is detected with its filesystem", arguments: allFilesystems)
    func detectsConnectedDrive(filesystem: String) async throws {
        let disk = try await TestDisk(filesystem: filesystem)
        defer { disk.detach() }

        let partition = try #require(await DiskScanner().inspectDisk(bsdName: disk.bsdName))
        #expect(partition.fileSystemType == expectedType(filesystem))
        #expect(partition.driveKind == .diskImage)
        #expect(partition.isMounted == false)
        #expect(partition.isForeignOrRemovable)
        #expect(partition.canOmniFSMountReadWrite)
        #expect(partition.supportsRepair == repairableFilesystems.contains(filesystem))

        let all = await DiskScanner().scanPartitions()
        #expect(all.contains { $0.bsdName == disk.bsdName })
    }

    // MARK: - Copying in and out, moving, deleting

    @Test("Copy in, copy out, move, rename and delete on a mounted drive", arguments: allFilesystems)
    func fileOperations(filesystem: String) async throws {
        let disk = try await TestDisk(filesystem: filesystem)
        defer { disk.detach() }
        let fm = FileManager.default
        let volume = URL(fileURLWithPath: try await mount(disk))

        // Copy in: a 24 MB file and a folder tree with a Unicode name
        let local = disk.workDir.appendingPathComponent("local", isDirectory: true)
        try fm.createDirectory(at: local.appendingPathComponent("Ünïcode folder/nested"), withIntermediateDirectories: true)
        let big = local.appendingPathComponent("big.bin")
        try makeRandomFile(at: big, bytes: 24 << 20)
        try makeRandomFile(at: local.appendingPathComponent("Ünïcode folder/nested/small.bin"), bytes: 4096)
        try "hello from macOS".write(to: local.appendingPathComponent("Ünïcode folder/note.txt"), atomically: true, encoding: .utf8)

        try fm.copyItem(at: big, to: volume.appendingPathComponent("big.bin"))
        try fm.copyItem(at: local.appendingPathComponent("Ünïcode folder"), to: volume.appendingPathComponent("Ünïcode folder"))
        #expect(try sha256(volume.appendingPathComponent("big.bin")) == sha256(big))
        #expect(try String(contentsOf: volume.appendingPathComponent("Ünïcode folder/note.txt"), encoding: .utf8) == "hello from macOS")

        // Copy out
        let out = disk.workDir.appendingPathComponent("copied-out", isDirectory: true)
        try fm.copyItem(at: volume.appendingPathComponent("Ünïcode folder"), to: out)
        #expect(try sha256(out.appendingPathComponent("nested/small.bin"))
            == sha256(local.appendingPathComponent("Ünïcode folder/nested/small.bin")))

        // Move into the drive (source disappears), move and rename within it
        let moveMe = local.appendingPathComponent("move-me.bin")
        try makeRandomFile(at: moveMe, bytes: 1 << 20)
        let moveHash = try sha256(moveMe)
        try fm.moveItem(at: moveMe, to: volume.appendingPathComponent("move-me.bin"))
        #expect(!fm.fileExists(atPath: moveMe.path))
        try fm.moveItem(at: volume.appendingPathComponent("move-me.bin"), to: volume.appendingPathComponent("Ünïcode folder/moved.bin"))
        try retryingBusy { try fm.moveItem(at: volume.appendingPathComponent("Ünïcode folder"), to: volume.appendingPathComponent("Renamed folder")) }
        #expect(try sha256(volume.appendingPathComponent("Renamed folder/moved.bin")) == moveHash)

        // Overwrite in place
        try "updated".write(to: volume.appendingPathComponent("Renamed folder/note.txt"), atomically: false, encoding: .utf8)
        #expect(try String(contentsOf: volume.appendingPathComponent("Renamed folder/note.txt"), encoding: .utf8) == "updated")

        // Delete a file and a whole folder tree
        try fm.removeItem(at: volume.appendingPathComponent("big.bin"))
        try retryingBusy { try fm.removeItem(at: volume.appendingPathComponent("Renamed folder")) }
        #expect(!fm.fileExists(atPath: volume.appendingPathComponent("big.bin").path))
        #expect(!fm.fileExists(atPath: volume.appendingPathComponent("Renamed folder").path))

        // File locks (Finder and copyfile take them) must not hang: they stay local to this Mac
        let lockFile = volume.appendingPathComponent("locked.txt")
        try "lock".write(to: lockFile, atomically: false, encoding: .utf8)
        let fd = open(lockFile.path, O_RDWR)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        flock(fd, LOCK_UN)
        close(fd)
        try fm.removeItem(at: lockFile)

        // Mac metadata (extended attributes) round-trips; macOS keeps it in ._ files on these volumes
        let tagged = volume.appendingPathComponent("tagged.txt")
        try "tagged".write(to: tagged, atomically: false, encoding: .utf8)
        #expect(setxattr(tagged.path, "com.apple.omnifs.test", "hello", 5, 0, 0) == 0)
        var buffer = [UInt8](repeating: 0, count: 16)
        #expect(getxattr(tagged.path, "com.apple.omnifs.test", &buffer, buffer.count, 0, 0) == 5)
        try fm.removeItem(at: tagged)

        // Files must show as the user's own, or Finder refuses to modify or trash them
        let attributes = try fm.attributesOfItem(atPath: volume.path)
        #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())

        try await unmount(disk)
    }

    // MARK: - Btrfs subvolumes and ZFS datasets

    @Test("Btrfs subvolumes and ZFS child datasets are reachable and writable", arguments: [
        ("btrfs", "@home", "subvolume.txt", "inside a subvolume"),
        ("zfs", "child", "dataset.txt", "inside a child dataset"),
    ])
    func nestedFilesystems(filesystem: String, folder: String, file: String, contents: String) async throws {
        let disk = try await TestDisk(filesystem: filesystem)
        defer { disk.detach() }
        let volume = URL(fileURLWithPath: try await mount(disk))
        let nested = volume.appendingPathComponent(folder)

        let text = try String(contentsOf: nested.appendingPathComponent(file), encoding: .utf8)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == contents)
        try "written from macOS".write(to: nested.appendingPathComponent("from-mac.txt"), atomically: true, encoding: .utf8)
        try await unmount(disk)

        let again = URL(fileURLWithPath: try await mount(disk, readOnly: true))
        #expect(try String(contentsOf: again.appendingPathComponent("\(folder)/from-mac.txt"), encoding: .utf8) == "written from macOS")
        try await unmount(disk)
    }

    // MARK: - Check & Repair

    @Test("Check & Repair leaves a healthy volume healthy and its data intact", arguments: repairableFilesystems)
    func repairHealthyVolume(filesystem: String) async throws {
        let disk = try await TestDisk(filesystem: filesystem)
        defer { disk.detach() }
        let source = disk.workDir.appendingPathComponent("keep.bin")
        try makeRandomFile(at: source, bytes: 2 << 20)
        let volume = URL(fileURLWithPath: try await mount(disk))
        try FileManager.default.copyItem(at: source, to: volume.appendingPathComponent("keep.bin"))
        try await unmount(disk)

        let partition = try #require(await DiskScanner().inspectDisk(bsdName: disk.bsdName))
        let result = try await MountManager().repair(partition: partition)
        #expect(result.success, "repair failed: \(result.message)")
        #expect(VMMountRegistry.activeRecord(bsdName: disk.bsdName) == nil)

        let checked = URL(fileURLWithPath: try await mount(disk, readOnly: true))
        #expect(try sha256(checked.appendingPathComponent("keep.bin")) == sha256(source))
        try await unmount(disk)
    }

    @Test("An NTFS volume Windows left dirty is refused read & write until Check & Repair fixes it")
    func repairDirtyNTFS() async throws {
        let disk = try await TestDisk(filesystem: "ntfs", windowsDirty: true)
        defer { disk.detach() }
        let partition = try #require(await DiskScanner().inspectDisk(bsdName: disk.bsdName))

        let refused = try await MountManager().mount(
            partition: partition,
            options: MountOptions(isReadOnly: false, customMountPoint: disk.workDir.appendingPathComponent("refused").path)
        )
        #expect(!refused.success)
        #expect(refused.message.localizedCaseInsensitiveContains("dirty"))

        let repaired = try await MountManager().repair(partition: partition)
        #expect(repaired.success, "repair failed: \(repaired.message)")

        let volume = URL(fileURLWithPath: try await mount(disk))
        try "after repair".write(to: volume.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        try await unmount(disk)
    }

    @Test("Move to Trash (macOS gives network volumes no Trash; Finder deletes immediately instead)", arguments: ["ntfs"])
    func moveToTrash(filesystem: String) async throws {
        let disk = try await TestDisk(filesystem: filesystem)
        defer { disk.detach() }
        let volume = URL(fileURLWithPath: try await mount(disk))
        let file = volume.appendingPathComponent("trash-me.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        // Known limitation of network volumes: a real Trash needs an FSKit module (paid Apple Developer Program)
        withKnownIssue("Network volumes have no Trash; Finder offers Delete Immediately") {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        try FileManager.default.removeItem(at: file)
        try await unmount(disk)
    }

    // MARK: - Persistence, read-only, eject

    @Test("Data survives unmount and remount; read-only mounts reject writes", arguments: allFilesystems)
    func persistenceAndReadOnly(filesystem: String) async throws {
        let disk = try await TestDisk(filesystem: filesystem)
        defer { disk.detach() }
        let source = disk.workDir.appendingPathComponent("persist.bin")
        try makeRandomFile(at: source, bytes: 8 << 20)

        let rw = URL(fileURLWithPath: try await mount(disk))
        try FileManager.default.copyItem(at: source, to: rw.appendingPathComponent("persist.bin"))
        try await unmount(disk)
        #expect(!VMMountRegistry.isMountPoint(rw.path))

        // A fresh VM must see exactly what the previous one wrote
        let ro = URL(fileURLWithPath: try await mount(disk, readOnly: true))
        #expect(try sha256(ro.appendingPathComponent("persist.bin")) == sha256(source))
        #expect(throws: (any Error).self) {
            try "nope".write(to: ro.appendingPathComponent("write-attempt.txt"), atomically: false, encoding: .utf8)
        }
        try await unmount(disk)
    }

    @Test("Ejecting the volume from outside OmniFS shuts the VM down and frees the drive")
    func externalEject() async throws {
        let disk = try await TestDisk(filesystem: "ntfs")
        defer { disk.detach() }
        let mountPoint = try await mount(disk)

        // What Finder's Eject does
        try run("/usr/sbin/diskutil", ["unmount", mountPoint])
        #expect(try await waitUntil(seconds: 40) { VMMountRegistry.activeRecord(bsdName: disk.bsdName) == nil })

        // The drive is free again, so it can be mounted once more
        _ = try await mount(disk)
        try await unmount(disk)
    }

    @Test("Without a custom mount point, volumes mount in /Volumes under their name, like other drives")
    func mountsInVolumes() async throws {
        let disk = try await TestDisk(filesystem: "ntfs")
        defer { disk.detach() }
        let partition = try #require(await DiskScanner().inspectDisk(bsdName: disk.bsdName))
        let result = try await MountManager().mount(partition: partition, options: .standardReadWrite)
        #expect(result.success, "mount failed: \(result.message)")
        #expect(result.mountPoint.hasPrefix("/Volumes/OMNIFS"))
        #expect(VMMountRegistry.isMountPoint(result.mountPoint))
        // The helper tracks the path NetFS chose, so the drive shows as mounted there and unmounts cleanly
        #expect(await DiskScanner().inspectDisk(bsdName: disk.bsdName)?.mountPoint == result.mountPoint)
        try await unmount(disk)
        #expect(!FileManager.default.fileExists(atPath: result.mountPoint))
    }

    @Test("A second mount of the same drive is refused while one is in progress")
    func concurrentMountIsRefused() async throws {
        let disk = try await TestDisk(filesystem: "ext4")
        defer { disk.detach() }
        let partition = try #require(await DiskScanner().inspectDisk(bsdName: disk.bsdName))

        // Simulate another process (the pane, the app or the CLI) in the middle of mounting this drive
        let lock = try #require(VMMountRegistry.acquireOperationLock(bsdName: disk.bsdName))
        let result = try await MountManager().mount(partition: partition, options: .standardReadWrite)
        VMMountRegistry.releaseLock(lock)

        #expect(!result.success)
        #expect(result.message.contains("in progress"))
        #expect(VMMountRegistry.activeRecord(bsdName: disk.bsdName) == nil)
    }
}

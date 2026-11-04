import Foundation
import Virtualization
import OmniFSCore

// omnifs-vmd: boots the OmniFS Linux guest with one partition attached, waits for it to export
// the volume over NFS, then keeps the VM alive until the macOS NFS mount goes away.
// With --repair it instead runs the filesystem's checker in the guest and records the result.
//
// Usage: omnifs-vmd --disk <dev|image> --fs <ntfs|ext2|ext3|ext4|btrfs|xfs|zfs> --state <file>
//                   (--mountpoint <dir> [--name <name>] [--ro] | --repair)
//                   [--vm-dir <dir>] [--format]

struct Arguments {
    var disk = ""
    var fs = ""
    var mountPoint = ""
    var stateFile = ""
    var vmDir = ""
    var readOnly = false
    var format = false
    var repair = false
    var name = ""

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--disk": disk = it.next() ?? ""
            case "--fs": fs = it.next() ?? ""
            case "--mountpoint": mountPoint = it.next() ?? ""
            case "--state": stateFile = it.next() ?? ""
            case "--vm-dir": vmDir = it.next() ?? ""
            case "--name": name = it.next() ?? ""
            case "--ro": readOnly = true
            case "--format": format = true
            case "--repair": repair = true
            default: die("unknown argument \(arg)")
            }
        }
        if disk.isEmpty || fs.isEmpty || stateFile.isEmpty || (mountPoint.isEmpty && !repair) {
            die("usage: omnifs-vmd --disk <dev|image> --fs <type> --state <file> (--mountpoint <dir> [--name <name>] [--ro] | --repair) [--vm-dir <dir>]")
        }
        if repair && readOnly {
            die("--repair needs write access; it cannot be combined with --ro")
        }
        // Same sanitizing as the guest init: the name becomes the NFS export path, which Finder shows
        name = name.filter { $0 != "/" && $0 != "\"" && !$0.isNewline }
        if name.isEmpty {
            name = URL(fileURLWithPath: mountPoint).lastPathComponent.filter { $0 != "/" && $0 != "\"" }
        }
        if name.isEmpty {
            name = "volume"
        }
        if format && disk.hasPrefix("/dev/") {
            die("--format is only allowed on disk image files")
        }
        if vmDir.isEmpty {
            vmDir = VMMountRegistry.vmAssetsDirectory()?.path ?? ""
        }
        if !FileManager.default.fileExists(atPath: vmDir + "/Image") {
            die("VM image not found; build it with scripts/build_vm_image.py or pass --vm-dir")
        }
    }
}

/// Opens a privileged device through /usr/libexec/authopen, which shows the macOS authorization dialog and
/// passes the opened descriptor back over a Unix socket (SCM_RIGHTS) on its stdout.
func authopen(_ path: String, readOnly: Bool) -> Int32? {
    var sockets: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { return nil }
    defer { close(sockets[0]) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
    process.arguments = ["-stdoutpipe"] + (readOnly ? [] : ["-o", String(O_RDWR)]) + [path]
    process.standardOutput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: false)
    do {
        try process.run()
    } catch {
        close(sockets[1])
        return nil
    }
    close(sockets[1])

    // cmsghdr is 12 bytes on Darwin, so the descriptor sits at offset 12 of a 16-byte control buffer
    var byte: UInt8 = 0
    var control = [UInt8](repeating: 0, count: 16)
    var received: Int = -1
    withUnsafeMutablePointer(to: &byte) { bytePtr in
        control.withUnsafeMutableBytes { controlPtr in
            var iov = iovec(iov_base: bytePtr, iov_len: 1)
            withUnsafeMutablePointer(to: &iov) { iovPtr in
                var msg = msghdr()
                msg.msg_iov = iovPtr
                msg.msg_iovlen = 1
                msg.msg_control = controlPtr.baseAddress
                msg.msg_controllen = socklen_t(controlPtr.count)
                received = recvmsg(sockets[0], &msg, 0)
            }
        }
    }
    process.waitUntilExit()

    let level = control.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
    let type = control.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self) }
    guard received > 0, process.terminationStatus == 0, level == SOL_SOCKET, type == SCM_RIGHTS else { return nil }
    return control.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Int32.self) }
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("omnifs-vmd: \(message)\n".utf8))
    exit(1)
}

@MainActor
final class GuestController: NSObject, VZVirtualMachineDelegate {
    let args: Arguments
    let state: VMMountState
    var vm: VZVirtualMachine!
    let toGuest = Pipe()
    let fromGuest = Pipe()
    var buffer = Data()
    var phase = Phase.booting
    var waitedForMount = 0

    enum Phase { case booting, waitingForMount, mounted, stopping }

    init(args: Arguments) {
        self.args = args
        self.state = VMMountState(stateFile: URL(fileURLWithPath: args.stateFile))
        super.init()
    }

    func start() {
        let config = VZVirtualMachineConfiguration()
        let vmDir = URL(fileURLWithPath: args.vmDir)
        let boot = VZLinuxBootLoader(kernelURL: vmDir.appendingPathComponent("Image"))
        boot.initialRamdiskURL = vmDir.appendingPathComponent("initramfs.cpio.gz")
        let debug = ProcessInfo.processInfo.environment["OMNIFS_DEBUG"] == "1"
        boot.commandLine = "console=hvc0 \(debug ? "omnifs.debug=1" : "quiet") omnifs.fs=\(args.fs) omnifs.ro=\(args.readOnly ? 1 : 0) omnifs.mkfs=\(args.format ? 1 : 0) omnifs.action=\(args.repair ? "repair" : "mount")"
            + (ProcessInfo.processInfo.environment["OMNIFS_SHARE"].map { " omnifs.share=\($0)" } ?? "")
        config.bootLoader = boot
        // Every core the Mac has, and a quarter of its unified memory (guest RAM is only backed as it is used)
        config.cpuCount = min(ProcessInfo.processInfo.activeProcessorCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let quarter = ProcessInfo.processInfo.physicalMemory / 4
        config.memorySize = min(max(quarter, 1 << 30), 8 << 30, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        do {
            let attachment: VZStorageDeviceAttachment
            if args.disk.hasPrefix("/dev/") {
                // The caller has already unmounted it from macOS and normally handed the device node to this
                // user; otherwise ask macOS for access through authopen
                var fd = open(args.disk, args.readOnly ? O_RDONLY : O_RDWR)
                if fd < 0 && (errno == EACCES || errno == EPERM) {
                    fd = authopen(args.disk, readOnly: args.readOnly) ?? -1
                }
                guard fd >= 0 else { fail("cannot open \(args.disk): \(String(cString: strerror(errno)))") }
                attachment = try VZDiskBlockDeviceStorageDeviceAttachment(
                    fileHandle: FileHandle(fileDescriptor: fd, closeOnDealloc: true),
                    readOnly: args.readOnly,
                    synchronizationMode: .full
                )
            } else {
                attachment = try VZDiskImageStorageDeviceAttachment(
                    url: URL(fileURLWithPath: args.disk),
                    readOnly: args.readOnly,
                    cachingMode: .automatic,
                    synchronizationMode: .full
                )
            }
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            // Recovery aid: reusing a previous VM's MAC address gets its IP back from the NAT's DHCP, so NFS requests
            // a Mac process is still waiting on can complete
            if let mac = ProcessInfo.processInfo.environment["OMNIFS_MAC"].flatMap(VZMACAddress.init(string:)) {
                network.macAddress = mac
            }
            config.networkDevices = [network]

            let console = VZVirtioConsoleDeviceSerialPortConfiguration()
            console.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: toGuest.fileHandleForReading,
                fileHandleForWriting: fromGuest.fileHandleForWriting
            )
            config.serialPorts = [console]
            try config.validate()
        } catch {
            fail("invalid VM configuration: \(error.localizedDescription)")
        }

        fromGuest.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }

        vm = VZVirtualMachine(configuration: config)
        vm.delegate = self
        vm.start { [weak self] result in
            if case .failure(let error) = result {
                self?.fail("VM failed to start: \(error.localizedDescription)")
            }
        }

        // dispatchMain() never runs the main RunLoop, so use a dispatch timer rather than Timer
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        // The helper outlives the shell that launched it, so a hangup must not stop the VM
        signal(SIGHUP, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.shutdown(unmountFirst: true) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    var signalSources: [DispatchSourceSignal] = []
    let timer = DispatchSource.makeTimerSource(queue: .main)

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        FileHandle.standardError.write(data)
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line)
        }
    }

    private func handle(line: String) {
        if line == "OMNIFS_WANT_NAME" {
            toGuest.fileHandleForWriting.write(Data("\(args.name)\n".utf8))
        } else if line.hasPrefix("OMNIFS_READY ip="), phase == .booting {
            // The guest reports its export path itself (its shell may normalize the name, e.g. trim spaces)
            let fields = line.dropFirst("OMNIFS_READY ip=".count)
            let ip = String(fields.prefix { $0 != " " })
            let exportPath = fields.range(of: " export=").map { String(fields[$0.upperBound...]) } ?? "/exports/\(args.name)"
            prepareMountPoint()
            phase = .waitingForMount
            state.write(.init(pid: getpid(), status: .ready, ip: ip, exportPath: exportPath, mountPoint: args.mountPoint, readOnly: args.readOnly, message: nil))
        } else if line.hasPrefix("OMNIFS_REPAIRED "), args.repair {
            state.write(.init(pid: getpid(), status: .repaired, ip: nil, mountPoint: args.mountPoint, readOnly: false,
                              message: String(line.dropFirst("OMNIFS_REPAIRED ".count))))
        } else if line.hasPrefix("OMNIFS_ERROR ") {
            fail(String(line.dropFirst("OMNIFS_ERROR ".count)))
        }
    }

    private func prepareMountPoint() {
        try? FileManager.default.createDirectory(atPath: args.mountPoint, withIntermediateDirectories: true)
    }

    /// Where macOS mounted the export: NetFS may pick another /Volumes path than requested, which MountManager
    /// records in the state file (only MountManager writes it after "ready", so the two never race)
    private var mountPoint: String {
        state.read()?.mountPoint ?? args.mountPoint
    }

    private func tick() {
        switch phase {
        case .waitingForMount:
            if VMMountRegistry.isMountPoint(mountPoint) || state.mountConfirmed {
                phase = .mounted
            } else if state.stopRequested || waitedForMount >= 90 {
                shutdown(unmountFirst: false)
            }
            waitedForMount += 1
        case .mounted:
            // Unmounted from Finder, diskutil or omnifs: release the partition
            if !VMMountRegistry.isMountPoint(mountPoint) {
                shutdown(unmountFirst: false)
            } else if state.stopRequested {
                shutdown(unmountFirst: true)
            }
        case .booting:
            // A running check or repair is never interrupted: that is what damages filesystems
            if state.stopRequested && !args.repair { shutdown(unmountFirst: false) }
        case .stopping:
            break
        }
    }

    func shutdown(unmountFirst: Bool) {
        guard phase != .stopping else { return }
        let wasBooting = phase == .booting
        phase = .stopping
        if unmountFirst && VMMountRegistry.isMountPoint(mountPoint) {
            let umount = Process()
            umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
            umount.arguments = ["-f", mountPoint]
            try? umount.run()
            umount.waitUntilExit()
        }
        if wasBooting {
            vm.stop { _ in }
        } else {
            toGuest.fileHandleForWriting.write(Data("shutdown\n".utf8))
        }
        // Force the VM off if the guest does not power down in time
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated {
                self?.vm.stop { _ in }
                self?.finish(code: 1)
            }
        }
    }

    private func finish(code: Int32) -> Never {
        let mountPoint = mountPoint
        forceUnmount(mountPoint)
        rmdir(mountPoint)
        // A repair's result stays for MountManager to read (it removes the file)
        if !args.repair {
            state.remove()
        }
        exit(code)
    }

    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("omnifs-vmd: \(message)\n".utf8))
        // Read before the failure record below replaces the mount point MountManager recorded
        let mountPoint = mountPoint
        state.write(.init(pid: getpid(), status: .failed, ip: nil, mountPoint: args.mountPoint, readOnly: args.readOnly, message: message))
        forceUnmount(mountPoint)
        if phase != .waitingForMount && phase != .mounted {
            rmdir(args.mountPoint)
        }
        exit(1)
    }

    /// If the guest is gone while macOS still has its NFS export mounted, every access to that mount would hang;
    /// drop the mount so Finder and apps get errors instead
    private func forceUnmount(_ mountPoint: String) {
        guard VMMountRegistry.isMountPoint(mountPoint) else { return }
        let umount = Process()
        umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
        umount.arguments = ["-f", mountPoint]
        try? umount.run()
        umount.waitUntilExit()
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { finish(code: 0) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated { fail("VM stopped: \(error.localizedDescription)") }
    }
}

let controller = MainActor.assumeIsolated { GuestController(args: Arguments(CommandLine.arguments)) }
MainActor.assumeIsolated { controller.start() }
dispatchMain()

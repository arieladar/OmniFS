import SwiftUI
import AppKit

// MARK: - Navigation Panes

public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case volumes = "Volumes"
    case filesystems = "Formats"
    case options = "Options"
    case about = "About"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .volumes: return "Connected Volumes"
        case .filesystems: return "File System Formats"
        case .options: return "Mount Options"
        case .about: return "About OmniFS"
        }
    }

    public var iconName: String {
        switch self {
        case .volumes: return "externaldrive"
        case .filesystems: return "internaldrive"
        case .options: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Apple System Squircle Icon Badge

public struct AppleSettingsIcon: View {
    let systemName: String
    let gradientColors: [Color]
    var size: CGFloat = 28

    public init(systemName: String, color: Color, size: CGFloat = 28) {
        self.systemName = systemName
        self.gradientColors = [color.opacity(0.85), color]
        self.size = size
    }

    public init(systemName: String, gradientColors: [Color], size: CGFloat = 28) {
        self.systemName = systemName
        self.gradientColors = gradientColors
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .frame(width: size, height: size)
                .shadow(color: gradientColors.last?.opacity(0.2) ?? .clear, radius: 2, y: 1)

            Image(systemName: systemName)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Root Settings Container View

public struct SettingsContainerView: View {
    @State private var selectedPane: SettingsPane = .volumes

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Apple System Settings Top Segmented Navigation
            Picker("", selection: $selectedPane) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.rawValue, systemImage: pane.iconName)
                        .tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .padding(.horizontal, 14)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Active Tab Content
            Group {
                switch selectedPane {
                case .volumes:
                    VolumesSettingsView()
                case .filesystems:
                    FileSystemsSettingsView()
                case .options:
                    MountOptionsSettingsView()
                case .about:
                    AboutOmniFSView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Volumes & Disks Settings View

public struct VolumesSettingsView: View {
    @State private var partitions: [DiskPartition] = []
    @State private var isLoading = false
    @State private var scanGeneration = 0
    @State private var storageSignature = ""
    @State private var statusBanner: StatusBannerInfo?
    @State private var inspectedPartition: DiskPartition?
    @State private var repairCandidate: DiskPartition?
    @State private var searchText = ""

    public init() {}

    private var activePartitions: [DiskPartition] {
        partitions.filter { $0.isForeignOrRemovable }
    }

    private var filteredPartitions: [DiskPartition] {
        if searchText.isEmpty {
            return activePartitions
        }
        return activePartitions.filter {
            $0.volumeName.localizedCaseInsensitiveContains(searchText) ||
            $0.bsdName.localizedCaseInsensitiveContains(searchText) ||
            $0.fileSystemType.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var totalBytes: UInt64 {
        activePartitions.reduce(0) { $0 + $1.totalSizeBytes }
    }

    public var body: some View {
        Form {
            // Status banner first so mount results and errors are always visible
            if let banner = statusBanner {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: banner.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(banner.isError ? Color.red : Color.green)
                        Text(banner.message)
                            .font(.callout)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            statusBanner = nil
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }

            // Apple-Style Storage Capacity Bar
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Foreign Storage")
                                .font(.headline)
                            Text("NTFS, ext2/3/4, Btrfs, XFS and ZFS volumes available on this Mac")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task { await refreshDisks() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                    .symbolEffect(.rotate, isActive: isLoading)
                                Text("Refresh")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLoading)
                    }

                    // Native Storage Bar
                    StorageCapacityBar(partitions: activePartitions)
                }
                .padding(.vertical, 6)
            }

            // Volumes List
            Section {
                if isLoading && partitions.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Scanning connected storage...")
                            .padding(.vertical, 24)
                        Spacer()
                    }
                } else if activePartitions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "externaldrive.badge.questionmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 4) {
                            Text("No Foreign Volumes Connected")
                                .font(.headline)
                            Text("Connect an external storage device formatted with Windows (NTFS), Linux (ext2/3/4, Btrfs, XFS) or ZFS.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(filteredPartitions) { partition in
                        VolumeRowView(
                            partition: partition,
                            onMountRW: { Task { await mount(partition: partition, readOnly: false) } },
                            onMountRO: { Task { await mount(partition: partition, readOnly: true) } },
                            onUnmount: { Task { await unmount(partition: partition) } },
                            onReveal: { revealInFinder(partition: partition) },
                            onInspect: { inspectedPartition = partition },
                            onRepair: { repairCandidate = partition }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Volumes")
                    Spacer()
                    if !activePartitions.isEmpty {
                        Text("\(filteredPartitions.count) of \(activePartitions.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("OmniFS automatically discovers Linux and Windows storage while strictly excluding your internal Mac drive and system APFS containers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .searchable(text: $searchText, prompt: "Search volumes")
        .confirmationDialog(
            "Check & Repair “\(repairCandidate?.volumeName ?? "")”?",
            isPresented: Binding(get: { repairCandidate != nil }, set: { if !$0 { repairCandidate = nil } }),
            presenting: repairCandidate
        ) { partition in
            Button("Check & Repair") {
                Task { await repair(partition: partition) }
            }
        } message: { _ in
            Text("The volume is unmounted while it is checked and mounted again afterwards. Checking a large drive can take a while; don't disconnect it until the check finishes.")
        }
        .sheet(item: $inspectedPartition) { part in
            VolumeInspectorSheet(partition: part)
        }
        .task {
            await refreshDisks()
            // VM-served (NFS) mounts, drives without a mountable volume and the omnifs CLI don't reliably notify
            // this view, so poll a cheap snapshot and only rescan when it changes
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                let signature = VMMountRegistry.storageSignature()
                if signature != storageSignature {
                    await refreshDisks(quiet: true)
                }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await refreshDisks(quiet: true) }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await refreshDisks(quiet: true) }
        }
    }

    private func refreshDisks(quiet: Bool = false) async {
        // Scans can overlap (notifications, polling, user actions); only the newest one is applied
        scanGeneration += 1
        let generation = scanGeneration
        if !quiet {
            isLoading = true
        }
        let signature = VMMountRegistry.storageSignature()
        let scanned = await DiskScanner().scanPartitions()
        if generation == scanGeneration {
            partitions = scanned
            storageSignature = signature
        }
        if !quiet {
            isLoading = false
        }
    }

    private func mount(partition: DiskPartition, readOnly: Bool) async {
        let opts: MountOptions = readOnly ? .standardReadOnly : .standardReadWrite
        do {
            let res = try await MountManager.shared.mount(partition: partition, options: opts)
            statusBanner = StatusBannerInfo(message: res.message, isError: !res.success)
            await refreshDisks()
        } catch {
            statusBanner = StatusBannerInfo(message: "Failed to mount \(partition.bsdName): \(error.localizedDescription)", isError: true)
        }
    }

    private func repair(partition: DiskPartition) async {
        statusBanner = StatusBannerInfo(message: "Checking \(partition.volumeName)… Don't disconnect the drive.", isError: false)
        do {
            let res = try await MountManager.shared.repair(partition: partition)
            statusBanner = StatusBannerInfo(message: "\(partition.volumeName): \(res.message)", isError: !res.success)
            await refreshDisks()
        } catch {
            statusBanner = StatusBannerInfo(message: "Failed to check \(partition.bsdName): \(error.localizedDescription)", isError: true)
        }
    }

    private func unmount(partition: DiskPartition) async {
        do {
            let success = try await MountManager.shared.unmount(bsdNameOrMountPoint: partition.bsdName)
            statusBanner = StatusBannerInfo(
                message: success ? "Unmounted \(partition.volumeName)" : "Failed to unmount \(partition.volumeName)",
                isError: !success
            )
            await refreshDisks()
        } catch {
            statusBanner = StatusBannerInfo(message: "Failed to unmount \(partition.bsdName): \(error.localizedDescription)", isError: true)
        }
    }

    private func revealInFinder(partition: DiskPartition) {
        if let mp = partition.mountPoint {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: mp)
        }
    }
}

private struct StatusBannerInfo: Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

// MARK: - Native Apple Storage Capacity Bar

public struct StorageCapacityBar: View {
    let partitions: [DiskPartition]

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Contiguous Apple-style Storage Bar
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if partitions.isEmpty {
                        Capsule()
                            .fill(Color(nsColor: .separatorColor).opacity(0.3))
                            .frame(width: geo.size.width)
                    } else {
                        // Small partitions get a minimum share so they stay visible; shares are then
                        // normalized so the segments always fill exactly the bar's width
                        let shares = partitions.map { max(0.08, CGFloat($0.totalSizeBytes) / CGFloat(max(1, totalBytes))) }
                        let totalShare = shares.reduce(0, +)
                        ForEach(Array(partitions.enumerated()), id: \.element.id) { index, part in
                            Rectangle()
                                .fill(colorForType(part.fileSystemType))
                                .frame(width: geo.size.width * shares[index] / totalShare)
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 16)

            // Flowing Apple Legend
            if partitions.isEmpty {
                HStack {
                    Text("No foreign storage connected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                HStack(spacing: 16) {
                    ForEach(uniqueFSTypes, id: \.self) { fs in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(colorForType(fs))
                                .frame(width: 8, height: 8)
                            Text(fs.description)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                            Text(formattedTotal(for: fs))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private var totalBytes: UInt64 {
        partitions.reduce(0) { $0 + $1.totalSizeBytes }
    }

    private var uniqueFSTypes: [FileSystemType] {
        Array(Set(partitions.map { $0.fileSystemType })).sorted(by: { $0.description < $1.description })
    }

    private func formattedTotal(for type: FileSystemType) -> String {
        let sum = partitions.filter { $0.fileSystemType == type }.reduce(0) { $0 + $1.totalSizeBytes }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(sum))
    }

    private func colorForType(_ type: FileSystemType) -> Color {
        switch type {
        case .ext2, .ext3, .ext4: return .orange
        case .ntfs: return .blue
        case .btrfs: return .teal
        case .xfs: return .purple
        case .zfs: return .indigo
        case .f2fs: return .mint
        case .udf: return .brown
        case .vfat, .exfat: return .green
        default: return Color(nsColor: .separatorColor)
        }
    }
}

// MARK: - Volume Row View

public struct VolumeRowView: View {
    let partition: DiskPartition
    let onMountRW: () -> Void
    let onMountRO: () -> Void
    let onUnmount: () -> Void
    let onReveal: () -> Void
    let onInspect: () -> Void
    let onRepair: () -> Void

    public var body: some View {
        HStack(spacing: 14) {
            // Authentic Squircle Icon
            // Symbol shows the physical device, color shows the filesystem
            AppleSettingsIcon(
                systemName: partition.driveKind.iconName,
                color: iconColor(for: partition.fileSystemType),
                size: 32
            )
            .help(partition.deviceSummary)

            // Primary Information
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(partition.volumeName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    Text(partition.bsdName)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Text(partition.fileSystemType.description)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(iconColor(for: partition.fileSystemType))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(iconColor(for: partition.fileSystemType).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .fixedSize()
                }

                HStack(spacing: 8) {
                    Text(partition.formattedSize)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Text("•")
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    if partition.isMounted {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(partition.isReadOnly ? Color.orange : Color.green)
                                .frame(width: 6, height: 6)
                            Text(partition.isReadOnly ? "Read-Only" : "Mounted")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(partition.isReadOnly ? Color.orange : Color.green)
                                .fixedSize()
                        }
                        .fixedSize()

                        if let mp = partition.mountPoint, !mp.isEmpty {
                            Text("at \(mp)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("Not Mounted")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }

            Spacer()

            // Trailing Actions conforming strictly to Apple macOS HIG
            HStack(spacing: 8) {
                if partition.isMounted {
                    if partition.isReadOnly && partition.canOmniFSMountReadWrite {
                        Button(action: onMountRW) {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil")
                                Text("Remount RW")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .help("Remount volume in Read & Write mode via OmniFS")
                    }

                    Button(action: onReveal) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help("Show in Finder")

                    Button(action: onUnmount) {
                        Image(systemName: "eject")
                    }
                    .buttonStyle(.bordered)
                    .help("Eject")
                    .accessibilityLabel("Eject")
                } else {
                    Menu {
                        Button(action: onMountRW) {
                            Label("Mount Read & Write", systemImage: "pencil")
                        }
                        Button(action: onMountRO) {
                            Label("Mount Read-Only", systemImage: "lock")
                        }
                        if partition.supportsRepair {
                            Divider()
                            Button(action: onRepair) {
                                Label("Check & Repair…", systemImage: "stethoscope")
                            }
                        }
                    } label: {
                        Text("Mount")
                    }
                    .menuStyle(.borderedButton)
                }

                Button(action: onInspect) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.bordered)
                .help("Get Info")
            }
            // Buttons keep their full size; the volume details on the left truncate instead
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if partition.supportsRepair {
                Button(action: onRepair) {
                    Label("Check & Repair…", systemImage: "stethoscope")
                }
            }
            Button(action: onInspect) {
                Label("Get Info", systemImage: "info.circle")
            }
        }
    }

    private func iconColor(for type: FileSystemType) -> Color {
        switch type {
        case .ext2, .ext3, .ext4: return .orange
        case .ntfs: return .blue
        case .btrfs: return .teal
        case .xfs: return .purple
        case .zfs: return .indigo
        case .f2fs: return .mint
        case .udf: return .brown
        case .vfat, .exfat: return .green
        default: return .secondary
        }
    }
}

// MARK: - Native Volume Inspector Sheet

public struct VolumeInspectorSheet: View {
    let partition: DiskPartition
    @Environment(\.dismiss) private var dismiss
    @State private var copiedUUID = false

    public var body: some View {
        VStack(spacing: 0) {
            // Apple Sheet Header
            HStack {
                AppleSettingsIcon(systemName: partition.driveKind.iconName, color: .blue, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(partition.volumeName)
                        .font(.headline)
                    Text(partition.fileSystemType.description + " Volume Information")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Form {
                Section("General") {
                    LabeledContent("Volume Name", value: partition.volumeName)
                    LabeledContent("File System", value: partition.fileSystemType.description)
                    LabeledContent("Capacity", value: partition.formattedSize)
                    LabeledContent("Device Type", value: partition.driveKind.description)
                    if let model = partition.deviceModel {
                        LabeledContent("Device", value: model)
                    }
                    if let connection = partition.connection {
                        LabeledContent("Connection", value: connection)
                    }

                    if let uuid = partition.metadata?.uuid {
                        HStack {
                            Text("Volume UUID")
                            Spacer()
                            Text(uuid)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(uuid, forType: .string)
                                copiedUUID = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedUUID = false
                                }
                            } label: {
                                Image(systemName: copiedUUID ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(copiedUUID ? Color.green : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy UUID")
                        }
                    }
                }

                Section("Storage & Geometry") {
                    if let bs = partition.metadata?.blockSize {
                        LabeledContent("Allocation Block Size", value: "\(bs) bytes")
                    }
                    if let tb = partition.metadata?.totalBlocks {
                        LabeledContent("Total Blocks", value: "\(tb)")
                    }
                    if let fb = partition.metadata?.freeBlocks {
                        LabeledContent("Available Blocks", value: "\(fb)")
                    }
                }

                Section("Integrity & Status") {
                    if let isClean = partition.metadata?.isClean {
                        LabeledContent("File System State") {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(isClean ? Color.green : Color.red)
                                    .frame(width: 7, height: 7)
                                Text(isClean ? "Clean" : "Requires journal recovery")
                                    .foregroundStyle(isClean ? Color.green : Color.red)
                            }
                        }
                    }

                    if let lastMount = partition.metadata?.lastMountTime {
                        LabeledContent("Last Mounted", value: lastMount.formatted(date: .abbreviated, time: .shortened))
                    }

                    if let features = partition.metadata?.featuresDescription {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Volume Features")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(features)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }

                Section("Mount Points & Device") {
                    LabeledContent("BSD Device", value: partition.devicePath)
                    LabeledContent("Raw Character Device", value: partition.rawDevicePath)
                    if let mp = partition.mountPoint {
                        LabeledContent("Mount Point", value: mp)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 460, minHeight: 480)
    }
}

// MARK: - File Systems Settings View

public struct FileSystemsSettingsView: View {
    public init() {}

    private let vmInstalled = VMMountRegistry.helperExecutable() != nil && VMMountRegistry.vmAssetsDirectory() != nil

    private func driverStatus(for type: FileSystemType) -> (text: String, color: Color) {
        if vmInstalled {
            return ("Read & Write via Linux VM", .green)
        }
        if type.isNativeReadableOnMacOS {
            return ("Read-Only (macOS built-in)", .orange)
        }
        return ("Linux VM not installed", .secondary)
    }

    public var body: some View {
        Form {
            Section {
                FileSystemRow(
                    name: "ext2, ext3, ext4",
                    family: "Linux",
                    description: "Mounted read & write by the Linux kernel ext4 driver, with journaling and extents.",
                    iconName: "externaldrive.badge.person.crop",
                    color: .orange,
                    status: driverStatus(for: .ext4)
                )

                FileSystemRow(
                    name: "Btrfs (B-tree File System)",
                    family: "Linux",
                    description: "Copy-on-write Linux filesystem, mounted by the Linux kernel Btrfs driver. Every subvolume and snapshot appears as a folder.",
                    iconName: "leaf.fill",
                    color: .teal,
                    status: driverStatus(for: .btrfs)
                )

                FileSystemRow(
                    name: "XFS",
                    family: "Linux",
                    description: "64-bit journaling filesystem, mounted by the Linux kernel XFS driver.",
                    iconName: "square.stack.3d.up.fill",
                    color: .purple,
                    status: driverStatus(for: .xfs)
                )

                FileSystemRow(
                    name: "ZFS (OpenZFS)",
                    family: "Linux & Unix",
                    description: "Pooled copy-on-write filesystem from Sun (Solaris, FreeBSD, TrueNAS, Linux). Imports the pool, mounts all datasets and exports it cleanly on eject. Encrypted datasets are not supported.",
                    iconName: "square.stack.3d.down.right.fill",
                    color: .indigo,
                    status: driverStatus(for: .zfs)
                )

                FileSystemRow(
                    name: "F2FS (Flash-Friendly File System)",
                    family: "Linux",
                    description: "Flash-optimized filesystem used by Android phones, SD cards and SSDs, mounted by the Linux kernel F2FS driver.",
                    iconName: "sdcard.fill",
                    color: .mint,
                    status: driverStatus(for: .f2fs)
                )
            } header: {
                Text("Linux & Unix File Systems")
            } footer: {
                Text("Linux volumes are served by a lightweight Linux VM (Apple Virtualization framework) and appear in Finder over a private NFS link. No kernel extensions or FUSE.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                FileSystemRow(
                    name: "NTFS (New Technology File System)",
                    family: "Windows",
                    description: "Read & write through the Linux kernel ntfs3 driver. Read-only mounts use the macOS built-in driver.",
                    iconName: "pc",
                    color: .blue,
                    status: driverStatus(for: .ntfs)
                )
            } header: {
                Text("Windows File Systems")
            } footer: {
                Text("Volumes left dirty by Windows hibernation, Fast Startup or a crash are refused read & write; use Check & Repair (right-click the volume), or shut Windows down fully.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                FileSystemRow(
                    name: "exFAT & FAT32 (MS-DOS)",
                    family: "Universal",
                    description: "Cross-platform storage natively monitored through macOS DiskArbitration.",
                    iconName: "externaldrive.fill",
                    color: .green,
                    status: ("System Built-in", .green)
                )

                FileSystemRow(
                    name: "UDF (Universal Disk Format)",
                    family: "Universal",
                    description: "Optical-disc format also used on some USB drives and cameras. Read-only uses the macOS built-in driver; read & write (UDF up to 2.01) the Linux kernel UDF driver.",
                    iconName: "opticaldisc.fill",
                    color: .brown,
                    status: driverStatus(for: .udf)
                )
            } header: {
                Text("Universal Storage")
            }
        }
        .formStyle(.grouped)
    }
}

private struct FileSystemRow: View {
    let name: String
    let family: String
    let description: String
    let iconName: String
    let color: Color
    let status: (text: String, color: Color)

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AppleSettingsIcon(systemName: iconName, color: color, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(name)
                        .font(.body.weight(.medium))
                    Spacer()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 6, height: 6)
                        Text(status.text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Mount Options Settings View

public struct MountOptionsSettingsView: View {
    @State private var autoMount = true
    @State private var defaultReadOnly = false
    @State private var notifyOnMount = true
    @State private var mountPath = "/Volumes"
    @State private var ignorePermissions = true
    @State private var allowOtherUsers = true
    @State private var forceFsync = true
    @State private var autoRepairJournal = true

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Automatically mount connected volumes", isOn: $autoMount)
                    .toggleStyle(.switch)

                Toggle("Mount volumes as read-only by default", isOn: $defaultReadOnly)
                    .toggleStyle(.switch)

                Toggle("Show notification when volume is mounted", isOn: $notifyOnMount)
                    .toggleStyle(.switch)
            } header: {
                Text("Mounting Behavior")
            } footer: {
                Text("Foreign volumes will be detected upon connection and mounted under \(mountPath).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Ignore ownership on foreign volumes", isOn: $ignorePermissions)
                    .toggleStyle(.switch)

                Toggle("Allow other local users to access volumes", isOn: $allowOtherUsers)
                    .toggleStyle(.switch)
            } header: {
                Text("Permissions")
            } footer: {
                Text("When ownership is ignored, files on foreign volumes are treated as owned by the current user to allow direct editing without administrator privileges.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Flush buffers before disconnecting (fsync)", isOn: $forceFsync)
                    .toggleStyle(.switch)

                Toggle("Check and replay journal before mounting", isOn: $autoRepairJournal)
                    .toggleStyle(.switch)
            } header: {
                Text("Data Integrity")
            } footer: {
                Text("Guarantees file changes are committed to disk before ejection and replays journals after unexpected disconnections.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About OmniFS View

public struct AboutOmniFSView: View {
    @State private var copiedReport = false

    public init() {}

    private var appIconImage: NSImage? {
        // Look in main bundle or any loaded bundles
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        for b in bundles {
            if let p = b.path(forResource: "AppIcon", ofType: "png") ?? b.path(forResource: "OmniFS", ofType: "icns") {
                return NSImage(contentsOfFile: p)
            }
        }
        return nil
    }

    public var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    if let img = appIconImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)
                    } else {
                        AppleSettingsIcon(
                            systemName: "externaldrive.fill.badge.checkmark",
                            color: .blue,
                            size: 60
                        )
                    }

                    VStack(spacing: 3) {
                        Text("OmniFS")
                            .font(.system(size: 20, weight: .bold))
                        Text("Version 1.0 (Build 2026.10)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text("Universal read and write filesystem engine for macOS on Apple Silicon.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            Section("Specifications") {
                LabeledContent("Operating System", value: "macOS 15 Sequoia (Darwin 27)")
                LabeledContent("Architecture", value: "Apple Silicon (ARM64 Native)")
                LabeledContent("Execution Model", value: "Linux VM (Virtualization.framework) + NFS")
                LabeledContent("Kernel Extensions", value: "None (Zero-Kext)")
                LabeledContent("License", value: "MIT Open Source")
            }

            Section("Support & Diagnostics") {
                Button {
                    copyDiagnostics()
                } label: {
                    HStack {
                        Image(systemName: copiedReport ? "checkmark" : "doc.on.clipboard")
                            .foregroundStyle(copiedReport ? Color.green : Color.accentColor)
                        Text(copiedReport ? "Diagnostics Copied to Clipboard" : "Copy Diagnostics Report")
                    }
                }

                Link(destination: URL(string: "https://github.com")!) {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        Text("OmniFS Source Repository")
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func copyDiagnostics() {
        let report = """
        === OmniFS System Diagnostics ===
        Timestamp: \(Date())
        Version: 1.0 (Build 2026.10)
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: Apple Silicon arm64
        Drivers:
          - Linux VM helper: \(VMMountRegistry.helperExecutable()?.path ?? "not installed")
          - Linux VM image: \(VMMountRegistry.vmAssetsDirectory()?.path ?? "not installed")
          - ext2 / ext3 / ext4, Btrfs, XFS, ZFS: Linux VM
          - NTFS: Linux VM (read-write), macOS built-in (read-only)
          - exFAT / FAT32: macOS built-in
        =================================
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copiedReport = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            copiedReport = false
        }
    }
}

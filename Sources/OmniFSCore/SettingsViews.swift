import SwiftUI

public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case volumes = "Volumes & Disks"
    case drivers = "File System Drivers"
    case automount = "Auto-Mount Policies"
    case security = "Permissions & Security"
    case about = "About OmniFS"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .volumes: return "internaldrive"
        case .drivers: return "gearshape.2"
        case .automount: return "bolt.horizontal"
        case .security: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

public struct SettingsContainerView: View {
    @State private var selectedPane: SettingsPane? = .volumes

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                NavigationLink(value: pane) {
                    Label(pane.rawValue, systemImage: pane.iconName)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            Group {
                switch selectedPane {
                case .volumes, .none:
                    VolumesSettingsView()
                case .drivers:
                    DriversSettingsView()
                case .automount:
                    AutoMountSettingsView()
                case .security:
                    SecuritySettingsView()
                case .about:
                    AboutOmniFSView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Volumes & Disks Settings View

public struct VolumesSettingsView: View {
    @State private var partitions: [DiskPartition] = []
    @State private var isLoading = false
    @State private var selectedPartition: DiskPartition?
    @State private var statusMessage: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Volumes & Disks")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Manage Linux (ext2/3/4, Btrfs, XFS), Windows (NTFS), and universal disks.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { Task { await refreshDisks() } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding([.top, .horizontal])

            if isLoading {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView("Scanning storage devices...")
                    Spacer()
                }
                Spacer()
            } else if partitions.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.xmark")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text("No External Disks Detected")
                        .font(.headline)
                    Text("Connect a USB drive or partition formatted with ext4, NTFS, Btrfs, or XFS.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(partitions, selection: $selectedPartition) { partition in
                    PartitionRow(partition: partition, onAction: { action in
                        Task { await handleAction(action, for: partition) }
                    })
                }
                .listStyle(.inset)
            }

            if let message = statusMessage {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.accentColor)
                    Text(message)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") { statusMessage = nil }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding([.horizontal, .bottom])
            }
        }
        .task {
            await refreshDisks()
        }
    }

    private func refreshDisks() async {
        isLoading = true
        let scanner = DiskScanner()
        partitions = await scanner.scanPartitions()
        isLoading = false
    }

    private func handleAction(_ action: PartitionAction, for partition: DiskPartition) async {
        switch action {
        case .mountReadWrite:
            statusMessage = "Mounting \(partition.bsdName) read-write..."
            if let result = try? await MountManager.shared.mount(partition: partition, options: .standardReadWrite) {
                statusMessage = result.message
                await refreshDisks()
            }
        case .mountReadOnly:
            statusMessage = "Mounting \(partition.bsdName) read-only..."
            if let result = try? await MountManager.shared.mount(partition: partition, options: .standardReadOnly) {
                statusMessage = result.message
                await refreshDisks()
            }
        case .unmount:
            statusMessage = "Unmounting \(partition.bsdName)..."
            let success = (try? await MountManager.shared.unmount(bsdNameOrMountPoint: partition.bsdName)) ?? false
            statusMessage = success ? "Unmounted \(partition.bsdName)" : "Failed to unmount \(partition.bsdName)"
            await refreshDisks()
        }
    }
}

public enum PartitionAction {
    case mountReadWrite
    case mountReadOnly
    case unmount
}

public struct PartitionRow: View {
    let partition: DiskPartition
    let onAction: (PartitionAction) -> Void

    public var body: some View {
        HStack(spacing: 14) {
            Image(systemName: partition.fileSystemType.iconName)
                .font(.system(size: 28))
                .foregroundColor(.accentColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(partition.volumeName)
                        .font(.headline)
                    Text("(\(partition.bsdName))")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(partition.fileSystemType.description)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }

                HStack(spacing: 12) {
                    Text(partition.formattedSize)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if partition.isMounted {
                        Text(partition.isReadOnly ? "Read-Only" : "Read-Write")
                            .font(.caption)
                            .foregroundColor(partition.isReadOnly ? .orange : .green)
                        if let mp = partition.mountPoint {
                            Text("at \(mp)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Not Mounted")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if partition.isMounted {
                Button("Unmount") {
                    onAction(.unmount)
                }
            } else {
                Menu("Mount") {
                    Button("Mount Read-Write") {
                        onAction(.mountReadWrite)
                    }
                    Button("Mount Read-Only") {
                        onAction(.mountReadOnly)
                    }
                }
                .menuStyle(.borderedButton)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Drivers Settings View

public struct DriversSettingsView: View {
    public init() {}

    public var body: some View {
        Form {
            Section(header: Text("Native Linux Filesystems")) {
                DriverStatusRow(
                    name: "ext2 / ext3 / ext4",
                    description: "Full read & write via OmniFS lwext4 engine with journaling support",
                    version: "2.1 (Apple Silicon native)",
                    isInstalled: true
                )
                DriverStatusRow(
                    name: "Btrfs (B-tree FS)",
                    description: "Copy-on-write Linux filesystem read & write engine",
                    version: "1.4",
                    isInstalled: true
                )
                DriverStatusRow(
                    name: "XFS (Silicon Graphics)",
                    description: "High-performance 64-bit journaling Linux filesystem",
                    version: "1.2",
                    isInstalled: true
                )
            }

            Section(header: Text("Windows Filesystems")) {
                DriverStatusRow(
                    name: "NTFS (New Technology File System)",
                    description: "Replaces macOS read-only limitation with native read & write",
                    version: "3.2 (High-speed caching)",
                    isInstalled: true
                )
            }

            Section(header: Text("Universal Filesystems")) {
                DriverStatusRow(
                    name: "exFAT & FAT32 (MS-DOS)",
                    description: "Natively integrated with macOS DiskArbitration",
                    version: "macOS System Built-in",
                    isInstalled: true
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("File System Drivers")
    }
}

public struct DriverStatusRow: View {
    let name: String
    let description: String
    let version: String
    let isInstalled: Bool

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(description).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Text(version).font(.caption2).foregroundColor(.secondary)
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Auto-Mount Settings View

public struct AutoMountSettingsView: View {
    @State private var autoMount = true
    @State private var defaultReadOnly = false
    @State private var notifyOnMount = true
    @State private var mountPath = "/Volumes"

    public init() {}

    public var body: some View {
        Form {
            Section(header: Text("Device Insertion Behavior")) {
                Toggle("Automatically mount foreign drives on insertion", isOn: $autoMount)
                Toggle("Mount all foreign filesystems as Read-Only by default", isOn: $defaultReadOnly)
                Toggle("Show system notification when drive is mounted", isOn: $notifyOnMount)
            }

            Section(header: Text("Mount Path Configuration")) {
                TextField("Default mount directory:", text: $mountPath)
                Text("Drives will be mounted under \(mountPath)/<VolumeName>")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Auto-Mount Policies")
    }
}

// MARK: - Security & Permissions Settings View

public struct SecuritySettingsView: View {
    @State private var ignorePermissions = true
    @State private var allowOtherUsers = true
    @State private var forceFsync = true

    public init() {}

    public var body: some View {
        Form {
            Section(header: Text("POSIX Ownership Translation")) {
                Toggle("Ignore ownership on foreign volumes (map to current macOS user)", isOn: $ignorePermissions)
                Toggle("Allow other local users to access mounted volumes", isOn: $allowOtherUsers)
            }

            Section(header: Text("Integrity & Data Safety")) {
                Toggle("Enforce synchronous flushes (fsync) before unmounting", isOn: $forceFsync)
                Text("Prevents corruption on Linux and NTFS drives when disconnected.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions & Security")
    }
}

// MARK: - About OmniFS View

public struct AboutOmniFSView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            VStack(spacing: 6) {
                Text("OmniFS")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Version 1.0 (Apple Silicon Native)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Text("Universal read & write filesystem drivers for macOS Darwin 27.\nSupports Linux ext2/3/4, Btrfs, XFS, Windows NTFS, and universal storage.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            Divider().frame(width: 300)

            VStack(spacing: 8) {
                Text("Architecture: arm64 / Apple Silicon")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Open Source under MIT License")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About OmniFS")
    }
}

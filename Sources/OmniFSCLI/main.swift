import Foundation
import OmniFSCore

@main
struct OmniFSCLI {
    static func main() async {
        let args = CommandLine.arguments

        guard args.count > 1 else {
            printUsage()
            return
        }

        let command = args[1]
        switch command {
        case "list", "ls":
            await handleList()
        case "mount":
            await handleMount(args: Array(args.dropFirst(2)))
        case "unmount", "umount":
            await handleUnmount(args: Array(args.dropFirst(2)))
        case "inspect":
            await handleInspect(args: Array(args.dropFirst(2)))
        case "help", "--help", "-h":
            printUsage()
        default:
            print("Unknown command: \(command)")
            printUsage()
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        OmniFS - Universal Linux & Windows Filesystem Engine for macOS (Apple Silicon)
        Usage: omnifs <command> [options]

        Commands:
          list               List all disks, partitions, and detected filesystems
          mount <disk>       Mount partition (e.g. disk3s1) [--ro | --rw]
          unmount <target>   Unmount partition or mount point
          inspect <devPath>  Dump superblock metadata for a block device or raw image
          help               Show this help message

        Supported Filesystems:
          • Linux:   ext2, ext3, ext4, Btrfs, XFS
          • Windows: NTFS (Read & Write)
          • Universal: exFAT, FAT32/VFAT
        """)
    }

    static func handleList() async {
        print("Scanning connected storage devices...")
        let scanner = DiskScanner()
        let partitions = await scanner.scanPartitions()

        if partitions.isEmpty {
            print("No partitions found.")
            return
        }

        func pad(_ str: String, _ width: Int) -> String {
            if str.count >= width { return String(str.prefix(width)) }
            return str + String(repeating: " ", count: width - str.count)
        }

        print("\n--------------------------------------------------------------------------------")
        print("\(pad("DEVICE", 12)) \(pad("FILESYSTEM", 16)) \(pad("SIZE", 10)) \(pad("MOUNTED", 12)) \(pad("LABEL", 20))")
        print("--------------------------------------------------------------------------------")

        for p in partitions {
            let mountedStr = p.isMounted ? "Yes (\(p.isReadOnly ? "RO" : "RW"))" : "No"
            let fsStr = p.fileSystemType.description
            print("\(pad(p.bsdName, 12)) \(pad(fsStr, 16)) \(pad(p.formattedSize, 10)) \(pad(mountedStr, 12)) \(pad(p.volumeName, 20))")
            if let mp = p.mountPoint, !mp.isEmpty {
                print("   ↳ Mount Point: \(mp)")
            }
            if let meta = p.metadata, let uuid = meta.uuid {
                print("   ↳ UUID: \(uuid) | Block Size: \(meta.blockSize ?? 0) bytes")
            }
        }
        print("--------------------------------------------------------------------------------\n")
    }

    static func handleMount(args: [String]) async {
        guard let bsdName = args.first else {
            print("Error: Missing disk identifier (e.g. omnifs mount disk3s1)")
            return
        }

        let isReadOnly = args.contains("--ro")
        let scanner = DiskScanner()
        guard let partition = await scanner.inspectDisk(bsdName: bsdName) else {
            print("Error: Could not locate partition '\(bsdName)'")
            return
        }

        print("Mounting \(partition.bsdName) [\(partition.fileSystemType)] in \(isReadOnly ? "Read-Only" : "Read-Write") mode...")
        let options = MountOptions(isReadOnly: isReadOnly)
        do {
            let result = try await MountManager.shared.mount(partition: partition, options: options)
            if result.success {
                print("✓ Successfully mounted at: \(result.mountPoint)")
            } else {
                print("✗ Mount failed: \(result.message)")
            }
        } catch {
            print("✗ Mount error: \(error)")
        }
    }

    static func handleUnmount(args: [String]) async {
        guard let target = args.first else {
            print("Error: Missing mount target (e.g. omnifs unmount disk3s1)")
            return
        }

        print("Unmounting \(target)...")
        do {
            let success = try await MountManager.shared.unmount(bsdNameOrMountPoint: target)
            if success {
                print("✓ Successfully unmounted \(target)")
            } else {
                print("✗ Failed to unmount \(target)")
            }
        } catch {
            print("✗ Unmount error: \(error)")
        }
    }

    static func handleInspect(args: [String]) async {
        guard let path = args.first else {
            print("Error: Missing device or image file path (e.g. omnifs inspect /dev/disk3s1)")
            return
        }

        print("Inspecting superblock on: \(path)")
        let sniffer = SuperblockSniffer()
        guard let meta = sniffer.probe(devicePath: path) else {
            print("No recognized superblock found on \(path)")
            return
        }

        print("\n=== Superblock Inspection Result ===")
        print("Filesystem:    \(meta.fileSystemType)")
        print("Volume Label:  \(meta.volumeName ?? "(none)")")
        print("UUID:          \(meta.uuid ?? "(none)")")
        print("Block Size:    \(meta.blockSize ?? 0) bytes")
        print("Clean State:   \(meta.isClean == true ? "Clean" : "Dirty / Requires check")")
        if let total = meta.totalBlocks {
            print("Total Blocks:  \(total)")
        }
        if let free = meta.freeBlocks {
            print("Free Blocks:   \(free)")
        }
        if let lastMount = meta.lastMountTime {
            print("Last Mounted:  \(lastMount)")
        }
        if let desc = meta.featuresDescription {
            print("Features:      \(desc)")
        }
        print("====================================\n")
    }
}

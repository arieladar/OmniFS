import Testing
import Foundation
@testable import OmniFSCore

struct OmniFSTests {

    @Test func testFileSystemTypeClassification() {
        let ext4 = FileSystemType.ext4
        #expect(ext4.family == .linux)
        #expect(ext4.requiresOmniFSDriver == true)
        #expect(ext4.isNativeWritableOnMacOS == false)

        let ntfs = FileSystemType.ntfs
        #expect(ntfs.family == .windows)
        #expect(ntfs.requiresOmniFSDriver == true)
        #expect(ntfs.isNativeReadableOnMacOS == true)
        #expect(ntfs.isNativeWritableOnMacOS == false)

        let exfat = FileSystemType.exfat
        #expect(exfat.family == .universal)
        #expect(exfat.requiresOmniFSDriver == false)
        #expect(exfat.isNativeWritableOnMacOS == true)

        let btrfs = FileSystemType.btrfs
        #expect(btrfs.family == .linux)
        #expect(btrfs.requiresOmniFSDriver == true)

        let xfs = FileSystemType.xfs
        #expect(xfs.family == .linux)
        #expect(xfs.requiresOmniFSDriver == true)
    }

    @Test func testExt4SuperblockSniffer() {
        var data = Data(count: 2048)

        // Superblock begins at offset 1024
        let sbOffset = 1024

        // Magic 0xEF53 at offset 0x38 in superblock
        data[sbOffset + 0x38] = 0x53
        data[sbOffset + 0x39] = 0xEF

        // Set log block size = 2 (Block size = 1024 << 2 = 4096)
        data[sbOffset + 0x18] = 0x02

        // Set extents feature in incompat flags (offset 0x60) -> 0x0040
        data[sbOffset + 0x60] = 0x40

        // Set volume label "MyLinuxDrive" at offset 0x78
        let label = "MyLinuxDrive".data(using: .utf8)!
        for (i, byte) in label.enumerated() {
            data[sbOffset + 0x78 + i] = byte
        }

        // Set clean state = 1 at offset 0x3A
        data[sbOffset + 0x3A] = 0x01

        let sniffer = SuperblockSniffer()
        let result = sniffer.probe(data: data)

        #expect(result != nil)
        #expect(result?.fileSystemType == .ext4)
        #expect(result?.volumeName == "MyLinuxDrive")
        #expect(result?.blockSize == 4096)
        #expect(result?.isClean == true)
    }

    @Test func testNTFSSuperblockSniffer() {
        var data = Data(count: 1024)

        // OEM ID "NTFS    " at offset 3
        let oem = "NTFS    ".data(using: .ascii)!
        for (i, byte) in oem.enumerated() {
            data[3 + i] = byte
        }

        // Bytes per sector = 512 (0x0200) at offset 0x0B
        data[0x0B] = 0x00
        data[0x0C] = 0x02

        // Sectors per cluster = 8 at offset 0x0D
        data[0x0D] = 0x08

        let sniffer = SuperblockSniffer()
        let result = sniffer.probe(data: data)

        #expect(result != nil)
        #expect(result?.fileSystemType == .ntfs)
        #expect(result?.blockSize == 4096) // 512 * 8 = 4096
    }

    @Test func testBtrfsSuperblockSniffer() {
        // Btrfs superblock is at offset 65536
        var data = Data(count: 65536 + 4096)

        let sbOffset = 65536
        // Magic "_BHRfS_M" at offset 0x40 in superblock
        let magic = "_BHRfS_M".data(using: .ascii)!
        for (i, byte) in magic.enumerated() {
            data[sbOffset + 0x40 + i] = byte
        }

        // Label at offset 0x12B
        let label = "BtrfsData".data(using: .utf8)!
        for (i, byte) in label.enumerated() {
            data[sbOffset + 0x12B + i] = byte
        }

        let sniffer = SuperblockSniffer()
        let result = sniffer.probe(data: data)

        #expect(result != nil)
        #expect(result?.fileSystemType == .btrfs)
        #expect(result?.volumeName == "BtrfsData")
    }

    @Test func testXFSSuperblockSniffer() {
        var data = Data(count: 1024)

        // Magic "XFSB" at offset 0
        let magic = "XFSB".data(using: .ascii)!
        for (i, byte) in magic.enumerated() {
            data[i] = byte
        }

        // Block size = 4096 (Big Endian: 0x00001000) at offset 0x04
        data[0x04] = 0x00
        data[0x05] = 0x00
        data[0x06] = 0x10
        data[0x07] = 0x00

        // Label at offset 0x6C
        let label = "XFSBackup".data(using: .ascii)!
        for (i, byte) in label.enumerated() {
            data[0x6C + i] = byte
        }

        let sniffer = SuperblockSniffer()
        let result = sniffer.probe(data: data)

        #expect(result != nil)
        #expect(result?.fileSystemType == .xfs)
        #expect(result?.volumeName == "XFSBackup")
        #expect(result?.blockSize == 4096)
    }

    @Test func testExFATSuperblockSniffer() {
        var data = Data(count: 1024)

        // "EXFAT   " at offset 3
        let oem = "EXFAT   ".data(using: .ascii)!
        for (i, byte) in oem.enumerated() {
            data[3 + i] = byte
        }

        let sniffer = SuperblockSniffer()
        let result = sniffer.probe(data: data)

        #expect(result != nil)
        #expect(result?.fileSystemType == .exfat)
    }

    @Test func testMountOptions() {
        let opts = MountOptions(isReadOnly: false, allowOther: true, customMountPoint: "/Volumes/TestDrive")
        #expect(opts.isReadOnly == false)
        #expect(opts.allowOther == true)
        #expect(opts.customMountPoint == "/Volumes/TestDrive")
    }
}

import Foundation
import XCTest
@testable import SFTPCore

final class SFTPLinkTests: XCTestCase {
    func testDirectoryAttributesDistinguishFoldersFilesAndUnknownTargets() throws {
        let id = SFTPLinkService.uint32(1)
        let directory = Data([105]) + id + SFTPLinkService.uint32(7)
            + SFTPLinkService.uint32(0) + SFTPLinkService.uint32(4096)
            + SFTPLinkService.uint32(501) + SFTPLinkService.uint32(20) + SFTPLinkService.uint32(0o040755)
        XCTAssertEqual(try SFTPLinkService.decodeDirectoryAttribute(directory, id: 1), true)
        let file = Data([105]) + id + SFTPLinkService.uint32(4) + SFTPLinkService.uint32(0o100644)
        XCTAssertEqual(try SFTPLinkService.decodeDirectoryAttribute(file, id: 1), false)
        let missing = Data([101]) + id + SFTPLinkService.uint32(2)
        XCTAssertNil(try SFTPLinkService.decodeDirectoryAttribute(missing, id: 1))
        XCTAssertThrowsError(try SFTPLinkService.decodeDirectoryAttribute(directory, id: 2))
        XCTAssertThrowsError(try SFTPLinkService.decodeDirectoryAttribute(Data([105]), id: 1))
    }

    func testLocalServerInspectsMultipleLinkTargetsInOneSession() throws {
        #if os(macOS)
        let server = "/usr/libexec/sftp-server"
        #else
        let server = "/usr/lib/openssh/sftp-server"
        #endif
        guard FileManager.default.isExecutableFile(atPath: server) else { throw XCTSkip("Local SFTP server unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("bytes".utf8).write(to: root.appendingPathComponent("file"))
        for (name, target) in ["folder-link": "folder", "chain": "folder-link", "file-link": "file", "broken": "missing", "loop": "loop"] {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(name).path, withDestinationPath: target)
        }
        let input = Pipe(), output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: server)
        process.standardInput = input; process.standardOutput = output
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let names = ["folder-link", "chain", "file-link", "broken", "loop"]
        let paths = names.map { root.appendingPathComponent($0).path }
        let result = try SFTPLinkService.inspectDirectoryLinks(paths: paths, input: input.fileHandleForWriting, output: output.fileHandleForReading)
        XCTAssertEqual(result[paths[0]], true)
        XCTAssertEqual(result[paths[1]], true)
        XCTAssertEqual(result[paths[2]], false)
        XCTAssertNil(result[paths[3]])
        XCTAssertNil(result[paths[4]])
    }

    private func string(_ value: String) -> Data {
        let data = Data(value.utf8)
        return SFTPLinkService.uint32(UInt32(data.count)) + data
    }

    func testIconTargetsResolveFileChainsAndKeepBrokenLinksUnknown() throws {
        #if os(macOS)
        let server = "/usr/libexec/sftp-server"
        #else
        let server = "/usr/lib/openssh/sftp-server"
        #endif
        guard FileManager.default.isExecutableFile(atPath: server) else { throw XCTSkip("Local SFTP server unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("日本語 document.pdf")
        try Data("bytes".utf8).write(to: file)
        let links = ["folder-link": "folder", "file-link.txt": file.lastPathComponent,
                     "chain": "file-link.txt", "broken": "missing", "loop": "loop"]
        for (name, target) in links {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(name).path, withDestinationPath: target)
        }
        let input = Pipe(), output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: server)
        process.standardInput = input; process.standardOutput = output
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let targets = try SFTPLinkService.inspectLinkIconTargets(paths: links.keys.map { root.appendingPathComponent($0).path },
                                                               input: input.fileHandleForWriting, output: output.fileHandleForReading)
        XCTAssertEqual(targets[root.appendingPathComponent("folder-link").path]?.isDirectory, true)
        for name in ["file-link.txt", "chain"] {
            let target = targets[root.appendingPathComponent(name).path]
            XCTAssertEqual(target?.isDirectory, false)
            let targetPath = try XCTUnwrap(target?.path)
            // Foundation and sftp-server can spell macOS's temporary directory
            // as /var or /private/var. Normalize both sides the same way.
            let targetURL = URL(fileURLWithPath: targetPath)
            XCTAssertEqual(targetURL.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
            XCTAssertEqual(targetURL.lastPathComponent, file.lastPathComponent,
                           "The server must resolve the link chain to the actual filename")
        }
        XCTAssertNil(targets[root.appendingPathComponent("broken").path])
        XCTAssertNil(targets[root.appendingPathComponent("loop").path])
    }

    func testReadLinkDecodesExactTargetAndRejectsErrorsAndInvalidFrames() throws {
        for target in ["../日本語 folder/file", "/outside/missing", "-leading-option", "../a -> b", "../quote'\\name"] {
            let payload = Data([104]) + SFTPLinkService.uint32(1) + SFTPLinkService.uint32(1)
                + string(target) + string("") + SFTPLinkService.uint32(0)
            XCTAssertEqual(try SFTPLinkService.decodeTarget(payload), target)
        }
        let error = Data([101]) + SFTPLinkService.uint32(1) + SFTPLinkService.uint32(2) + string("No such file") + string("")
        XCTAssertThrowsError(try SFTPLinkService.decodeTarget(error))
        XCTAssertThrowsError(try SFTPLinkService.decodeTarget(Data([104, 0])))
        let invalidTarget = Data([104]) + SFTPLinkService.uint32(1) + SFTPLinkService.uint32(1) + string("bad\npath")
        XCTAssertThrowsError(try SFTPLinkService.decodeTarget(invalidTarget))
        let wrongID = Data([104]) + SFTPLinkService.uint32(2) + SFTPLinkService.uint32(1) + string("target")
        XCTAssertThrowsError(try SFTPLinkService.decodeTarget(wrongID))
    }

    func testLocalSFTPServerPreservesRelativeAbsoluteAndDanglingLinkTargets() throws {
        #if os(macOS)
        let server = "/usr/libexec/sftp-server"
        #else
        let server = "/usr/lib/openssh/sftp-server"
        #endif
        guard FileManager.default.isExecutableFile(atPath: server) else { throw XCTSkip("Local SFTP server unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for target in ["../日本語 folder/missing", "/missing/absolute", "-option", "../a -> b"] {
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            let input = Pipe(), output = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: server)
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            defer {
                try? input.fileHandleForWriting.close()
                try? output.fileHandleForReading.close()
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            XCTAssertEqual(try SFTPLinkService.exchange(path: link.path, input: input.fileHandleForWriting,
                                                       output: output.fileHandleForReading), target)
            try FileManager.default.removeItem(at: link)
        }
    }
}

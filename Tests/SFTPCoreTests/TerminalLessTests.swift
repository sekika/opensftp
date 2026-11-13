import Foundation
import XCTest
@testable import SFTPCore

final class TerminalLessTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''", options: .literal) + "'" }
    private var shells: [String] {
        ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/fish", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private func arguments(_ text: String) -> [String] {
        var values = text.components(separatedBy: "\u{0}")
        if values.last == "" { values.removeLast() }
        return values
    }

    func testLocalShellPreservesEverySshArgumentWithoutExecutingFilename() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("quote' \\\\ $(touch injected); mark'\u{301} 日本語.txt").path
        let request = try TerminalLessCommand(host: "user@host", path: path)
        let posix = "cd " + quote(root.path) + "; set -- " + String(request.localScript.dropFirst("exec ".count)) + "; printf '%s\\000' \"$@\""
        let result = await SSHProcess.run("/bin/sh", ["-c", posix])
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertEqual(arguments(result.stdout), ["/usr/bin/ssh"] + request.arguments)
        XCTAssertEqual(Array(request.arguments.prefix(4)), ["-t", "-oStrictHostKeyChecking=yes", "--", "user@host"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
    }

    func testTerminalBootstrapIsShortAndLauncherCleansItselfBeforeExec() async throws {
        let request = try TerminalLessCommand(host: "host", path: "/" + String(repeating: "quote'\\日本語", count: 500))
        let longLauncher = try TerminalLessLauncher(script: request.localScript)
        defer { longLauncher.remove() }
        XCTAssertFalse(longLauncher.commandLine.contains("\n"))
        XCTAssertLessThan(longLauncher.commandLine.utf8.count, 1024)
        XCTAssertTrue(try String(contentsOf: longLauncher.file).contains(request.localScript))
        let mode = try FileManager.default.attributesOfItem(atPath: longLauncher.directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        let fileMode = try FileManager.default.attributesOfItem(atPath: longLauncher.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)

        for shell in shells {
            // Exercise the actual short command through each interactive-shell
            // parser, then execute a harmless stand-in instead of contacting SSH.
            let launcher = try TerminalLessLauncher(script: "exec /bin/sh -c 'printf launched'")
            defer { launcher.remove() }
            let result = await SSHProcess.run(shell, ["-c", launcher.commandLine + "; printf shell-still-running"])
            XCTAssertTrue(result.succeeded, "\(shell): \(result.stderr)")
            XCTAssertEqual(result.stdout, "launched", shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.directory.path), shell)
        }
    }

    func testRemoteShellPassesLiteralTextPathToLess() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("quote' \\\\ $(touch injected); mark'\u{301} 日本語.txt")
        try Data("plain text\n".utf8).write(to: file)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let less = bin.appendingPathComponent("less")
        try Data("#!/bin/sh\nprintf '%s\\000' \"$@\"\n".utf8).write(to: less)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: less.path)
        let request = try TerminalLessCommand(host: "host", path: file.path)
        for shell in shells {
            // Set PATH in the outer POSIX test driver, then model the remote
            // login shell interpreting SSH's command before /bin/sh takes over.
            let script = "cd " + quote(root.path) + "; PATH=" + quote(bin.path) + ":\"$PATH\"; export PATH; exec "
                + quote(shell) + " -c " + quote(request.remoteCommand)
            let result = await SSHProcess.run("/bin/sh", ["-c", script])
            XCTAssertTrue(result.succeeded, "\(shell): \(result.stderr)")
            XCTAssertEqual(arguments(result.stdout), ["--", file.path], shell)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
    }

    func testLauncherPreservesFailureForTerminalDiagnostics() async throws {
        for shell in shells {
            let launcher = try TerminalLessLauncher(script: "exec /bin/sh -c 'echo connection-failed >&2; exit 23'")
            defer { launcher.remove() }
            let result = await SSHProcess.run(shell, ["-c", launcher.commandLine])
            XCTAssertFalse(result.succeeded, shell)
            XCTAssertTrue(result.stderr.contains("connection-failed"), shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.directory.path), shell)
        }
    }

    func testRemoteChecksRejectBinaryFilesDirectoriesAndLinks() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("binary")
        try Data([0, 255, 0, 255]).write(to: binary)
        let text = root.appendingPathComponent("text")
        try Data("hello\n".utf8).write(to: text)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: text)
        for path in [binary.path, root.path, link.path] {
            let request = try TerminalLessCommand(host: "host", path: path)
            let result = await SSHProcess.run("/bin/sh", ["-c", request.remoteCommand])
            XCTAssertFalse(result.succeeded)
            XCTAssertTrue(result.stderr.contains("OpenSFTP:"), result.stderr)
        }
    }

    func testRejectsOptionsRelativePathsAndControlCharacters() {
        for host in ["-oProxyCommand=bad", "sftp://host", "host\nother"] {
            XCTAssertThrowsError(try TerminalLessCommand(host: host, path: "/file"))
        }
        for path in ["relative", "/bad\nname", "/bad\u{0}name", "/a/../file"] {
            XCTAssertThrowsError(try TerminalLessCommand(host: "host", path: path))
        }
    }
}

import XCTest
@testable import SFTPCore
import SFTPPTY
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class PTYTests: XCTestCase {
    func testPipeChildSeesEOFWithoutInheritingParentPipeEnds() throws {
        let input = Pipe(), output = Pipe(), error = Pipe()
        // Force inheritable descriptors: Foundation's defaults vary by platform.
        for pipe in [input, output, error] {
            for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
                let descriptor = handle.fileDescriptor
                XCTAssertEqual(fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) & ~FD_CLOEXEC), 0)
            }
        }
        // cat, like rsync --files-from=-, must read stdin through EOF to finish.
        let argv = [strdup("/bin/cat"), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { argv.forEach { free($0) } }
        let pid = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                opensftp_spawn_pipes("/bin/cat", input.fileHandleForReading.fileDescriptor,
                    output.fileHandleForWriting.fileDescriptor, error.fileHandleForWriting.fileDescriptor,
                    args.baseAddress!, env.baseAddress!)
            }
        }
        XCTAssertGreaterThan(pid, 0)
        guard pid > 0 else { return }
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        try error.fileHandleForWriting.close()
        let manifest = Data("./日本語\u{0}./sub/file\u{0}".utf8)
        try input.fileHandleForWriting.write(contentsOf: manifest)
        try input.fileHandleForWriting.close()
        let finished = expectation(description: "Child exits on manifest EOF")
        DispatchQueue.global().async {
            XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), manifest)
            XCTAssertTrue(error.fileHandleForReading.readDataToEndOfFile().isEmpty)
            XCTAssertEqual(sftp_wait(pid), 0)
            finished.fulfill()
        }
        // Kill on timeout so a regression cannot leave a blocked reader behind.
        let result = XCTWaiter.wait(for: [finished], timeout: 3)
        if result != .completed { _ = kill(-pid, SIGKILL) }
        XCTAssertEqual(result, .completed)
    }

    func testCancellationStopsSFTPProcessGroupForPipeAndPTYRuns() throws {
        for usePTY in [false, true] {
            let input = Pipe(), output = Pipe(), error = Pipe()
            // A local transport that never answers the SFTP handshake.
            let arguments = ["sftp", "-D", "/bin/sleep 30", "local"]
            let argv = arguments.map { strdup($0) } + [nil]
            let envp: [UnsafeMutablePointer<CChar>?] = [nil]
            defer { argv.forEach { free($0) } }
            var master: Int32 = -1
            let pid = argv.withUnsafeBufferPointer { args in
                envp.withUnsafeBufferPointer { env in
                    if usePTY {
                        return sftp_spawn_pty(&master, input.fileHandleForReading.fileDescriptor,
                                              error.fileHandleForWriting.fileDescriptor, args.baseAddress!, env.baseAddress!)
                    }
                    return sftp_spawn_pipes(input.fileHandleForReading.fileDescriptor,
                                             output.fileHandleForWriting.fileDescriptor,
                                             error.fileHandleForWriting.fileDescriptor, args.baseAddress!, env.baseAddress!)
                }
            }
            XCTAssertGreaterThan(pid, 0)
            guard pid > 0 else { continue }
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            try error.fileHandleForWriting.close()
            let cancellation = RunCancellation()
            cancellation.install {
                _ = kill(-pid, SIGKILL)
                _ = kill(pid, SIGKILL)
            }
            let stopped = expectation(description: "SFTP and its transport stop")
            let terminalDescriptor = master
            DispatchQueue.global().async {
                if usePTY {
                    while SFTPService.readTransferOutput(from: terminalDescriptor) != nil {}
                    _ = close(terminalDescriptor)
                } else { _ = output.fileHandleForReading.readDataToEndOfFile() }
                _ = error.fileHandleForReading.readDataToEndOfFile()
                cancellation.finish()
                XCTAssertNotEqual(sftp_wait(pid), 0)
                stopped.fulfill()
            }
            cancellation.cancel()
            wait(for: [stopped], timeout: 3)
        }
    }

    func testCancellationBeforeInstallationAndAfterFinish() {
        let cancellation = RunCancellation()
        var calls = 0
        cancellation.cancel()
        cancellation.install { calls += 1 }
        cancellation.cancel()
        XCTAssertEqual(calls, 1)
        cancellation.finish()
        cancellation.cancel()
        XCTAssertEqual(calls, 1)

        let finished = RunCancellation()
        finished.install { XCTFail("A finished run must never be signalled") }
        finished.finish()
        finished.cancel()
    }

    func testSmallProgressFrameIsReadBeforeWriterCloses() throws {
        // Keep the writer open: a buffered read would hold this initial frame
        // until more output arrives or the transfer finishes.
        let pipe = Pipe()
        let frame = Data("\rfile 0% 0 0.0KB/s --:-- ETA".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: frame)
        let received = expectation(description: "Initial progress arrives while transfer is running")
        let finished = expectation(description: "Reader finishes")
        DispatchQueue.global().async {
            let data = SFTPService.readTransferOutput(from: pipe.fileHandleForReading.fileDescriptor)
            XCTAssertEqual(data, frame)
            var decoder = ProgressOutputDecoder()
            var fractions: [Double] = []
            _ = decoder.consume(data ?? Data()) { fractions.append($0.fraction) }
            XCTAssertEqual(fractions, [0])
            received.fulfill()
            try? pipe.fileHandleForReading.close()
            finished.fulfill()
        }
        wait(for: [received], timeout: 1)
        try pipe.fileHandleForWriting.close()
        wait(for: [finished], timeout: 1)
    }

    func testLocalSFTPTransfersStreamProgressWithInheritedAlarmBlocked() throws {
        try assertLocalTransferStreamsProgress(command: "put")
        try assertLocalTransferStreamsProgress(command: "get")
    }

    private func assertLocalTransferStreamsProgress(command: String) throws {
        #if os(macOS)
        let server = "/usr/libexec/sftp-server"
        #else
        let server = "/usr/lib/openssh/sftp-server"
        #endif
        guard FileManager.default.isExecutableFile(atPath: server) else {
            throw XCTSkip("Local OpenSSH SFTP server is unavailable")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source with spaces")
        let destination = directory.appendingPathComponent("destination")
        let bytes = Data(repeating: 65, count: 131072)
        try bytes.write(to: source)
        let input = Pipe(), error = Pipe()
        // Pin the buffer size: server-advertised read limits can otherwise let
        // this whole file arrive in one read, before the limiter starts waiting.
        // 128 KiB at 256 Kbit/s takes about four seconds with these small reads.
        let arguments: [String] = ["sftp", "-D", server, "-B", "4096", "-R", "1",
                                   "-l", "256", "-b", "-", "local"]
        let environment: [String] = ["LC_ALL=C", "SSH_ASKPASS_REQUIRE=never"]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { value in
            value.withCString { strdup($0) }
        } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { value in
            value.withCString { strdup($0) }
        } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var master: Int32 = -1
        // Simulate a dispatch worker's signal mask. Without resetting this in
        // the child, the initial 0% arrives but the alarm cannot refresh it.
        var blocked = sigset_t(), previous = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGALRM)
        XCTAssertEqual(pthread_sigmask(SIG_BLOCK, &blocked, &previous), 0)
        let pid = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                sftp_spawn_pty(&master, input.fileHandleForReading.fileDescriptor,
                               error.fileHandleForWriting.fileDescriptor, args.baseAddress!, env.baseAddress!)
            }
        }
        XCTAssertEqual(pthread_sigmask(SIG_SETMASK, &previous, nil), 0)
        XCTAssertGreaterThan(pid, 0)
        guard pid > 0 else { return }
        try input.fileHandleForReading.close()
        try error.fileHandleForWriting.close()
        let terminal = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let batch = "progress\n\(command) \(try SFTPCommand.quote(source.path)) \(try SFTPCommand.quote(destination.path))\nbye\n"
        try input.fileHandleForWriting.write(contentsOf: Data(batch.utf8))
        try input.fileHandleForWriting.close()
        var decoder = ProgressOutputDecoder()
        var fractions: [Double] = []
        var receivedBeforeCompletion = false
        func receive(_ value: TransferProgress) {
            fractions.append(value.fraction)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let saved = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            if value.fraction > 0, value.fraction < 1, saved < bytes.count { receivedBeforeCompletion = true }
        }
        while let data = SFTPService.readTransferOutput(from: terminal.fileDescriptor) {
            _ = decoder.consume(data, progress: receive)
        }
        _ = decoder.consume(Data(), finish: true, progress: receive)
        try terminal.close()
        XCTAssertEqual(sftp_wait(pid), 0)
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        try error.fileHandleForReading.close()
        XCTAssertTrue(stderr.isEmpty, String(decoding: stderr, as: UTF8.self))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertTrue(receivedBeforeCompletion, "\(command): Progress must advance before the destination is complete; received: \(fractions)")
        XCTAssertTrue(fractions.contains(0))
        XCTAssertTrue(fractions.contains(where: { $0 > 0 && $0 < 1 }), "Expected intermediate progress; received: \(fractions)")
        XCTAssertTrue(fractions.contains(1))
    }
}

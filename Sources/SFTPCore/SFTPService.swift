import Foundation
import SFTPPTY
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum FailureKind: String {
    case launch = "sftp起動失敗", hostKeyMismatch = "ホスト鍵不一致", hostKeyUnknown = "ホスト鍵未登録"
    case authentication = "認証失敗", network = "接続失敗・切断", operation = "操作失敗"
}

public struct RunResult {
    public let started: Date
    public let ended: Date
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let failure: FailureKind?
    public var succeeded: Bool { failure == nil }

    public init(started: Date, ended: Date, stdout: String, stderr: String, exitCode: Int32, failure: FailureKind?) {
        self.started = started; self.ended = ended; self.stdout = stdout; self.stderr = stderr
        self.exitCode = exitCode; self.failure = failure
    }

    public static func classify(code: Int32, stdout: String, stderr: String) -> FailureKind? {
        let text = (stderr + "\n" + stdout).lowercased()
        if text.contains("remote host identification has changed") || text.contains("offending ") { return .hostKeyMismatch }
        if text.contains("host key verification failed") || text.contains("no ") && text.contains("host key is known") { return .hostKeyUnknown }
        if text.contains("permission denied (publickey") || text.contains("authentication failed") || text.contains("too many authentication failures") { return .authentication }
        if ["connection refused", "connection closed", "connection reset", "could not resolve", "timed out", "no route to host", "network is unreachable", "broken pipe"].contains(where: text.contains) { return .network }
        if code != 0 { return .operation }
        let responseLines = stdout.components(separatedBy: .newlines).filter { !$0.hasPrefix("sftp> ") }
        let errorPattern = #"(?i)^(?:failure|error:|couldn't |cannot |invalid command|permission denied|no such file)"#
        if responseLines.contains(where: { $0.range(of: errorPattern, options: .regularExpression) != nil }) { return .operation }
        // OpenSSH can emit failures even when its final process status is zero.
        if ["permission denied", "failure", "no such file", "couldn't", "cannot ", "not found", "invalid command", "not a directory", "is a directory"].contains(where: stderr.lowercased().contains) { return .operation }
        return nil
    }
}

public enum LogRedactor {
    public static func redact(_ text: String) -> String {
        var insideKey = false
        return text.components(separatedBy: .newlines).map { line in
            if line == BoundedLog.marker.trimmingCharacters(in: .newlines) { return line }
            let upper = line.uppercased()
            if upper.contains("-----BEGIN ") && upper.contains("PRIVATE KEY") { insideKey = true }
            if insideKey {
                if upper.contains("-----END ") && upper.contains("PRIVATE KEY") { insideKey = false }
                return "[秘密鍵出力をマスク]"
            }
            // This fixed SSH option disables password prompts; it contains no
            // credential. Keep the rest of the line subject to normal masking.
            let lower = line.lowercased().replacingOccurrences(of: "numberofpasswordprompts=0", with: "")
            if ["password", "passphrase", "secret", "token", "verification code", "one-time", "otp"].contains(where: lower.contains) {
                return "[認証情報の可能性がある行をマスク]"
            }
            return line
        }.joined(separator: "\n")
    }
}

public struct LinkIconTarget: Codable, Sendable {
    public let isDirectory: Bool
    public let path: String?
    public init(isDirectory: Bool, path: String? = nil) {
        self.isDirectory = isDirectory; self.path = path
    }
}

public protocol SFTPRunning {
    func linkIconTargets(host: String, paths: [String]) async -> [String: LinkIconTarget]
    func directoryLinks(host: String, paths: [String]) async -> [String: Bool]
    func readLink(host: String, path: String) async -> RunResult
    func run(host: String, commands: [String]) async -> RunResult
    func run(host: String, commands: [String], progress: @escaping @Sendable (TransferProgress) async -> Void) async -> RunResult
}

public extension SFTPRunning {
    func linkIconTargets(host: String, paths: [String]) async -> [String: LinkIconTarget] {
        await directoryLinks(host: host, paths: paths).mapValues { LinkIconTarget(isDirectory: $0) }
    }
    func directoryLinks(host: String, paths: [String]) async -> [String: Bool] { [:] }
    func readLink(host: String, path: String) async -> RunResult {
        await SFTPLinkService.readLink(host: host, path: path)
    }
    func run(host: String, commands: [String], progress: @escaping @Sendable (TransferProgress) async -> Void) async -> RunResult {
        await run(host: host, commands: commands)
    }
}

public struct SFTPService: SFTPRunning {
    public func linkIconTargets(host: String, paths: [String]) async -> [String: LinkIconTarget] {
        await SFTPLinkService.linkIconTargets(host: host, paths: paths)
    }
    private let limitsOverride: ResourceLimits?
    public init(limits: ResourceLimits? = nil) { limitsOverride = limits?.validated }
    public func directoryLinks(host: String, paths: [String]) async -> [String: Bool] {
        await SFTPLinkService.directoryLinks(host: host, paths: paths)
    }

    static func processEnvironment(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited
        // LC_ALL overrides individual categories. Keep dates and diagnostics in
        // English, but allow OpenSSH to print UTF-8 paths instead of octal bytes.
        environment.removeValue(forKey: "LC_ALL")
        environment["LANG"] = "C"
        environment["LC_TIME"] = "C"
        environment["LC_MESSAGES"] = "C"
        #if canImport(Darwin)
        environment["LC_CTYPE"] = "en_US.UTF-8"
        #else
        environment["LC_CTYPE"] = "C.UTF-8"
        #endif
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment.removeValue(forKey: "SSH_ASKPASS")
        return environment
    }
    public func run(host: String, commands: [String], progress: @escaping @Sendable (TransferProgress) async -> Void) async -> RunResult {
        let limits = limitsOverride ?? .standard
        guard commands.first.map({ $0.hasPrefix("get ") || $0.hasPrefix("put ") }) == true else {
            return await run(host: host, commands: commands)
        }
        // Progress is a snapshot: retain the latest value if the UI is busy,
        // rather than accumulating an unbounded queue of meter updates.
        let (events, sink) = AsyncStream<TransferProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { for await value in events { await progress(value) } }
        let cancellation = RunCancellation()
        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<RunResult, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.transfer(host: host, commands: commands, cancellation: cancellation, limits: limits) { sink.yield($0) })
                }
            }
        }, onCancel: { cancellation.cancel() })
        sink.finish()
        await consumer.value
        return result
    }

    private static func transfer(host: String, commands: [String], cancellation: RunCancellation, limits: ResourceLimits, progress: @escaping @Sendable (TransferProgress) -> Void) -> RunResult {
        let started = Date()
        let failure = RunResult(started: started, ended: Date(), stdout: "", stderr: "転送用sftpを起動できません。", exitCode: -1, failure: .launch)
        guard (try? SFTPCommand.validateHost(host)) != nil else { return failure }
        let input = Pipe(), error = Pipe()
        #if canImport(Darwin)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        let environment = processEnvironment(ProcessInfo.processInfo.environment)
        let arguments = ["/usr/bin/sftp", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oNumberOfPasswordPrompts=0",
                         "-oConnectTimeout=15", "-oServerAliveInterval=15", "-oServerAliveCountMax=3", "-b", "-", "--", host]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { value in
            value.withCString { strdup($0) }
        } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { entry in
            "\(entry.key)=\(entry.value)".withCString { strdup($0) }
        } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var master: Int32 = -1
        let pid = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                sftp_spawn_pty(&master, input.fileHandleForReading.fileDescriptor,
                               error.fileHandleForWriting.fileDescriptor, args.baseAddress!, env.baseAddress!)
            }
        }
        guard pid > 0 else { return failure }
        // forkpty gives this run its own group, including its SSH child.
        cancellation.install {
            _ = kill(-pid, SIGKILL)
            _ = kill(pid, SIGKILL)
        }
        defer { cancellation.finish() }
        try? input.fileHandleForReading.close()
        try? error.fileHandleForWriting.close()
        let terminal = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let err = DataBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            var decoder = ProgressOutputDecoder(pendingLimit: limits.logBytes)
            var diagnostics = BoundedOutput(limit: limits.logBytes)
            while let data = Self.readTransferOutput(from: error.fileHandleForReading.fileDescriptor) {
                _ = diagnostics.append(Data(decoder.consume(data, progress: progress).utf8))
            }
            _ = diagnostics.append(Data(decoder.consume(Data(), finish: true, progress: progress).utf8))
            err.data = Data(diagnostics.text.utf8)
            try? error.fileHandleForReading.close()
            readers.leave()
        }
        // Batch mode starts with the meter disabled. Toggle it explicitly; no -N dependency.
        try? input.fileHandleForWriting.write(contentsOf: Data((["progress"] + commands).joined(separator: "\n").appending("\n").utf8))
        try? input.fileHandleForWriting.close()
        var decoder = ProgressOutputDecoder(pendingLimit: limits.logBytes)
        var stdout = BoundedOutput(limit: limits.logBytes)
        // PTYs can report EIO rather than EOF when the slave closes.
        while let data = readTransferOutput(from: terminal.fileDescriptor) {
            _ = stdout.append(Data(decoder.consume(data, progress: progress).utf8))
        }
        _ = stdout.append(Data(decoder.consume(Data(), finish: true, progress: progress).utf8))
        try? terminal.close()
        readers.wait()
        // Stop sending signals before reaping makes the PID reusable.
        cancellation.finish()
        let code = Int32(sftp_wait(pid))
        let stderr = String(decoding: err.data, as: UTF8.self)
        let output = stdout.text
        return RunResult(started: started, ended: Date(), stdout: output, stderr: stderr, exitCode: code,
                         failure: code == 127 ? .launch : RunResult.classify(code: code, stdout: output, stderr: stderr))
    }

    // FileHandle.read(upToCount:) may wait to fill the requested buffer on a PTY.
    // A single POSIX read returns the bytes currently available, so a small meter
    // frame reaches the UI while the transfer is still running.
    static func readTransferOutput(from descriptor: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress!, bytes.count)
            }
            if count > 0 { return Data(buffer.prefix(count)) }
            if count < 0, errno == EINTR { continue }
            // EOF, or EIO when the PTY slave closes.
            return nil
        }
    }

    public func run(host: String, commands: [String]) async -> RunResult {
        let limits = limitsOverride ?? .standard
        let isListing = commands.contains { $0 == "ls" || $0.hasPrefix("ls ") }
        let cancellation = RunCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let started = Date()
                    let arguments = ["/usr/bin/sftp", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oNumberOfPasswordPrompts=0",
                                     "-oConnectTimeout=15", "-oServerAliveInterval=15", "-oServerAliveCountMax=3", "-b", "-", "--", host]
                    let environment = Self.processEnvironment(ProcessInfo.processInfo.environment)
                    let argv = arguments.map { strdup($0) } + [nil]
                    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
                    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
                    let input = Pipe(), output = Pipe(), error = Pipe()
                    #if canImport(Darwin)
                    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    #endif
                    let pid: pid_t
                    if (try? SFTPCommand.validateHost(host)) != nil {
                        pid = argv.withUnsafeBufferPointer { args in
                            envp.withUnsafeBufferPointer { env in
                                sftp_spawn_pipes(input.fileHandleForReading.fileDescriptor,
                                                 output.fileHandleForWriting.fileDescriptor,
                                                 error.fileHandleForWriting.fileDescriptor,
                                                 args.baseAddress!, env.baseAddress!)
                            }
                        }
                    } else { pid = -1 }
                    guard pid > 0 else {
                        continuation.resume(returning: RunResult(started: started, ended: Date(), stdout: "",
                            stderr: "macOS標準のsftpを起動できません。接続先と実行環境を確認してください。", exitCode: -1, failure: .launch))
                        return
                    }
                    cancellation.install { _ = kill(-pid, SIGKILL) }
                    try? input.fileHandleForReading.close()
                    try? output.fileHandleForWriting.close()
                    try? error.fileHandleForWriting.close()
                    // Drain both pipes concurrently so either stream can exceed the pipe buffer.
                    let readers = DispatchGroup()
                    let out = DataBox(), err = DataBox()
                    for (pipe, box) in [(output, out), (error, err)] {
                        readers.enter()
                        DispatchQueue.global(qos: .utility).async {
                            let listingOutput = isListing && box === out
                            let captured = BoundedOutput.read(pipe.fileHandleForReading,
                                limit: listingOutput ? limits.listingBytes : limits.logBytes,
                                onExceeded: { if listingOutput { cancellation.cancel() } })
                            box.data = captured.data
                            box.exceeded = captured.exceeded
                            try? pipe.fileHandleForReading.close()
                            readers.leave()
                        }
                    }
                    // Only small, generated batches are accepted. Never pass a shell command.
                    let batch = Data((commands.joined(separator: "\n") + "\n").utf8)
                    try? input.fileHandleForWriting.write(contentsOf: batch)
                    try? input.fileHandleForWriting.close()
                    readers.wait()
                    cancellation.finish()
                    let code = Int32(sftp_wait(pid))
                    let overflow = isListing && out.exceeded
                    let stdout = overflow ? "" : String(decoding: out.data, as: UTF8.self) + (out.exceeded ? BoundedLog.marker : "")
                    let stderr = String(decoding: err.data, as: UTF8.self) + (err.exceeded ? BoundedLog.marker : "")
                        + (overflow ? "\n" + ResourceLimitError.listing.localizedDescription : "")
                    continuation.resume(returning: RunResult(started: started, ended: Date(), stdout: stdout,
                        stderr: stderr, exitCode: code,
                        failure: overflow ? .operation : code == 127 ? .launch : RunResult.classify(code: code, stdout: stdout, stderr: stderr)))
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}

// Installation and cancellation may race with process startup on the worker queue.
// Keep the action under the lock so finish cannot leave a stale signal pending.
final class RunCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var stop: (() -> Void)?

    func install(_ action: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        stop = action
        if cancelled { action() }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        stop?()
    }

    func whileCancelling(_ action: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if cancelled, stop != nil { action() }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        stop = nil
    }
}

private final class DataBox: @unchecked Sendable { var data = Data(); var exceeded = false }

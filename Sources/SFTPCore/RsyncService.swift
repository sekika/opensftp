import Foundation
import SFTPPTY
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum FolderTransferMethod: String, Sendable, CaseIterable {
    case sftp = "SFTP"
    case sftpOverwrite = "SFTP: すべて上書き"
    case rsync = "rsync"
    case rsyncDelete = "rsync --delete"

    public static func choices(destinationExists: Bool) -> [Self] {
        destinationExists ? allCases : [.sftp, .rsync]
    }

    public func selectionTitle(destinationExists: Bool) -> String {
        destinationExists ? selectionTitle : rawValue
    }

    public var selectionTitle: String { self == .sftp ? "SFTP: 更新分だけ" : rawValue }
    public var policy: FolderTransferPolicy { self == .sftpOverwrite ? .overwrite : .updatedOnly }
}

/// Planned transfers use a NUL-delimited manifest of accepted files and links.
/// Delete mode instead compares the entire source tree using native recursion.
public struct RsyncRequest: Sendable {
    public let arguments: [String]
    public let input: Data

    /// Shell-quoted for display only; execution still uses the argument array.
    public var commandLine: String {
        (["/usr/bin/rsync"] + arguments).map {
            "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    public static func makeSSHCommand(preferences: ConnectionPreferences) -> String {
        var options = [
            "-oBatchMode=yes",
            "-oStrictHostKeyChecking=\(preferences.strictHostKeyChecking)",
            "-oNumberOfPasswordPrompts=0",
            "-oConnectTimeout=\(max(1, preferences.connectTimeout))",
            "-oServerAliveInterval=\(max(0, preferences.serverAliveInterval))",
            "-oServerAliveCountMax=\(max(1, preferences.serverAliveCountMax))"
        ]
        let extra = preferences.extraOptions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            options.append(extra)
        }
        return "/usr/bin/ssh " + options.joined(separator: " ")
    }

    public init(host: String, local: URL, remote: String, direction: FolderTransferDirection, files: [String], deleteExtraneous: Bool = false, preferences: ConnectionPreferences = .standard) throws {
        try SFTPCommand.validateHost(host)
        try SFTPCommand.validatePath(remote)
        guard local.isFileURL, local.path.hasPrefix("/"), remote.hasPrefix("/"), remote != "/",
              !remote.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw InputError.invalidPath
        }
        for file in files {
            try SFTPCommand.validatePath(file)
            guard !file.hasPrefix("/"), !file.hasSuffix("/"), !file.contains("//"),
                  !file.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw InputError.invalidPath
            }
        }
        if deleteExtraneous {
            guard files.isEmpty else { throw InputError.invalidPath }
        }
        if files.isEmpty {
            guard local.path != "/", !local.pathComponents.contains(where: { $0 == "." || $0 == ".." }) else { throw InputError.invalidPath }
        }
        // Keep user paths out of the remote operand parser. The remote shell
        // receives just a quoted cd followed by rsync's generated server command.
        let quotedRoot = "'" + remote.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let ssh = Self.makeSSHCommand(preferences: preferences)
        let localRoot = local.path.hasSuffix("/") ? local.path : local.path + "/"
        let remoteRoot = host + ":./"
        // Whole-tree recursion compares the complete tree directly.
        // If files are specified, a filtered --files-from manifest is used.
        let mode = files.isEmpty
            ? (deleteExtraneous ? ["--recursive", "--delete"] : ["--recursive"])
            : ["--relative", "--no-implied-dirs", "--ignore-times", "--from0", "--files-from=-"]
        var initialArgs = [preferences.rsyncCompression ? "-avz" : "-av"]
        if preferences.rsyncExtendedAttributes {
            initialArgs.append("-E")
        }
        // Display UTF-8 filenames as text in logs instead of rsync's byte escapes.
        initialArgs += ["--8-bit-output", "-e", ssh]
        arguments = initialArgs + mode + ["--stats",
                     "--rsync-path=cd " + quotedRoot + " && rsync", "--"] +
            (direction == .upload ? [localRoot, remoteRoot] : [remoteRoot, localRoot])
        input = Data(files.sorted().flatMap { Array(("./" + $0).utf8) + [UInt8(0)] })
    }
}

public enum RsyncOutputChunk: Sendable {
    case stdout(String), stderr(String)
}

public protocol RsyncRunning {
    func run(_ request: RsyncRequest) async -> RunResult
    func run(_ request: RsyncRequest, output: @escaping @Sendable (RsyncOutputChunk) async -> Void) async -> RunResult
}

public extension RsyncRunning {
    func run(_ request: RsyncRequest, output: @escaping @Sendable (RsyncOutputChunk) async -> Void) async -> RunResult {
        let result = await run(request)
        if !result.stdout.isEmpty { await output(.stdout(result.stdout)) }
        if !result.stderr.isEmpty { await output(.stderr(result.stderr)) }
        return result
    }
}

public struct RsyncService: RsyncRunning, Sendable {
    private let executable: String
    private let argumentsOverride: [String]?
    public init() { executable = "/usr/bin/rsync"; argumentsOverride = nil }
    // Exercise the real process/streaming path with a local gated child in tests.
    init(executable: String, arguments: [String]) {
        self.executable = executable; self.argumentsOverride = arguments
    }

    public func run(_ request: RsyncRequest) async -> RunResult {
        await run(request, output: { _ in })
    }

    public func run(_ request: RsyncRequest, output receive: @escaping @Sendable (RsyncOutputChunk) async -> Void) async -> RunResult {
        let logLimit = ResourceLimits.standard.logBytes
        let executable = self.executable
        let arguments = argumentsOverride ?? request.arguments
        let (events, sink) = AsyncStream<RsyncOutputChunk>.makeStream()
        let consumer = Task { for await event in events { await receive(event) } }
        let cancellation = RunCancellation()
        let result: RunResult = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let started = Date()
                    let input = Pipe(), error = Pipe()
                    #if canImport(Darwin)
                    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    #endif
                    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
                    let envp = SFTPService.processEnvironment(ProcessInfo.processInfo.environment)
                        .map { strdup("\($0.key)=\($0.value)") } + [nil]
                    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
                    var master: Int32 = -1
                    let pid = argv.withUnsafeBufferPointer { args in
                        envp.withUnsafeBufferPointer { env in
                            opensftp_spawn_output_pty(executable, &master, input.fileHandleForReading.fileDescriptor,
                                                      error.fileHandleForWriting.fileDescriptor, args.baseAddress!, env.baseAddress!)
                        }
                    }
                    guard pid > 0 else {
                        continuation.resume(returning: RunResult(started: started, ended: Date(), stdout: "",
                            stderr: "rsyncを起動できません。/usr/bin/rsyncを確認してください。", exitCode: -1, failure: .launch))
                        return
                    }
                    cancellation.install {
                        // Let rsync remove its temporary file before escalating.
                        _ = kill(-pid, SIGTERM)
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            cancellation.whileCancelling { _ = kill(-pid, SIGKILL) }
                        }
                    }
                    try? input.fileHandleForReading.close()
                    try? error.fileHandleForWriting.close()
                    let terminal = FileHandle(fileDescriptor: master, closeOnDealloc: true)
                    let readers = DispatchGroup()
                    let stdout = RsyncOutput(limit: logLimit), stderr = RsyncOutput(limit: logLimit)
                    for (handle, box, isError) in [(terminal, stdout, false), (error.fileHandleForReading, stderr, true)] {
                        readers.enter()
                        DispatchQueue.global(qos: .utility).async {
                            var decoder = RsyncLineDecoder()
                            while let data = SFTPService.readTransferOutput(from: handle.fileDescriptor) {
                                let exceeded = box.captured.exceeded
                                let retained = box.captured.append(data)
                                var text = decoder.consume(retained)
                                if box.captured.exceeded && !exceeded {
                                    text += decoder.consume(Data(), finish: true) + BoundedLog.marker
                                }
                                if !text.isEmpty { sink.yield(isError ? .stderr(text) : .stdout(text)) }
                            }
                            let tail = decoder.consume(Data(), finish: true)
                            if !tail.isEmpty { sink.yield(isError ? .stderr(tail) : .stdout(tail)) }
                            try? handle.close()
                            readers.leave()
                        }
                    }
                    try? input.fileHandleForWriting.write(contentsOf: request.input)
                    try? input.fileHandleForWriting.close()
                    readers.wait()
                    cancellation.finish()
                    let code = Int32(sftp_wait(pid))
                    let out = stdout.captured.text
                    let err = stderr.captured.text
                    continuation.resume(returning: RunResult(started: started, ended: Date(), stdout: out, stderr: err,
                        exitCode: code, failure: code == 0 ? nil : .operation))
                }
            }
        }, onCancel: { cancellation.cancel() })
        sink.finish()
        await consumer.value
        return result
    }
}

private final class RsyncOutput: @unchecked Sendable {
    var captured: BoundedOutput
    init(limit: Int) { captured = BoundedOutput(limit: limit) }
}

/// Publish complete lines, retaining split UTF-8 and partial credential markers
/// until the line can be redacted as a whole. Flush any final tail at EOF.
struct RsyncLineDecoder {
    private var pending = Data()
    mutating func consume(_ data: Data, finish: Bool = false) -> String {
        pending.append(data)
        guard let newline = pending.lastIndex(of: 10) else {
            if finish { defer { pending = Data() }; return String(decoding: pending, as: UTF8.self) }
            return ""
        }
        let end = finish ? pending.endIndex : pending.index(after: newline)
        let text = String(decoding: pending[..<end], as: UTF8.self)
        pending = Data(pending[end...])
        return text
    }
}

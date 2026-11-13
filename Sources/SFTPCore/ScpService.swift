import Foundation
import SFTPPTY
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ScpRequest: Sendable {
    public let source: RemoteEndpoint
    public let destination: RemoteEndpoint
    public let arguments: [String]
    public init(source: RemoteEndpoint, destination: RemoteEndpoint) throws {
        try source.validate(); try destination.validate()
        self.source = source; self.destination = destination
        // Only the source operand is globbed by scp's SFTP client. Destination
        // paths are literal. Shell quotes would become filename characters.
        var literal = ""
        for char in source.path {
            if "\\*?[]{}".contains(char) { literal.append("\\") }
            literal.append(char)
        }
        arguments = ["-3", "-B", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
                     "-oNumberOfPasswordPrompts=0", "-oConnectTimeout=15",
                     "-oServerAliveInterval=15", "-oServerAliveCountMax=3", "--",
                     source.host + ":" + literal, destination.description]
    }
    public var commandLine: String { SSHProcess.commandLine("/usr/bin/scp", arguments) }
}

public protocol ScpRunning: Sendable {
    func checkAvailability() async throws
    func connectionKey(host: String) async throws -> String
    func run(_ request: ScpRequest) async -> RunResult
}

public extension ScpRunning {
    func checkAvailability() async throws {}
    func connectionKey(host: String) async throws -> String { host.lowercased() }
}

public struct ScpService: ScpRunning {
    public init() {}
    public func checkAvailability() async throws {
        let result = await SSHProcess.run("/usr/bin/ssh", ["-V"])
        try Task.checkCancellation()
        let version = result.stderr + result.stdout
        guard result.succeeded,
              let range = version.range(of: #"OpenSSH_[0-9]+"#, options: .regularExpression),
              let major = Int(version[range].dropFirst("OpenSSH_".count)), major >= 9,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/scp") else {
            throw RemoteTransferError("リモート間コピーにはOpenSSH 9以降のscpが必要です。旧SCP方式への自動切替は行いません。")
        }
    }
    public func connectionKey(host: String) async throws -> String {
        try SFTPCommand.validateHost(host)
        let result = await SSHProcess.run("/usr/bin/ssh", ["-G", "--", host])
        try Task.checkCancellation()
        guard result.succeeded else { throw RemoteTransferError("SSH接続設定を確認できません: \(host)") }
        var values: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard let hostname = values["hostname"], let port = values["port"], let user = values["user"] else {
            throw RemoteTransferError("SSH接続設定を確認できません: \(host)")
        }
        return [hostname.lowercased(), port, user, values["proxyjump"] ?? "none", values["proxycommand"] ?? "none"].joined(separator: "\n")
    }
    public func run(_ request: ScpRequest) async -> RunResult {
        await SSHProcess.run("/usr/bin/scp", request.arguments)
    }
}

/// Fixed executables and argument arrays; process-group cancellation also stops
/// scp's two SSH children. Both output pipes are drained concurrently.
enum SSHProcess {
    static func commandLine(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
    static func run(_ executable: String, _ arguments: [String]) async -> RunResult {
        let logLimit = ResourceLimits.standard.logBytes
        let cancellation = RunCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let started = Date()
                    let input = Pipe(), output = Pipe(), error = Pipe()
                    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
                    let envp = SFTPService.processEnvironment(ProcessInfo.processInfo.environment)
                        .map { strdup("\($0.key)=\($0.value)") } + [nil]
                    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
                    let pid = argv.withUnsafeBufferPointer { args in
                        envp.withUnsafeBufferPointer { env in
                            opensftp_spawn_pipes(executable, input.fileHandleForReading.fileDescriptor,
                                output.fileHandleForWriting.fileDescriptor, error.fileHandleForWriting.fileDescriptor,
                                args.baseAddress!, env.baseAddress!)
                        }
                    }
                    guard pid > 0 else {
                        continuation.resume(returning: RunResult(started: started, ended: Date(), stdout: "",
                            stderr: "プロセスを起動できません: \(executable)", exitCode: -1, failure: .launch))
                        return
                    }
                    cancellation.install { _ = kill(-pid, SIGKILL) }
                    try? input.fileHandleForReading.close()
                    try? input.fileHandleForWriting.close()
                    try? output.fileHandleForWriting.close()
                    try? error.fileHandleForWriting.close()
                    let readers = DispatchGroup()
                    let stdout = ProcessOutput(), stderr = ProcessOutput()
                    for (handle, box) in [(output.fileHandleForReading, stdout), (error.fileHandleForReading, stderr)] {
                        readers.enter()
                        DispatchQueue.global(qos: .utility).async {
                            box.data = Data(BoundedOutput.read(handle, limit: logLimit).text.utf8)
                            try? handle.close()
                            readers.leave()
                        }
                    }
                    readers.wait()
                    cancellation.finish()
                    let code = Int32(sftp_wait(pid))
                    let out = String(decoding: stdout.data, as: UTF8.self)
                    let err = String(decoding: stderr.data, as: UTF8.self)
                    continuation.resume(returning: RunResult(started: started, ended: Date(), stdout: out,
                        stderr: err, exitCode: code, failure: code == 0 ? nil : RunResult.classify(code: code, stdout: out, stderr: err) ?? .operation))
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}

private final class ProcessOutput: @unchecked Sendable { var data = Data() }

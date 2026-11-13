import Foundation
import SFTPPTY
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// OpenSSH's interactive client has no readlink command, and ls longnames need
/// not contain link targets. Read the actual target using SFTP v3 READLINK.
enum SFTPLinkService {
    static func linkIconTargets(host: String, paths: [String]) async -> [String: LinkIconTarget] {
        guard !paths.isEmpty else { return [:] }
        let cancellation = RunCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<[String: LinkIconTarget], Never>) in
                DispatchQueue.global(qos: .utility).async {
                    let result = execute(host: host, path: paths[0], cancellation: cancellation, operation: { input, output in
                        let targets = try inspectLinkIconTargets(paths: paths, input: input, output: output)
                        return String(decoding: try JSONEncoder().encode(targets), as: UTF8.self)
                    })
                    let targets = result.succeeded
                        ? (try? JSONDecoder().decode([String: LinkIconTarget].self, from: Data(result.stdout.utf8))) ?? [:]
                        : [:]
                    continuation.resume(returning: targets)
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    static func directoryLinks(host: String, paths: [String]) async -> [String: Bool] {
        guard !paths.isEmpty else { return [:] }
        let cancellation = RunCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<[String: Bool], Never>) in
                DispatchQueue.global(qos: .utility).async {
                    let result = execute(host: host, path: paths[0], cancellation: cancellation, operation: { input, output in
                        let kinds = try inspectDirectoryLinks(paths: paths, input: input, output: output)
                        return String(decoding: try JSONEncoder().encode(kinds), as: UTF8.self)
                    })
                    var kinds: [String: Bool] = [:]
                    if result.succeeded {
                        kinds = (try? JSONDecoder().decode([String: Bool].self, from: Data(result.stdout.utf8))) ?? [:]
                    }
                    continuation.resume(returning: kinds)
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    static func readLink(host: String, path: String) async -> RunResult {
        let cancellation = RunCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: execute(host: host, path: path, cancellation: cancellation))
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    static func execute(host: String, path: String, cancellation: RunCancellation,
                                operation: ((FileHandle, FileHandle) throws -> String)? = nil) -> RunResult {
        let started = Date()
        do { try SFTPCommand.validateHost(host); try SFTPCommand.validatePath(path) }
        catch {
            return RunResult(started: started, ended: Date(), stdout: "", stderr: error.localizedDescription,
                             exitCode: -1, failure: .operation)
        }
        let input = Pipe(), output = Pipe(), error = Pipe()
        #if canImport(Darwin)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        let arguments = ["/usr/bin/ssh", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oNumberOfPasswordPrompts=0",
                         "-oConnectTimeout=15", "-oServerAliveInterval=15", "-oServerAliveCountMax=3", "-s", "--", host, "sftp"]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = SFTPService.processEnvironment(ProcessInfo.processInfo.environment)
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let pid = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                opensftp_spawn_pipes("/usr/bin/ssh", input.fileHandleForReading.fileDescriptor,
                    output.fileHandleForWriting.fileDescriptor, error.fileHandleForWriting.fileDescriptor,
                    args.baseAddress!, env.baseAddress!)
            }
        }
        guard pid > 0 else {
            return RunResult(started: started, ended: Date(), stdout: "", stderr: "SFTP操作用のSSHを起動できません。",
                             exitCode: -1, failure: .launch)
        }
        cancellation.install { _ = kill(-pid, SIGKILL) }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        let readers = DispatchGroup()
        let logLimit = ResourceLimits.standard.logBytes
        let diagnostic = LinkDiagnostic()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            diagnostic.data = Data(BoundedOutput.read(error.fileHandleForReading, limit: logLimit).text.utf8)
            try? error.fileHandleForReading.close()
            readers.leave()
        }
        var target = "", problem: String?
        do {
            if let operation { target = try operation(input.fileHandleForWriting, output.fileHandleForReading) }
            else { target = try exchange(path: path, input: input.fileHandleForWriting, output: output.fileHandleForReading) }
        } catch {
            problem = error.localizedDescription
            // A malformed/non-SFTP peer must not leave the job waiting for EOF.
            _ = kill(-pid, SIGKILL)
        }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        readers.wait()
        cancellation.finish()
        let code = Int32(sftp_wait(pid))
        let stderr = String(decoding: diagnostic.data, as: UTF8.self)
        let failure = RunResult.classify(code: code, stdout: "", stderr: stderr)
        return RunResult(started: started, ended: Date(), stdout: target,
                         stderr: stderr + (problem.map { "\n" + $0 } ?? ""), exitCode: code,
                         failure: failure ?? (problem == nil ? nil : .operation))
    }

    static func exchange(path: String, input: FileHandle, output: FileHandle) throws -> String {
        try SFTPCommand.validatePath(path)
        try negotiate(input: input, output: output)
        try input.write(contentsOf: readLinkRequest(path))
        return try decodeTarget(readPacket(output))
    }

    private static func negotiate(input: FileHandle, output: FileHandle) throws {
        try input.write(contentsOf: packet(Data([1]) + uint32(3)))
        var version = LinkPacket(try readPacket(output))
        guard try version.byte() == 2, try version.integer() == 3 else { throw LinkError.invalidResponse }
    }

    /// STAT follows a link but does not open or enumerate its target directory.
    /// Missing/inaccessible targets stay unknown rather than failing the listing.
    static func inspectDirectoryLinks(paths: [String], input: FileHandle, output: FileHandle) throws -> [String: Bool] {
        for path in paths { try SFTPCommand.validatePath(path) }
        try negotiate(input: input, output: output)
        var kinds: [String: Bool] = [:]
        for (index, path) in paths.enumerated() {
            let id = UInt32(index + 1)
            let bytes = Data(path.utf8)
            try input.write(contentsOf: packet(Data([17]) + uint32(id) + uint32(UInt32(bytes.count)) + bytes))
            if let directory = try decodeDirectoryAttribute(readPacket(output), id: id) { kinds[path] = directory }
        }
        return kinds
    }

    static func inspectLinkIconTargets(paths: [String], input: FileHandle, output: FileHandle) throws -> [String: LinkIconTarget] {
        for path in paths { try SFTPCommand.validatePath(path) }
        try negotiate(input: input, output: output)
        var targets: [String: LinkIconTarget] = [:]
        for path in paths {
            let bytes = Data(path.utf8)
            let argument = uint32(UInt32(bytes.count)) + bytes
            try input.write(contentsOf: packet(Data([17]) + uint32(1) + argument))
            guard let kind = try decodeTargetKind(readPacket(output), id: 1) else { continue }
            if kind == 0o040000 {
                targets[path] = LinkIconTarget(isDirectory: true)
            } else if kind == 0o100000 {
                // REALPATH follows link chains, including relative targets. Use
                // the target's extension even when the link has another name.
                try input.write(contentsOf: packet(Data([16]) + uint32(1) + argument))
                let data = try readPacket(output)
                if data.first == 101 { continue }
                let target = try decodeTarget(data)
                guard target.hasPrefix("/") else { continue }
                targets[path] = LinkIconTarget(isDirectory: false, path: target)
            }
        }
        return targets
    }

    static func decodeDirectoryAttribute(_ data: Data, id: UInt32) throws -> Bool? {
        guard let kind = try decodeTargetKind(data, id: id) else { return nil }
        return kind == 0o040000
    }

    private static func decodeTargetKind(_ data: Data, id: UInt32) throws -> UInt32? {
        var response = LinkPacket(data)
        let type = try response.byte()
        guard try response.integer() == id else { throw LinkError.invalidResponse }
        if type == 101 { return nil }
        guard type == 105 else { throw LinkError.invalidResponse }
        let flags = try response.integer()
        if flags & 1 != 0 { _ = try response.integer(); _ = try response.integer() }
        if flags & 2 != 0 { _ = try response.integer(); _ = try response.integer() }
        guard flags & 4 != 0 else { return nil }
        let permissions = try response.integer()
        let kind = permissions & 0o170000
        return kind == 0 ? nil : kind
    }

    static func readLinkRequest(_ path: String) -> Data {
        let bytes = Data(path.utf8)
        return packet(Data([19]) + uint32(1) + uint32(UInt32(bytes.count)) + bytes)
    }

    static func decodeTarget(_ data: Data) throws -> String {
        var response = LinkPacket(data)
        let type = try response.byte()
        guard try response.integer() == 1 else { throw LinkError.invalidResponse }
        if type == 101 {
            let code = try response.integer()
            throw LinkError.status(code, try response.string())
        }
        guard type == 104, try response.integer() == 1 else { throw LinkError.invalidResponse }
        let target = try response.string()
        try SFTPCommand.validatePath(target)
        return target
    }

    static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    static func packet(_ payload: Data) -> Data { uint32(UInt32(payload.count)) + payload }

    private static func readPacket(_ handle: FileHandle) throws -> Data {
        func exact(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                    throw LinkError.invalidResponse
                }
                result.append(chunk)
            }
            return result
        }
        var header = LinkPacket(try exact(4))
        let count = try header.integer()
        guard count > 0, count <= 1_048_576 else { throw LinkError.invalidResponse }
        return try exact(Int(count))
    }
}

private struct LinkPacket {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }
    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw LinkError.invalidResponse }
        defer { offset += 1 }
        return data[offset]
    }
    mutating func integer() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(try byte()) }
        return value
    }
    mutating func string() throws -> String {
        let count = Int(try integer())
        guard count <= data.count - offset,
              let value = String(data: data.subdata(in: offset..<(offset + count)), encoding: .utf8) else {
            throw LinkError.invalidResponse
        }
        offset += count
        return value
    }
}

private enum LinkError: LocalizedError {
    case invalidResponse, status(UInt32, String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "SFTPのリンク先応答を解析できません。"
        case let .status(code, message): return "リンク先を取得できません（SFTP \(code)）: \(message)"
        }
    }
}
private final class LinkDiagnostic: @unchecked Sendable { var data = Data() }

import Foundation

public struct RemoteEndpoint: Hashable, Codable, Sendable {
    public let host: String
    public let path: String
    public init(host: String, path: String) { self.host = host; self.path = path }
    public var description: String { "\(host):\(path)" }
    public var name: String { (path as NSString).lastPathComponent }
    public var parent: Self { Self(host: host, path: (path as NSString).deletingLastPathComponent) }
    public func child(_ name: String) -> Self { Self(host: host, path: SFTPCommand.join(path, name)) }
    public func validate() throws {
        try SFTPCommand.validateHost(host)
        try SFTPCommand.validatePath(path)
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw InputError.invalidPath
        }
    }
}

public struct RemoteAttributes: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, directory, symbolicLink, other }
    public let size: UInt64?
    public let permissions: UInt32?
    public let accessed: UInt32?
    public let modified: UInt32?
    public var kind: Kind {
        switch (permissions ?? 0) & 0o170000 {
        case 0o100000: return .file
        case 0o040000: return .directory
        case 0o120000: return .symbolicLink
        default: return .other
        }
    }
    public init(size: UInt64? = nil, permissions: UInt32? = nil, accessed: UInt32? = nil, modified: UInt32? = nil) {
        self.size = size; self.permissions = permissions; self.accessed = accessed; self.modified = modified
    }
}

public struct RemoteNode: Codable, Sendable {
    public let name: String
    public let attributes: RemoteAttributes
    public init(name: String, attributes: RemoteAttributes) { self.name = name; self.attributes = attributes }
}

/// Exact SFTP names and timestamps, independent of ls's display formatting.
public protocol RemoteFileSystem: Sendable {
    func attributes(_ endpoint: RemoteEndpoint, followLink: Bool) async throws -> RemoteAttributes?
    func list(_ directory: RemoteEndpoint) async throws -> [RemoteNode]
    func realPath(_ endpoint: RemoteEndpoint) async throws -> String
    func readLink(_ endpoint: RemoteEndpoint) async throws -> String
    func createDirectory(_ endpoint: RemoteEndpoint) async throws
    func createFile(_ endpoint: RemoteEndpoint) async throws
    func setAttributes(_ endpoint: RemoteEndpoint, attributes: RemoteAttributes) async throws
    func createLink(_ endpoint: RemoteEndpoint, target: String) async throws
    func rename(_ temporary: RemoteEndpoint, to destination: RemoteEndpoint, overwrite: Bool) async throws
    func remove(_ endpoint: RemoteEndpoint) async throws
}

enum RemoteOperation: Sendable {
    case attributes(String, Bool), list(String), realPath(String), readLink(String)
    case mkdir(String), create(String), setAttributes(String, RemoteAttributes), symlink(String, String)
    case rename(String, String, Bool), remove(String)
    var path: String {
        switch self {
        case let .attributes(p, _), let .list(p), let .realPath(p), let .readLink(p), let .mkdir(p),
             let .create(p), let .setAttributes(p, _), let .symlink(p, _), let .rename(p, _, _), let .remove(p): return p
        }
    }
}

struct RemoteReply: Codable {
    var attributes: RemoteAttributes?
    var nodes: [RemoteNode]?
    var path: String?
}

public struct SFTPRemoteFileSystem: RemoteFileSystem {
    private let log: @Sendable (String, RunResult) async -> Void
    public init(log: @escaping @Sendable (String, RunResult) async -> Void = { _, _ in }) { self.log = log }
    private func request(_ host: String, _ operation: RemoteOperation) async throws -> RemoteReply {
        try Task.checkCancellation()
        let result = await SFTPLinkService.remoteRequest(host: host, operation: operation)
        let display = "sftp \(host) \(String(describing: operation))\n"
        await log(host, RunResult(started: result.started, ended: result.ended, stdout: display,
                                 stderr: result.stderr, exitCode: result.exitCode, failure: result.failure))
        try Task.checkCancellation()
        guard result.succeeded else { throw RemoteTransferError(result.stderr.isEmpty ? "SFTP操作に失敗しました: \(host)" : result.stderr) }
        return try JSONDecoder().decode(RemoteReply.self, from: Data(result.stdout.utf8))
    }
    public func attributes(_ e: RemoteEndpoint, followLink: Bool = false) async throws -> RemoteAttributes? {
        try await request(e.host, .attributes(e.path, followLink)).attributes
    }
    public func list(_ e: RemoteEndpoint) async throws -> [RemoteNode] { try await request(e.host, .list(e.path)).nodes ?? [] }
    public func realPath(_ e: RemoteEndpoint) async throws -> String {
        guard let path = try await request(e.host, .realPath(e.path)).path else { throw InputError.invalidPath }
        try RemoteEndpoint(host: e.host, path: path).validate()
        return path
    }
    public func readLink(_ e: RemoteEndpoint) async throws -> String {
        guard let path = try await request(e.host, .readLink(e.path)).path else { throw InputError.invalidPath }
        try SFTPCommand.validatePath(path)
        return path
    }
    public func createDirectory(_ e: RemoteEndpoint) async throws { _ = try await request(e.host, .mkdir(e.path)) }
    public func createFile(_ e: RemoteEndpoint) async throws { _ = try await request(e.host, .create(e.path)) }
    public func setAttributes(_ e: RemoteEndpoint, attributes: RemoteAttributes) async throws {
        _ = try await request(e.host, .setAttributes(e.path, attributes))
    }
    public func createLink(_ e: RemoteEndpoint, target: String) async throws { _ = try await request(e.host, .symlink(e.path, target)) }
    public func rename(_ e: RemoteEndpoint, to destination: RemoteEndpoint, overwrite: Bool) async throws {
        guard e.host == destination.host else { throw InputError.invalidHost }
        _ = try await request(e.host, .rename(e.path, destination.path, overwrite))
    }
    public func remove(_ e: RemoteEndpoint) async throws { _ = try await request(e.host, .remove(e.path)) }
}

public struct RemoteTransferError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension SFTPLinkService {
    static func remoteRequest(host: String, operation: RemoteOperation) async -> RunResult {
        let cancellation = RunCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: execute(host: host, path: operation.path, cancellation: cancellation) { input, output in
                        let wire = RemoteWire(input: input, output: output)
                        let reply = try wire.perform(operation)
                        return String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
                    })
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}

/// A bounded SFTP v3 exchange. No filenames or attributes are parsed from ls.
final class RemoteWire {
    let input: FileHandle, output: FileHandle
    let limits: ResourceLimits
    private var listingBytesRemaining: Int?
    var id: UInt32 = 0
    var extensions: Set<String> = []
    init(input: FileHandle, output: FileHandle, limits: ResourceLimits = .standard) {
        self.input = input; self.output = output; self.limits = limits.validated
    }
    func perform(_ operation: RemoteOperation) throws -> RemoteReply {
        try input.write(contentsOf: frame(Data([1]) + u32(3)))
        var version = RemotePacket(try read())
        guard try version.byte() == 2, try version.uint32() == 3 else { throw malformed() }
        while !version.finished { extensions.insert(try version.string()); _ = try version.string() }
        switch operation {
        case let .attributes(path, follow):
            var response = try exchange(follow ? 17 : 7, string(path))
            if response.type == 101 {
                let code = try response.uint32()
                if code == 2 { return RemoteReply() }
                throw RemoteTransferError("SFTP \(code): \(try response.string())")
            }
            guard response.type == 105 else { throw malformed() }
            return RemoteReply(attributes: try response.attributes())
        case let .realPath(path), let .readLink(path):
            let type: UInt8
            if case .realPath = operation { type = 16 } else { type = 19 }
            var response = try exchange(type, string(path))
            try require(&response, type: 104)
            guard try response.uint32() == 1 else { throw malformed() }
            return RemoteReply(path: try response.string())
        case let .list(path):
            listingBytesRemaining = limits.listingBytes
            var opened = try exchange(11, string(path))
            try require(&opened, type: 102)
            let handle = try opened.bytes()
            var nodes: [RemoteNode] = [], names = Set<String>()
            while true {
                var response = try exchange(12, bytes(handle))
                if response.type == 101 {
                    let code = try response.uint32()
                    if code == 1 { break }
                    throw RemoteTransferError("SFTP \(code): \(try response.string())")
                }
                try require(&response, type: 104)
                let count = try response.uint32()
                guard count > 0, count <= 100_000 else { throw malformed() }
                for _ in 0..<count {
                    let name = try response.string()
                    _ = try response.string() // server longname is presentation only
                    let attributes = try response.attributes()
                    if name == "." || name == ".." { continue }
                    try SFTPCommand.validateName(name)
                    guard names.insert(name).inserted else { throw malformed() }
                    guard nodes.count < limits.listingEntries else { throw ResourceLimitError.listing }
                    nodes.append(RemoteNode(name: name, attributes: attributes))
                }
            }
            try status(4, bytes(handle))
            return RemoteReply(nodes: nodes)
        case let .mkdir(path): try status(14, string(path) + u32(4) + u32(0o700))
        case let .create(path):
            // SSH_FXF_WRITE | SSH_FXF_CREAT | SSH_FXF_EXCL, never follow an existing link.
            var response = try exchange(3, string(path) + u32(0x2 | 0x8 | 0x20) + u32(4) + u32(0o600))
            try require(&response, type: 102)
            try status(4, bytes(try response.bytes()))
        case let .setAttributes(path, attrs):
            var flags: UInt32 = 0, data = Data()
            if let mode = attrs.permissions { flags |= 4; data += u32(mode & 0o777) }
            if let modified = attrs.modified { flags |= 8; data += u32(attrs.accessed ?? modified) + u32(modified) }
            try status(9, string(path) + u32(flags) + data)
        case let .symlink(path, target):
            try SFTPCommand.validatePath(target)
            // OpenSSH's SFTP v3 symlink order is target, linkpath.
            try status(20, string(target) + string(path))
        case let .rename(old, new, overwrite):
            if overwrite {
                guard extensions.contains("posix-rename@openssh.com") else {
                    throw RemoteTransferError("サーバーは既存項目の原子的な置換に対応していません。")
                }
                try status(200, string("posix-rename@openssh.com") + string(old) + string(new))
            } else { try status(18, string(old) + string(new)) }
        case let .remove(path): try status(13, string(path))
        }
        return RemoteReply()
    }
    private func exchange(_ type: UInt8, _ data: Data) throws -> RemotePacket {
        id += 1
        try input.write(contentsOf: frame(Data([type]) + u32(id) + data))
        var response = RemotePacket(try read())
        response.type = try response.byte()
        guard try response.uint32() == id else { throw malformed() }
        return response
    }
    private func status(_ type: UInt8, _ data: Data) throws {
        var response = try exchange(type, data)
        guard response.type == 101 else { throw malformed() }
        let code = try response.uint32()
        guard code == 0 else { throw RemoteTransferError("SFTP \(code): \(try response.string())") }
    }
    private func require(_ response: inout RemotePacket, type: UInt8) throws {
        if response.type == 101 { throw RemoteTransferError("SFTP \(try response.uint32()): \(try response.string())") }
        guard response.type == type else { throw malformed() }
    }
    private func read() throws -> Data {
        func exact(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let part = try output.read(upToCount: count - data.count), !part.isEmpty else { throw malformed() }
                data += part
            }
            return data
        }
        var header = RemotePacket(try exact(4))
        let count = try header.uint32()
        guard count > 0, count <= 1_048_576 else { throw malformed() }
        if let remaining = listingBytesRemaining {
            guard Int(count) + 4 <= remaining else { throw ResourceLimitError.listing }
            listingBytesRemaining = remaining - Int(count) - 4
        }
        return try exact(Int(count))
    }
    private func u32(_ n: UInt32) -> Data { SFTPLinkService.uint32(n) }
    private func string(_ s: String) -> Data { bytes(Data(s.utf8)) }
    private func bytes(_ d: Data) -> Data { u32(UInt32(d.count)) + d }
    private func frame(_ d: Data) -> Data { bytes(d) }
    private func malformed() -> RemoteTransferError { RemoteTransferError("SFTP応答を解析できません。") }
}

private struct RemotePacket {
    let data: Data
    var offset = 0
    var type: UInt8 = 0
    init(_ data: Data) { self.data = data }
    var finished: Bool { offset == data.count }
    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw RemoteTransferError("SFTP応答が途切れました。") }
        defer { offset += 1 }
        return data[offset]
    }
    mutating func uint32() throws -> UInt32 {
        var n: UInt32 = 0
        for _ in 0..<4 { n = n << 8 | UInt32(try byte()) }
        return n
    }
    mutating func uint64() throws -> UInt64 { UInt64(try uint32()) << 32 | UInt64(try uint32()) }
    mutating func bytes() throws -> Data {
        let count = Int(try uint32())
        guard count <= data.count - offset else { throw RemoteTransferError("SFTP応答の長さが不正です。") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func string() throws -> String {
        guard let value = String(data: try bytes(), encoding: .utf8) else { throw RemoteTransferError("SFTPの名前がUTF-8ではありません。") }
        return value
    }
    mutating func attributes() throws -> RemoteAttributes {
        let flags = try uint32()
        var size: UInt64?, mode: UInt32?, accessed: UInt32?, modified: UInt32?
        if flags & 1 != 0 { size = try uint64() }
        if flags & 2 != 0 { _ = try uint32(); _ = try uint32() }
        if flags & 4 != 0 { mode = try uint32() }
        if flags & 8 != 0 { accessed = try uint32(); modified = try uint32() }
        if flags & 0x80000000 != 0 {
            let count = try uint32()
            guard count <= 100_000 else { throw RemoteTransferError("SFTP属性が多すぎます。") }
            for _ in 0..<count { _ = try bytes(); _ = try bytes() }
        }
        guard flags & ~UInt32(0x8000000f) == 0 else { throw RemoteTransferError("未対応のSFTP属性です。") }
        return RemoteAttributes(size: size, permissions: mode, accessed: accessed, modified: modified)
    }
}

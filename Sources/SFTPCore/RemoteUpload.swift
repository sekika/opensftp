import Foundation

/// Guards SFTP uploads with canonical parent paths and staged publication.
@MainActor
public final class RemoteUpload {
    private let fs: any RemoteFileSystem
    private let root: RemoteEndpoint
    private let diagnostic: (String) -> Void

    private init(fileSystem: any RemoteFileSystem, root: RemoteEndpoint, diagnostic: @escaping (String) -> Void) {
        fs = fileSystem; self.root = root; self.diagnostic = diagnostic
    }

    public static func prepare(directory: RemoteEndpoint, fileSystem: any RemoteFileSystem,
                               diagnostic: @escaping (String) -> Void = { _ in }) async throws -> RemoteUpload {
        try directory.validate()
        // Resolve the user-selected directory once (including intentional SSH
        // home/path aliases). All subsequent writes use this canonical spelling.
        let root = RemoteEndpoint(host: directory.host, path: try await fileSystem.realPath(directory))
        try root.validate()
        let upload = RemoteUpload(fileSystem: fileSystem, root: root, diagnostic: diagnostic)
        try await upload.checkParents(of: root.child(".opensftp-parent-check"))
        return upload
    }

    public func destination(named name: String) throws -> RemoteEndpoint {
        try SFTPCommand.validateName(name)
        return root.child(name)
    }

    public func checkParents(of destination: RemoteEndpoint) async throws {
        try Task.checkCancellation()
        try destination.validate()
        let parent = destination.parent
        guard destination.host == root.host,
              parent.path == root.path || root.path == "/" || parent.path.hasPrefix(root.path + "/") else {
            throw changed(destination)
        }
        // Checking only the leaf in a directory listing follows a substituted
        // parent symlink. LSTAT every ancestor and compare REALPATH as well,
        // including ancestors above the selected directory.
        var ancestors: [RemoteEndpoint] = [], current = parent
        while true {
            ancestors.append(current)
            if current.path == "/" { break }
            current = current.parent
        }
        for directory in ancestors.reversed() {
            try Task.checkCancellation()
            guard try await fs.attributes(directory, followLink: false)?.kind == .directory,
                  try await fs.realPath(directory) == directory.path else { throw changed(directory) }
        }
        // These are separate SFTP requests, not a filesystem transaction. A
        // hostile writer can still race the next operation. Server permissions
        // must prevent other users from replacing destination ancestors for a
        // strict guarantee; rechecks detect substitutions already visible here.
    }

    public func upload(to destination: RemoteEndpoint, allowOverwrite: Bool = true,
                       preserveSourceAttributes: Bool = false, newFilePermissions: UInt32? = nil,
                       write: (RemoteEndpoint) async throws -> Void) async throws {
        try await checkParents(of: destination)
        let expected = try await fs.attributes(destination, followLink: false)
        guard expected == nil || (allowOverwrite && expected?.kind == .file) else { throw changed(destination) }
        let temporary = destination.parent.child(".opensftp-\(UUID().uuidString).partial")
        var created = false
        do {
            // SFTP CREATE|EXCL reserves a private (0600) temporary file and
            // fails on a collision, including a pre-existing symbolic link.
            try await fs.createFile(temporary)
            created = true
            try await checkParents(of: destination)
            guard try await fs.attributes(temporary, followLink: false)?.kind == .file else { throw changed(temporary) }
            // The CLI reopens this pathname, so the reservation is not a held
            // file handle across put. Directory permissions are also required
            // to prevent races against the temporary entry itself.
            try await write(temporary)
            try await checkParents(of: destination)
            guard try await fs.attributes(temporary, followLink: false)?.kind == .file,
                  try await fs.attributes(destination, followLink: false) == expected else { throw changed(destination) }
            if !preserveSourceAttributes, let permissions = expected?.permissions ?? newFilePermissions {
                // Ordinary put used to retain an existing destination's mode.
                // New files use the local source mode. Keep the temporary
                // private until transfer has completed successfully.
                try await fs.setAttributes(temporary, attributes: RemoteAttributes(permissions: permissions & 0o777))
                try await checkParents(of: destination)
            }
            guard try await fs.attributes(destination, followLink: false) == expected else { throw changed(destination) }
            // Never truncate the final pathname with put: rename replaces its
            // directory entry without following a newly substituted leaf link.
            // Fail closed if the server cannot atomically replace an existing
            // file; do not emulate replacement by deleting the original first.
            try await fs.rename(temporary, to: destination, overwrite: expected != nil)
        } catch {
            if created {
                // Cancellation must not skip cleanup. Revalidate parents first
                // so cleanup itself does not knowingly traverse a changed link.
                do {
                    try await Task { @MainActor in
                        try await self.checkParents(of: temporary)
                        if try await self.fs.attributes(temporary, followLink: false)?.kind == .file {
                            try await self.fs.remove(temporary)
                        }
                    }.value
                } catch {
                    diagnostic("一時項目が残っている可能性があります: \(temporary.description)\n\(error.localizedDescription)\n")
                }
            }
            throw error
        }
    }

    private func changed(_ endpoint: RemoteEndpoint) -> RemoteTransferError {
        RemoteTransferError("転送計画後に項目が変更されました: \(endpoint.description)")
    }
}

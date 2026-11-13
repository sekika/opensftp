import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Run command syntax in /bin/sh on both machines. The user's local/remote login
/// shells only parse a portable bootstrap argument, never the script's syntax.
public struct TerminalLessCommand: Sendable {
    public let remoteCommand: String
    public let arguments: [String]
    let localScript: String

    public init(host: String, path: String) throws {
        try RemoteEndpoint(host: host, path: path).validate()
        let p = Self.quote(path)
        let script = """
        test -f \(p) && test ! -L \(p) && test -r \(p) || { printf '%s\\n' 'OpenSFTP: select a readable regular text file.' >&2; exit 1; }
        mime=$(file -b --mime -- \(p)) || exit 1
        case "$mime" in
          text/*) ;;
          *charset=*) charset=${mime##*charset=}; case "$charset" in binary|'') printf '%s\\n' 'OpenSFTP: this file is not text.' >&2; exit 1;; esac ;;
          *) printf '%s\\n' 'OpenSFTP: this file is not text.' >&2; exit 1 ;;
        esac
        command -v less >/dev/null 2>&1 || { printf '%s\\n' 'OpenSFTP: less is not installed.' >&2; exit 127; }
        exec less -- \(p)
        """
        remoteCommand = "exec /bin/sh -c " + Self.quote(script)
        // Keep normal interactive SSH authentication in Terminal, while retaining
        // the app's strict host-key verification. -t supplies less with a PTY.
        arguments = ["-t", "-oStrictHostKeyChecking=yes", "--", host, remoteCommand]
        localScript = "exec " + (["/usr/bin/ssh"] + arguments).map(Self.quote).joined(separator: " ")
    }

    static func quote(_ value: String) -> String {
        // fish interprets \\ inside single quotes, while POSIX sh preserves it.
        // Emit backslashes (and apostrophes) as escaped, unquoted segments so
        // both shells hand exactly the same script string to /bin/sh -c.
        // Use scalars: an apostrophe followed by a combining mark still needs
        // escaping even though Swift may treat them as one Character.
        var result = "'"
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x27: result += "'\\''"
            case 0x5c: result += "'\\\\'"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "'"
    }

    // The command is passed as argv to a fixed AppleScript, never interpolated
    // into AppleScript source. No target tab/window means a new Terminal window;
    // do not inject commands into a user's existing interactive session.
    public static let appleScript = """
    on run argv
        tell application id "com.apple.Terminal"
            launch
            do script (item 1 of argv)
            activate
        end tell
    end run
    """

    // Run independently of the app, after SSH succeeds. Match the original TTY
    // so changing focus never closes another session. Explicitly discard the
    // finished session rather than asking to save it.
    static let closeAppleScript = """
    on run argv
        tell application id "com.apple.Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is (item 1 of argv) then
                        close terminalTab saving no
                        return
                    end if
                end repeat
            end repeat
        end tell
    end run
    """
}

/// Terminal receives only a short, single-line bootstrap. Sending the complete
/// nested SSH script through do script can exceed terminal input limits or be
/// changed by interactive input handling, even when shell quoting is correct.
struct TerminalLessLauncher {
    let directory: URL
    let file: URL
    let commandLine: String

    init(script: String) throws {
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSFTP-less-XXXXXX").path.utf8CString)
        guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) != nil }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        directory = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        file = directory.appendingPathComponent("open.sh")
        // Exit the interactive login shell too; exiting open.sh alone leaves
        // fish/zsh waiting at its prompt. Keep errors visible in that shell.
        commandLine = "/bin/sh " + TerminalLessCommand.quote(file.path) + " && exit"
        // mkdtemp creates a private (0700) directory. Only command text is
        // stored here; no remote file content is downloaded. Parse the entire
        // block before unlinking the script, then retain Terminal's stdin for
        // SSH authentication and less. The session outlives the app.
        let body = "#!/bin/sh\n{\n/bin/rm -f -- " + TerminalLessCommand.quote(file.path)
            + "\n/bin/rmdir -- " + TerminalLessCommand.quote(directory.path)
            + "\nterminal_tty=$(/usr/bin/tty)\n(\n" + script + "\n)\n"
            + "result=$?\nif [ \"$result\" -eq 0 ] && [ -n \"$terminal_tty\" ]; then\n"
            + "/usr/bin/osascript -e " + TerminalLessCommand.quote(TerminalLessCommand.closeAppleScript)
            + " \"$terminal_tty\" </dev/null >/dev/null 2>&1 &\nfi\nexit \"$result\"\n}\n"
        guard FileManager.default.createFile(atPath: file.path, contents: Data(body.utf8),
                                            attributes: [.posixPermissions: 0o600]) else {
            try? FileManager.default.removeItem(at: directory)
            throw PreviewError("Terminalを開けませんでした: could not create launch script")
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

public struct TerminalLessService: Sendable {
    public init() {}
    public func open(host: String, path: String) async throws {
        let request = try TerminalLessCommand(host: host, path: path)
        let launcher = try TerminalLessLauncher(script: request.localScript)
        let result = await SSHProcess.run("/usr/bin/osascript", ["-e", TerminalLessCommand.appleScript, launcher.commandLine])
        guard result.succeeded else {
            launcher.remove()
            try Task.checkCancellation()
            if result.stderr.contains("-1743") {
                throw PreviewError("Terminalの操作が許可されていません。システム設定の「プライバシーとセキュリティ → オートメーション」でOpenSFTPからTerminalへの操作を許可してください。")
            }
            throw PreviewError("Terminalを開けませんでした: " + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Successful do script can return before the shell starts the helper.
        // Let the helper remove itself; removing it here races with Terminal.
        try Task.checkCancellation()
        // This only confirms window creation. SSH/less errors are shown in
        // Terminal, and that independent session survives closing the app.
    }
}

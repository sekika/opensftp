import Foundation
import SFTPPTY
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Separate from transfer logging: binary output never becomes a RunResult or log.
enum PreviewProcess {
    static func run(_ executable: String, _ arguments: [String], limit: Int, timeout: Int = 30) async throws -> Data {
        let cancellation = RunCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
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
                        continuation.resume(throwing: PreviewError("SSHコマンドが利用できないためプレビューできません"))
                        return
                    }
                    cancellation.install { _ = kill(-pid, SIGKILL) }
                    let timeoutState = PreviewTimeoutState()
                    let deadline = DispatchWorkItem { timeoutState.expire(); cancellation.cancel() }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(max(1, timeout)), execute: deadline)
                    defer { deadline.cancel() }
                    try? input.fileHandleForReading.close()
                    try? input.fileHandleForWriting.close()
                    try? output.fileHandleForWriting.close()
                    try? error.fileHandleForWriting.close()
                    let readers = DispatchGroup()
                    let stdout = PreviewOutput(), stderr = PreviewOutput()
                    for (handle, box) in [(output.fileHandleForReading, stdout), (error.fileHandleForReading, stderr)] {
                        readers.enter()
                        DispatchQueue.global(qos: .utility).async {
                            let maximum = box === stdout ? limit : 16_384
                            while true {
                                let chunk = handle.readData(ofLength: 8192)
                                if chunk.isEmpty { break }
                                let remaining = maximum - box.data.count
                                box.data.append(chunk.prefix(max(0, remaining)))
                                if chunk.count > remaining {
                                    box.exceeded = true
                                    _ = kill(-pid, SIGKILL)
                                    break
                                }
                            }
                            try? handle.close()
                            readers.leave()
                        }
                    }
                    readers.wait()
                    cancellation.finish()
                    let code = Int32(sftp_wait(pid))
                    if timeoutState.expired {
                        continuation.resume(throwing: PreviewError("プレビューの処理時間が上限を超えたため表示を中止しました。"))
                    } else if stdout.exceeded || stderr.exceeded {
                        continuation.resume(throwing: PreviewError("取得サイズが上限を超えたため表示できません"))
                    } else if code != 0 || String(decoding: stderr.data, as: UTF8.self).contains("OPEN_SFTP_PREVIEW_COMMAND_FAILED:") {
                        let diagnostic = String(decoding: stderr.data, as: UTF8.self)
                        let output = String(decoding: stdout.data, as: UTF8.self)
                        var details: [String] = []
                        if !diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            details.append("標準エラー:\n" + diagnostic.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            details.append("標準出力:\n" + output.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        if details.isEmpty { details.append("終了コード: \(code)") }
                        continuation.resume(throwing: PreviewError("SSHコマンドが利用できないか、必要なツールがないためプレビューできません。\n" + details.joined(separator: "\n")))
                    } else {
                        continuation.resume(returning: stdout.data)
                    }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}

private final class PreviewOutput: @unchecked Sendable { var data = Data(); var exceeded = false }

private final class PreviewTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func expire() { lock.lock(); value = true; lock.unlock() }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

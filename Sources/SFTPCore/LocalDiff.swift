import Foundation

/// Runs diff locally without passing file names through a shell.
public enum LocalDiff {
    public static func commandLine(original: URL, saved: URL) -> String {
        (["/usr/bin/diff", "-u", original.path, saved.path]).map {
            "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    public static func run(original: URL, saved: URL, limits: ResourceLimits = .standard) async -> RunResult {
        let limits = limits.validated
        let cancellation = RunCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let started = Date()
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
                    process.arguments = ["-u", original.path, saved.path]
                    process.standardInput = FileHandle.nullDevice
                    let output = Pipe(), diagnostic = Pipe()
                    process.standardOutput = output
                    process.standardError = diagnostic
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: RunResult(started: started, ended: Date(), stdout: "",
                            stderr: error.localizedDescription, exitCode: -1, failure: .launch))
                        return
                    }
                    cancellation.install { if process.isRunning { process.terminate() } }
                    defer { cancellation.finish() }
                    // Drain both pipes concurrently, including diffs larger than a pipe buffer.
                    let readers = DispatchGroup()
                    let stdout = DiffOutput(), stderr = DiffOutput()
                    for (pipe, box) in [(output, stdout), (diagnostic, stderr)] {
                        readers.enter()
                        DispatchQueue.global(qos: .utility).async {
                            let captured = BoundedOutput.read(pipe.fileHandleForReading, limit: limits.diffBytes,
                                onExceeded: { cancellation.cancel() })
                            box.data = captured.data
                            box.exceeded = captured.exceeded
                            try? pipe.fileHandleForReading.close()
                            readers.leave()
                        }
                    }
                    process.waitUntilExit()
                    readers.wait()
                    let code = process.terminationStatus
                    let exceeded = stdout.exceeded || stderr.exceeded
                    continuation.resume(returning: RunResult(started: started, ended: Date(),
                        stdout: String(decoding: stdout.data, as: UTF8.self),
                        stderr: String(decoding: stderr.data, as: UTF8.self)
                            + (exceeded ? "\n差分が取得上限を超えたため比較を中止しました。\n" : ""), exitCode: code,
                        failure: exceeded ? .operation : code == 0 || code == 1 ? nil : .operation))
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}

private final class DiffOutput: @unchecked Sendable { var data = Data(); var exceeded = false }

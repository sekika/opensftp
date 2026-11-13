import Foundation

public struct TransferProgress: Sendable, Equatable {
    public let fraction: Double
    public let transferred: String
    public let speed: String
    public let remaining: String

    public static func parse(_ line: String) -> TransferProgress? {
        // Match the suffix, since filenames may contain spaces and percent signs.
        let pattern = #"\s(\d{1,3})%\s+(\d+(?:\.\d+)?[KMGT]?B?)\s+(\d+(?:\.\d+)?[KMGT]?B/s)\s+(?:\d+:\d{2}(?::\d{2})?\s+ETA|-\s+stalled\s+-|--:--\s+ETA|\d+:\d{2}(?::\d{2})?)\s*$"#
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        let fields = line[match].split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 4, let percent = Double(fields[0].dropLast()), percent <= 100 else { return nil }
        // A partial ETA frame must not be mistaken for a final elapsed time.
        guard percent == 100 || fields.last == "ETA" || fields.last == "-" else { return nil }
        let eta: String
        if fields[3] == "-" { eta = "—（停滞中）" }
        else if fields[3] == "--:--" { eta = "計算中" }
        else if fields.last == "ETA" { eta = "約" + fields[3] }
        else { eta = "—" } // Final meter contains elapsed time, not ETA.
        return TransferProgress(fraction: percent / 100, transferred: fields[1], speed: fields[2], remaining: eta)
    }
}

/// Incremental byte framing preserves UTF-8 across reads and handles CR redraws.
public struct ProgressOutputDecoder {
    private var pending = Data()
    private let pendingLimit: Int
    private var discardingLine = false
    public init(pendingLimit: Int = ResourceLimits.standard.logBytes) { self.pendingLimit = max(1, pendingLimit) }

    public mutating func consume(_ data: Data, finish: Bool = false,
                                 progress: (TransferProgress) -> Void) -> String {
        var data = data
        if discardingLine {
            if let end = data.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                data = Data(data[data.index(after: end)...])
                discardingLine = false
            } else { data = Data() }
        }
        pending.append(data)
        var diagnostics = ""
        while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            if let value = TransferProgress.parse(line) { progress(value) }
            else if !line.isEmpty { diagnostics += line + "\n" }
        }
        if finish, !pending.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
            if let value = TransferProgress.parse(line) { progress(value) }
            else { diagnostics += line }
            pending.removeAll()
        } else if let value = TransferProgress.parse(String(decoding: pending, as: UTF8.self)) {
            // A redraw starts with CR but has no trailing delimiter until the next tick.
            progress(value)
            pending.removeAll()
        }
        if pending.count > pendingLimit {
            diagnostics += String(decoding: pending.prefix(pendingLimit), as: UTF8.self) + BoundedLog.marker
            pending.removeAll()
            discardingLine = true
        }
        return diagnostics
    }
}

import Foundation

public struct RemoteEntry: Identifiable, Hashable {
    public enum Kind: String { case file = "ファイル", directory = "フォルダ", symbolicLink = "シンボリックリンク", other = "その他" }
    public let name: String
    public let kind: Kind
    public let size: Int64
    public let modified: String
    public let modifiedDate: Date?
    public let permissions: String
    public let owner: String
    public var id: String { name }
    public var isHidden: Bool { name.hasPrefix(".") }
    public var isDirectory: Bool { kind == .directory }
    public var isRegularFile: Bool { kind == .file }
}

public struct DirectoryListing {
    public let path: String?
    public let entries: [RemoteEntry]
    public let unparsed: [String]
    public let limitExceeded: Bool

    public static func parseChecked(_ output: String, now: Date = Date(), limits: ResourceLimits = .standard) throws -> DirectoryListing {
        let listing = parse(output, now: now, limits: limits)
        guard !listing.limitExceeded else { throw ResourceLimitError.listing }
        return listing
    }

    public static func parse(_ output: String, now: Date = Date(), limits: ResourceLimits = .standard) -> DirectoryListing {
        let limits = limits.validated
        let failure = DirectoryListing(path: nil, entries: [], unparsed: [ResourceLimitError.listing.localizedDescription], limitExceeded: true)
        guard output.utf8.count <= limits.listingBytes else { return failure }
        // SFTP listings may use "?" when the hard-link count is unavailable.
        let pattern = #"^([bcdlps-][rwxstST-]{9}[+@.]?)\s+(?:\d+|\?)\s+(\S+)\s+\S+\s+(\d+)\s+([A-Za-z]{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4})) ([\s\S]+)$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var path: String?
        var entries: [RemoteEntry] = []
        var unparsed: [String] = []
        var names = Set<String>()
        var rows = 0
        // SFTP output is captured from pipes, so LF alone frames list rows.
        // Preserve CR and other control characters because they can be part of
        // a literal filename (for example macOS's custom-icon file "Icon\r").
        for line in LFLineSequence(output) {
            if line.hasPrefix("Remote working directory: ") {
                let candidate = String(line.dropFirst("Remote working directory: ".count))
                if candidate.hasPrefix("/"), (try? SFTPCommand.validatePath(candidate)) != nil { path = candidate }
                else { unparsed.append(line) }
                continue
            }
            if line.isEmpty || line.hasPrefix("sftp> ") || line.hasPrefix("Connected to ") || line.hasPrefix("total ") { continue }
            rows += 1
            // Include malformed rows in the budget and allow '.' and '..'.
            // Streaming avoids allocating an array for millions of blank lines.
            if rows > limits.listingEntries + 2 { return failure }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { unparsed.append(line); continue }
            func group(_ index: Int) -> String { String(line[Range(match.range(at: index), in: line)!]) }
            let permissions = group(1)
            let kind: RemoteEntry.Kind
            switch permissions.first {
            case "d": kind = .directory
            case "-": kind = .file
            case "l": kind = .symbolicLink
            default: kind = .other
            }
            // The textual arrow in symlink listings is ambiguous; do not offer destructive operations on links.
            let name = kind == .symbolicLink ? String(group(5).components(separatedBy: " -> ")[0]) : group(5)
            if name == "." || name == ".." { continue }
            let containsUnrepresentableSeparator = name.contains("\n") || name.unicodeScalars.contains { $0.value == 0 }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !containsUnrepresentableSeparator,
                  names.insert(name).inserted, let size = Int64(group(3)) else { unparsed.append(line); continue }
            let stamp = group(4).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            entries.append(RemoteEntry(name: name, kind: kind, size: size, modified: stamp,
                                       modifiedDate: parseDate(stamp, now: now), permissions: permissions, owner: group(2)))
            // Discard the entire result on overflow; partial metadata must not
            // be mistaken for a complete transfer/deletion/conflict plan.
            if entries.count > limits.listingEntries { return failure }
        }
        return DirectoryListing(path: path, entries: entries, unparsed: unparsed, limitExceeded: false)
    }

    private static func parseDate(_ stamp: String, now: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = stamp.contains(":") ? "MMM d HH:mm yyyy" : "MMM d yyyy"
        let year = Calendar.current.component(.year, from: now)
        guard var date = formatter.date(from: stamp.contains(":") ? "\(stamp) \(year)" : stamp) else { return nil }
        if stamp.contains(":"), date.timeIntervalSince(now) > 86400 {
            date = Calendar.current.date(byAdding: .year, value: -1, to: date) ?? date
        }
        return date
    }
}

/// LF alone frames OpenSSH listings. Unlike byLines, this preserves literal CR
/// in names, and unlike components(separatedBy:), it allocates one row at a time.
struct LFLineSequence: Sequence {
    let text: String
    init(_ text: String) { self.text = text }
    func makeIterator() -> Iterator { Iterator(bytes: text.utf8, cursor: text.utf8.startIndex) }
    struct Iterator: IteratorProtocol {
        let bytes: String.UTF8View
        var cursor: String.UTF8View.Index
        mutating func next() -> String? {
            guard cursor < bytes.endIndex else { return nil }
            let end = bytes[cursor...].firstIndex(of: 10) ?? bytes.endIndex
            let line = String(decoding: bytes[cursor..<end], as: UTF8.self)
            cursor = end == bytes.endIndex ? end : bytes.index(after: end)
            return line
        }
    }
}

import Foundation

/// User-visible resource budgets. Protocol packet-size checks remain fixed:
/// increasing a UI limit must not weaken validation of individual SFTP packets.
public struct ResourceLimits: Equatable, Sendable {
    public var listingEntries = 100_000
    public var listingMiB = 64
    public var traversalEntries = 1_000_000
    public var traversalDepth = 128
    public var logMiB = 4
    public var diffMiB = 8
    public var previewTextMiB = 1
    public var previewTimeoutSeconds = 30

    public init() {}
    public static let `default` = ResourceLimits()
    public static var standard: Self { Self(defaults: .standard) }

    public var validated: Self {
        var value = self
        value.listingEntries = min(1_000_000, max(1, listingEntries))
        value.listingMiB = min(256, max(1, listingMiB))
        value.traversalEntries = min(5_000_000, max(1, traversalEntries))
        value.traversalDepth = min(256, max(1, traversalDepth))
        value.logMiB = min(64, max(1, logMiB))
        value.diffMiB = min(64, max(1, diffMiB))
        value.previewTextMiB = min(50, max(1, previewTextMiB))
        value.previewTimeoutSeconds = min(300, max(1, previewTimeoutSeconds))
        return value
    }
    public var listingBytes: Int { validated.listingMiB * 1_048_576 }
    public var logBytes: Int { validated.logMiB * 1_048_576 }
    public var diffBytes: Int { validated.diffMiB * 1_048_576 }
    public var previewTextBytes: Int { validated.previewTextMiB * 1_048_576 }

    public init(defaults: UserDefaults) {
        self.init()
        listingEntries = defaults.object(forKey: "limitListingEntries") as? Int ?? listingEntries
        listingMiB = defaults.object(forKey: "limitListingMiB") as? Int ?? listingMiB
        traversalEntries = defaults.object(forKey: "limitTraversalEntries") as? Int ?? traversalEntries
        traversalDepth = defaults.object(forKey: "limitTraversalDepth") as? Int ?? traversalDepth
        logMiB = defaults.object(forKey: "limitLogMiB") as? Int ?? logMiB
        diffMiB = defaults.object(forKey: "limitDiffMiB") as? Int ?? diffMiB
        previewTextMiB = defaults.object(forKey: "limitPreviewTextMiB") as? Int ?? previewTextMiB
        previewTimeoutSeconds = defaults.object(forKey: "limitPreviewTimeoutSeconds") as? Int ?? previewTimeoutSeconds
        self = validated
    }
    public func save(to defaults: UserDefaults) {
        let value = validated
        defaults.set(value.listingEntries, forKey: "limitListingEntries")
        defaults.set(value.listingMiB, forKey: "limitListingMiB")
        defaults.set(value.traversalEntries, forKey: "limitTraversalEntries")
        defaults.set(value.traversalDepth, forKey: "limitTraversalDepth")
        defaults.set(value.logMiB, forKey: "limitLogMiB")
        defaults.set(value.diffMiB, forKey: "limitDiffMiB")
        defaults.set(value.previewTextMiB, forKey: "limitPreviewTextMiB")
        defaults.set(value.previewTimeoutSeconds, forKey: "limitPreviewTimeoutSeconds")
    }
}

public enum ResourceLimitError: LocalizedError {
    case listing, traversal, depth
    public var errorDescription: String? {
        switch self {
        case .listing: return "一覧が上限を超えたため取得を中止しました。"
        case .traversal: return "フォルダ処理の総項目数が上限を超えたため中止しました。"
        case .depth: return "フォルダ階層が上限を超えたため中止しました。"
        }
    }
}

struct TraversalBudget {
    let limits: ResourceLimits
    private(set) var count = 0
    init(_ limits: ResourceLimits = .standard) { self.limits = limits.validated }
    mutating func consume(_ amount: Int) throws {
        guard amount >= 0, amount <= limits.traversalEntries - count else { throw ResourceLimitError.traversal }
        count += amount
    }
    func checkDepth(_ depth: Int) throws {
        guard depth < limits.traversalDepth else { throw ResourceLimitError.depth }
    }
}

/// Prefix retention bounds memory while continuing to drain child-process pipes.
/// Listings must fail on overflow; a truncated listing must never become a plan.
struct BoundedOutput {
    let limit: Int
    private(set) var data = Data()
    private(set) var exceeded = false
    init(limit: Int) { self.limit = max(0, limit) }
    mutating func append(_ chunk: Data) -> Data {
        let retained = Data(chunk.prefix(max(0, limit - data.count)))
        data.append(retained)
        if retained.count < chunk.count { exceeded = true }
        return retained
    }
    var text: String { String(decoding: data, as: UTF8.self) + (exceeded ? BoundedLog.marker : "") }
    static func read(_ handle: FileHandle, limit: Int, onExceeded: () -> Void = {}) -> Self {
        var result = Self(limit: limit)
        while true {
            let chunk = handle.readData(ofLength: 8192)
            if chunk.isEmpty { break }
            let wasExceeded = result.exceeded
            _ = result.append(chunk)
            if result.exceeded && !wasExceeded { onExceeded() }
        }
        return result
    }
}

public enum BoundedLog {
    public static let marker = "\n[上限を超えたため以降の出力を省略]\n"
    public static func clip(_ text: String, limit: Int = ResourceLimits.standard.logBytes) -> String {
        // Appending to an already clipped log must not multiply omission marks.
        if let end = text.range(of: marker) {
            let clipped = clip(String(text[..<end.lowerBound]), limit: limit)
            return clipped.hasSuffix(marker) ? clipped : clipped + marker
        }
        guard text.utf8.count > limit else { return text }
        return String(decoding: text.utf8.prefix(max(0, limit)), as: UTF8.self) + marker
    }
}

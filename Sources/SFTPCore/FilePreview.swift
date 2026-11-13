import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct PreviewError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct PreviewPreferences: Equatable, Sendable {
    public var lines: Int
    public var binaryMiB: Int
    public init(lines: Int = 50, binaryMiB: Int = 5) {
        self.lines = min(1000, max(1, lines))
        self.binaryMiB = min(50, max(1, binaryMiB))
    }
    public init(defaults: UserDefaults) {
        self.init(lines: defaults.object(forKey: "previewLines") as? Int ?? 50,
                  binaryMiB: defaults.object(forKey: "previewBinaryMiB") as? Int ?? 5)
    }
    public var validated: Self { Self(lines: lines, binaryMiB: binaryMiB) }
    public func save(to defaults: UserDefaults) {
        defaults.set(validated.lines, forKey: "previewLines")
        defaults.set(validated.binaryMiB, forKey: "previewBinaryMiB")
    }
}

public enum PreviewKind: String, Sendable {
    case text, image, archive, pdf, word, media, hex
    public static func detect(_ mime: String, charset: String) -> Self {
        if mime.hasPrefix("text/") || (!charset.isEmpty && charset != "binary") { return .text }
        if mime.hasPrefix("image/") { return .image }
        if mime == "application/pdf" { return .pdf }
        if mime == "application/vnd.openxmlformats-officedocument.wordprocessingml.document" { return .word }
        if ["application/zip", "application/x-zip", "application/x-tar", "application/gzip", "application/x-gzip", "application/x-bzip2", "application/x-xz"].contains(mime) { return .archive }
        if mime.hasPrefix("audio/") || mime.hasPrefix("video/") { return .media }
        return .hex
    }
}

public struct PreviewDocument: Sendable {
    public var kind: PreviewKind
    public var mime: String
    public var charset: String
    public var text = ""
    /// Display-ready, validated single-frame PNG; never original image bytes.
    public var image: Data?
    public var firstLine = 1
    public var lineCount = 0
    public var hasNext = false
    public var note = ""
}

public enum PreviewPage: Sendable { case first, previous, next, last }

public enum PDFPreviewTab: String, Sendable {
    case text, firstPage
}

public protocol PreviewRunning: Sendable {
    func read(host: String, command: String, limit: Int) async throws -> Data
    func read(host: String, command: String, limit: Int, timeout: Int) async throws -> Data
}

public extension PreviewRunning {
    func read(host: String, command: String, limit: Int, timeout: Int) async throws -> Data {
        try await read(host: host, command: command, limit: limit)
    }
}

public struct SSHPreviewRunner: PreviewRunning {
    public init() {}
    public func read(host: String, command: String, limit: Int) async throws -> Data {
        try await read(host: host, command: command, limit: limit, timeout: ResourceLimits.standard.previewTimeoutSeconds)
    }
    public func read(host: String, command: String, limit: Int, timeout: Int) async throws -> Data {
        try SFTPCommand.validateHost(host)
        // ssh sends a remote command through the account's configured shell.
        // Wrap the script as one quoted argument so fish/zsh do not parse its
        // POSIX operators, assignments, braces, or path quoting themselves.
        let scriptArgument = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let remoteCommand = "exec /bin/sh -c " + scriptArgument
        do {
            let result = try await PreviewProcess.run("/usr/bin/ssh", ["-T", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
                "-oNumberOfPasswordPrompts=0", "-oConnectTimeout=15", "-oServerAliveInterval=15",
                "-oServerAliveCountMax=3", "--", host, remoteCommand], limit: limit, timeout: timeout)
            try Task.checkCancellation()
            return result
        } catch let error as PreviewError where error.message.hasPrefix("SSHコマンドが利用できないか、必要なツールがないためプレビューできません。") {
            throw PreviewError(error.message + "\n\n実行コマンド:\n" + remoteCommand)
        }
    }
}

/// Every request uses stdout only. Neither side creates a preview file.
public struct FilePreviewService: Sendable {
    private let runner: any PreviewRunning
    public init(runner: any PreviewRunning = SSHPreviewRunner()) { self.runner = runner }
    public static func quote(_ path: String) throws -> String {
        try SFTPCommand.validatePath(path)
        guard path.hasPrefix("/") else { throw InputError.invalidPath }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public func load(host: String, path: String, preferences: PreviewPreferences,
                     current: PreviewDocument? = nil, page: PreviewPage = .first,
                     limits: ResourceLimits = .standard, pdfTab: PDFPreviewTab = .text,
                     onKindDetected: (@Sendable (PreviewKind) async -> Void)? = nil) async throws -> PreviewDocument {
        try SFTPCommand.validateHost(host)
        let p = try Self.quote(path), settings = preferences.validated
        let limits = limits.validated
        // Report upstream failures even on shells without pipefail. SIGPIPE
        // after head has received its page is an expected early termination.
        func firstLines(_ command: String) -> String {
            "{ " + command + "; s=$?; if [ \"$s\" -ne 0 ] && [ \"$s\" -ne 141 ]; then printf 'OPEN_SFTP_PREVIEW_COMMAND_FAILED:%s\\n' \"$s\" >&2; fi; } | head -n \(settings.lines)"
        }
        func read(_ command: String, _ limit: Int? = nil) async throws -> Data {
            // Refuse symlinks and special files again at read time.
            try await runner.read(host: host, command: "test -f \(p) && test ! -L \(p) && test -r \(p) || exit 1; " + command,
                                  limit: limit ?? limits.previewTextBytes, timeout: limits.previewTimeoutSeconds)
        }
        let description = try await read("file -b --mime -- \(p)", 4096)
        let parts = String(decoding: description, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ";")
        let mime = parts[0].lowercased()
        guard mime.contains("/"), parts.count > 1, let encoding = parts.dropFirst().first(where: { $0.contains("charset=") }) else {
            throw PreviewError("SSHコマンドが利用できないためプレビューできません（fileの応答を確認できません）")
        }
        let charset = encoding.components(separatedBy: "charset=").last!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var doc = PreviewDocument(kind: .detect(mime, charset: charset), mime: mime, charset: charset)
        if doc.kind == .text {
            let sample = try await read("head -c 256 \(p)", 256)
            if sample.contains(0) {
                doc.kind = .hex
                doc.note = "NULを検出したためHexDumpで表示します"
            }
        }
        // Publish the detected kind before running format-specific tools so a
        // failed PDF tab never hides the other tab (e.g. missing pdftoppm).
        await onKindDetected?(doc.kind)
        try Task.checkCancellation()
        switch doc.kind {
        case .text:
            var start = 1
            if let current, current.kind == .text {
                switch page {
                case .first: break
                case .previous: start = max(1, current.firstLine - settings.lines)
                case .next: start = current.firstLine + current.lineCount
                case .last:
                    let countData = try await read("awk 'END { print NR }' \(p)", 128)
                    guard let count = Int(String(decoding: countData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), count >= 0, count < Int.max - 2000 else { throw PreviewError("行数を取得できません") }
                    start = max(1, count - settings.lines + 1)
                }
            }
            // Keep one extra line for paging and one extra byte to detect overflow.
            // Bound both remote output and local buffering before decoding text.
            let textLimit = limits.previewTextBytes
            let data = try await read("command -v head >/dev/null && command -v tail >/dev/null || exit 127; head -n \(start + settings.lines) \(p) | tail -n +\(start) | head -c \(textLimit + 1)", textLimit + 1)
            guard data.count <= textLimit else {
                throw PreviewError("テキストが1ページの取得上限（\(limits.previewTextMiB) MiB）を超えています。ダウンロードして確認してください。")
            }
            if data.contains(0) { doc.kind = .hex; doc.note = "NULを検出したためHexDumpで表示します" }
            else {
                let value = try Self.decode(data, charset: charset)
                var lines = value.components(separatedBy: "\n")
                if value.hasSuffix("\n") || value.isEmpty { lines.removeLast() }
                doc.firstLine = start; doc.hasNext = lines.count > settings.lines
                doc.lineCount = min(settings.lines, lines.count)
                doc.text = lines.prefix(settings.lines).joined(separator: "\n")
            }
        case .image:
            let maximum = settings.binaryMiB * 1_048_576
            // Stat avoids transferring a known oversized original. GNU/BSD stat
            // have different format flags; both return only a decimal byte count.
            let sizeData = try await read("if n=$(stat -c %s -- \(p) 2>/dev/null); then printf '%s\\n' \"$n\"; else stat -f %z \(p); fi", 128)
            guard let size = UInt64(String(decoding: sizeData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw PreviewError("画像のファイルサイズを確認できません。")
            }
            guard size <= UInt64(maximum) else {
                throw PreviewError("画像が取得上限を超えています。ダウンロードして確認してください。")
            }
            // A small prefix often exposes dimensions (PNG/JPEG/GIF, etc.).
            // Reject oversized dimensions before fetching the rest when possible.
            let header = try await read("head -c \(ImagePreview.headerBytes) \(p)", ImagePreview.headerBytes)
            try ImagePreview.validateHeader(header)
            let original: Data
            if header.count < ImagePreview.headerBytes { original = header }
            else { original = try await read("head -c \(maximum + 1) \(p)", maximum + 1) }
            // Recheck after receipt: the file may have changed since stat or
            // prefix inspection. No unchecked original reaches the UI decoder.
            guard original.count <= maximum else {
                throw PreviewError("画像が取得上限を超えています。ダウンロードして確認してください。")
            }
            doc.image = try await ImagePreview.thumbnail(original)
        case .pdf:
            switch pdfTab {
            case .text:
                doc.text = try Self.decode(await read("pdftotext -f 1 -l 3 \(p) -"), charset: "utf-8")
                doc.note = "PDFの先頭3ページから抽出したテキスト"
            case .firstPage:
                // Omit the output prefix: Poppler writes PNG to stdout without
                // either machine creating a preview file. Render only page 1
                // with bounded dimensions before transferring or decoding it.
                let command = "command -v pdftoppm >/dev/null 2>&1 || { printf '%s\\n' 'OpenSFTP: pdftoppm is required for PDF image preview.' >&2; exit 127; }; pdftoppm -f 1 -l 1 -singlefile -scale-to 2048 -png \(p)"
                let data = try await read(command, settings.binaryMiB * 1_048_576)
                doc.image = try await ImagePreview.thumbnail(data)
                doc.note = "PDFの1ページ目"
            }
        case .word:
            // Extract XML in memory; do not hide unzip failures behind a pipeline.
            let xml = try await read("unzip -p \(p) word/document.xml")
            let extractor = WordPreviewText()
            let parser = XMLParser(data: xml); parser.delegate = extractor
            parser.shouldResolveExternalEntities = false
            guard parser.parse() else { throw PreviewError("Word文書の本文を解析できません") }
            doc.text = extractor.value.components(separatedBy: "\n").prefix(settings.lines).joined(separator: "\n")
            doc.note = "※装飾・表・画像を除く簡易テキストプレビュー"
            if let properties = try? await read("unzip -p \(p) docProps/core.xml") {
                let metadata = WordPreviewProperties()
                let parser = XMLParser(data: properties); parser.delegate = metadata
                parser.shouldResolveExternalEntities = false
                if parser.parse(), !metadata.value.isEmpty { doc.note += "\n" + metadata.value.joined(separator: " · ") }
            }
        case .archive:
            let command: String
            if mime.contains("zip") && !mime.contains("gzip") && !mime.contains("bzip") { command = "unzip -l \(p)" }
            else { command = "tar -tvf \(p)" }
            do { doc.text = String(decoding: try await read(firstLines(command)), as: UTF8.self).components(separatedBy: "\n").prefix(settings.lines).joined(separator: "\n") }
            catch {
                if mime == "application/gzip" || mime == "application/x-gzip" {
                    // Gzip can contain a plain text log rather than a tar archive.
                    let data = try await read(firstLines("gzip -cd \(p)"))
                    if data.contains(0) { throw PreviewError("gzipの内容はテキストではありません") }
                    doc.text = try Self.decode(data, charset: "utf-8").components(separatedBy: "\n").prefix(settings.lines).joined(separator: "\n")
                    doc.note = "gzipのテキスト内容"
                } else { throw error }
            }
        case .media:
            let data = try await read("ffprobe -v error -print_format json -show_format -show_streams \(p)")
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { throw PreviewError("メディア情報を解析できません") }
            doc.text = String(decoding: pretty, as: UTF8.self)
            if mime.hasPrefix("video/") {
                do {
                    let streams = (object as? [String: Any])?["streams"] as? [[String: Any]]
                    guard let video = streams?.first(where: { $0["codec_type"] as? String == "video" }),
                          let width = video["width"] as? NSNumber, let height = video["height"] as? NSNumber,
                          width.doubleValue.isFinite, height.doubleValue.isFinite,
                          width.doubleValue > 0, height.doubleValue > 0,
                          width.doubleValue <= Double(ImagePreview.maximumDimension), height.doubleValue <= Double(ImagePreview.maximumDimension),
                          Double(width.intValue) == width.doubleValue, Double(height.intValue) == height.doubleValue else {
                        throw PreviewError("動画のフレーム寸法を確認できないか、上限を超えています。")
                    }
                    try ImagePreview.validateDimensions(width: width.intValue, height: height.intValue)
                    // Match the probed first video stream and shrink on the
                    // server too, before receiving the encoded frame bytes.
                    let frame = try await read("ffmpeg -v error -ss 00:00:01 -i \(p) -map 0:v:0 -frames:v 1 -vf \"scale='min(2048,iw)':'min(2048,ih)':force_original_aspect_ratio=decrease\" -f image2pipe -vcodec png -", settings.binaryMiB * 1_048_576)
                    doc.image = try await ImagePreview.thumbnail(frame)
                }
                catch is CancellationError { throw CancellationError() }
                catch { doc.note = "代表フレームを取得できません: " + error.localizedDescription }
            }
        case .hex: break
        }
        if doc.kind == .hex {
            let data = try await read("head -c 256 \(p)", 256)
            doc.text = Self.hex(data)
        }
        try Task.checkCancellation()
        return doc
    }
    public static func decode(_ data: Data, charset: String) throws -> String {
        let encoding: String.Encoding
        switch charset {
        case "utf-8", "utf8", "us-ascii", "ascii": encoding = .utf8
        case "iso-8859-1": encoding = .isoLatin1
        case "utf-16le": encoding = .utf16LittleEndian
        case "utf-16be": encoding = .utf16BigEndian
        case "shift_jis", "shift-jis", "sjis", "unknown-8bit": encoding = .shiftJIS
        default: throw PreviewError("対応していない文字コードです: " + charset)
        }
        guard let value = String(data: data, encoding: encoding) else { throw PreviewError("文字コードを判別できません: " + charset) }
        return value
    }
    public static func hex(_ data: Data) -> String {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(row.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%08x  ", offset) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  |" + ascii + "|"
        }.joined(separator: "\n")
    }
}

private final class WordPreviewText: NSObject, XMLParserDelegate {
    var value = ""
    private var inText = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "w:t" { inText = true }
        if name == "w:tab" { value += "\t" }
        if name == "w:br" { value += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { value += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "w:t" { inText = false }
        if name == "w:p" { value += "\n" }
    }
}

private final class WordPreviewProperties: NSObject, XMLParserDelegate {
    var value: [String] = []
    private var element: String?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if ["dc:title", "dc:creator", "dcterms:created", "dcterms:modified"].contains(name) { element = name; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if element != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if element == name { value.append(name + ": " + text); element = nil }
    }
}

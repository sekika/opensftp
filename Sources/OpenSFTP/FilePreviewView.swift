import AppKit
import SwiftUI
import SFTPCore

@MainActor
final class FilePreviewModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var path = ""
    @Published private(set) var document: PreviewDocument?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var isPDF = false
    @Published private(set) var pdfTab: PDFPreviewTab
    @Published private(set) var size: CGSize
    private var host = ""
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let service: FilePreviewService
    private let defaults: UserDefaults
    private var pdfDocuments: [PDFPreviewTab: PreviewDocument] = [:]

    init(service: FilePreviewService = FilePreviewService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.pdfTab = defaults.string(forKey: "previewPDFTab").flatMap(PDFPreviewTab.init(rawValue:)) ?? .text
        let width = defaults.double(forKey: "previewWindowWidth")
        let height = defaults.double(forKey: "previewWindowHeight")
        self.size = CGSize(width: width >= 420 && width <= 1400 ? width : 680,
                           height: height >= 320 && height <= 1100 ? height : 510)
    }
    func resize(to proposed: CGSize) {
        size = CGSize(width: min(1400, max(420, proposed.width)), height: min(1100, max(320, proposed.height)))
        defaults.set(Double(size.width), forKey: "previewWindowWidth")
        defaults.set(Double(size.height), forKey: "previewWindowHeight")
    }
    func show(host: String, path: String) {
        guard !isPresented || self.host != host || self.path != path else { return }
        self.host = host; self.path = path; isPresented = true
        // Read the latest choice when opening another file, including choices
        // saved by a preview belonging to a different browser window.
        pdfTab = defaults.string(forKey: "previewPDFTab").flatMap(PDFPreviewTab.init(rawValue:)) ?? .text
        document = nil; isPDF = false; pdfDocuments.removeAll()
        fetch(.first)
    }
    func selectPDFTab(_ tab: PDFPreviewTab) {
        guard isPDF, tab != pdfTab else { return }
        pdfTab = tab
        defaults.set(tab.rawValue, forKey: "previewPDFTab")
        fetch(.first)
    }
    private func detected(_ kind: PreviewKind, token: UUID) {
        guard generation == token, isPresented else { return }
        isPDF = kind == .pdf
    }
    func fetch(_ page: PreviewPage) {
        task?.cancel()
        let token = UUID(); generation = token
        let pdfTab = pdfTab
        if isPDF, let cached = pdfDocuments[pdfTab] {
            document = cached; error = nil; loading = false; task = nil
            return
        }
        let host = host, path = path, current = document
        let settings = AppPreferences.shared.preview.validated
        let limits = AppPreferences.shared.limits.validated
        document = nil; error = nil; loading = true
        task = Task { [weak self, service] in
            do {
                let result = try await service.load(host: host, path: path, preferences: settings, current: current, page: page, limits: limits,
                                                    pdfTab: pdfTab, onKindDetected: { [weak self] kind in
                    await self?.detected(kind, token: token)
                })
                guard let self, !Task.isCancelled, self.generation == token, self.isPresented else { return }
                if result.kind == .pdf { self.pdfDocuments[pdfTab] = result }
                self.document = result; self.loading = false; self.task = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == token, self.isPresented else { return }
                self.error = error.localizedDescription; self.loading = false; self.task = nil
            }
        }
    }
    func clearSelection() {
        task?.cancel(); task = nil; generation = UUID()
        path = ""; document = nil; loading = false
        isPDF = false; pdfDocuments.removeAll()
        error = "通常ファイルを一つ選択してください"
    }
    func showError(path: String, message: String) {
        task?.cancel(); task = nil; generation = UUID()
        self.path = path; document = nil; error = message; loading = false; isPresented = true
        isPDF = false; pdfDocuments.removeAll()
    }
    func close() {
        task?.cancel(); task = nil; generation = UUID()
        isPresented = false; document = nil; error = nil; path = ""; host = ""; loading = false
        isPDF = false; pdfDocuments.removeAll()
    }
}

/// A movable, resizable utility window stays open while browser selection changes.
@MainActor
struct PreviewPresenter: NSViewRepresentable {
    @ObservedObject var preview: FilePreviewModel
    let language: AppLanguage
    func makeCoordinator() -> Coordinator { Coordinator(preview) }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        if preview.isPresented, let parentWindow = view.window {
            if let panel = coordinator.panel {
                if let hosting = panel.contentViewController as? NSHostingController<FilePreviewView> {
                    hosting.rootView = FilePreviewView(model: preview, language: language)
                }
                if panel.contentRect(forFrameRect: panel.frame).size != preview.size {
                    panel.setContentSize(preview.size)
                }
                if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
            } else {
                let panel = NSPanel(contentRect: NSRect(origin: .zero, size: preview.size),
                                    styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                    backing: .buffered, defer: false)
                panel.title = AppStrings.translate("プレビュー", to: language)
                panel.isReleasedWhenClosed = false
                panel.contentViewController = NSHostingController(rootView: FilePreviewView(model: preview, language: language))
                panel.setFrameAutosaveName("OpenSFTP.PreviewWindow")
                panel.delegate = coordinator
                coordinator.panel = panel
                if !panel.setFrameUsingName("OpenSFTP.PreviewWindow") {
                    let parentFrame = parentWindow.frame
                    panel.setFrameTopLeftPoint(NSPoint(x: parentFrame.minX + 48, y: parentFrame.maxY - 48))
                }
                panel.makeKeyAndOrderFront(nil)
            }
        } else if !preview.isPresented {
            coordinator.closePanel()
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.preview.close()
        coordinator.closePanel()
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let preview: FilePreviewModel
        var panel: NSPanel?
        init(_ preview: FilePreviewModel) { self.preview = preview }
        func closePanel() {
            guard let panel else { return }
            self.panel = nil
            panel.delegate = nil
            panel.close()
            panel.contentViewController = nil
        }
        func windowWillClose(_ notification: Notification) {
            guard let closingPanel = notification.object as? NSPanel, closingPanel === panel else { return }
            closingPanel.saveFrame(usingName: "OpenSFTP.PreviewWindow")
            panel = nil
            closingPanel.delegate = nil
            closingPanel.contentViewController = nil
            preview.close()
        }
    }
}

@MainActor
private struct FilePreviewView: View {
    @ObservedObject var model: FilePreviewModel
    let language: AppLanguage
    @State private var showLineNumbers = true
    private func tr(_ text: String) -> String { AppStrings.translate(text, to: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tr("プレビュー"), systemImage: "eye").font(.headline)
                Text((model.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(tr("閉じる")) { model.close() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if model.isPDF {
                Picker(tr("PDFの表示"), selection: Binding(get: { model.pdfTab }, set: { model.selectPDFTab($0) })) {
                    Text(tr("テキスト")).tag(PDFPreviewTab.text)
                    Text(tr("1ページ目")).tag(PDFPreviewTab.firstPage)
                }
                .pickerStyle(.segmented)
            }
            if model.loading {
                Spacer(); HStack { Spacer(); ProgressView(); Spacer() }; Spacer()
            } else if let error = model.error {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if error.hasPrefix("SSHコマンドが利用できない") || error.hasPrefix("Preview is unavailable") {
                            Text(tr("SSHコマンドが利用できないか、必要なツールがないためプレビューできません。"))
                                .fontWeight(.semibold)
                            let lines = error.components(separatedBy: "\n")
                            let details = lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : error
                            if !details.isEmpty {
                                Text(details).textSelection(.enabled).font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            Text(tr(error)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let doc = model.document {
                HStack {
                    Text(doc.mime); Text(doc.charset)
                }.font(.caption).foregroundStyle(.secondary)
                if !doc.note.isEmpty { Text(tr(doc.note)).font(.caption).foregroundStyle(.secondary) }
                if let data = doc.image {
                    // The service supplies a checked, single-frame thumbnail;
                    // creating NSImage here never decodes the original file.
                    if let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: doc.kind == .media ? CGFloat(180) : CGFloat.infinity)
                    } else { Text(tr("この画像形式を表示できません")) }
                }
                if doc.image == nil || doc.kind == .media {
                    if doc.kind == .archive {
                        archive(doc.text)
                    } else if doc.kind == .media {
                        media(doc.text)
                    } else {
                        PreviewTextView(text: doc.text, firstLine: doc.kind == .text ? doc.firstLine : nil,
                                        showLineNumbers: showLineNumbers, highlight: doc.kind == .text)
                    }
                }
                if doc.kind == .text {
                    HStack {
                        Button(tr("先頭")) { model.fetch(.first) }.disabled(doc.firstLine == 1)
                        Button(tr("前")) { model.fetch(.previous) }.disabled(doc.firstLine == 1)
                        Text(doc.lineCount == 0 ? tr("空のファイル") : "\(doc.firstLine)–\(doc.firstLine + doc.lineCount - 1) " + tr("行"))
                            .font(.caption).monospacedDigit()
                        Button(tr("次")) { model.fetch(.next) }.disabled(!doc.hasNext)
                        Button(tr("最後")) { model.fetch(.last) }.disabled(!doc.hasNext)
                        Toggle(tr("行番号を表示"), isOn: $showLineNumbers)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
            ResizeGrip { model.resize(to: CGSize(width: model.size.width + $0.width,
                                                  height: model.size.height + $0.height)) }
        }.padding(16).frame(width: model.size.width, height: model.size.height)
    }
    private func archive(_ text: String) -> some View {
        // Preserve tool-supplied names verbatim, including embedded spaces.
        Table(text.components(separatedBy: "\n").enumerated().map { ArchiveRow(id: $0.offset, detail: $0.element) }) {
            TableColumn(tr("ファイル名")) { row in Text(row.name).textSelection(.enabled) }
            TableColumn(tr("サイズ")) { row in Text(row.size).monospacedDigit() }.width(80)
            TableColumn(tr("更新日時")) { row in Text(row.date) }.width(150)
        }
    }
    private func media(_ text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if let format = object["format"] as? [String: Any] {
                        mediaCard("Format", values: format, keys: ["format_long_name", "duration", "size", "bit_rate"])
                    }
                    if let streams = object["streams"] as? [[String: Any]] {
                        ForEach(streams.indices, id: \.self) { index in
                            mediaCard("Stream \(index + 1)", values: streams[index], keys: ["codec_type", "codec_long_name", "width", "height", "sample_rate", "channels"])
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func mediaCard(_ title: String, values: [String: Any], keys: [String]) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading) {
                ForEach(keys, id: \.self) { key in
                    if let value = values[key] { Text("\(key): \(String(describing: value))").textSelection(.enabled) }
                }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
private struct ArchiveRow: Identifiable {
    let id: Int
    var name: String
    var size = ""
    var date = ""
    init(id: Int, detail: String) {
        self.id = id; self.name = detail
        // unzip -l and common GNU/BSD tar -tvf layouts. Unknown layouts remain
        // readable as the complete original line instead of dropping names.
        let patterns = [
            // unzip -l: size, ISO date, then the full filename.
            #"^\s*([0-9]+)\s+([0-9]{4}-[0-9]{2}-[0-9]{2}\s+[0-9:]+)\s+(.+)$"#,
            // GNU tar: mode, owner/group, size, ISO date and time.
            #"^[-dlcbps][rwxstST-]{9}[+@.]?\s+\S+\s+([0-9]+)\s+([0-9]{4}-[0-9]{2}-[0-9]{2}\s+[0-9:]+)\s+(.+)$"#,
            // BSD tar: mode, uid/gid, size, month/day/year, filename.
            #"^[-dlcbps][rwxstST-]{9}[+@.]?\s+\S+\s+([0-9]+)\s+([A-Za-z]{3}\s+[0-9]{1,2}\s+[0-9]{4})\s+(.+)$"#,
            // Tar variants that show month/day/time and optionally the year.
            #"^[-dlcbps][rwxstST-]{9}[+@.]?\s+\S+\s+([0-9]+)\s+([A-Za-z]{3}\s+[0-9]{1,2}\s+[0-9:]+(?:\s+[0-9]{4})?)\s+(.+)$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
                  let a = Range(match.range(at: 1), in: detail),
                  let b = Range(match.range(at: 2), in: detail),
                  let c = Range(match.range(at: 3), in: detail) else { continue }
            size = String(detail[a]); date = String(detail[b]); name = String(detail[c]); break
        }
    }
}

/// Plain attributed text prevents HTML, scripts and remote resources executing.
@MainActor
private struct PreviewTextView: NSViewRepresentable {
    let text: String
    let firstLine: Int?
    let showLineNumbers: Bool
    let highlight: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 648, height: 360))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false; view.isRichText = false; view.isAutomaticLinkDetectionEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let content: String
        if let firstLine, showLineNumbers {
            content = text.components(separatedBy: "\n").enumerated()
                .map { "\(firstLine + $0.offset)  \($0.element)" }.joined(separator: "\n")
        } else {
            content = text
        }
        let attributed = NSMutableAttributedString(string: content, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor])
        if highlight {
            let patterns: [(String, NSColor)] = [
                (#"\b(func|class|struct|enum|let|var|if|else|return|import|def|for|while|true|false|null|nil)\b"#, .systemPurple),
                (#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, .systemRed),
                (#"(?m)(//|#).*?$"#, .secondaryLabelColor)
            ]
            for (pattern, color) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: content, range: NSRange(location: 0, length: attributed.length)) {
                    attributed.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
        }
        view.textStorage?.setAttributedString(attributed)
        view.scrollToBeginningOfDocument(nil)
        scroll.layoutSubtreeIfNeeded()
        let clipView = scroll.contentView
        clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
        scroll.reflectScrolledClipView(clipView)
    }
}


@MainActor
private struct ResizeGrip: View {
    let onResize: (CGSize) -> Void
    @State private var lastTranslation = CGSize.zero
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = CGSize(width: value.translation.width - lastTranslation.width,
                                           height: value.translation.height - lastTranslation.height)
                        lastTranslation = value.translation
                        onResize(delta)
                    }
                    .onEnded { _ in lastTranslation = .zero })
                .help("プレビューの大きさを変更")
        }
    }
}

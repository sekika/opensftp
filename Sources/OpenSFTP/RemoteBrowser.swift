import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ApplicationServices
import SFTPCore

@MainActor
struct RemoteBrowser: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        let browser = BrowserCanvas(model: model)
        browser.autoresizingMask = [.width]
        scroll.documentView = browser
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? BrowserCanvas else { return }
        scroll.hasHorizontalScroller = !model.iconView
        canvas.update(width: scroll.contentSize.width, minimumHeight: scroll.contentSize.height)
    }
}

/// AppKit owns selection, keyboard navigation, and native file-promise dragging.
@MainActor
final class BrowserCanvas: NSView, NSDraggingSource, NSMenuDelegate {
    private let model: AppModel
    private var items: [RemoteEntry] = []
    private var icons = false
    private var anchor: Int?
    private var keyboardFocus: Int?
    private var pressEvent: NSEvent?
    private var pressIndex: Int?
    private var collapseOnMouseUp = false
    private var dropHighlight = false
    private var folderDragSource: FolderDragSource?
    private var remoteDragID: UUID?
    private var resizingColumn: Int?
    private var resizeStartX: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0
    private var fileIcons: [String: NSImage] = [:]
    private let rowHeight: CGFloat = 30
    private var iconSize: CGFloat { CGFloat(AppPreferences.shared.appearance.iconSize) }
    private var iconLabelLines: Int { AppPreferences.shared.appearance.iconLabelLines }
    private var labelHeight: CGFloat { CGFloat(iconLabelLines) * 16.0 + 2.0 }
    private var cellWidth: CGFloat { CGFloat(AppPreferences.shared.appearance.iconTileWidth) }
    private var iconVerticalPadding: CGFloat { iconSize * 0.2 }
    private var iconLabelSpacing: CGFloat { iconSize * 0.15 }
    private var cellHeight: CGFloat { iconVerticalPadding * 2 + iconSize + iconLabelSpacing + labelHeight }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    private var columns: Int { max(1, Int(bounds.width / cellWidth)) }
    private var headerHeight: CGFloat { icons ? 0 : 30 }
    private var columnLayout: BrowserColumnLayout { BrowserColumnLayout(savedWidths: model.listColumnWidths.map { Double($0) }) }
    private var columnStarts: [CGFloat] { columnLayout.starts }
    private var dividerPositions: [CGFloat] { columnStarts.dropFirst().map { $0 - 6 } }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !icons else { return }
        for x in dividerPositions {
            addCursorRect(NSRect(x: x - 4, y: 0, width: 8, height: headerHeight), cursor: .resizeLeftRight)
        }
    }

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([RemotePromiseProvider.remoteType, .fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(model.localized("リモートファイル一覧"))
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: .appearancePreferencesChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func appearanceChanged() {
        if let scroll = enclosingScrollView {
            update(width: scroll.contentSize.width, minimumHeight: scroll.contentSize.height)
        } else {
            needsDisplay = true
        }
    }

    func update(width: CGFloat, minimumHeight: CGFloat) {
        let updated = model.visibleEntries
        if updated.map(\.id) != items.map(\.id) { anchor = nil; keyboardFocus = nil }
        items = updated
        if icons != model.iconView { resizingColumn = nil }
        icons = model.iconView
        setFrameSize(NSSize(width: width, height: minimumHeight))
        setAccessibilityLabel(model.localized("リモートファイル一覧"))
        setAccessibilityValue(model.localized("\(items.count)項目、\(model.selection.count)項目を選択"))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let viewportWidth = enclosingScrollView?.contentSize.width ?? newSize.width
        let width = icons ? viewportWidth : max(viewportWidth, columnLayout.requiredWidth)
        let count = max(1, Int(width / cellWidth))
        let rows = icons ? Int(ceil(Double(items.count) / Double(count))) : items.count
        let minimum = enclosingScrollView?.contentSize.height ?? newSize.height
        super.setFrameSize(NSSize(width: width, height: max(minimum, headerHeight + CGFloat(rows) * (icons ? cellHeight : rowHeight))))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func itemRect(_ index: Int) -> NSRect {
        if icons {
            let width = bounds.width / CGFloat(columns)
            return NSRect(x: CGFloat(index % columns) * width, y: CGFloat(index / columns) * cellHeight, width: width, height: cellHeight)
        }
        return NSRect(x: 0, y: headerHeight + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
    }
    private func index(at point: NSPoint) -> Int? {
        guard point.y >= headerHeight, point.x >= 0, point.x < bounds.width else { return nil }
        let index = icons ? Int(point.y / cellHeight) * columns + min(columns - 1, Int(point.x / (bounds.width / CGFloat(columns)))) : Int((point.y - headerHeight) / rowHeight)
        return items.indices.contains(index) ? index : nil
    }
    private func icon(_ item: RemoteEntry) -> NSImage {
        if item.kind == .symbolicLink, model.directoryLinkNames.contains(item.name) { return model.directoryLinkIcon }
        if item.kind == .symbolicLink, let icon = model.fileLinkIcon(for: item.name) { return icon }
        if item.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        if item.isRegularFile {
            let suffix = (item.name as NSString).pathExtension.lowercased()
            if !suffix.isEmpty {
                if let cached = fileIcons[suffix] { return cached }
                if let type = UTType(filenameExtension: suffix) {
                    let image = NSWorkspace.shared.icon(for: type)
                    fileIcons[suffix] = image
                    return image
                }
            }
        }
        let symbol = item.kind == .symbolicLink ? "link" : "doc"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.localized(item.kind.rawValue))!
        return image.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) ?? image
    }

    private func text(_ string: String, in rect: NSRect, color: NSColor = .labelColor, size: CGFloat = 12, centered: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.alignment = centered ? .center : .left
        (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func iconLabel(_ name: String, in rect: NSRect, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        let storage = NSTextStorage(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: color, .paragraphStyle: paragraph
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: rect.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = iconLabelLines
        container.lineBreakMode = .byTruncatingTail
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let glyphs = layout.glyphRange(for: container)
        layout.drawGlyphs(forGlyphRange: glyphs, at: rect.origin)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); dirtyRect.fill()
        if !icons {
            NSColor.windowBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight).fill()
            for (i, label) in ["名前", "種類", "サイズ", "更新時刻"].enumerated() {
                let mark = model.sortColumn == i ? (model.ascending ? " ↑" : " ↓") : ""
                let end = i == 3 ? bounds.width : columnStarts[i + 1]
                text(model.localized(label) + mark, in: NSRect(x: columnStarts[i], y: 8, width: max(0, end - columnStarts[i] - 8), height: 18), color: .secondaryLabelColor, size: 11)
            }
            NSColor.separatorColor.setStroke()
            for x in dividerPositions {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: x, y: 4))
                line.line(to: NSPoint(x: x, y: headerHeight - 4))
                line.stroke()
            }
        }
        for (i, item) in items.enumerated() {
            let rect = itemRect(i)
            guard rect.intersects(dirtyRect) else { continue }
            let selected = model.selection.contains(item.id)
            if selected {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 2), xRadius: 5, yRadius: 5).fill()
            } else if !icons && i % 2 == 1 {
                NSColor.alternatingContentBackgroundColors[1].setFill(); rect.fill()
            }
            let color: NSColor = selected ? .selectedTextColor : .labelColor
            let image = icon(item)
            if icons {
                image.draw(in: NSRect(x: rect.midX - iconSize / 2, y: rect.minY + iconVerticalPadding, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                iconLabel(item.name, in: NSRect(x: rect.minX + 8, y: rect.minY + iconVerticalPadding + iconSize + iconLabelSpacing, width: rect.width - 16, height: labelHeight), color: color)
            } else {
                image.draw(in: NSRect(x: 12, y: rect.minY + 6, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                text(item.name, in: NSRect(x: 38, y: rect.minY + 7, width: columnStarts[1] - 48, height: 20), color: color)
                let values = [model.kindDescription(item), item.isDirectory ? "—" : AppStrings.byteCount(item.size, language: model.language), item.modified]
                for (offset, value) in values.enumerated() {
                    let column = offset + 1
                    let end = column == 3 ? bounds.width : columnStarts[column + 1]
                    text(value, in: NSRect(x: columnStarts[column], y: rect.minY + 7, width: end - columnStarts[column] - 8, height: 20), color: selected ? color : .secondaryLabelColor)
                }
            }
        }
        if items.isEmpty {
            text(model.localized(model.connected ? "このフォルダに表示する項目はありません" : "Hostを入力して接続してください"), in: NSRect(x: 20, y: 95, width: bounds.width - 40, height: 25), color: .secondaryLabelColor, size: 14, centered: true)
        }
        if dropHighlight {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: visibleRect.insetBy(dx: 3, dy: 3)); border.lineWidth = 3; border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressEvent = event; collapseOnMouseUp = false
        let point = convert(event.locationInWindow, from: nil)
        if !icons, point.y < headerHeight {
            pressEvent = nil; pressIndex = nil
            if let column = dividerPositions.firstIndex(where: { abs($0 - point.x) <= 4 }) {
                resizingColumn = column
                resizeStartX = point.x
                resizeStartWidth = model.listColumnWidths[column]
                return
            }
            let column = columnStarts.lastIndex(where: { point.x >= $0 }) ?? 0
            model.sort(by: column); return
        }
        guard let i = index(at: point) else { model.selection = []; pressIndex = nil; return }
        pressIndex = i; keyboardFocus = i
        if event.modifierFlags.contains(.shift), let anchor, items.indices.contains(anchor) {
            model.selection = Set(items[min(anchor, i)...max(anchor, i)].map(\.id))
        } else if event.modifierFlags.contains(.command) {
            if !model.selection.insert(items[i].id).inserted { model.selection.remove(items[i].id) }
            anchor = i
        } else if !model.selection.contains(items[i].id) {
            model.selection = [items[i].id]; anchor = i
        } else { collapseOnMouseUp = true }
        needsDisplay = true
        if event.clickCount == 2 {
            model.selection = [items[i].id]
            collapseOnMouseUp = false
            model.openSelection()
        }
    }
    override func mouseUp(with event: NSEvent) {
        if resizingColumn != nil {
            resizingColumn = nil; pressEvent = nil; pressIndex = nil
            needsDisplay = true
            return
        }
        if collapseOnMouseUp, let i = pressIndex, items.indices.contains(i) { model.selection = [items[i].id]; anchor = i }
        collapseOnMouseUp = false; pressEvent = nil; needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "[" { model.back(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "]" { model.forward(); return }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "a" { model.selectAll(); return }
        if event.modifierFlags.contains(.command), event.keyCode == 126 { model.parent(); return }
        if event.keyCode == 49 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { model.previewSelection(); return }
        if event.keyCode == 36 || event.keyCode == 76 { model.openSelection(); return }
        let step: Int
        switch event.keyCode {
        case 123: step = -1
        case 124: step = 1
        case 125: step = icons ? columns : 1
        case 126: step = icons ? -columns : -1
        default: super.keyDown(with: event); return
        }
        guard !items.isEmpty else { return }
        let current = keyboardFocus ?? items.firstIndex(where: { model.selection.contains($0.id) }) ?? (step > 0 ? -1 : items.count)
        let next = max(0, min(items.count - 1, current + step))
        keyboardFocus = next
        if event.modifierFlags.contains(.shift), let anchor, items.indices.contains(anchor) {
            model.selection = Set(items[min(anchor, next)...max(anchor, next)].map(\.id))
        } else { model.selection = [items[next].id]; anchor = next }
        scrollToVisible(itemRect(next)); needsDisplay = true
    }
    override func selectAll(_ sender: Any?) { model.selectAll(); needsDisplay = true }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        if let i = index(at: convert(event.locationInWindow, from: nil)), !model.selection.contains(items[i].id) {
            model.selection = [items[i].id]; anchor = i
        }
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ enabled: Bool) {
            let item = NSMenuItem(title: model.localized(title), action: action, keyEquivalent: ""); item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        add("プレビュー", #selector(previewItem), model.canPreview)
        add("Terminalで開く（less）", #selector(openInTerminal), model.canOpenInTerminal)
        add("開く", #selector(openItem), model.selectedEntries.count == 1 && model.selectedEntries.first.map { $0.isDirectory || $0.isRegularFile || $0.kind == .symbolicLink } == true)
        add("Finderへダウンロード…", #selector(downloadItems), model.canDownload)
        if !model.selectedEntries.isEmpty, !model.canDownload { add("特殊ファイルは転送対象外", #selector(downloadItems), false) }
        add("名前変更・移動…", #selector(renameItem), model.selectedEntries.count == 1 && model.canModify)
        add("削除…", #selector(deleteItems), model.canModify)
        add("情報を見る", #selector(infoItems), !model.selection.isEmpty)
        menu.addItem(.separator()); add("再読込", #selector(reloadItems), model.connected)
        return menu
    }
    @objc private func previewItem() { model.previewSelection() }
    @objc private func openInTerminal() { model.openSelectionInTerminal() }
    @objc private func openItem() { model.openSelection() }
    @objc private func downloadItems() { model.downloadSelection() }
    @objc private func renameItem() { model.rename() }
    @objc private func deleteItems() { model.deleteSelection() }
    @objc private func infoItems() { model.showInfo() }
    @objc private func reloadItems() { model.refresh() }

    override func mouseDragged(with event: NSEvent) {
        if let column = resizingColumn {
            let point = convert(event.locationInWindow, from: nil)
            model.resizeListColumn(column, to: resizeStartWidth + point.x - resizeStartX)
            if let scroll = enclosingScrollView {
                update(width: scroll.contentSize.width, minimumHeight: scroll.contentSize.height)
            }
            return
        }
        guard let start = pressEvent, pressIndex != nil, model.canDownload else { return }
        let current = convert(event.locationInWindow, from: nil), origin = convert(start.locationInWindow, from: nil)
        guard hypot(current.x - origin.x, current.y - origin.y) > 4 else { return }
        collapseOnMouseUp = false; pressEvent = nil
        let entries = model.selectedEntries
        let dragID = model.workspace.beginDrag(from: model)
        remoteDragID = dragID
        if entries.contains(where: { $0.isDirectory || $0.kind == .symbolicLink }) {
            // NSFilePromiseProvider lets Finder uniquify each final filename.
            // Folder merges need the destination directory and original names.
            let source = FolderDragSource(model: model, drop: FolderDrop(host: model.host, remoteDirectory: model.path, entries: entries))
            source.remoteDragID = dragID
            folderDragSource = source
            do {
                let promises = try source.makePasteboardItems()
                for item in promises { item.setString(dragID.uuidString, forType: RemotePromiseProvider.remoteType) }
                let draggingItems = zip(promises, entries).enumerated().map { offset, pair in
                    let item = NSDraggingItem(pasteboardWriter: pair.0)
                    item.setDraggingFrame(NSRect(x: current.x + CGFloat(offset * 5), y: current.y + CGFloat(offset * 5), width: 32, height: 32), contents: icon(pair.1))
                    return item
                }
                beginDraggingSession(with: draggingItems, event: start, source: source)
            } catch {
                model.workspace.endDrag(dragID)
                folderDragSource = nil
                model.errorMessage = error.localizedDescription
            }
            return
        }
        folderDragSource = nil
        let draggingItems = model.selectedEntries.enumerated().map { offset, entry -> NSDraggingItem in
            let writer = PromiseWriter(model: model, host: model.host, remote: SFTPCommand.join(model.path, entry.name), name: entry.name, isDirectory: entry.isDirectory)
            let provider = RemotePromiseProvider(fileType: entry.isDirectory ? UTType.folder.identifier : (UTType(filenameExtension: (entry.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier), delegate: writer, dragID: dragID)
            provider.userInfo = writer // Delegate is weak. Retain it for the lifetime of the promise.
            let item = NSDraggingItem(pasteboardWriter: provider)
            item.setDraggingFrame(NSRect(x: current.x + CGFloat(offset * 5), y: current.y + CGFloat(offset * 5), width: 32, height: 32), contents: icon(entry))
            return item
        }
        beginDraggingSession(with: draggingItems, event: start, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let remoteDragID { model.workspace.endDrag(remoteDragID) }
        remoteDragID = nil
    }

    private func internalDragID(_ pasteboard: NSPasteboard) -> UUID? {
        guard let value = pasteboard.string(forType: RemotePromiseProvider.remoteType) else { return nil }
        return UUID(uuidString: value)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.availableType(from: [RemotePromiseProvider.remoteType]) != nil {
            guard let id = internalDragID(sender.draggingPasteboard), model.workspace.drag(id, to: model) != nil else { return [] }
            dropHighlight = true; needsDisplay = true; return .copy
        }
        guard model.connected, sender.draggingSource as? BrowserCanvas !== self,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        dropHighlight = true; needsDisplay = true; return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false; needsDisplay = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false; needsDisplay = true
        if sender.draggingPasteboard.availableType(from: [RemotePromiseProvider.remoteType]) != nil {
            guard let id = internalDragID(sender.draggingPasteboard) else { return false }
            return model.workspace.consumeDrag(id, to: model)
        }
        guard model.connected, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        model.upload(urls); return true
    }
}

/// A snapshot: navigation or selection changes during dragging cannot change
/// the source. The receiver supplies a directory, never a uniquified filename.
@MainActor
struct FolderDrop {
    let host: String
    let remoteDirectory: String
    let entries: [RemoteEntry]
}

/// File-URL promises expose the actual paste destination and let the source
/// choose the final name. Each item supplies a content UTI and a deferred URL.
@MainActor
final class FolderDragSource: NSObject, NSDraggingSource {
    nonisolated static let urlPromiseType = NSPasteboard.PasteboardType(kPasteboardTypeFileURLPromise as String)
    nonisolated static let contentType = NSPasteboard.PasteboardType(kPasteboardTypeFilePromiseContent as String)
    private let model: AppModel
    private let drop: FolderDrop
    private var accepted = Set<Int>()
    private var writers: [FolderURLPromiseWriter] = []
    var remoteDragID: UUID?

    init(model: AppModel, drop: FolderDrop) {
        self.model = model; self.drop = drop
        super.init()
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let remoteDragID { model.workspace.endDrag(remoteDragID) }
        remoteDragID = nil
    }

    func makePasteboardItems() throws -> [NSPasteboardItem] {
        try drop.entries.enumerated().map { index, entry in
            let item = NSPasteboardItem()
            let writer = FolderURLPromiseWriter(source: self, index: index, name: entry.name)
            let type = entry.isDirectory ? UTType.folder : entry.kind == .symbolicLink ? .item : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
            guard item.setString(type.identifier, forType: Self.contentType),
                  item.setDataProvider(writer, forTypes: [Self.urlPromiseType]) else {
                throw NSError(domain: "OpenSFTP.Drag", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "フォルダ転送用のドラッグデータを登録できません。"])
            }
            writers.append(writer)
            return item
        }
    }

    nonisolated static func destinationDirectory(from pasteboard: NSPasteboard) -> URL? {
        var carbonPasteboard: Pasteboard?
        guard PasteboardCreate(pasteboard.name.rawValue as CFString, &carbonPasteboard) == noErr,
              let carbonPasteboard else { return nil }
        _ = PasteboardSynchronize(carbonPasteboard)
        var location: CFURL?
        guard PasteboardCopyPasteLocation(carbonPasteboard, &location) == noErr,
              let location else { return nil }
        let url = location as URL
        return url.isFileURL ? url : nil
    }

    fileprivate func accept(index: Int, destination: URL) {
        guard drop.entries.indices.contains(index), accepted.insert(index).inserted else { return }
        let entry = drop.entries[index]
        model.download(host: drop.host, remote: SFTPCommand.join(drop.remoteDirectory, entry.name),
                       to: destination, isDirectory: entry.isDirectory, isSymbolicLink: entry.kind == .symbolicLink, completion: nil)
    }

    fileprivate func missingDestination() {
        model.errorMessage = "ドラッグ先の保存フォルダを取得できません。保存先指定メニューを利用してください。"
    }
}

/// Metadata is supplied before dropping; the URL is requested only when the
/// receiver supplies its paste location. Keep this callback synchronous and
/// enqueue transfer/confirmation on the main actor after returning the URL.
private final class FolderURLPromiseWriter: NSObject, NSPasteboardItemDataProvider {
    private weak var source: FolderDragSource?
    private let index: Int
    private let name: String

    init(source: FolderDragSource, index: Int, name: String) {
        self.source = source; self.index = index; self.name = name
        super.init()
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == FolderDragSource.urlPromiseType, let pasteboard, let source else { return }
        guard let directory = FolderDragSource.destinationDirectory(from: pasteboard) else {
            Task { @MainActor in source.missingDestination() }
            return
        }
        let destination = directory.appendingPathComponent(name)
        guard item.setString(destination.absoluteString, forType: FolderDragSource.urlPromiseType) else { return }
        let index = self.index
        Task { @MainActor in source.accept(index: index, destination: destination) }
    }
}

/// The same drag offers a Finder promise and an in-process capability token.
/// Internal receivers read only the token and never fulfill the file promise.
private final class RemotePromiseProvider: NSFilePromiseProvider {
    static let remoteType = NSPasteboard.PasteboardType("local.opensftp.remote-items")
    private let dragID: UUID
    init(fileType: String, delegate: any NSFilePromiseProviderDelegate, dragID: UUID) {
        self.dragID = dragID
        super.init()
        self.fileType = fileType
        self.delegate = delegate
    }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [Self.remoteType]
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == Self.remoteType ? dragID.uuidString : super.pasteboardPropertyList(forType: type)
    }
}

@MainActor
private final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    private let model: AppModel
    private let host: String
    private let remote: String
    private let name: String
    private let isDirectory: Bool
    init(model: AppModel, host: String, remote: String, name: String, isDirectory: Bool) {
        self.model = model; self.host = host; self.remote = remote; self.name = name; self.isDirectory = isDirectory
    }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        // AppKit may call this outside the main actor. Hop before accessing the model.
        Task { @MainActor [self] in
            model.download(host: host, remote: remote, to: url, isDirectory: isDirectory, completion: completionHandler)
        }
    }
}

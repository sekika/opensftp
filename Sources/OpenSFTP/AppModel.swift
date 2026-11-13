import AppKit
import SwiftUI
import SFTPCore
import UniformTypeIdentifiers

struct JobRecord: Identifiable {
    enum State: String { case waiting = "待機中", running = "実行中", completed = "完了", failed = "失敗", cancelled = "中断" }
    enum Navigation { case visit, refresh, history(Int) }
    enum Request {
        case listing(String?, Int)
        case upload(URL, String)
        case download(String, URL, openAfterDownload: Bool)
        case openLink(String, URL, Int)
        case mutation(String, [String])
        case folder(URL, String, FolderTransferDirection)
        case symbolicLink(URL, String, FolderTransferDirection)
        case recursiveDelete(String)
        case remoteCopy(RemoteCopyRequest)
    }
    let id = UUID()
    let created = Date()
    let host: String
    let title: String
    let target: String
    let request: Request
    var navigation: Navigation = .visit
    var state: State = .waiting
    var started: Date?
    var ended: Date?
    var result = ""
    private var stdoutStorage = ""
    private var stderrStorage = ""
    private let logLimit: Int
    var stdout: String {
        get { stdoutStorage }
        set { stdoutStorage = BoundedLog.clip(newValue, limit: logLimit) }
    }
    var stderr: String {
        get { stderrStorage }
        set { stderrStorage = BoundedLog.clip(newValue, limit: logLimit) }
    }
    var exitCode: Int32?
    var progress: TransferProgress?
    var showProgress = false
    var progressUpdated: Date?
    var completion: ((Error?) -> Void)?

    init(host: String, title: String, target: String, request: Request, completion: ((Error?) -> Void)? = nil,
         logLimit: Int = ResourceLimits.standard.logBytes) {
        self.host = host; self.title = title; self.target = target; self.request = request; self.completion = completion
        self.logLimit = max(1, logLimit)
    }
}

@MainActor
final class AppModel: ObservableObject {
    let windowID = UUID()
    @Published var windowNumber = 0
    weak var window: NSWindow?
    let workspace: AppWorkspace
    @Published var outgoingJobs: [JobRecord] = []
    @Published private var hiddenOutgoingIDs = Set<UUID>()
    var displayedJobs: [JobRecord] { (jobs + outgoingJobs.filter { !hiddenOutgoingIDs.contains($0.id) }).sorted { $0.created < $1.created } }
    var hasRelatedWork: Bool { busy || outgoingJobs.contains { $0.state == .waiting || $0.state == .running } }
    private let remoteFileSystem: (any RemoteFileSystem)?
    private let scp: any ScpRunning
    private let chooseRemotePolicy: ((String) -> FolderTransferPolicy?)?
    private var executionTask: Task<Void, Never>?
    private var activeJobID: UUID?
    private var refreshAfterPendingListing = false

    @Published var language: AppLanguage
    func localized(_ source: String) -> String { AppStrings.translate(source, to: language) }
    @Published var hosts: [String] = []
    @Published var hostInput: String {
        didSet { defaults.set(hostInput, forKey: "hostInput") }
    }
    @Published var host = ""
    @Published var path = ""
    @Published private(set) var folderHistory: [String] = []
    @Published private(set) var historyIndex = -1
    @Published var entries: [RemoteEntry] = []
    @Published private(set) var directoryLinkNames = Set<String>()
    @Published private(set) var fileLinkTargets: [String: String] = [:]
    @Published var selection = Set<String>() { didSet { updatePreviewSelection() } }
    let preview = FilePreviewModel()
    @Published private(set) var openingTerminal = false
    var canPreview: Bool {
        guard connected, selectedEntries.count == 1, let item = selectedEntries.first else { return false }
        return item.isRegularFile || (item.kind == .symbolicLink && fileLinkTargets[item.name] != nil)
    }
    var canOpenInTerminal: Bool {
        canPreview && !openingTerminal && selectedEntries.first.map { $0.isRegularFile && (try? SFTPCommand.validateName($0.name)) != nil } == true
    }
    func previewSelection() {
        guard canPreview else { return }
        let name = selectedEntries[0].name
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            preview.showError(path: name, message: "ファイル名に制御文字が含まれるためプレビューできません")
            return
        }
        let target = selectedEntries[0].kind == .symbolicLink ? fileLinkTargets[name] : nil
        preview.show(host: host, path: target ?? SFTPCommand.join(path, name))
    }
    func openSelectionInTerminal() {
        guard canOpenInTerminal, let item = selectedEntries.first else { return }
        let host = host, remote = SFTPCommand.join(path, item.name)
        openingTerminal = true
        let openTextInTerminal = self.openTextInTerminal
        Task { [weak self] in
            defer { self?.openingTerminal = false }
            do { try await openTextInTerminal(host, remote) }
            catch { self?.errorMessage = error.localizedDescription }
        }
    }
    private func updatePreviewSelection() {
        guard preview.isPresented else { return }
        if canPreview { previewSelection() } else { preview.clearSelection() }
    }
    @Published var jobs: [JobRecord] = [] { didSet { workspace.synchronize(self) } }
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var status = "接続先を選択してください"
    @Published var showConnectionBar = true
    @Published var showStatusBar: Bool {
        didSet { defaults.set(showStatusBar, forKey: "showStatusBar") }
    }
    @Published var showFolderStatusBar: Bool {
        didSet { defaults.set(showFolderStatusBar, forKey: "showFolderStatusBar") }
    }
    @Published var showQueue: Bool {
        didSet { defaults.set(showQueue, forKey: "showQueue") }
    }
    @Published var showLogs: Bool {
        didSet { defaults.set(showLogs, forKey: "showLogs") }
    }
    @Published var logSelection: UUID?
    @Published var iconView: Bool {
        didSet { defaults.set(iconView, forKey: "iconView") }
    }
    @Published var showHidden: Bool {
        didSet {
            defaults.set(showHidden, forKey: "showHidden")
            selection.formIntersection(Set(visibleEntries.map(\.id)))
        }
    }
    @Published var sortColumn: Int {
        didSet { defaults.set(sortColumn, forKey: "sortColumn") }
    }
    @Published private(set) var listColumnWidths: [CGFloat]
    func resizeListColumn(_ column: Int, to width: CGFloat) {
        guard listColumnWidths.indices.contains(column), width.isFinite else { return }
        let adjusted = max(BrowserColumnLayout.minimums[column], width)
        guard listColumnWidths[column] != adjusted else { return }
        listColumnWidths[column] = adjusted
        defaults.set(listColumnWidths.map { Double($0) }, forKey: "listColumnWidths")
    }
    @Published var ascending: Bool {
        didSet { defaults.set(ascending, forKey: "sortAscending") }
    }
    private var revision = 0
    private let defaults: UserDefaults
    private let service: any SFTPRunning
    private let rsync: any RsyncRunning
    enum FileConflictChoice: Equatable { case overwrite, keepBoth, cancel }
    private let chooseFileConflict: ((String, String) -> FileConflictChoice)?
    private let chooseFolderMethod: ((String) -> FolderTransferMethod?)?
    private var queueTask: Task<Void, Never>?
    private var progressRevealTask: Task<Void, Never>?
    private var linkInspectionTask: Task<Void, Never>?
    private let downloadsDirectoryOverride: URL?
    private var downloadsDirectory: URL { downloadsDirectoryOverride ?? AppPreferences.shared.downloadDirectory }
    private let openLocalFile: (URL) throws -> Void
    private let openTextInTerminal: (String, String) async throws -> Void

    init(workspace: AppWorkspace? = nil,
         remoteFileSystem: (any RemoteFileSystem)? = nil,
         scp: any ScpRunning = ScpService(),
         chooseRemotePolicy: ((String) -> FolderTransferPolicy?)? = nil,
         service: any SFTPRunning = SFTPService(),
         rsync: any RsyncRunning = RsyncService(),
         chooseFileConflict: ((String, String) -> FileConflictChoice)? = nil,
         chooseFolderMethod: ((String) -> FolderTransferMethod?)? = nil,
         language: AppLanguage? = nil,
         defaults: UserDefaults = .standard,
         downloadsDirectory: URL? = nil,
         openTextInTerminal: @escaping (String, String) async throws -> Void = { host, path in
             try await TerminalLessService().open(host: host, path: path)
         },
         openLocalFile: @escaping (URL) throws -> Void = { url in
             let process = Process()
             process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
             process.arguments = [url.path]
             try process.run()
         }) {
        self.workspace = workspace ?? AppWorkspace.shared
        self.remoteFileSystem = remoteFileSystem
        self.scp = scp
        self.chooseRemotePolicy = chooseRemotePolicy
        self.defaults = defaults
        self.hostInput = defaults.string(forKey: "hostInput") ?? ""
        self.showStatusBar = defaults.object(forKey: "showStatusBar") as? Bool ?? true
        self.showFolderStatusBar = defaults.object(forKey: "showFolderStatusBar") as? Bool ?? true
        self.showQueue = defaults.object(forKey: "showQueue") as? Bool ?? true
        self.showLogs = defaults.object(forKey: "showLogs") as? Bool ?? false
        self.iconView = defaults.object(forKey: "iconView") as? Bool ?? false
        self.showHidden = defaults.bool(forKey: "showHidden")
        let savedSortColumn = defaults.integer(forKey: "sortColumn")
        self.sortColumn = (0...3).contains(savedSortColumn) ? savedSortColumn : 0
        self.ascending = defaults.object(forKey: "sortAscending") as? Bool ?? true
        self.listColumnWidths = BrowserColumnLayout(savedWidths: defaults.array(forKey: "listColumnWidths") as? [Double]).widths
        self.service = service
        self.rsync = rsync
        self.language = language ?? AppLanguage.systemDefault()
        self.chooseFileConflict = chooseFileConflict
        self.chooseFolderMethod = chooseFolderMethod
        self.downloadsDirectoryOverride = downloadsDirectory
        self.openLocalFile = openLocalFile
        self.openTextInTerminal = openTextInTerminal
        reloadHosts()
    }

    private func selectFolderMethod(destinationExists: Bool) -> FolderTransferMethod? {
        if let chooseFolderMethod { return chooseFolderMethod("転送方法を選択してください。") }
        let methods = FolderTransferMethod.choices(destinationExists: destinationExists)
        let alert = NSAlert()
        alert.messageText = localized("フォルダの転送方法")
        alert.informativeText = localized("転送方法を選択してください。")
        for method in methods { alert.addButton(withTitle: localized(method.selectionTitle(destinationExists: destinationExists))) }
        alert.addButton(withTitle: localized("キャンセル")).keyEquivalent = "\u{1b}"
        let selected = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return methods.indices.contains(selected) ? methods[selected] : nil
    }

    var connected: Bool { !host.isEmpty && !path.isEmpty }
    private var listingPending: Bool {
        jobs.contains { job in
            guard job.host == host, job.state == .waiting || job.state == .running else { return false }
            if case .listing = job.request { return true }
            if case .openLink = job.request { return true }
            return false
        }
    }
    var canGoBack: Bool { connected && !listingPending && historyIndex > 0 }
    var canGoForward: Bool { connected && !listingPending && historyIndex >= 0 && historyIndex + 1 < folderHistory.count }
    var selectedEntries: [RemoteEntry] { visibleEntries.filter { selection.contains($0.id) } }
    var canDownload: Bool { !selectedEntries.isEmpty && selectedEntries.allSatisfy { $0.isRegularFile || $0.isDirectory || $0.kind == .symbolicLink } }
    var canModify: Bool {
        !selectedEntries.isEmpty && selectedEntries.allSatisfy { $0.kind == .file || $0.kind == .directory }
    }
    var visibleEntries: [RemoteEntry] {
        entries.filter { showHidden || !$0.isHidden }.sorted { a, b in
            let comparison: ComparisonResult
            switch sortColumn {
            case 1: comparison = kindDescription(a).localizedStandardCompare(kindDescription(b))
            case 2: comparison = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case 3:
                let left = a.modifiedDate ?? .distantPast, right = b.modifiedDate ?? .distantPast
                comparison = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            default: comparison = a.name.localizedStandardCompare(b.name)
            }
            let resolved = comparison == .orderedSame ? a.name.localizedStandardCompare(b.name) : comparison
            return ascending ? resolved == .orderedAscending : resolved == .orderedDescending
        }
    }

    func kindDescription(_ entry: RemoteEntry) -> String {
        if entry.isRegularFile {
            let suffix = (entry.name as NSString).pathExtension.lowercased()
            if !suffix.isEmpty,
               let type = UTType(filenameExtension: suffix), !type.isDynamic,
               let description = type.localizedDescription, !description.isEmpty {
                return description
            }
        }
        return localized(entry.kind.rawValue)
    }

    func reloadHosts() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        do { hosts = SSHConfig.hosts(in: try String(contentsOf: url, encoding: .utf8)) }
        catch {
            hosts = []
            if FileManager.default.fileExists(atPath: url.path) { errorMessage = "~/.ssh/config を読み込めません。アクセス権とUTF-8形式を確認してください。" }
        }
    }

    func connect() {
        guard !hasRelatedWork else { return }
        let candidate = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try SFTPCommand.validateHost(candidate)
            host = candidate; path = ""; entries = []; selection = []
            directoryLinkNames = []
            fileLinkTargets = [:]
            folderHistory = []; historyIndex = -1
            load(nil)
        } catch { errorMessage = error.localizedDescription }
    }

    func load(_ directory: String?, navigation: JobRecord.Navigation = .visit) {
        guard !host.isEmpty else { return }
        cancelLinkInspection()
        revision += 1
        var job = JobRecord(host: host, title: "一覧取得", target: directory ?? "ホーム", request: .listing(directory, revision))
        job.navigation = navigation
        enqueue(job)
    }
    func refresh() { if connected, !listingPending { load(path, navigation: .refresh) } }
    func refreshAfterMutation() {
        guard connected else { return }
        if listingPending { refreshAfterPendingListing = true }
        else { refresh() }
    }
    func back() {
        guard canGoBack else { return }
        let index = historyIndex - 1
        load(folderHistory[index], navigation: .history(index))
    }
    func forward() {
        guard canGoForward else { return }
        let index = historyIndex + 1
        load(folderHistory[index], navigation: .history(index))
    }

    private func recordNavigation(to directory: String, navigation: JobRecord.Navigation) {
        switch navigation {
        case .visit:
            if folderHistory.indices.contains(historyIndex), folderHistory[historyIndex] == directory { return }
            folderHistory = Array(folderHistory.prefix(historyIndex + 1))
            folderHistory.append(directory)
            historyIndex = folderHistory.count - 1
        case .refresh:
            if folderHistory.indices.contains(historyIndex) { folderHistory[historyIndex] = directory }
            else { folderHistory = [directory]; historyIndex = 0 }
        case let .history(index):
            guard folderHistory.indices.contains(index) else { return }
            folderHistory[index] = directory
            historyIndex = index
        }
    }
    func parent() {
        guard connected else { return }
        load((path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent)
    }
    func openSelection() {
        guard connected, selectedEntries.count == 1, let item = selectedEntries.first else { return }
        let remote = SFTPCommand.join(path, item.name)
        if item.isDirectory {
            load(remote)
        } else if item.kind == .symbolicLink {
            cancelLinkInspection()
            revision += 1
            enqueue(JobRecord(host: host, title: "リンクを開く", target: remote,
                              request: .openLink(remote, downloadsDirectory.appendingPathComponent(item.name), revision)))
        } else if item.isRegularFile {
            if AppPreferences.shared.doubleClickAction == .preview {
                previewSelection()
            } else {
                let destination = downloadsDirectory.appendingPathComponent(item.name)
                enqueue(JobRecord(host: host, title: "取得して開く", target: remote,
                                  request: .download(remote, destination, openAfterDownload: true)))
            }
        }
    }
    func selectAll() { selection = Set(visibleEntries.map(\.id)) }
    func sort(by column: Int) {
        if sortColumn == column { ascending.toggle() } else { sortColumn = column; ascending = true }
    }

    func newFolder() {
        guard connected, let name = prompt("フォルダ作成", message: "\(host):\(path) に作成する名前", value: localized("新しいフォルダ")) else { return }
        do {
            try SFTPCommand.validateName(name)
            mutate("mkdir", [SFTPCommand.join(path, name)])
        } catch { errorMessage = error.localizedDescription }
    }
    func rename() {
        guard selectedEntries.count == 1, canModify, let item = selectedEntries.first,
              let name = prompt("名前変更・移動", message: "\(host):\(SFTPCommand.join(path, item.name))\n新しい名前、または移動先の絶対パス", value: item.name) else { return }
        do {
            try SFTPCommand.validatePath(name)
            if !name.hasPrefix("/") { try SFTPCommand.validateName(name) }
            let destination = name.hasPrefix("/") ? name : SFTPCommand.join(path, name)
            mutate("rename", [SFTPCommand.join(path, item.name), destination])
        } catch { errorMessage = error.localizedDescription }
    }
    func deleteSelection() {
        guard canModify else { return }
        let items = selectedEntries
        let details = items.map { "\(localized($0.isDirectory ? "フォルダと配下をすべて削除" : "ファイルを削除")): \(SFTPCommand.join(path, $0.name))" }.joined(separator: "\n")
        let notice = localized("\nフォルダ内の隠しファイルも削除します。リンク先はたどりません。ごみ箱には入らず、元に戻せません。")
        guard confirm("\(items.count)項目を削除しますか？", message: "\(localized("接続先:")) \(host)\n\(details)\(notice)", action: "削除") else { return }
        for item in items {
            let remote = SFTPCommand.join(path, item.name)
            if item.isDirectory {
                enqueue(JobRecord(host: host, title: "フォルダ削除", target: remote, request: .recursiveDelete(remote)))
            } else { mutate("rm", [remote]) }
        }
    }
    private func mutate(_ verb: String, _ paths: [String]) {
        enqueue(JobRecord(host: host, title: verb, target: paths.joined(separator: " → "), request: .mutation(verb, paths)))
    }

    func upload(_ urls: [URL]) {
        guard connected else { return }
        var files: [URL] = []
        var rejected: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true || values?.isDirectory == true || values?.isSymbolicLink == true,
                  (try? SFTPCommand.validateName(url.lastPathComponent)) != nil else { rejected.append(url.lastPathComponent); continue }
            files.append(url)
        }
        if !rejected.isEmpty { errorMessage = "通常ファイル・フォルダ・シンボリックリンクのみ転送できます。対象外: " + rejected.joined(separator: ", ") }
        let existing = Set(entries.map(\.name))
        let conflicts = files.filter { existing.contains($0.lastPathComponent) && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true && (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        if !conflicts.isEmpty, !confirm("同名ファイルを上書きしますか？", message: "\(host):\(path)\n" + conflicts.map(\.lastPathComponent).joined(separator: "\n"), action: "上書き") { return }
        for url in files {
            let remote = SFTPCommand.join(path, url.lastPathComponent)
            let link = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            let directory = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !directory, link, let target = entries.first(where: { $0.name == url.lastPathComponent }), target.kind != (link ? .symbolicLink : .file) {
                errorMessage = "同名のフォルダ・リンク等があるため転送できません: " + remote
                continue
            }
            enqueue(JobRecord(host: host, title: directory ? "フォルダ送信" : "アップロード", target: remote,
                              request: directory ? .folder(url, remote, .upload) : link ? .symbolicLink(url, remote, .upload) : .upload(url, remote)))
        }
    }

    func downloadSelection() {
        guard canDownload else { return }
        let panel = NSOpenPanel()
        panel.title = localized("ダウンロード先を選択")
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = localized("ダウンロード先を選択")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        for entry in selectedEntries {
            download(host: host, remote: SFTPCommand.join(path, entry.name), to: directory.appendingPathComponent(entry.name), isDirectory: entry.isDirectory, isSymbolicLink: entry.kind == .symbolicLink, completion: nil)
        }
    }
    func download(host: String, remote: String, to destination: URL, isDirectory: Bool = false, isSymbolicLink: Bool = false, completion: ((Error?) -> Void)?) {
        if isSymbolicLink {
            enqueue(JobRecord(host: host, title: "リンク受信", target: remote, request: .symbolicLink(destination, remote, .download), completion: completion))
            return
        }
        if isDirectory {
            enqueue(JobRecord(host: host, title: "フォルダ受信", target: remote, request: .folder(destination, remote, .download), completion: completion))
            return
        }
        enqueue(JobRecord(host: host, title: "ダウンロード", target: remote, request: .download(remote, destination, openAfterDownload: false), completion: completion))
    }

    func retry(_ job: JobRecord) {
        if !jobs.contains(where: { $0.id == job.id }) {
            workspace.owner(of: job.id)?.retry(job)
            return
        }
        guard job.state == .failed else { return }
        if case let .mutation(verb, paths) = job.request {
            guard confirm("\(verb) を再実行しますか？", message: localized("接続先:") + " \(job.host)\n" + paths.joined(separator: "\n"), action: "再実行") else { return }
        }
        if case let .recursiveDelete(remote) = job.request {
            let message = "\(localized("接続先:")) \(job.host)\n\(localized("対象:")) \(remote)" + localized("\nフォルダ内の隠しファイルも削除します。リンク先はたどりません。ごみ箱には入らず、元に戻せません。")
            guard confirm("フォルダの再帰削除を再実行しますか？", message: message, action: "削除") else { return }
        }
        var new = JobRecord(host: job.host, title: job.title, target: job.target, request: job.request)
        if case let .listing(directory, _) = job.request {
            guard job.host == host else { errorMessage = "一覧取得を再実行するには、このHostへ接続してください。"; return }
            revision += 1
            new = JobRecord(host: job.host, title: job.title, target: job.target, request: .listing(directory, revision))
        }
        if case let .openLink(remote, destination, _) = job.request {
            guard job.host == host else { errorMessage = "一覧取得を再実行するには、このHostへ接続してください。"; return }
            cancelLinkInspection()
            revision += 1
            new = JobRecord(host: job.host, title: job.title, target: job.target, request: .openLink(remote, destination, revision))
        }
        enqueue(new)
    }

    lazy var directoryLinkIcon: NSImage = Self.linkIcon(base: NSWorkspace.shared.icon(for: .folder))
    private var fileLinkIcons: [String: NSImage] = [:]

    func fileLinkIcon(for name: String) -> NSImage? {
        guard let target = fileLinkTargets[name] else { return nil }
        let suffix = (target as NSString).pathExtension.lowercased()
        if let cached = fileLinkIcons[suffix] { return cached }
        let type = suffix.isEmpty ? UTType.data : (UTType(filenameExtension: suffix) ?? .data)
        let image = Self.linkIcon(base: NSWorkspace.shared.icon(for: type))
        fileLinkIcons[suffix] = image
        return image
    }

    private static func linkIcon(base: NSImage) -> NSImage {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        base.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 15, height: 15)).fill()
        NSColor.white.setStroke()
        let arrow = NSBezierPath()
        arrow.lineWidth = 1.8
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 4, y: 4))
        arrow.line(to: NSPoint(x: 11, y: 11))
        arrow.line(to: NSPoint(x: 6.5, y: 11))
        arrow.move(to: NSPoint(x: 11, y: 11))
        arrow.line(to: NSPoint(x: 11, y: 6.5))
        arrow.stroke()
        image.unlockFocus()
        return image
    }

    func infoDetails(_ entry: RemoteEntry, host: String, directory: String, original: String? = nil) -> String {
        var lines = [
            "\(localized("種類")): \(kindDescription(entry))",
            "\(localized("サイズ")): \(entry.size) \(localized("バイト"))",
            "\(localized("ホスト")): \(host)",
            "\(localized("場所")): \(SFTPCommand.join(directory, entry.name))",
            "\(localized("更新日")): \(entry.modified)"
        ]
        if let original { lines.append("\(localized("オリジナル")): \(original)") }
        lines.append("\(localized("所有者")): \(entry.owner)")
        lines.append("\(localized("アクセス権")): \(entry.permissions.dropFirst().prefix(9))")
        return lines.joined(separator: "\n")
    }

    func showInfo() {
        let items = selectedEntries
        let infoHost = host, infoPath = path
        func section(_ entry: RemoteEntry, original: String? = nil) -> String {
            let details = infoDetails(entry, host: infoHost, directory: infoPath, original: original)
            return items.count == 1 ? details : "\(entry.name)\n\n\(details)"
        }
        let sections = items.map { section($0) }
        let text = sections.joined(separator: "\n\n")
        let alert = NSAlert(); alert.messageText = items.count == 1 ? items[0].name : localized("情報"); alert.informativeText = text
        if selectedEntries.count == 1, let entry = selectedEntries.first {
            if entry.kind == .symbolicLink, directoryLinkNames.contains(entry.name) {
                alert.icon = directoryLinkIcon
            } else if entry.kind == .symbolicLink, let icon = fileLinkIcon(for: entry.name) {
                alert.icon = icon
            } else if entry.isRegularFile {
                let suffix = (entry.name as NSString).pathExtension.lowercased()
                let type = suffix.isEmpty ? UTType.data : (UTType(filenameExtension: suffix) ?? .data)
                alert.icon = NSWorkspace.shared.icon(for: type)
            } else if entry.isDirectory {
                alert.icon = NSWorkspace.shared.icon(for: .folder)
            } else {
                let symbol = entry.kind == .symbolicLink ? "link" : "doc"
                alert.icon = NSImage(systemSymbolName: symbol, accessibilityDescription: kindDescription(entry))?
                    .withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
            }
        }
        guard items.contains(where: { $0.kind == .symbolicLink }) else {
            alert.runModal()
            return
        }
        let unavailable = localized("リンク先を取得できません。")
        Task {
            var details = sections
            for (index, entry) in items.enumerated() where entry.kind == .symbolicLink {
                let result = await service.readLink(host: infoHost, path: SFTPCommand.join(infoPath, entry.name))
                if result.succeeded, !result.stdout.isEmpty,
                   (try? SFTPCommand.validatePath(result.stdout)) != nil {
                    let target = result.stdout.hasPrefix("/") ? result.stdout : SFTPCommand.join(infoPath, result.stdout)
                    details[index] = section(entry, original: target)
                } else {
                    details[index] = section(entry, original: unavailable)
                }
            }
            alert.informativeText = details.joined(separator: "\n\n")
            alert.runModal()
        }
    }

    func copyRemote(_ copy: RemoteCopyRequest) {
        let target = copy.source.description + " → " + copy.destinationDirectory.child(copy.source.name).description
        enqueue(JobRecord(host: copy.destinationDirectory.host, title: "リモート間コピー", target: target, request: .remoteCopy(copy)))
    }

    func clearFinishedHistory() {
        guard !hasRelatedWork else { return }
        hiddenOutgoingIDs.formUnion(outgoingJobs.filter { $0.state != .waiting && $0.state != .running }.map(\.id))
        jobs.removeAll { $0.state != .waiting && $0.state != .running }
        logSelection = nil
    }

    func cancelJob(_ id: UUID) {
        if activeJobID == id { executionTask?.cancel(); return }
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.state == .waiting }) else { return }
        let completion = jobs[index].completion
        jobs[index].state = .cancelled
        jobs[index].result = "中断しました"
        jobs[index].ended = Date()
        jobs[index].completion = nil
        completion?(CancellationError())
    }

    private func enqueue(_ job: JobRecord) {
        if busy, queueTask?.isCancelled == true {
            var cancelled = job
            cancelled.state = .cancelled
            cancelled.result = "中断しました"
            cancelled.ended = Date()
            cancelled.completion = nil
            jobs.append(cancelled)
            job.completion?(CancellationError())
            return
        }
        jobs.append(job)
        guard !busy else { return }
        busy = true
        queueTask = Task { await drain() }
    }

    func interrupt() {
        workspace.interruptOutgoing(from: self)
        cancelLinkInspection()
        guard busy else { return }
        queueTask?.cancel()
        executionTask?.cancel()
        status = "中断中…"
        // Settle pending promises too; no queued operation should start after stop.
        let pending = jobs.filter { $0.state == .waiting && $0.id != activeJobID }
        for job in pending {
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            jobs[index].state = .cancelled
            jobs[index].result = "中断しました"
            jobs[index].ended = Date()
            jobs[index].completion = nil
        }
        for job in pending { job.completion?(CancellationError()) }
    }

    private func drain() async {
        while !Task.isCancelled, let index = jobs.firstIndex(where: { $0.state == .waiting }) {
            let job = jobs[index]
            activeJobID = job.id
            let execution = Task<Void, Never> { @MainActor in
                var acquired = false
                defer { if acquired { self.workspace.scheduler.release(job.id) } }
                var staging: URL?
                var scope: URL?
                var completionError: Error?
                var downloadDestination: URL?
                var overwriteDownload = false
                do {
                    if case .listing = job.request {} else {
                        jobs[index].result = "実行待ち…"
                        try await workspace.scheduler.acquire(job.id)
                        acquired = true
                    }
                    try Task.checkCancellation()
                    jobs[index].state = .running; jobs[index].started = Date()
                    jobs[index].result = ""
                    status = "\(job.title): \(job.target)"
                    var request = job.request
                    var linkPreviewPath: String?
                    if case let .openLink(remote, destination, token) = request {
                        let kinds = await service.directoryLinks(host: job.host, paths: [remote])
                        try Task.checkCancellation()
                        guard job.host == host, token == revision else { throw CancellationError() }
                        guard let directory = kinds[remote] else { throw appError("リンク先の種類を確認できません: \(remote)。リンク切れやアクセス権を確認してください。") }
                        if !directory, AppPreferences.shared.doubleClickAction == .preview {
                            // Resolve the full chain so the preview reader can keep
                            // rejecting symbolic links when it reads the file.
                            linkPreviewPath = try await uploadFileSystem(index: index)
                                .realPath(RemoteEndpoint(host: job.host, path: remote))
                            try Task.checkCancellation()
                            guard job.host == host, token == revision else { throw CancellationError() }
                        } else {
                            request = directory ? .listing(remote, token) : .download(remote, destination, openAfterDownload: true)
                        }
                    }
                    if let linkPreviewPath {
                        preview.show(host: job.host, path: linkPreviewPath)
                    } else if case let .remoteCopy(copy) = request {
                        defer { self.workspace.refresh(host: copy.destinationDirectory.host) }
                        try await transferRemote(copy, index: index)
                    } else if case let .upload(local, remote) = request {
                        if local.startAccessingSecurityScopedResource() { scope = local }
                        try await transferUpload(local: local, remote: remote, job: job, index: index)
                    } else if case let .folder(local, remote, direction) = request {
                        if local.startAccessingSecurityScopedResource() { scope = local }
                        try await transferFolder(local: local, remote: remote, direction: direction, job: job, index: index)
                    } else if case let .symbolicLink(local, remote, direction) = request {
                        if local.startAccessingSecurityScopedResource() { scope = local }
                        if direction == .download {
                            // cd succeeds only for a directory target. A file or
                            // dangling link is copied as a link instead.
                            let probe = await service.run(host: job.host, commands: try SFTPCommand.listing(remote))
                            try Task.checkCancellation()
                            if probe.succeeded, (try DirectoryListing.parseChecked(probe.stdout)).path != nil {
                                try await transferFolder(local: local, remote: remote, direction: direction, job: job, index: index)
                            } else {
                                try await transferLink(local: local, remote: remote, direction: direction, job: job, index: index)
                            }
                        } else {
                            try await transferLink(local: local, remote: remote, direction: direction, job: job, index: index)
                        }
                    } else if case let .recursiveDelete(remote) = request {
                        // Refresh after partial failures as well, so the browser
                        // reflects any items already removed before the failure.
                        defer { if !Task.isCancelled, job.host == host, connected { refresh() } }
                        let deletion = RemoteDeletion(host: job.host, service: service, log: { result in
                            self.jobs[index].stdout += LogRedactor.redact(result.stdout)
                            self.jobs[index].stderr += LogRedactor.redact(result.stderr)
                            self.jobs[index].exitCode = result.exitCode
                        }, status: { message in self.jobs[index].result = message })
                        let count = try await deletion.removeFolder(at: remote)
                        jobs[index].result = "削除完了：\(count)項目"
                    } else {
                        let commands: [String]
                        switch request {
                        case let .listing(directory, _): commands = try SFTPCommand.listing(directory)
                        case .upload: preconditionFailure("Uploads use staged publication")
                        case let .download(remote, originalDestination, openAfterDownload):
                            if openAfterDownload {
                                try FileManager.default.createDirectory(at: originalDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            }
                            let resolved = try resolveDownloadDestination(originalDestination)
                            let destination = resolved.url
                            downloadDestination = destination
                            overwriteDownload = resolved.overwrite
                            let temp = destination.deletingLastPathComponent().appendingPathComponent(".opensftp-\(UUID().uuidString).partial")
                            // Transfer into a private file, then publish it only after success.
                            guard FileManager.default.createFile(atPath: temp.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw appError("ダウンロード先に書き込めません。") }
                            staging = temp
                            commands = try SFTPCommand.operation("get", remote, temp.path)
                        case .folder, .symbolicLink, .recursiveDelete, .openLink, .remoteCopy: preconditionFailure("Folder/link jobs use dedicated operations")
                        case let .mutation(verb, paths):
                            if verb == "rename" { commands = try SFTPCommand.operation(verb, paths[0], paths[1]) }
                            else { commands = try SFTPCommand.operation(verb, paths[0]) }
                        }
                        let jobID = job.id
                        let result = await service.run(host: job.host, commands: commands) { value in
                            await self.receiveProgress(value, jobID: jobID)
                        }
                        jobs[index].started = result.started; jobs[index].ended = result.ended
                        jobs[index].stdout = LogRedactor.redact(result.stdout)
                        jobs[index].stderr = LogRedactor.redact(result.stderr)
                        jobs[index].exitCode = result.exitCode
                        try Task.checkCancellation()
                        if let failure = result.failure { throw appError(explanation(failure, host: job.host)) }
                        switch request {
                        case let .listing(_, token):
                            let listing = try DirectoryListing.parseChecked(result.stdout)
                            guard let directory = listing.path else { throw appError("現在パスを解析できません。詳細ログを確認してください。") }
                            if job.host == host, token == revision {
                                recordNavigation(to: directory, navigation: job.navigation)
                                path = directory; entries = listing.entries
                                inspectDirectoryLinks(in: directory, token: token)
                                selection.formIntersection(Set(visibleEntries.map(\.id)))
                            }
                            if !listing.unparsed.isEmpty {
                                jobs[index].result = "完了（解析できない行: \(listing.unparsed.count)件。ログを確認）"
                            }
                        case let .download(_, originalDestination, openAfterDownload):
                            let destination = downloadDestination ?? originalDestination
                            if let staging {
                                if overwriteDownload {
                                    // Publish only after success; a failed transfer preserves the original.
                                    let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                                        throw appError("保存先の種類が変更されました: \(destination.path)")
                                    }
                                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging, backupItemName: nil, options: [.usingNewMetadataOnly])
                                } else { try FileManager.default.moveItem(at: staging, to: destination) }
                            }
                            if destination != originalDestination {
                                await logLocalDiff(original: originalDestination, saved: destination, index: index)
                                try Task.checkCancellation()
                            }
                            if openAfterDownload {
                                try openLocalFile(destination)
                                jobs[index].result = "保存して開きました"
                            } else {
                                jobs[index].result = "保存しました"
                            }
                        case .folder, .symbolicLink, .recursiveDelete, .openLink, .remoteCopy: preconditionFailure("Folder/link jobs use dedicated operations")
                        case .upload, .mutation:
                            if job.host == host, connected { refresh() }
                        }
                    }
                    try Task.checkCancellation()
                    jobs[index].state = .completed
                    if jobs[index].result.isEmpty { jobs[index].result = "完了" }
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError
                    jobs[index].state = cancelled ? .cancelled : .failed
                    jobs[index].result = cancelled ? "中断しました" : LogRedactor.redact(error.localizedDescription)
                    if !cancelled { errorMessage = jobs[index].result }
                    completionError = cancelled ? CancellationError() : error
                }
                progressRevealTask?.cancel()
                progressRevealTask = nil
                jobs[index].showProgress = false
                if let staging { try? FileManager.default.removeItem(at: staging) }
                if let scope { scope.stopAccessingSecurityScopedResource() }
                jobs[index].completion = nil
                jobs[index].ended = Date()
                job.completion?(completionError)
            }
            executionTask = execution
            await execution.value
            executionTask = nil
            activeJobID = nil
        }
        queueTask = nil
        busy = false
        status = connected ? host : "未接続"
        if refreshAfterPendingListing {
            refreshAfterPendingListing = false
            if !Task.isCancelled { refresh() }
        }
    }

    func cancelLinkInspection() {
        linkInspectionTask?.cancel()
        linkInspectionTask = nil
    }

    private func inspectDirectoryLinks(in directory: String, token: Int) {
        cancelLinkInspection()
        directoryLinkNames = []
        fileLinkTargets = [:]
        let paths = entries.filter { $0.kind == .symbolicLink }.map { SFTPCommand.join(directory, $0.name) }
        guard !paths.isEmpty else { return }
        let service = self.service, queryHost = host
        linkInspectionTask = Task { [weak self] in
            let targets = await service.linkIconTargets(host: queryHost, paths: paths)
            guard !Task.isCancelled, let self, self.host == queryHost, self.path == directory, self.revision == token else { return }
            self.directoryLinkNames = Set(targets.filter { $0.value.isDirectory }.map { ($0.key as NSString).lastPathComponent })
            self.fileLinkTargets = Dictionary(uniqueKeysWithValues: targets.compactMap { path, target in
                guard !target.isDirectory, let resolved = target.path else { return nil }
                return ((path as NSString).lastPathComponent, resolved)
            })
            self.updatePreviewSelection()
            self.linkInspectionTask = nil
        }
    }

    private func transferFolder(local: URL, remote: String, direction: FolderTransferDirection, job: JobRecord, index: Int) async throws {
        var method = FolderTransferMethod.sftp
        var methodTitle = method.rawValue
        var stdoutPrefix: String?, stderrPrefix: String?
        let transfer = FolderTransfer(host: job.host, service: service, rsync: rsync, fileSystem: uploadFileSystem(index: index), chooseMethod: { destinationExists in
            guard let selected = self.selectFolderMethod(destinationExists: destinationExists) else { return nil }
            method = selected
            methodTitle = selected.selectionTitle(destinationExists: destinationExists)
            self.jobs[index].result = methodTitle + "でフォルダを確認中…"
            return selected
        }, choosePolicy: { _ in method.policy }, skipConflict: { message in
            self.confirm("種類が異なる項目をスキップしますか？", message: self.localized(message) + self.localized("\n置き換えや削除は行いません。"), action: "スキップ")
        }, log: { result in
            self.jobs[index].stdout += LogRedactor.redact(result.stdout)
            self.jobs[index].stderr += LogRedactor.redact(result.stderr)
            self.jobs[index].exitCode = result.exitCode
        }, status: { message in
            self.jobs[index].result = message
        }, rsyncOutput: { stdout, stderr in
            if stdoutPrefix == nil {
                stdoutPrefix = self.jobs[index].stdout
                stderrPrefix = self.jobs[index].stderr
            }
            // Re-redact the entire accumulated stream so secrets and private
            // key bodies remain masked even when split across read boundaries.
            self.jobs[index].stdout = (stdoutPrefix ?? "") + LogRedactor.redact(stdout)
            self.jobs[index].stderr = (stderrPrefix ?? "") + LogRedactor.redact(stderr)
        })
        let summary = try await transfer.run(local: local, remote: remote, direction: direction) { [weak self] value in
            await self?.receiveProgress(value, jobID: job.id)
        }
        jobs[index].result = methodTitle + " · " + summary.description
        if direction == .upload, job.host == host, connected { refresh() }
    }

    private func transferLink(local: URL, remote: String, direction: FolderTransferDirection, job: JobRecord, index: Int) async throws {
        let transfer = FolderTransfer(host: job.host, service: service, fileSystem: uploadFileSystem(index: index), choosePolicy: { _ in .overwrite },
                                      skipConflict: { _ in false }, log: { result in
            self.jobs[index].stdout += LogRedactor.redact(result.stdout)
            self.jobs[index].stderr += LogRedactor.redact(result.stderr)
            self.jobs[index].exitCode = result.exitCode
        }, status: { message in self.jobs[index].result = message })
        try await transfer.runLink(local: local, remote: remote, direction: direction)
        jobs[index].result = "リンクをコピーしました"
        if direction == .upload, job.host == host, connected { refresh() }
    }

    private func transferRemote(_ copy: RemoteCopyRequest, index: Int) async throws {
        let fs: any RemoteFileSystem = remoteFileSystem ?? SFTPRemoteFileSystem(log: { [weak self] host, result in
            await self?.appendRemoteLog(host: host, result: result, index: index)
        })
        jobs[index].stdout = "scp・Mac経由\n\(copy.source.description) → \(copy.destinationDirectory.description)\n"
        let transfer = RemoteTransfer(fileSystem: fs, scp: scp, chooseFile: { conflict in
            if let choose = self.chooseFileConflict {
                switch choose(conflict.destination.description, conflict.alternative) {
                case .overwrite: return .overwrite
                case .keepBoth: return .keepBoth
                case .cancel: return .cancel
                }
            }
            let alert = NSAlert()
            alert.messageText = self.localized("同名のファイルが存在します")
            alert.informativeText = conflict.destination.description
            alert.addButton(withTitle: self.localized("上書き保存")).isEnabled = conflict.canOverwrite
            alert.addButton(withTitle: self.localized("{0}として保存").replacingOccurrences(of: "{0}", with: conflict.alternative))
            alert.addButton(withTitle: self.localized("キャンセル")).keyEquivalent = "\u{1b}"
            switch await self.presentRemoteAlert(alert) {
            case .alertFirstButtonReturn: return .overwrite
            case .alertSecondButtonReturn: return .keepBoth
            default: return .cancel
            }
        }, choosePolicy: { message in
            if let choose = self.chooseRemotePolicy { return choose(message) }
            let alert = NSAlert()
            alert.messageText = self.localized("フォルダの更新方法")
            alert.informativeText = message
            for title in ["更新分だけ", "すべて上書き", "キャンセル"] { alert.addButton(withTitle: self.localized(title)) }
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            switch await self.presentRemoteAlert(alert) {
            case .alertFirstButtonReturn: return .updatedOnly
            case .alertSecondButtonReturn: return .overwrite
            default: return nil
            }
        }, skipConflict: { message in
            let alert = NSAlert()
            alert.messageText = self.localized("種類が異なる項目をスキップしますか？")
            alert.informativeText = message
            alert.addButton(withTitle: self.localized("スキップ"))
            alert.addButton(withTitle: self.localized("キャンセル")).keyEquivalent = "\u{1b}"
            return await self.presentRemoteAlert(alert) == .alertFirstButtonReturn
        }, log: { host, result in
            self.appendRemoteLog(host: host, result: result, index: index)
        }, status: { message in self.jobs[index].result = message })
        let expectedKind: RemoteAttributes.Kind?
        switch copy.sourceKind {
        case .file?: expectedKind = .file
        case .directory?: expectedKind = .directory
        case .symbolicLink?: expectedKind = .symbolicLink
        case .other?: expectedKind = .other
        case nil: expectedKind = nil
        }
        let summary = try await transfer.run(source: copy.source, destinationDirectory: copy.destinationDirectory, expectedKind: expectedKind)
        jobs[index].result = summary.description
    }

    private func uploadFileSystem(index: Int) -> any RemoteFileSystem {
        remoteFileSystem ?? SFTPRemoteFileSystem(log: { [weak self] host, result in
            await self?.appendRemoteLog(host: host, result: result, index: index)
        })
    }

    private func transferUpload(local: URL, remote: String, job: JobRecord, index: Int) async throws {
        let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw appError("通常ファイルのみ転送できます。") }
        // Pin the canonical parent before showing the conflict dialog: a
        // directory changed while the user decides must fail later rechecks.
        let upload = try await RemoteUpload.prepare(
            directory: RemoteEndpoint(host: job.host, path: (remote as NSString).deletingLastPathComponent),
            fileSystem: uploadFileSystem(index: index), diagnostic: { message in
                self.jobs[index].stderr += LogRedactor.redact(message)
            })
        let proposed = try upload.destination(named: (remote as NSString).lastPathComponent)
        let resolved = try await resolveUploadDestination(proposed.path, host: job.host)
        let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value
        try await upload.upload(to: RemoteEndpoint(host: job.host, path: resolved.path), allowOverwrite: resolved.overwrite,
                                newFilePermissions: permissions) { temporary in
            let current = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard current.isRegularFile == true, current.isSymbolicLink != true else { throw self.appError("通常ファイルのみ転送できます。") }
            let result = await self.service.run(host: job.host, commands: try SFTPCommand.operation("put", local.path, temporary.path)) { value in
                await self.receiveProgress(value, jobID: job.id)
            }
            self.jobs[index].stdout += LogRedactor.redact(result.stdout)
            self.jobs[index].stderr += LogRedactor.redact(result.stderr)
            self.jobs[index].exitCode = result.exitCode
            try Task.checkCancellation()
            if let failure = result.failure { throw self.appError(self.explanation(failure, host: job.host)) }
        }
        if job.host == host, connected { refresh() }
    }

    private func appendRemoteLog(host: String, result: RunResult, index: Int) {
        jobs[index].stdout += LogRedactor.redact("[\(host)]\n" + result.stdout + "\n[exit: \(result.exitCode)]\n")
        jobs[index].stderr += LogRedactor.redact(result.stderr)
        jobs[index].exitCode = result.exitCode
    }

    private func presentRemoteAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard !Task.isCancelled else { return .abort }
        guard let window else { return .abort }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in continuation.resume(returning: response) }
                if Task.isCancelled { window.endSheet(alert.window, returnCode: .abort) }
            }
        }, onCancel: {
            Task { @MainActor in
                if alert.window.sheetParent != nil { window.endSheet(alert.window, returnCode: .abort) }
            }
        })
    }

    private func receiveProgress(_ value: TransferProgress, jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].state == .running else { return }
        let first = jobs[index].progress == nil
        jobs[index].progress = value
        jobs[index].progressUpdated = Date()
        guard first else { return }
        progressRevealTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, let index = self.jobs.firstIndex(where: { $0.id == jobID }),
                  self.jobs[index].state == .running else { return }
            self.jobs[index].showProgress = true
        }
    }

    private func explanation(_ failure: FailureKind, host: String) -> String {
        switch failure {
        case .launch: return "macOS標準のsftpを起動できません。"
        case .hostKeyMismatch: return "ホスト鍵が一致しません。管理者に確認し、ターミナルで sftp \(host) の接続を確認してください。"
        case .hostKeyUnknown: return "ホスト鍵が未登録です。ターミナルで sftp \(host) を実行し、ホスト鍵を確認・登録してください。"
        case .authentication: return "認証に失敗しました。ターミナルで sftp \(host) が成功するか確認してください。鍵・Agent・Keychainの準備が必要です。"
        case .network: return "接続に失敗、または切断されました。部分転送の可能性があります。ダウンロードの一時ファイルは削除します。アップロード先は確認してください。"
        case .operation: return "SFTP操作が失敗しました。権限・対象パスを詳細ログで確認してください。転送は一部のみ完了している可能性があります。"
        }
    }
    private func appError(_ message: String) -> NSError { NSError(domain: "OpenSFTP", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func availableCopyName(_ name: String, exists: (String) -> Bool) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        var n = 1
        while exists("\(stem)-\(n)\(suffix)") { n += 1 }
        return "\(stem)-\(n)\(suffix)"
    }

    private func selectFileConflict(destination: String, alternative: String) -> FileConflictChoice {
        if let chooseFileConflict { return chooseFileConflict(destination, alternative) }
        let alert = NSAlert()
        alert.messageText = localized("同名のファイルが存在します")
        alert.informativeText = destination
        alert.addButton(withTitle: localized("上書き保存"))
        alert.addButton(withTitle: localized("{0}として保存").replacingOccurrences(of: "{0}", with: alternative))
        alert.addButton(withTitle: localized("キャンセル"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .keepBoth
        default: return .cancel
        }
    }

    private func resolveUploadDestination(_ remote: String, host: String) async throws -> (path: String, overwrite: Bool) {
        let parent = (remote as NSString).deletingLastPathComponent
        let name = (remote as NSString).lastPathComponent
        let result = await service.run(host: host, commands: try SFTPCommand.listing(parent))
        try Task.checkCancellation()
        if let failure = result.failure { throw appError(explanation(failure, host: host)) }
        let listing = try DirectoryListing.parseChecked(result.stdout)
        guard listing.path != nil, listing.unparsed.isEmpty else {
            throw appError("フォルダ一覧を完全に解析できません: \(parent)")
        }
        guard let existing = listing.entries.first(where: { $0.name == name }) else { return (remote, false) }
        let names = Set(listing.entries.map(\.name))
        let alternative = Self.availableCopyName(name, exists: { names.contains($0) })
        switch selectFileConflict(destination: "\(host):\(remote)", alternative: alternative) {
        case .cancel: throw CancellationError()
        case .keepBoth: return (SFTPCommand.join(parent, alternative), false)
        case .overwrite:
            guard existing.kind == .file else { throw appError("同名のフォルダ・リンク等があるため転送できません: " + remote) }
            return (remote, true)
        }
    }

    private func resolveDownloadDestination(_ destination: URL) throws -> (url: URL, overwrite: Bool) {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        // Enumerating also detects dangling links, which fileExists does not.
        let names = Set(try fm.contentsOfDirectory(atPath: parent.path))
        guard names.contains(destination.lastPathComponent) else { return (destination, false) }
        let alternative = Self.availableCopyName(destination.lastPathComponent, exists: { names.contains($0) })
        switch selectFileConflict(destination: destination.path, alternative: alternative) {
        case .cancel: throw CancellationError()
        case .keepBoth: return (parent.appendingPathComponent(alternative), false)
        case .overwrite:
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw appError("保存先の種類が変更されました: \(destination.path)")
            }
            return (destination, true)
        }
    }

    private func logLocalDiff(original: URL, saved: URL, index: Int) async {
        jobs[index].stdout += "\n$ " + LogRedactor.redact(LocalDiff.commandLine(original: original, saved: saved)) + "\n"
        let result = await LocalDiff.run(original: original, saved: saved)
        jobs[index].stdout += LogRedactor.redact(result.stdout)
        jobs[index].stdout += "\n[diff exit: \(result.exitCode)]\n"
        if !result.stderr.isEmpty {
            jobs[index].stderr += "\n[diff]\n" + LogRedactor.redact(result.stderr)
        }
        // diff's exit code belongs to the comparison, not the successful transfer.
    }

    private func prompt(_ title: String, message: String, value: String) -> String? {
        let alert = NSAlert(); alert.messageText = localized(title); alert.informativeText = localized(message)
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        alert.accessoryView = field; alert.addButton(withTitle: localized("実行")); alert.addButton(withTitle: localized("キャンセル"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    private func confirm(_ title: String, message: String, action: String) -> Bool {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = localized(title); alert.informativeText = localized(message)
        alert.addButton(withTitle: localized(action)); alert.addButton(withTitle: localized("キャンセル"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

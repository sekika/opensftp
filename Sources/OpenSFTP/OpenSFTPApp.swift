import SwiftUI
import AppKit
import SFTPCore

@main
@MainActor
struct OpenSFTPApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("OpenSFTP", id: "browser") {
            BrowserWindow(delegate: delegate)
        }
        .defaultSize(width: WindowSizePreferences().restoredSize.width, height: WindowSizePreferences().restoredSize.height)
        .commands { BrowserCommands() }
    }
}

@MainActor
private struct BrowserWindow: View {
    let delegate: ApplicationDelegate
    @StateObject private var model = AppModel()
    @ObservedObject private var workspace = AppWorkspace.shared
    @ObservedObject private var preferences = AppPreferences.shared
    var body: some View {
        ContentView(model: model)
            .preferredColorScheme(preferences.appearance.colorTheme.colorScheme)
            .environment(\.locale, Locale(identifier: model.language.rawValue))
            .focusedSceneObject(model)
            .onReceive(workspace.$language.dropFirst()) { _ in
                DispatchQueue.main.async { delegate.localizeMenus() }
            }
            .frame(minWidth: CGFloat(preferences.appearance.minWindowWidth), minHeight: CGFloat(preferences.appearance.minWindowHeight))
            .background(MainWindowReader { window in delegate.attach(window, model: model) }.frame(width: 0, height: 0))
    }
}

@MainActor
private struct BrowserCommands: Commands {
    @FocusedObject private var focusedModel: AppModel?
    @ObservedObject private var workspace = AppWorkspace.shared
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(workspace.language == .japanese ? "OpenSFTP について" : "About OpenSFTP") {
                showBuildInformation()
            }
        }
        CommandGroup(replacing: .help) {
            Button(workspace.language == .japanese ? "OpenSFTPヘルプ" : "OpenSFTP Help") {
                openDocumentation(for: workspace.language)
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button(AppStrings.translate("設定…", to: workspace.language)) { openSettingsWindow() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button(AppStrings.translate("新規ウィンドウ", to: workspace.language)) { openWindow(id: "browser") }
                .keyboardShortcut("n")
        }
        if let model = focusedModel {
            CommandMenu(model.localized("接続")) {
                Button(model.localized("接続先候補を更新")) { workspace.reloadHosts() }
                Button(model.localized("再接続")) { model.connect() }.disabled(model.hasRelatedWork)
            }
            CommandMenu(model.localized("言語")) {
                Toggle("日本語", isOn: Binding(get: { workspace.language == .japanese }, set: { if $0 { workspace.setLanguage(.japanese) } }))
                Toggle("English", isOn: Binding(get: { workspace.language == .english }, set: { if $0 { workspace.setLanguage(.english) } }))
            }
            CommandMenu(model.localized("リモート")) {
                Button(model.localized("戻る")) { model.back() }.keyboardShortcut("[").disabled(!model.canGoBack)
                Button(model.localized("進む")) { model.forward() }.keyboardShortcut("]").disabled(!model.canGoForward)
                Button(model.localized("上位フォルダ")) { model.parent() }.keyboardShortcut(.upArrow, modifiers: .command).disabled(!model.connected)
                Button(model.localized("再読込")) { model.refresh() }.keyboardShortcut("r").disabled(!model.connected)
                Button(model.localized("フォルダ作成…")) { model.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!model.connected)
                Button(model.localized("ダウンロード…")) { model.downloadSelection() }.disabled(!model.canDownload)
                Button(model.localized("中断")) { model.interrupt() }.disabled(!model.hasRelatedWork)
                Button(model.localized("名前変更・移動…")) { model.rename() }.disabled(model.selectedEntries.count != 1 || !model.canModify)
                Button(model.localized("削除…")) { model.deleteSelection() }.keyboardShortcut(.delete, modifiers: .command).disabled(!model.canModify)
            }
            CommandGroup(after: .toolbar) {
                Toggle(model.localized("接続バーを表示"), isOn: Binding(get: { model.showConnectionBar }, set: { model.showConnectionBar = $0 }))
                Toggle(model.localized("全体のステータスバーを表示"), isOn: Binding(get: { model.showStatusBar }, set: { model.showStatusBar = $0 }))
                Toggle(model.localized("フォルダのステータスバーを表示"), isOn: Binding(get: { model.showFolderStatusBar }, set: { model.showFolderStatusBar = $0 }))
                Toggle(model.localized("隠しファイルを表示"), isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 })).keyboardShortcut(".", modifiers: [.command, .shift])
                Toggle(model.localized("アイコン表示"), isOn: Binding(get: { model.iconView }, set: { model.iconView = $0 }))
                Toggle(model.localized("転送・操作キューを表示"), isOn: Binding(get: { model.showQueue }, set: { model.showQueue = $0 })).keyboardShortcut("k", modifiers: [.command, .shift])
                Toggle(model.localized("実行ログを表示"), isOn: Binding(get: { model.showLogs }, set: { model.showLogs = $0 })).keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }

    private func showBuildInformation() {
        let language = workspace.language
        let japanese = language == .japanese
        let alert = NSAlert()
        alert.messageText = "OpenSFTP"
        alert.icon = NSApp.applicationIconImage
        let bundle = Bundle.main
        let repositoryLabel = japanese ? "リポジトリ" : "Repository"
        let repository = bundle.object(forInfoDictionaryKey: "OpenSFTPBuildRepository") as? String
        var lines = ["\(repositoryLabel): \(repository ?? (japanese ? "不明" : "Unknown"))"]
        if let commit = bundle.object(forInfoDictionaryKey: "OpenSFTPBuildCommit") as? String,
           let date = bundle.object(forInfoDictionaryKey: "OpenSFTPBuildCommitDate") as? String {
            let commitLabel = japanese ? "コミット" : "Commit"
            let dateLabel = japanese ? "コミット日時" : "Commit date"
            lines.append("\(commitLabel): \(commit.prefix(12))")
            lines.append("\(dateLabel): \(date)")
            if bundle.object(forInfoDictionaryKey: "OpenSFTPBuildDirty") as? Bool == true {
                lines.append(japanese ? "ローカルの変更を含むビルドです。" : "This build includes local changes.")
            }
        } else {
            lines.append(japanese ? "コミット情報はありません。" : "Commit information is unavailable.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: japanese ? "ドキュメントを開く" : "Open Documentation")
        if alert.runModal() == .alertSecondButtonReturn {
            openDocumentation(for: language)
        }
    }

    private func openDocumentation(for language: AppLanguage) {
        let address = language == .japanese
            ? "https://sekika.github.io/opensftp/ja/"
            : "https://sekika.github.io/opensftp/"
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var windows: [ObjectIdentifier: BrowserWindowDelegate] = [:]
    func attach(_ window: NSWindow, model: AppModel) {
        let name = model.windowNumber == 0 ? "OpenSFTP" : "OpenSFTP \(model.windowNumber)"
        window.title = model.connected ? "\(name) — \(model.host):\(model.path)" : name
        guard windows[ObjectIdentifier(window)] == nil else { return }
        model.window = window
        model.workspace.register(model)
        window.isRestorable = false
        window.contentMinSize = WindowSizePreferences.minimum
        window.setContentSize(WindowSizePreferences().restoredSize)
        let observer = BrowserWindowDelegate(model: model, previous: window.delegate) { [weak self] window in
            self?.didClose(window)
        }
        windows[ObjectIdentifier(window)] = observer
        window.delegate = observer
        NSApp.activate(ignoringOtherApps: true)
        localizeMenus()
    }
    private func didClose(_ window: NSWindow) {
        if let observer = windows.removeValue(forKey: ObjectIdentifier(window)), let model = observer.model {
            WindowSizePreferences().save(window.contentRect(forFrameRect: window.frame).size)
            model.workspace.unregister(model)
            model.window = nil
        }
        // Browser windows, rather than transient sheets/panels, define lifetime.
        DispatchQueue.main.async { [weak self] in
            if self?.windows.isEmpty == true { NSApp.terminate(nil) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        for observer in windows.values { observer.model?.cancelLinkInspection(); observer.model?.preview.close() }
        if let window = NSApp.orderedWindows.first(where: { windows[ObjectIdentifier($0)] != nil }) {
            WindowSizePreferences().save(window.contentRect(forFrameRect: window.frame).size)
        }
    }
    func localizeMenus() {
        guard let menu = NSApp.mainMenu else { return }
        let language = AppWorkspace.shared.language
        @MainActor func update(_ menu: NSMenu) {
            for item in menu.items {
                item.title = AppStrings.translate(item.title, to: language)
                if let submenu = item.submenu { submenu.title = AppStrings.translate(submenu.title, to: language); update(submenu) }
            }
        }
        update(menu)
    }
    func applicationDidBecomeActive(_ notification: Notification) { localizeMenus() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "png"), let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.localizeMenus() }
        }
        NotificationCenter.default.addObserver(forName: .appearancePreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateWindowMinimumSizes() }
        }
    }
    func updateWindowMinimumSizes() {
        let minSize = WindowSizePreferences().minimum
        for window in windows.values.compactMap(\.model?.window) {
            window.contentMinSize = minSize
            let contentRect = window.contentRect(forFrameRect: window.frame)
            if contentRect.width < minSize.width || contentRect.height < minSize.height {
                var newRect = contentRect
                newRect.size.width = max(contentRect.width, minSize.width)
                newRect.size.height = max(contentRect.height, minSize.height)
                let newFrame = window.frameRect(forContentRect: newRect)
                window.setFrame(newFrame, display: true, animate: true)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model = AppWorkspace.shared.openModels.first(where: { $0.hasRelatedWork }) {
            let alert = NSAlert()
            alert.messageText = model.localized("ジョブを実行しています")
            alert.informativeText = model.localized("転送が完了してからアプリを終了してください。")
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
}

/// Preserve SwiftUI's delegate callbacks while adding per-window close guards.
@MainActor
private final class BrowserWindowDelegate: NSObject, NSWindowDelegate {
    weak var model: AppModel?
    private let previous: (any NSWindowDelegate)?
    private let close: (NSWindow) -> Void
    init(model: AppModel, previous: (any NSWindowDelegate)?, close: @escaping (NSWindow) -> Void) {
        self.model = model; self.previous = previous; self.close = close
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let model, model.hasRelatedWork {
            if sender.attachedSheet == nil {
                let alert = NSAlert()
                alert.messageText = model.localized("ジョブを実行しています")
                let jobs = model.displayedJobs.filter { $0.state == .waiting || $0.state == .running }
                alert.informativeText = model.localized("関連する転送の完了を待つか、中断してから閉じてください。")
                    + "\n\n" + jobs.prefix(5).map { model.localized($0.title) + ": " + $0.target }.joined(separator: "\n")
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: sender)
            }
            return false
        }
        return previous?.windowShouldClose?(sender) ?? true
    }
    func windowWillClose(_ notification: Notification) {
        let originalDelegate = previous
        if let window = notification.object as? NSWindow { close(window) }
        originalDelegate?.windowWillClose?(notification)
    }
    func windowDidBecomeKey(_ notification: Notification) { previous?.windowDidBecomeKey?(notification) }
    nonisolated override func responds(to selector: Selector!) -> Bool {
        MainActor.assumeIsolated { super.responds(to: selector) || previous?.responds(to: selector) == true }
    }
    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        let target = MainActor.assumeIsolated {
            DelegateTarget(value: previous?.responds(to: selector) == true ? previous : nil)
        }
        return target.value ?? super.forwardingTarget(for: selector)
    }
}

// assumeIsolated checks the main executor before reading the delegate; the
// wrapper keeps its generic result Sendable without claiming AppKit is so.
private struct DelegateTarget: @unchecked Sendable { let value: Any? }

@MainActor
func openSettingsWindow() {
    SettingsWindowManager.shared.show()
}

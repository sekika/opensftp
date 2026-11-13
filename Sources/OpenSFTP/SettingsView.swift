import SwiftUI
import AppKit
import SFTPCore

public enum SettingsTab: Hashable, Sendable {
    case appearance
    case connection
    case limits
    case files
}

public struct SettingsView: View {
    @ObservedObject var preferences = AppPreferences.shared
    @ObservedObject var workspace = AppWorkspace.shared

    public init() {}

    public var body: some View {
        TabView {
            AppearanceSettingsView(preferences: preferences)
                .tabItem {
                    Label(AppStrings.translate("外観", to: workspace.language), systemImage: "paintpalette")
                }
                .tag(SettingsTab.appearance)

            ConnectionSettingsView(preferences: preferences)
                .tabItem {
                    Label("rsync", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(SettingsTab.connection)

            Form {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppStrings.translate("ファイルのダブルクリック時", to: workspace.language))
                    Picker("", selection: $preferences.doubleClickAction) {
                        Text(AppStrings.translate("プレビュー", to: workspace.language)).tag(AppPreferences.DoubleClickAction.preview)
                        Text(AppStrings.translate("ダウンロードして開く", to: workspace.language)).tag(AppPreferences.DoubleClickAction.download)
                    }.pickerStyle(.radioGroup)
                    Divider()
                    Text(AppStrings.translate("ダウンロード先", to: workspace.language))
                    HStack {
                        Text(preferences.downloadDirectory.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button(AppStrings.translate("選択…", to: workspace.language)) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                            panel.directoryURL = preferences.downloadDirectory
                            if panel.runModal() == .OK, let url = panel.url { preferences.downloadDirectory = url }
                        }
                    }
                }
            }
            .padding(20)
            .tabItem { Label((workspace.language == .english ? "Interaction" : "操作"), systemImage: "doc") }
            .tag(SettingsTab.files)

            LimitsSettingsView(preferences: preferences)
                .tabItem { Label(AppStrings.translate("上限", to: workspace.language), systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.limits)
        }
        .preferredColorScheme(preferences.appearance.colorTheme.colorScheme)
    }
}

private struct LimitsSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject private var workspace = AppWorkspace.shared
    private func tr(_ text: String) -> String { AppStrings.translate(text, to: workspace.language) }

    private func number(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String, initial: Int) -> some View {
        HStack {
            Text(tr(title))
            Spacer()
            TextField("", value: value, format: .number)
                .frame(width: 95).textFieldStyle(.roundedBorder)
                .help("\(range.lowerBound)–\(range.upperBound)")
                .onSubmit { value.wrappedValue = min(range.upperBound, max(range.lowerBound, value.wrappedValue)) }
            Text(tr(unit)).frame(width: 44, alignment: .leading)
            Text(tr("初期値") + ": \(initial)").font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
        }
    }
    var body: some View {
        ScrollView {
            Form {
                Section(header: Text(tr("ファイル一覧"))) {
                    number("1フォルダの最大項目数", value: $preferences.limits.listingEntries, range: 1...1_000_000, unit: "件", initial: 100_000)
                    number("一覧の最大取得量", value: $preferences.limits.listingMiB, range: 1...256, unit: "MiB", initial: 64)
                    Text(tr("超過時は一覧取得と、その一覧を使う転送・削除を中止します。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(header: Text(tr("フォルダ処理"))) {
                    number("再帰走査の最大総項目数", value: $preferences.limits.traversalEntries, range: 1...5_000_000, unit: "件", initial: 1_000_000)
                    number("最大階層数", value: $preferences.limits.traversalDepth, range: 1...256, unit: "階層", initial: 128)
                    Text(tr("SFTPのフォルダ転送・再帰削除・リモート間コピーに適用します。超過時は計画を中止します。rsyncの走査には適用しません。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(header: Text(tr("ログ・差分"))) {
                    number("ログの最大保持量", value: $preferences.limits.logMiB, range: 1...64, unit: "MiB", initial: 4)
                    number("差分の最大取得量", value: $preferences.limits.diffMiB, range: 1...64, unit: "MiB", initial: 8)
                    Text(tr("ログは各ジョブの標準出力・標準エラーごとに制限し、以降を省略して処理を続けます。差分は超過時に比較を中止します。保存済みファイルは残ります。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(header: Text(tr("プレビュー"))) {
                    number("テキストプレビューの行数", value: $preferences.preview.lines, range: 1...1000, unit: "行", initial: 50)
                    number("テキスト・抽出情報の最大取得量", value: $preferences.limits.previewTextMiB, range: 1...50, unit: "MiB", initial: 1)
                    number("画像・動画の最大取得量", value: $preferences.preview.binaryMiB, range: 1...50, unit: "MiB", initial: 5)
                    number("プレビューの処理時間", value: $preferences.limits.previewTimeoutSeconds, range: 1...300, unit: "秒", initial: 30)
                    Text(tr("取得量・処理時間を超えると表示を中止します。時間はコマンドごと、テキスト取得量は次の1行を含みます。HexDumpは先頭256 Bです。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(tr("画像は寸法を確認し、表示用に縮小します。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(tr("変更は次に開始する処理から反映します。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("初期値に戻す")) { preferences.resetLimits() }
                }
            }.padding(20)
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject private var workspace = AppWorkspace.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(AppStrings.translate("配色", to: workspace.language))
                        .frame(width: 130, alignment: .leading)
                    Picker("", selection: $preferences.appearance.colorTheme) {
                        Text(AppStrings.translate("システム設定に従う", to: workspace.language)).tag(AppColorTheme.system)
                        Text(AppStrings.translate("ライト", to: workspace.language)).tag(AppColorTheme.light)
                        Text(AppStrings.translate("ダーク", to: workspace.language)).tag(AppColorTheme.dark)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(AppStrings.translate("幅", to: workspace.language))
                            .frame(width: 80, alignment: .leading)
                        TextField("", value: $preferences.appearance.minWindowWidth, format: .number)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                        Text("pt")
                        Stepper("", value: $preferences.appearance.minWindowWidth, in: 400...1600, step: 20)
                            .labelsHidden()
                        Spacer()
                    }
                    HStack {
                        Text(AppStrings.translate("高さ", to: workspace.language))
                            .frame(width: 80, alignment: .leading)
                        TextField("", value: $preferences.appearance.minWindowHeight, format: .number)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                        Text("pt")
                        Stepper("", value: $preferences.appearance.minWindowHeight, in: 300...1200, step: 20)
                            .labelsHidden()
                        Spacer()
                    }
                }
            } header: {
                Text(AppStrings.translate("最小ウィンドウサイズ", to: workspace.language))
                    .font(.headline)
            }

            Divider().padding(.vertical, 8)

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(AppStrings.translate("タイルの大きさ", to: workspace.language))
                            .frame(width: 130, alignment: .leading)
                        Slider(value: $preferences.appearance.iconSize, in: AppearancePreferences.iconSizeRange, step: 2) {
                            Text(AppStrings.translate("タイルの大きさ", to: workspace.language))
                        }
                        Text("\(Int(preferences.appearance.iconTileWidth)) pt")
                            .frame(width: 55, alignment: .trailing)
                            .monospacedDigit()
                    }
                    HStack {
                        Text(AppStrings.translate("ファイル名の行数", to: workspace.language))
                            .frame(width: 130, alignment: .leading)
                        Picker("", selection: $preferences.appearance.iconLabelLines) {
                            ForEach(1...5, id: \.self) { count in
                                Text(AppStrings.translate(count == 1 ? "1行" : "\(count)行", to: workspace.language)).tag(count)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                }
            } header: {
                Text(AppStrings.translate("アイコン表示", to: workspace.language))
                    .font(.headline)
            }

            Divider().padding(.vertical, 8)

            HStack {
                Spacer()
                Button(AppStrings.translate("初期値に戻す", to: workspace.language)) {
                    preferences.resetAppearance()
                }
            }
        }
        .padding(20)
    }
}

struct ConnectionSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject private var workspace = AppWorkspace.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $preferences.connection.rsyncExtendedAttributes) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppStrings.translate("拡張属性 (-E) を保持する", to: workspace.language))
                            Text(AppStrings.translate("macOS のリソースフォークや拡張属性を転送します。サーバー側の rsync が対応していない場合は無効にしてください。", to: workspace.language))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                        }
                    }
                    Toggle(isOn: $preferences.connection.rsyncCompression) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppStrings.translate("転送圧縮 (-z) を有効にする", to: workspace.language))
                            Text(AppStrings.translate("ネットワーク経由の転送時にデータを圧縮します。", to: workspace.language))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider().padding(.vertical, 8)

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(AppStrings.translate("接続タイムアウト", to: workspace.language))
                            .frame(width: 160, alignment: .leading)
                        TextField("", value: $preferences.connection.connectTimeout, format: .number)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Text(AppStrings.translate("秒", to: workspace.language))
                        Stepper("", value: $preferences.connection.connectTimeout, in: 1...300, step: 5)
                            .labelsHidden()
                        Spacer()
                    }
                    HStack {
                        Text(AppStrings.translate("生存確認の間隔", to: workspace.language))
                            .frame(width: 160, alignment: .leading)
                        TextField("", value: $preferences.connection.serverAliveInterval, format: .number)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Text(AppStrings.translate("秒（0で無効）", to: workspace.language))
                        Stepper("", value: $preferences.connection.serverAliveInterval, in: 0...300, step: 5)
                            .labelsHidden()
                        Spacer()
                    }
                    HStack {
                        Text(AppStrings.translate("生存確認の最大回数", to: workspace.language))
                            .frame(width: 160, alignment: .leading)
                        TextField("", value: $preferences.connection.serverAliveCountMax, format: .number)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Text(AppStrings.translate("回", to: workspace.language))
                        Stepper("", value: $preferences.connection.serverAliveCountMax, in: 1...20, step: 1)
                            .labelsHidden()
                        Spacer()
                    }
                }
            }

            Divider().padding(.vertical, 8)

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(AppStrings.translate("ホスト鍵の厳格チェック", to: workspace.language))
                            .frame(width: 160, alignment: .leading)
                        Picker("", selection: $preferences.connection.strictHostKeyChecking) {
                            Text(AppStrings.translate("厳格 (yes)", to: workspace.language)).tag("yes")
                            Text(AppStrings.translate("新規ホストを自動追加 (accept-new)", to: workspace.language)).tag("accept-new")
                            Text(AppStrings.translate("無効 (no)", to: workspace.language)).tag("no")
                        }
                        .frame(width: 230)
                        Spacer()
                    }
                    HStack(alignment: .top) {
                        Text(AppStrings.translate("追加の SSH オプション", to: workspace.language))
                            .frame(width: 160, alignment: .leading)
                        VStack(alignment: .leading) {
                            Toggle("TCPKeepAlive=yes", isOn: tcpKeepAliveBinding)
                        }
                    }
                }
            }

            Divider().padding(.vertical, 8)

            HStack {
                Spacer()
                Button(AppStrings.translate("初期値に戻す", to: workspace.language)) {
                    preferences.resetConnection()
                }
            }
        }
        .padding(20)
    }

    private var tcpKeepAliveBinding: Binding<Bool> {
        Binding(
            get: { preferences.connection.extraOptions.contains("-oTCPKeepAlive=yes") },
            set: { enabled in
                var options = preferences.connection.extraOptions
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty && $0 != "-oTCPKeepAlive=yes" }
                if enabled { options.append("-oTCPKeepAlive=yes") }
                preferences.connection.extraOptions = options.joined(separator: " ")
            }
        )
    }
}

@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?

    func show() {
        if let window = self.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let title = AppStrings.translate("設定", to: AppWorkspace.shared.language)
        let defaults = UserDefaults.standard
        let width = max(640, defaults.double(forKey: "settingsWindowWidth"))
        let height = max(560, defaults.double(forKey: "settingsWindowHeight"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.contentViewController = hosting
        window.minSize = NSSize(width: 640, height: 560)
        window.setFrameAutosaveName("OpenSFTP.SettingsWindow")
        _ = window.setFrameUsingName("OpenSFTP.SettingsWindow")
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowSize()
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowSize()
        self.window = nil
    }

    private func saveWindowSize() {
        guard let window else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        let defaults = UserDefaults.standard
        defaults.set(size.width, forKey: "settingsWindowWidth")
        defaults.set(size.height, forKey: "settingsWindowHeight")
    }
}

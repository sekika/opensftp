import SwiftUI
import SFTPCore

@MainActor
struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if model.showConnectionBar {
                connectionBar
                Divider()
            }
            navigationAndPanels
        }
        .background(PreviewPresenter(preview: model.preview, language: model.language))
        .alert(model.localized("操作を完了できませんでした"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(model.localized("ログを表示")) { model.showLogs = true; model.logSelection = model.jobs.last(where: { $0.state == .failed })?.id; model.errorMessage = nil }
            Button(model.localized("閉じる"), role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.localized(model.errorMessage ?? "")) }
    }

    private var connectionBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "network").foregroundStyle(.tint).font(.title2)
            Text("OpenSFTP").font(.headline)
            Divider().frame(height: 22)
            TextField(model.localized("Host または user@host"), text: $model.hostInput).textFieldStyle(.roundedBorder)
                .onSubmit { model.connect() }.disabled(model.hasRelatedWork)
            Menu {
                if model.hosts.isEmpty { Text(model.localized("~/.ssh/config に候補がありません")) }
                ForEach(model.hosts, id: \.self) { host in Button(host) { model.hostInput = host } }
                Divider()
                Button(model.localized("候補を更新")) { model.workspace.reloadHosts() }
            } label: { Image(systemName: "chevron.down") }.frame(width: 38).disabled(model.hasRelatedWork)
            Button(model.localized("接続する")) { model.connect() }.buttonStyle(.borderedProminent).disabled(model.hasRelatedWork || model.hostInput.isEmpty)
        }.padding(14)
    }

    private var navigationAndPanels: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.back() } label: { Image(systemName: "chevron.left") }.help(model.localized("戻る（⌘[）")).disabled(!model.canGoBack)
                Button { model.forward() } label: { Image(systemName: "chevron.right") }.help(model.localized("進む（⌘]）")).disabled(!model.canGoForward)
                Button { model.parent() } label: { Image(systemName: "arrow.up") }.help(model.localized("上位フォルダ（⌘↑）")).disabled(!model.connected)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help(model.localized("再読込（⌘R）")).disabled(!model.connected)
                Text(model.path.isEmpty ? model.localized("未接続") : model.path).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                Toggle(isOn: $model.showHidden) { Image(systemName: model.showHidden ? "eye" : "eye.slash") }.toggleStyle(.button).help(model.localized("隠しファイル（⌘⇧.）"))
                Picker(model.localized("表示方式"), selection: $model.iconView) {
                    Image(systemName: "list.bullet").tag(false)
                    Image(systemName: "square.grid.2x2").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 84)
                Button { model.newFolder() } label: { Image(systemName: "folder.badge.plus") }.disabled(!model.connected).help(model.localized("フォルダ作成"))
                Button { model.downloadSelection() } label: { Image(systemName: "square.and.arrow.down") }.disabled(!model.canDownload).help(model.localized("選択項目をダウンロード"))
                Button { model.deleteSelection() } label: { Image(systemName: "trash") }.disabled(!model.canModify).help(model.localized("削除"))
            }.padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            VSplitView {
                folder.frame(minHeight: 190, idealHeight: 300, maxHeight: .infinity)
                if model.showQueue {
                    queue.frame(minHeight: 110, idealHeight: 180, maxHeight: .infinity)
                }
                if model.showLogs {
                    logs.frame(minHeight: 100, idealHeight: 170, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showStatusBar {
                Divider()
                statusBar
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(model.hasRelatedWork ? Color.orange : model.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(!model.busy && model.hasRelatedWork ? model.localized("リモート間送信中…") : (model.connected && model.status == model.host ? model.host : model.localized(model.status)))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if model.hasRelatedWork { ProgressView().controlSize(.small) }
            if model.hasRelatedWork {
                Button { model.interrupt() } label: { Label(model.localized("中断"), systemImage: "stop.fill") }
                    .help(model.localized("実行中の処理と待機中のジョブを中断"))
            }
            Button { model.showQueue.toggle() } label: { Label(model.localized("キュー"), systemImage: "list.bullet.rectangle") }
                .help(model.showQueue ? model.localized("転送・操作キューを非表示（⌘⇧K）") : model.localized("転送・操作キューを表示（⌘⇧K）"))
            Button { model.showLogs.toggle() } label: { Label(model.localized("ログ"), systemImage: "terminal") }
        }.font(.caption).padding(10)
    }

    private var folder: some View {
        VStack(spacing: 0) {
            RemoteBrowser(model: model).frame(minHeight: 140, maxHeight: .infinity)
            if model.showFolderStatusBar {
                Divider()
                HStack {
                    Text(model.localized("\(model.visibleEntries.count)項目 · \(model.selection.count)項目を選択"))
                    Spacer()
                    if model.selectedEntries.contains(where: { !$0.isRegularFile && !$0.isDirectory && $0.kind != .symbolicLink }) {
                        Text(model.localized("特殊ファイルは転送対象外"))
                    } else {
                        Text(model.localized("Finderからドロップでアップロード · Finderへドラッグでダウンロード"))
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(model.localized("転送・操作キュー")).font(.headline)
                Text(model.localized("\(model.displayedJobs.filter { $0.state == .waiting || $0.state == .running }.count)件待機・実行中")).foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button(model.localized("完了履歴を消去")) { model.clearFinishedHistory() }
                    .disabled(model.hasRelatedWork).font(.caption)
            }.padding(.horizontal, 14).padding(.top, 9)
            Table(model.displayedJobs, selection: $model.logSelection) {
                TableColumn(model.localized("操作")) { job in Text(model.localized(model.outgoingJobs.contains(where: { $0.id == job.id }) ? "リモート間送信（参照）" : job.title)).lineLimit(1).help(model.localized(job.title)) }.width(min: 100, ideal: 135, max: 170)
                TableColumn(model.localized("接続先・対象")) { job in Text(displayedTarget(job)).lineLimit(1).truncationMode(.middle).help(job.target) }
                TableColumn(model.localized("状態")) { job in
                    QueueJobCell(model: model, jobID: job.id, column: .state)
                }.width(90)
                TableColumn(model.localized("開始")) { job in
                    QueueJobCell(model: model, jobID: job.id, column: .started)
                }.width(78)
                TableColumn(model.localized("結果")) { job in
                    QueueJobCell(model: model, jobID: job.id, column: .result)
                        .frame(height: 44)
                }.width(min: 150, ideal: 300)
            }.frame(minHeight: 70, maxHeight: .infinity)
        }
    }
    private var logs: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.outgoingJobs.contains(where: { $0.id == model.logSelection }) {
                Text(model.localized("詳細ログはコピー先ウィンドウに表示します")).foregroundStyle(.secondary)
                Button(model.localized("コピー先を表示")) {
                    if let id = model.logSelection, let destination = model.workspace.owner(of: id) {
                        destination.logSelection = id
                        destination.showLogs = true
                        destination.window?.makeKeyAndOrderFront(nil)
                    }
                }
            } else if let job = model.jobs.first(where: { $0.id == model.logSelection }) ?? model.jobs.last {
                Text("\(job.id.uuidString) · \(job.host) · \(model.localized(job.title))").font(.caption).foregroundStyle(.secondary)
                ScrollView(.vertical) {
                    Text(logText(job))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { Text(model.localized("操作を実行するとログが表示されます")).foregroundStyle(.secondary) }
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func logText(_ job: JobRecord) -> String {
        [
            model.localized("開始") + ": " + (job.started?.description ?? "—"),
            model.localized("終了") + ": " + (job.ended?.description ?? "—"),
            model.localized("終了コード") + ": " + (job.exitCode.map { String($0) } ?? "—"),
            model.localized("結果") + ": " + model.localized(job.result),
            "\nstdout:\n" + job.stdout, "\nstderr:\n" + job.stderr
        ].joined(separator: "\n")
    }

    private func displayedTarget(_ job: JobRecord) -> String {
        if case .remoteCopy = job.request { return job.target }
        if case .listing(nil, _) = job.request { return job.host + ":" + model.localized("ホーム") }
        return job.host + ":" + job.target
    }
}

// Table can retain a cell for the same row identity. Subscribe inside the cell
// so progress and completion use the latest record, rather than a captured value.
@MainActor
private struct QueueJobCell: View {
    enum Column { case state, started, result }
    @ObservedObject var model: AppModel
    let jobID: UUID
    let column: Column

    var body: some View {
        if let job = model.displayedJobs.first(where: { $0.id == jobID }) {
            switch column {
            case .state:
                Text(model.localized(job.state.rawValue))
                    .foregroundStyle(job.state == .failed ? Color.red : job.state == .completed ? Color.green : Color.primary)
            case .started:
                if let started = job.started { Text(started, style: .time) } else { Text("—") }
            case .result:
                HStack {
                    if job.showProgress, let progress = job.progress {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let stale = context.date.timeIntervalSince(job.progressUpdated ?? .distantPast) > 5
                            VStack(alignment: .leading, spacing: 2) {
                                if case .folder = job.request {
                                    Text(model.localized(job.result)).font(.caption2).lineLimit(1).help(model.localized(job.result))
                                }
                                ProgressView(value: progress.fraction)
                                Text(model.localized("\(Int(progress.fraction * 100))% · 約\(AppStrings.byteCountDescription(progress.transferred, language: model.language)) · \(stale ? "—" : progress.speed) · 残り\(model.localized(stale ? "—" : progress.remaining))"))
                                    .font(.caption2).lineLimit(1)
                            }
                        }
                    } else {
                        Text(model.localized(job.result)).lineLimit(1).help(model.localized(job.result))
                    }
                    if case .remoteCopy = job.request, job.state == .waiting || job.state == .running {
                        Button(model.localized("中断")) { (model.workspace.owner(of: job.id) ?? model).cancelJob(job.id) }.controlSize(.small)
                    }
                    if job.state == .failed {
                        Button(model.localized("再実行")) { model.retry(job) }.controlSize(.small)
                    }
                }
            }
        }
    }
}

import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case japanese = "ja", english = "en"

    public static func systemDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        let first = preferredLanguages.first?.lowercased().replacingOccurrences(of: "_", with: "-")
        guard let first else { return .english }
        return first == "ja" || first.hasPrefix("ja-") ? .japanese : .english
    }
}

/// Localizes presentation text without changing stored job data, protocol
/// output, file names, or paths. {0}, {1}, … are opaque interpolation values.
public enum AppStrings {
    public static func byteCount(_ bytes: Int64, language: AppLanguage) -> String {
        ByteCountFormatStyle(style: .file, spellsOutZero: false,
                             locale: Locale(identifier: language == .japanese ? "ja_JP" : "en_US")).format(bytes)
    }

    /// Folder progress may contain a size formatted before the language switch.
    /// Reformat byte-valued descriptions; abbreviated KB/MB/etc. stay unchanged.
    public static func byteCountDescription(_ source: String, language: AppLanguage) -> String {
        let pattern = #"^([0-9][0-9,\s]*)\s*(?:バイト|bytes?)$"#
        if let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
           let range = Range(match.range(at: 1), in: source),
           let bytes = Int64(source[range].filter { $0.isNumber }) {
            return byteCount(bytes, language: language)
        }
        if source == "Zero KB" { return "0 KB" }
        return source
    }

    public static func translate(_ source: String, to language: AppLanguage) -> String {
        if language == .japanese {
            return reverse[source] ?? source
        }
        if let value = catalog[source] { return value }
        for method in ["SFTP", "SFTP: 更新分だけ", "SFTP: すべて上書き", "rsync", "rsync --delete"] {
            let prefix = method + " · "
            if source.hasPrefix(prefix) {
                return translate(method, to: language) + " · " + translate(String(source.dropFirst(prefix.count)), to: language)
            }
        }
        if source.hasPrefix("完了：") {
            let counts = source.dropFirst("完了：".count).components(separatedBy: "・")
            return "Completed: " + counts.map { translate($0, to: language) }.joined(separator: ", ")
        }
        for rule in rules {
            if let translated = rule.translate(source) { return translated }
        }
        return source
    }

    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String
        let localizeFailure: Bool
        init(source: String, replacement: String) {
            let matches = placeholders.matches(in: source, range: NSRange(source.startIndex..., in: source))
            var pattern = "\\A", cursor = source.startIndex
            for match in matches {
                let range = Range(match.range, in: source)!
                pattern += NSRegularExpression.escapedPattern(for: String(source[cursor..<range.lowerBound])) + "([\\s\\S]*?)"
                cursor = range.upperBound
            }
            pattern += NSRegularExpression.escapedPattern(for: String(source[cursor...])) + "\\z"
            self.regex = try! NSRegularExpression(pattern: pattern)
            self.replacement = replacement
            self.localizeFailure = source.hasPrefix("{0}。") || source == "{0}でフォルダを確認中…"
        }
        func translate(_ source: String) -> String? {
            guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
            var result = "", cursor = replacement.startIndex
            for placeholder in placeholders.matches(in: replacement, range: NSRange(replacement.startIndex..., in: replacement)) {
                let range = Range(placeholder.range, in: replacement)!
                result += replacement[cursor..<range.lowerBound]
                let index = Int(replacement[Range(placeholder.range(at: 1), in: replacement)!])! + 1
                guard index < match.numberOfRanges, let valueRange = Range(match.range(at: index), in: source) else { return nil }
                let value = String(source[valueRange])
                result += localizeFailure && index == 1 ? catalog[value] ?? value : value
                cursor = range.upperBound
            }
            result += replacement[cursor...]
            return result
        }
    }
    private static let placeholders = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
    private static let rules = catalog.filter { $0.key.contains("{0}") }
        .sorted { $0.key.count > $1.key.count }
        .map { Rule(source: $0.key, replacement: $0.value) }
    private static let reverse = Dictionary(catalog.filter { !$0.key.contains("{0}") }.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

    private static let catalog: [String: String] = [
        "行": "lines",
        "行番号を表示": "Show line numbers",
        "ファイルのダブルクリック時": "When a file is double-clicked",
        "ダウンロードして開く": "Download and Open",
        "ダウンロード先": "Download Location",
        "選択…": "Choose…",
        "メディア情報を解析できません": "Unable to parse media information",
        "gzipの内容はテキストではありません": "The gzip contents are not text",
        "Word文書の本文を解析できません": "Unable to parse the Word document",
        "行数を取得できません": "Unable to retrieve the line count",
        "ファイル名に制御文字が含まれるためプレビューできません": "Cannot preview because the file name contains control characters",
        "実行コマンド": "Command",
        "標準エラー": "Standard Error",
        "標準出力": "Standard Output",
        "SSHコマンドが利用できないか、必要なツールがないためプレビューできません。\n{0}": "Preview is unavailable because SSH commands or required tools are unavailable.\n{0}",
        "代表フレームを取得できません: {0}": "Unable to retrieve a representative frame: {0}",
        "文字コードを判別できません: {0}": "Unable to decode character encoding: {0}",
        "対応していない文字コードです: {0}": "Unsupported character encoding: {0}",
        "gzipのテキスト内容": "Gzip text contents",
        "NULを検出したためHexDumpで表示します": "NUL detected; showing HexDump",
        "※装飾・表・画像を除く簡易テキストプレビュー": "Simplified text preview without formatting, tables or images",
        "PDFの先頭3ページから抽出したテキスト": "Text extracted from the first three PDF pages",
        "PDFの表示": "PDF View",
        "テキスト": "Text",
        "1ページ目": "First Page",
        "PDFの1ページ目": "First page of the PDF",
        "SSHコマンドが利用できないためプレビューできません（fileの応答を確認できません）": "Preview is unavailable because SSH commands cannot be used (invalid response from file)",
        "SSHコマンドが利用できないためプレビューできません": "Preview is unavailable because SSH commands cannot be used",
        "取得サイズが上限を超えたため表示できません": "The preview exceeds the maximum size",
        "テキストが1ページの取得上限（{0} MiB）を超えています。ダウンロードして確認してください。": "The text exceeds the {0} MiB limit per page. Download the file to view it.",
        "上限": "Limits",
        "ファイル一覧": "File Listings",
        "1フォルダの最大項目数": "Maximum items per folder",
        "一覧の最大取得量": "Maximum listing size",
        "フォルダ処理": "Folder Operations",
        "再帰走査の最大総項目数": "Maximum total scanned items",
        "最大階層数": "Maximum folder depth",
        "ログ・差分": "Logs and Diffs",
        "ログの最大保持量": "Maximum retained log size",
        "差分の最大取得量": "Maximum diff size",
        "テキスト・抽出情報の最大取得量": "Maximum text and extracted information size",
        "プレビューの処理時間": "Preview command timeout",
        "プレビューの処理時間が上限を超えたため表示を中止しました。": "Stopped the preview because the command time limit was exceeded.",
        "初期値": "Default",
        "件": "items", "階層": "levels",
        "超過時は一覧取得と、その一覧を使う転送・削除を中止します。": "Exceeding a limit stops the listing and any transfer or deletion using it.",
        "SFTPのフォルダ転送・再帰削除・リモート間コピーに適用します。超過時は計画を中止します。rsyncの走査には適用しません。": "Applies to SFTP folder transfers, recursive deletion, and remote copies. Exceeding a limit stops planning. Rsync scans are excluded.",
        "ログは各ジョブの標準出力・標準エラーごとに制限し、以降を省略して処理を続けます。差分は超過時に比較を中止します。保存済みファイルは残ります。": "Logs are limited separately for each job's stdout and stderr; further output is omitted while the operation continues. Exceeding the diff limit stops comparison and keeps saved files.",
        "取得量・処理時間を超えると表示を中止します。時間はコマンドごと、テキスト取得量は次の1行を含みます。HexDumpは先頭256 Bです。": "Exceeding the size or time limit stops the preview. Time is per command; text includes one lookahead line. HexDump shows the first 256 bytes.",
        "変更は次に開始する処理から反映します。": "Changes apply to subsequently started operations.",
        "一覧が上限を超えたため取得を中止しました。": "Stopped retrieving the listing because it exceeds a limit.",
        "フォルダ処理の総項目数が上限を超えたため中止しました。": "Stopped because the total scanned item limit was exceeded.",
        "フォルダ階層が上限を超えたため中止しました。": "Stopped because the folder depth limit was exceeded.",
        "差分が取得上限を超えたため比較を中止しました。": "Stopped comparison because the diff size limit was exceeded.",
        "テキストが1ページの取得上限（1 MiB）を超えています。ダウンロードして確認してください。": "The text exceeds the 1 MiB limit per page. Download the file to view it.",
        "サイズ・日時・ファイル名": "Size, date and file name",
        "この画像形式を表示できません": "This image format cannot be displayed",
        "画像・動画の最大取得量": "Maximum image and video frame transfer size",
        "画像は寸法を確認し、表示用に縮小します。": "Image dimensions are checked before creating a display thumbnail.",
        "画像の寸法を確認できません。": "Cannot determine the image dimensions.",
        "画像の縮小表示を作成できません。": "Cannot create an image thumbnail.",
        "画像のファイルサイズを確認できません。": "Cannot determine the image file size.",
        "画像が取得上限を超えています。ダウンロードして確認してください。": "The image exceeds the transfer size limit. Download the file to view it.",
        "画像の寸法が上限（5,000万画素・各辺16,384ピクセル）を超えています。ダウンロードして確認してください。": "The image exceeds the limit of 50 million pixels or 16,384 pixels per side. Download the file to view it.",
        "動画のフレーム寸法を確認できないか、上限を超えています。": "Video frame dimensions are unavailable or exceed the limit.",
        "通常ファイルを一つ選択してください": "Select one regular file",
        "空のファイル": "Empty file",
        "最後": "Last",
        "次": "Next",
        "前": "Previous",
        "先頭": "First",
        "テキスト・目次の受信上限は1 MiB、HexDumpは先頭256 Bです。": "Text and archive output is limited to 1 MiB; HexDump shows the first 256 bytes.",
        "バイナリプレビューの最大取得サイズ": "Maximum binary preview size",
        "テキストプレビューの行数": "Text preview lines",
        "プレビュー": "Preview",
        "Terminalで開く（less）": "Open in Terminal (less)",
        "Terminalを開けませんでした: {0}": "Could not open Terminal: {0}",
        "Terminalの操作が許可されていません。システム設定の「プライバシーとセキュリティ → オートメーション」でOpenSFTPからTerminalへの操作を許可してください。": "Terminal automation is not permitted. Allow OpenSFTP to control Terminal in System Settings > Privacy & Security > Automation.",
        "新規ウィンドウ": "New Window", "リモート間コピー": "Remote Copy",
        "リモート間送信（参照）": "Outgoing Copy (Reference)", "リモート間送信中…": "Sending remote copy…",
        "詳細ログはコピー先ウィンドウに表示します": "Detailed logs are shown in the destination window",
        "コピー先を表示": "Show Destination",
        "フォルダの更新方法": "Folder Update", "更新分だけ": "Updated Files Only", "すべて上書き": "Overwrite All",
        "実行待ち…": "Waiting to run…", "走査中…": "Scanning…", "保存を確定中…": "Finalizing…",
        "転送中：{0}/{1} · {2}": "Copying: {0}/{1} · {2}", "転送中：{0}": "Copying: {0}",
        "関連する転送の完了を待つか、中断してから閉じてください。": "Wait for related transfers to finish, or stop them before closing this window.",
        "リモート間コピーにはOpenSSH 9以降のscpが必要です。旧SCP方式への自動切替は行いません。": "Remote copying requires scp from OpenSSH 9 or later. Legacy SCP is not used as a fallback.",
        "SSH接続設定を確認できません: {0}": "Cannot inspect SSH connection settings: {0}",
        "プロセスを起動できません: {0}": "Cannot start process: {0}",
        "ルートフォルダはコピーできません。": "The root directory cannot be copied.",
        "コピー元が存在しません: {0}": "The copy source does not exist: {0}",
        "ファイルサイズを取得できません: {0}": "Cannot determine file size: {0}",
        "コピー先は通常のフォルダにしてください。": "The destination must be a regular directory.",
        "同じフォルダ、または互いの配下へはコピーできません。": "Cannot copy a folder onto itself or between overlapping directory trees.",
        "同じファイル、または種類の異なる項目には上書きできません。": "Cannot overwrite the same file or an item of a different type.",
        "特殊ファイルは転送対象外です。": "Special files cannot be transferred.",
        "フォルダが128階層以上あるため中止しました。": "Stopped because the directory tree is 128 levels or deeper.",
        "フォルダ一覧に重複した名前があります。": "The directory listing contains duplicate names.",
        "scpによる転送に失敗しました。詳細ログを確認してください。": "The scp transfer failed. See the detailed logs.",
        "転送計画後に項目が変更されました: {0}": "An item changed after planning: {0}",
        "転送先を確認できません。": "Cannot verify the upload destination.",
        "保存先のアクセス権を取得できません: {0}": "Cannot read the destination permissions: {0}",
        "サーバーは既存項目の原子的な置換に対応していません。": "The server does not support atomic replacement of existing items.",
        "SFTP操作に失敗しました: {0}": "The SFTP operation failed: {0}",
        "SFTP操作用のSSHを起動できません。": "Cannot start SSH for the SFTP operation.",
        "SFTP応答を解析できません。": "Cannot parse the SFTP response.",
        "SFTP応答が途切れました。": "The SFTP response was interrupted.",
        "SFTP応答の長さが不正です。": "The SFTP response length is invalid.",
        "SFTPの名前がUTF-8ではありません。": "An SFTP name is not valid UTF-8.",
        "SFTP属性が多すぎます。": "Too many SFTP attributes.", "未対応のSFTP属性です。": "Unsupported SFTP attributes.",
        "ホスト": "Host", "場所": "Location", "更新日": "Modified", "所有者": "Owner", "アクセス権": "Permissions",
        "オリジナル": "Original", "リンク先を取得できません。": "Cannot read the link target.",
        "言語": "Language", "接続": "Connection", "リモート": "Remote",
        "接続先候補を更新": "Reload Host List", "再接続": "Reconnect",
        "戻る": "Back", "進む": "Forward", "上位フォルダ": "Parent Folder", "再読込": "Refresh",
        "フォルダ作成…": "New Folder…", "ダウンロード…": "Download…", "名前変更・移動…": "Rename or Move…", "削除…": "Delete…",
        "隠しファイルを表示": "Show Hidden Files", "アイコン表示": "Icon View",
        "転送・操作キューを表示": "Show Transfer Queue", "実行ログを表示": "Show Logs",
        "フォルダのステータスバーを表示": "Show Folder Status Bar",
        "全体のステータスバーを表示": "Show Main Status Bar",
        "接続バーを表示": "Show Connection Bar",
        "Host または user@host": "Host or user@host", "~/.ssh/config に候補がありません": "No hosts in ~/.ssh/config",
        "候補を更新": "Reload Hosts", "接続する": "Connect", "未接続": "Not connected",
        "戻る（⌘[）": "Back (⌘[)", "進む（⌘]）": "Forward (⌘])", "上位フォルダ（⌘↑）": "Parent Folder (⌘↑)",
        "再読込（⌘R）": "Refresh (⌘R)", "隠しファイル（⌘⇧.）": "Hidden Files (⌘⇧.)",
        "表示方式": "View Mode", "フォルダ作成": "New Folder", "選択項目をダウンロード": "Download Selection",
        "削除": "Delete", "特殊ファイルは転送対象外": "Special files cannot be transferred",
        "Finderからドロップでアップロード · Finderへドラッグでダウンロード": "Drop from Finder to upload · Drag to Finder to download",
        "中断": "Cancel", "実行中の処理と待機中のジョブを中断": "Cancel the active operation and queued jobs",
        "キュー": "Queue", "ログ": "Logs", "転送・操作キューを非表示（⌘⇧K）": "Hide Transfer Queue (⌘⇧K)",
        "転送・操作キューを表示（⌘⇧K）": "Show Transfer Queue (⌘⇧K)",
        "操作を完了できませんでした": "The operation could not be completed", "ログを表示": "Show Logs", "閉じる": "Close",
        "転送・操作キュー": "Transfer Queue", "完了履歴を消去": "Clear Finished Jobs",
        "操作": "Operation", "接続先・対象": "Host / Target", "状態": "Status", "開始": "Started", "終了": "Finished",
        "終了コード": "Exit Code", "結果": "Result", "操作を実行するとログが表示されます": "Logs appear here after an operation starts",
        "待機中": "Waiting", "実行中": "Running", "完了": "Completed", "失敗": "Failed",
        "リモートファイル一覧": "Remote Files", "名前": "Name", "種類": "Kind", "サイズ": "Size", "更新時刻": "Modified",
        "ファイル": "File", "フォルダ": "Folder", "シンボリックリンク": "Symbolic Link", "その他": "Other", "バイト": "bytes",
        "このフォルダに表示する項目はありません": "No items to display in this folder", "Hostを入力して接続してください": "Enter a host to connect",
        "開く": "Open", "Finderへダウンロード…": "Download to Finder…", "情報を見る": "Get Info",
        "リンクを開く": "Open Link",
        "リンク先の種類を確認できません: {0}。リンク切れやアクセス権を確認してください。": "Cannot determine the link target type: {0}. Check for a broken link or missing permissions.",
        "転送方法を選択してください。": "Choose a transfer method.",
        "フォルダの転送方法": "Folder Transfer", "SFTP: 更新分だけ": "SFTP: Updated Files Only", "SFTP: すべて上書き": "SFTP: Overwrite All",
        "同名のファイルが存在します": "A file with the same name already exists",
        "上書き保存": "Overwrite", "{0}として保存": "Save as {0}",
        "キャンセル": "Cancel", "スキップ": "Skip", "上書き": "Overwrite", "再実行": "Retry", "実行": "Run",
        "新しいフォルダ": "New Folder", "名前変更・移動": "Rename or Move", "同名ファイルを上書きしますか？": "Overwrite existing files?",
        "ダウンロード先を選択": "Choose Download Folder", "フォルダの再帰削除を再実行しますか？": "Retry recursive folder deletion?",
        "情報": "Info", "一覧取得": "List Folder", "ホーム": "Home", "取得して開く": "Download and Open",
        "フォルダ削除": "Delete Folder", "フォルダ送信": "Upload Folder", "アップロード": "Upload",
        "リンク受信": "Download Link", "フォルダ受信": "Download Folder", "ダウンロード": "Download",
        "中断しました": "Cancelled", "中断中…": "Cancelling…", "保存して開きました": "Saved and opened",
        "保存しました": "Saved", "リンクをコピーしました": "Link copied", "接続先を選択してください": "Select a host",
        "種類が異なる項目をスキップしますか？": "Skip items with conflicting types?",
        "フォルダを確認中…": "Checking folder…", "rsync 転送中…": "Transferring with rsync…", "rsync --delete 転送中…": "Transferring with rsync --delete…",
        "完了（詳細はログを確認）": "Completed (see logs for details)", "計算中": "Calculating", "—（停滞中）": "— (stalled)",
        "ジョブを実行しています": "Jobs are running", "転送が完了してからアプリを終了してください。": "Wait for transfers to finish before quitting.",
        "接続先:": "Host:", "対象:": "Target:", "フォルダと配下をすべて削除": "Delete folder and all contents", "ファイルを削除": "Delete file",
        "\n置き換えや削除は行いません。": "\nNo items will be replaced or deleted.",
        "\nフォルダ内の隠しファイルも削除します。リンク先はたどりません。ごみ箱には入らず、元に戻せません。": "\nHidden files inside folders will also be deleted. Symbolic links are not followed. Items are not moved to Trash and cannot be restored.",
        "~/.ssh/config を読み込めません。アクセス権とUTF-8形式を確認してください。": "Cannot read ~/.ssh/config. Check its permissions and UTF-8 encoding.",
        "通常ファイルのみ転送できます。": "Only regular files can be transferred.",
        "通常ファイル・フォルダ・シンボリックリンクのみ転送できます。対象外: {0}": "Only regular files, folders, and symbolic links can be transferred. Unsupported: {0}",
        "同名のフォルダ・リンク等があるため転送できません: {0}": "A folder, link, or other item with the same name prevents transfer: {0}",
        "一覧取得を再実行するには、このHostへ接続してください。": "Connect to this host before retrying its folder listing.",
        "ダウンロード先に書き込めません。": "Cannot write to the download destination.",
        "現在パスを解析できません。詳細ログを確認してください。": "Cannot parse the current path. See the detailed logs.",
        "保存先に同名の項目が存在します。": "An item with the same name already exists at the destination.",
        "保存先に同名の項目が存在します: {0}": "An item with the same name already exists at the destination: {0}",
        "転送元: {0}\n転送先: {1}": "Source: {0}\nDestination: {1}",
        "{0}:{1} に作成する名前": "Name to create in {0}:{1}",
        "{0}\n新しい名前、または移動先の絶対パス": "{0}\nEnter a new name or an absolute destination path",
        "{0}項目を削除しますか？": "Delete {0} items?", "{0} を再実行しますか？": "Retry {0}?",
        "削除完了：{0}項目": "Deleted {0} items", "完了（解析できない行: {0}件。ログを確認）": "Completed ({0} unparsed lines; see logs)",
        "{0}でフォルダを確認中…": "Checking folder with {0}…", "フォルダを確認中：{0}": "Checking folder: {0}",
        "{0}/{1}件 · {2}": "{0}/{1} items · {2}", "rsync転送中：{0}ファイル": "rsync: transferring {0} items",
        "転送{0}件": "{0} transferred", "スキップ{0}件": "{0} skipped", "フォルダ作成{0}件": "folders created: {0}", "削除{0}件": "{0} deleted",
        "[秘密鍵出力をマスク]": "[Private key output masked]", "[認証情報の可能性がある行をマスク]": "[Possible credentials masked]",
        "{0}項目 · {1}項目を選択": "{0} items · {1} selected", "{0}項目、{1}項目を選択": "{0} items, {1} selected",
        "{0}件待機・実行中": "{0} queued or running", "{0}% · 約{1} · {2} · 残り{3}": "{0}% · about {1} · {2} · {3} remaining", "約{0}": "about {0}",
        "接続先は Host 名または user@host で入力してください。オプション、URL、ポート・パス指定は使用できません。": "Enter a host name or user@host. Options, URLs, ports, and paths are not accepted.",
        "パスに改行、NUL、制御文字は使用できません。": "Paths cannot contain newlines, NUL, or control characters.",
        "名前は空欄、.、..、スラッシュを含む値にできません。": "Names cannot be empty, '.', '..', or contain a slash.",
        "macOS標準のsftpを起動できません。": "Cannot start the macOS sftp client.",
        "macOS標準のsftpを起動できません。接続先と実行環境を確認してください。": "Cannot start the macOS sftp client. Check the host and execution environment.",
        "転送用sftpを起動できません。": "Cannot start sftp for the transfer.",
        "ホスト鍵が一致しません。管理者に確認し、ターミナルで sftp {0} の接続を確認してください。": "The host key does not match. Contact the administrator and verify the connection with sftp {0} in Terminal.",
        "ホスト鍵が未登録です。ターミナルで sftp {0} を実行し、ホスト鍵を確認・登録してください。": "The host key is not registered. Run sftp {0} in Terminal to verify and register it.",
        "認証に失敗しました。ターミナルで sftp {0} が成功するか確認してください。鍵・Agent・Keychainの準備が必要です。": "Authentication failed. Check that sftp {0} succeeds in Terminal and that your key, agent, and Keychain are ready.",
        "接続に失敗、または切断されました。部分転送の可能性があります。ダウンロードの一時ファイルは削除します。アップロード先は確認してください。": "The connection failed or was lost. Transfers may be incomplete. Temporary downloads are removed; check uploaded files on the server.",
        "SFTP操作が失敗しました。権限・対象パスを詳細ログで確認してください。転送は一部のみ完了している可能性があります。": "The SFTP operation failed. Check permissions and paths in the detailed logs. Transfers may be incomplete.",
        "sftp起動失敗": "sftp launch failed", "ホスト鍵不一致": "Host key mismatch", "ホスト鍵未登録": "Unknown host key",
        "認証失敗": "Authentication failed", "接続失敗・切断": "Connection failed or lost", "操作失敗": "Operation failed",
        "{0}。フォルダ転送は一部のみ完了している可能性があります。詳細ログを確認してください。": "{0}. The folder transfer may be incomplete. See the detailed logs.",
        "rsyncを起動できません。/usr/bin/rsyncを確認してください。": "Cannot start rsync. Check /usr/bin/rsync.",
        "rsyncを起動できません。ローカルの /usr/bin/rsync を確認してください。": "Cannot start rsync. Check the local /usr/bin/rsync.",
        "rsync転送に失敗しました（終了コード: {0}）。接続先でrsyncとSSHのコマンド実行が使えることを確認してください。詳細はログに記録しています。": "rsync failed (exit code: {0}). Check that rsync and SSH command execution are available on the remote host. See the logs for details.",
        "転送先・転送元には名前のあるフォルダを指定してください。": "Select a named folder as the transfer source or destination.",
        "アップロード元は通常のフォルダにしてください。": "The upload source must be a regular folder.", "ダウンロード元は通常のフォルダにしてください。": "The download source must be a regular folder.",
        "{0}\nフォルダと異なる種類の項目が存在します。": "{0}\nAn existing item is not a folder.",
        "{0}\n種類が異なる項目、またはリンクが存在します。": "{0}\nAn existing item has a different type or is a link.",
        "フォルダ一覧を完全に解析できません: {0}": "Cannot fully parse the folder listing: {0}",
        "フォルダ階層が深すぎます（上限128階層）。": "The folder tree exceeds the limit of 128 levels.",
        "種類の衝突によりフォルダ転送を中止しました。": "The folder transfer was cancelled because item types conflict.",
        "転送元はリンクではありません。": "The source is not a symbolic link.",
        "転送元が見つかりません: {0}": "Source not found: {0}", "転送元の種類が変更されました: {0}": "The source item type changed: {0}",
        "転送元のリンクが変更されました: {0}": "The source link changed: {0}", "転送先の種類が変更されました: {0}": "The destination item type changed: {0}",
        "保存先の種類が変更されました: {0}": "The destination item type changed: {0}",
        "保存先が転送計画後に変更されました: {0}": "The destination changed after planning: {0}",
        "保存先フォルダの種類が変更されました。": "The destination folder type changed.", "転送先フォルダの種類が変更されました。": "The remote destination folder type changed.",
        "一時ファイルを作成できません: {0}": "Cannot create a temporary file: {0}", "転送中にフォルダの種類が変更されました: {0}": "A folder type changed during transfer: {0}",
        "転送対象がフォルダの範囲外です: {0}": "The transfer item is outside the selected folder: {0}",
        "リンクの名前が曖昧か、フォルダが変更されています: {0}": "Link names are ambiguous or the folder changed: {0}",
        "リンク先フォルダを取得できません: {0}": "Cannot access the linked folder: {0}",
        "リンク先を取得できません: {0}。詳細ログを確認してください。": "Cannot read the link target: {0}. See the detailed logs.",
        "リンク先を取得できません（SFTP {0}）: {1}": "Cannot read the link target (SFTP {0}): {1}",
        "SFTPのリンク先応答を解析できません。": "Cannot parse the SFTP link target response.", "リンク先取得用のSSHを起動できません。": "Cannot start SSH to read the link target.",
        "ドラッグ先の保存フォルダを取得できません。保存先指定メニューを利用してください。": "Cannot determine the drop destination. Use the Download menu to choose a folder.",
        "フォルダ転送用のドラッグデータを登録できません。": "Cannot register drag data for the folder transfer.",
        "削除対象を確認中…": "Checking items to delete…", "削除対象を確認中：{0}": "Checking items to delete: {0}",
        "削除 {0}/{1}件 · {2}": "Deleting {0}/{1} items · {2}",
        "削除対象にはルート以外のフォルダの絶対パスを指定してください。": "Deletion requires an absolute folder path other than the filesystem root.",
        "削除対象が通常のフォルダではないか、見つかりません: {0}": "The item to delete is missing or is not a regular folder: {0}",
        "削除対象が128階層を超えています。削除は開始していません。": "The tree exceeds 128 levels. No items have been deleted.",
        "削除対象が指定範囲外です。": "An item to delete is outside the selected folder.",
        "削除対象が確認後に変更されました: {0}。一部の項目は削除済みの可能性があります。": "An item changed after confirmation: {0}. Some items may already have been deleted.",
        "削除中にフォルダの種類が変更されました: {0}。リンク先へは移動しません。": "A folder type changed during deletion: {0}. Its link target will not be followed.",
        "削除対象の一覧を完全に解析できません: {0}": "Cannot fully parse the deletion listing: {0}",
        "リンクの名前を安全に確認できません: {0}": "Cannot safely verify link names: {0}",
        "一覧の名前が一致しません。リンクの名前が曖昧か、フォルダが変更されています: {0}": "Listing names do not match. Link names are ambiguous or the folder changed: {0}",
        "{0}。削除を中止しました。一部の項目は削除済みの可能性があります。詳細ログを確認してください。": "{0}. Deletion stopped; some items may already have been deleted. See the detailed logs.",
        "編集": "Edit", "表示": "View", "ウインドウ": "Window", "ヘルプ": "Help",
        "OpenSFTPについて": "About OpenSFTP", "OpenSFTPを終了": "Quit OpenSFTP", "OpenSFTPを隠す": "Hide OpenSFTP",
        "ほかを隠す": "Hide Others", "すべてを表示": "Show All", "サービス": "Services",
        "取り消す": "Undo", "やり直す": "Redo", "カット": "Cut", "コピー": "Copy", "ペースト": "Paste", "すべてを選択": "Select All",
        "しまう": "Minimize", "拡大／縮小": "Zoom", "すべてを手前に移動": "Bring All to Front",
        "ツールバーを表示": "Show Toolbar", "ツールバーを非表示": "Hide Toolbar",
        "フルスクリーンにする": "Enter Full Screen", "フルスクリーンを解除": "Exit Full Screen", "ウインドウを閉じる": "Close Window",
        "設定": "Settings", "設定…": "Settings…", "外観": "Appearance",
        "最小ウィンドウサイズ": "Minimum Window Size",
        "幅": "Width", "高さ": "Height",
        "アイコンの大きさ": "Icon Size", "ファイル名の行数": "Filename Lines",
        "配色": "Appearance", "システム設定に従う": "System", "ライト": "Light", "ダーク": "Dark",
        "タイルの大きさ": "Tile Size",
        "タブバーを表示": "Show Tab Bar",
        "1行": "1 line", "2行": "2 lines", "3行": "3 lines", "4行": "4 lines", "5行": "5 lines",
        "初期値に戻す": "Reset to Defaults",
        "rsync 設定": "rsync Settings",
        "拡張属性 (-E) を保持する": "Preserve Extended Attributes (-E)",
        "macOS のリソースフォークや拡張属性を転送します。サーバー側の rsync が対応していない場合は無効にしてください。": "Transfers macOS resource forks and extended attributes. Disable if the remote rsync does not support -E.",
        "転送圧縮 (-z) を有効にする": "Enable Transfer Compression (-z)",
        "ネットワーク経由の転送時にデータを圧縮します。": "Compresses data during network transfer.",
        "SSH タイムアウト設定": "SSH Timeout Settings",
        "接続タイムアウト": "Connect Timeout",
        "生存確認の間隔": "Server Alive Interval",
        "生存確認の最大回数": "Server Alive Count Max",
        "秒": "seconds", "回": "times", "秒（0で無効）": "seconds (0 to disable)",
        "その他の接続設定": "Other Connection Settings",
        "ホスト鍵の厳格チェック": "Strict Host Key Checking",
        "厳格 (yes)": "Strict (yes)",
        "新規ホストを自動追加 (accept-new)": "Accept New Hosts (accept-new)",
        "無効 (no)": "Disabled (no)",
        "空欄または0で既定": "Blank or 0 for default",
        "追加の SSH オプション": "Additional SSH Options",
        "例: -oTCPKeepAlive=yes": "e.g. -oTCPKeepAlive=yes",
        "Preferences…": "Preferences…", "Settings…": "Settings…"
    ]
}

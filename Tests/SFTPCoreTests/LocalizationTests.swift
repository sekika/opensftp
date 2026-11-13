import XCTest
@testable import SFTPCore

final class LocalizationTests: XCTestCase {
    func testRemoteWindowAndCopyLabels() {
        XCTAssertEqual(AppStrings.translate("新規ウィンドウ", to: .english), "New Window")
        XCTAssertEqual(AppStrings.translate("転送中：2/10 · file.txt", to: .english), "Copying: 2/10 · file.txt")
        XCTAssertEqual(AppStrings.translate("詳細ログはコピー先ウィンドウに表示します", to: .english),
                       "Detailed logs are shown in the destination window")
    }
    func testByteUnitsFollowAppLanguageInsteadOfSystemLanguage() {
        let japanese = AppStrings.byteCount(12, language: .japanese)
        let english = AppStrings.byteCount(12, language: .english)
        XCTAssertTrue(japanese.contains("バイト"), japanese)
        XCTAssertTrue(english.contains("bytes"), english)
        XCTAssertFalse(english.contains("バイト"))
        XCTAssertEqual(AppStrings.byteCountDescription("12 バイト", language: .english), english)
        XCTAssertEqual(AppStrings.byteCountDescription("12 bytes", language: .japanese), japanese)
        XCTAssertEqual(AppStrings.byteCountDescription("1.2 MB", language: .english), "1.2 MB")
        XCTAssertEqual(AppStrings.byteCountDescription("64KB", language: .japanese), "64KB")
    }

    func testStartupUsesPrimarySystemLanguageAndFallsBackToEnglish() {
        for language in ["ja", "ja-JP", "ja_JP"] {
            XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: [language]), .japanese)
        }
        for languages in [["en-US", "ja-JP"], ["fr-FR", "ja-JP"], ["de"], []] {
            XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: languages), .english)
        }
    }

    func testLabelsSummariesAndErrorsAreTranslatedAtPresentationTime() {
        XCTAssertEqual(AppStrings.translate("実行中", to: .english), "Running")
        XCTAssertEqual(AppStrings.translate("SFTP: 更新分だけ · 完了：転送11件・スキップ1件・フォルダ作成1件", to: .english),
                       "SFTP: Updated Files Only · Completed: 11 transferred, 1 skipped, folders created: 1")
        XCTAssertEqual(AppStrings.translate("SFTP: すべて上書きでフォルダを確認中…", to: .english),
                       "Checking folder with SFTP: Overwrite All…")
        XCTAssertEqual(AppStrings.translate("認証失敗。フォルダ転送は一部のみ完了している可能性があります。詳細ログを確認してください。", to: .english),
                       "Authentication failed. The folder transfer may be incomplete. See the detailed logs.")
        XCTAssertEqual(AppStrings.translate("11項目 · 2項目を選択", to: .english), "11 items · 2 selected")
        XCTAssertEqual(AppStrings.translate("実行中", to: .japanese), "実行中")
        XCTAssertEqual(AppStrings.translate("About OpenSFTP", to: .japanese), "OpenSFTPについて")
        XCTAssertEqual(AppStrings.translate("OpenSFTPについて", to: .english), "About OpenSFTP")
    }

    func testTranslatedTemplatesPreserveOpaquePathsAndPlaceholderCharacters() {
        let source = "silver:/日本語/{1}/quote'file"
        let destination = "/tmp/完了/{0}/日本語"
        let description = "転送元: \(source)\n転送先: \(destination)"
        XCTAssertEqual(AppStrings.translate(description, to: .english), "Source: \(source)\nDestination: \(destination)")
        let error = "転送元が見つかりません: \(source)"
        XCTAssertEqual(AppStrings.translate(error, to: .english), "Source not found: \(source)")
        XCTAssertEqual(AppStrings.translate(source, to: .english), source)
        XCTAssertEqual(AppStrings.translate("Number of files transferred: 11", to: .english), "Number of files transferred: 11")
    }

    func testSettingsLocalization() {
        XCTAssertEqual(AppStrings.translate("設定", to: .english), "Settings")
        XCTAssertEqual(AppStrings.translate("外観", to: .english), "Appearance")
        XCTAssertEqual(AppStrings.translate("接続", to: .english), "Connection")
        XCTAssertEqual(AppStrings.translate("最小ウィンドウサイズ", to: .english), "Minimum Window Size")
        XCTAssertEqual(AppStrings.translate("アイコンの大きさ", to: .english), "Icon Size")
        XCTAssertEqual(AppStrings.translate("ファイル名の行数", to: .english), "Filename Lines")
        XCTAssertEqual(AppStrings.translate("拡張属性 (-E) を保持する", to: .english), "Preserve Extended Attributes (-E)")
        XCTAssertEqual(AppStrings.translate("接続タイムアウト", to: .english), "Connect Timeout")
        XCTAssertEqual(AppStrings.translate("Settings", to: .japanese), "設定")
    }
}

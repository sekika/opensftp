import Foundation
import XCTest
import SFTPCore
@testable import OpenSFTP

@MainActor
final class VSCodeModelTests: XCTestCase {
    private func preferences() throws -> AppPreferences {
        let suite = "OpenSFTP.VSCodeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppPreferences(defaults: defaults)
    }

    private func selectFile(_ model: AppModel) {
        model.host = "cat"
        model.hostInput = "other-host"
        model.path = "/Users/seki"
        model.entries = DirectoryListing.parse("""
        -rw-r--r-- 1 u g 10 Jan 1 2026 file.txt
        drwxr-xr-x 1 u g 10 Jan 1 2026 folder
        prw-r--r-- 1 u g 0 Jan 1 2026 pipe
        """).entries
        model.selection = ["file.txt"]
    }

    func testMenuRequiresBothEnablementAndApplicationAndValidSelection() throws {
        let prefs = try preferences()
        let model = AppModel(integrationPreferences: prefs)
        selectFile(model)
        XCTAssertFalse(model.showsVSCodeMenu)
        prefs.vsCodeEnabled = true
        XCTAssertFalse(model.showsVSCodeMenu)
        prefs.vsCodeApplication = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        XCTAssertTrue(model.showsVSCodeMenu)
        XCTAssertTrue(model.canOpenInVSCode)
        let selections: [Set<String>] = [[], ["folder"], ["pipe"], ["file.txt", "folder"]]
        for selection in selections {
            model.selection = selection
            XCTAssertFalse(model.canOpenInVSCode)
        }
        model.selection = ["file.txt"]
        prefs.vsCodeEnabled = false
        XCTAssertFalse(model.showsVSCodeMenu)
        XCTAssertFalse(model.canOpenInVSCode)
    }

    func testLaunchUsesSelectedApplicationAndConnectedHostSnapshot() async throws {
        let prefs = try preferences()
        prefs.vsCodeEnabled = true
        let application = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        prefs.vsCodeApplication = application
        var calls: [(URL, String, String)] = []
        let model = AppModel(integrationPreferences: prefs, openVSCode: { calls.append(($0, $1, $2)) })
        selectFile(model)
        model.openSelectionInVSCode()
        model.openSelectionInVSCode()
        model.host = "changed"
        model.selection = []
        for _ in 0..<1000 {
            if !model.openingVSCode { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(model.openingVSCode)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, application)
        XCTAssertEqual(calls.first?.1, "cat")
        XCTAssertEqual(calls.first?.2, "/Users/seki/file.txt")
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertFalse(model.preview.isPresented)
        XCTAssertNil(model.errorMessage)
    }

    func testLaunchFailureIsReportedAndDisabledIntegrationDoesNotLaunch() async throws {
        let prefs = try preferences()
        prefs.vsCodeApplication = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        var calls = 0
        let model = AppModel(integrationPreferences: prefs, openVSCode: { _, _, _ in
            calls += 1
            throw PreviewError("VS Codeを開けませんでした: test")
        })
        selectFile(model)
        model.openSelectionInVSCode()
        XCTAssertFalse(model.openingVSCode)
        prefs.vsCodeEnabled = true
        model.openSelectionInVSCode()
        for _ in 0..<1000 {
            if !model.openingVSCode { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.errorMessage, "VS Codeを開けませんでした: test")
        XCTAssertTrue(model.canOpenInVSCode)
    }

    func testPreferencesPersistAcrossLaunches() throws {
        let suite = "OpenSFTP.VSCodePersistenceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertFalse(prefs.vsCodeConfigured)
        prefs.vsCodeEnabled = true
        prefs.vsCodeApplication = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        let restored = AppPreferences(defaults: defaults)
        XCTAssertTrue(restored.vsCodeConfigured)
        XCTAssertEqual(restored.vsCodeApplication, prefs.vsCodeApplication)
        restored.vsCodeEnabled = false
        XCTAssertFalse(AppPreferences(defaults: defaults).vsCodeConfigured)
    }
}

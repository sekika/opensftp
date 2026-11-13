import Foundation
import XCTest
import SFTPCore
@testable import OpenSFTP

@MainActor
final class TerminalLessModelTests: XCTestCase {
    private func selectFile(_ model: AppModel) {
        model.host = "example"
        model.path = "/logs"
        model.entries = DirectoryListing.parse("""
        -rw-r--r-- 1 u g 10 Jan 1 2026 file.txt
        drwxr-xr-x 1 u g 10 Jan 1 2026 folder
        lrwxrwxrwx 1 u g 10 Jan 1 2026 link -> file.txt
        prw-r--r-- 1 u g 0 Jan 1 2026 pipe
        """).entries
        model.selection = ["file.txt"]
    }

    func testLaunchUsesSelectionSnapshotAndDoesNotStartPreviewOrQueueJob() async throws {
        var opened: [(String, String)] = []
        let model = AppModel(openTextInTerminal: { host, path in opened.append((host, path)) })
        selectFile(model)
        XCTAssertTrue(model.canOpenInTerminal)
        model.openSelectionInTerminal()
        XCTAssertTrue(model.openingTerminal)
        // Repeated clicks while automation is starting must not open duplicates.
        model.openSelectionInTerminal()
        model.selection = []
        for _ in 0..<1000 {
            if !model.openingTerminal { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(model.openingTerminal)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, "example")
        XCTAssertEqual(opened.first?.1, "/logs/file.txt")
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertFalse(model.preview.isPresented)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.errorMessage)
    }

    func testInvalidSelectionDoesNotInvokeTerminal() async throws {
        var calls = 0
        let model = AppModel(openTextInTerminal: { _, _ in calls += 1 })
        selectFile(model)
        let selections: [Set<String>] = [[], ["folder"], ["link"], ["pipe"], ["file.txt", "folder"]]
        for selection in selections {
            model.selection = selection
            XCTAssertFalse(model.canOpenInTerminal)
            model.openSelectionInTerminal()
        }
        model.selection = ["file.txt"]
        model.host = ""
        XCTAssertFalse(model.canOpenInTerminal)
        model.openSelectionInTerminal()
        try await Task.sleep(nanoseconds: 1_000_000)
        XCTAssertEqual(calls, 0)
    }

    func testLaunchErrorIsReportedAndAllowsRetry() async throws {
        let model = AppModel(openTextInTerminal: { _, _ in throw PreviewError("Terminalを開けませんでした: test") })
        selectFile(model)
        model.openSelectionInTerminal()
        for _ in 0..<1000 {
            if !model.openingTerminal { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(model.openingTerminal)
        XCTAssertTrue(model.canOpenInTerminal)
        XCTAssertEqual(model.errorMessage, "Terminalを開けませんでした: test")
        XCTAssertTrue(model.jobs.isEmpty)
    }
}

import XCTest
import SFTPCore
@testable import OpenSFTP

/// Deliberately ignores task cancellation so generation checks are exercised.
private actor DelayedPreviewRunner: PreviewRunning {
    private var pending: [String: CheckedContinuation<Data, Never>] = [:]
    func read(host: String, command: String, limit: Int) async throws -> Data {
        // Only the encoding probe completes immediately. Text pages now also
        // contain head -c for the byte cap and must keep their delayed response.
        if limit == 256, command.contains("head -c 256 ") { return Data("text".utf8) }
        if command.contains("file -b") {
            return Data("text/plain; charset=utf-8".utf8)
        }
        return await withCheckedContinuation { pending[command.contains("'/second'") ? "second" : "first"] = $0 }
    }
    func ready(_ key: String) -> Bool { pending[key] != nil }
    func finish(_ key: String, text: String) { pending.removeValue(forKey: key)?.resume(returning: Data(text.utf8)) }
}

private actor PDFPreviewRunner: PreviewRunning {
    private(set) var textReads = 0
    private(set) var imageReads = 0
    let failImage: Bool
    let delayImage: Bool
    private var pendingImage: CheckedContinuation<Data, Never>?
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg==")!
    init(failImage: Bool = false, delayImage: Bool = false) {
        self.failImage = failImage; self.delayImage = delayImage
    }
    func read(host: String, command: String, limit: Int) async throws -> Data {
        if command.contains("file -b") { return Data("application/pdf; charset=binary".utf8) }
        if command.contains("pdftotext") {
            textReads += 1
            return Data("PDF text".utf8)
        }
        imageReads += 1
        if failImage { throw PreviewError("pdftoppm is unavailable") }
        if delayImage { return await withCheckedContinuation { pendingImage = $0 } }
        return png
    }
    func imageIsPending() -> Bool { pendingImage != nil }
    func finishImage() { pendingImage?.resume(returning: png); pendingImage = nil }
}

@MainActor
final class FilePreviewModelTests: XCTestCase {
    private func waitUntil(_ check: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await check() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Preview did not reach the expected state")
    }
    func testPDFTabsLoadLazilyCacheAndRememberSelection() async throws {
        let name = "PDFTabs." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let runner = PDFPreviewRunner()
        let service = FilePreviewService(runner: runner)
        let model = FilePreviewModel(service: service, defaults: defaults)
        XCTAssertEqual(model.pdfTab, .text)
        model.show(host: "example", path: "/doc.pdf")
        try await waitUntil { model.document != nil }
        XCTAssertTrue(model.isPDF)
        var images = await runner.imageReads
        XCTAssertEqual(images, 0)
        model.selectPDFTab(.firstPage)
        try await waitUntil { model.document?.image != nil }
        model.selectPDFTab(.text)
        XCTAssertEqual(model.document?.text, "PDF text")
        model.selectPDFTab(.firstPage)
        XCTAssertNotNil(model.document?.image)
        images = await runner.imageReads
        let texts = await runner.textReads
        XCTAssertEqual(images, 1); XCTAssertEqual(texts, 1)
        model.close()
        XCTAssertNil(model.document)

        // New model simulates reopening the application. Restoring image mode
        // must fetch only the image, without a hidden text extraction first.
        let restored = FilePreviewModel(service: service, defaults: defaults)
        XCTAssertEqual(restored.pdfTab, .firstPage)
        restored.show(host: "example", path: "/another.pdf")
        try await waitUntil { restored.document?.image != nil }
        images = await runner.imageReads
        let restoredTexts = await runner.textReads
        XCTAssertEqual(images, 2); XCTAssertEqual(restoredTexts, 1)
        restored.close()
    }

    func testPDFFailedImageStillAllowsTextAndInvalidSavedTabFallsBack() async throws {
        let name = "PDFTabFailure." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unknown", forKey: "previewPDFTab")
        XCTAssertEqual(FilePreviewModel(defaults: defaults).pdfTab, .text)
        defaults.set("firstPage", forKey: "previewPDFTab")
        let runner = PDFPreviewRunner(failImage: true)
        let model = FilePreviewModel(service: FilePreviewService(runner: runner), defaults: defaults)
        model.show(host: "example", path: "/doc.pdf")
        try await waitUntil { model.error != nil }
        XCTAssertTrue(model.isPDF)
        XCTAssertEqual(model.error, "pdftoppm is unavailable")
        model.selectPDFTab(.text)
        try await waitUntil { model.document != nil }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.document?.text, "PDF text")
        XCTAssertEqual(defaults.string(forKey: "previewPDFTab"), "text")
        model.close()
    }

    func testSwitchingPDFAwayFromLoadingImageDiscardsItsLateResponse() async throws {
        let runner = PDFPreviewRunner(delayImage: true)
        let name = "PDFTabCancellation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = FilePreviewModel(service: FilePreviewService(runner: runner), defaults: defaults)
        model.show(host: "example", path: "/doc.pdf")
        try await waitUntil { model.document != nil }
        model.selectPDFTab(.firstPage)
        try await waitUntil { await runner.imageIsPending() }
        model.selectPDFTab(.text)
        XCTAssertEqual(model.document?.text, "PDF text")
        await runner.finishImage()
        await Task.yield()
        XCTAssertNil(model.document?.image)
        XCTAssertEqual(model.pdfTab, .text)
        XCTAssertFalse(model.loading)
        model.close()
    }

    func testSelectionSwitchDiscardsLateResponseAndCloseReleasesData() async throws {
        let runner = DelayedPreviewRunner()
        let model = FilePreviewModel(service: FilePreviewService(runner: runner))
        model.show(host: "example", path: "/first")
        try await waitUntil { await runner.ready("first") }
        model.show(host: "example", path: "/second")
        try await waitUntil { await runner.ready("second") }
        await runner.finish("second", text: "new\n")
        try await waitUntil { model.document != nil }
        XCTAssertEqual(model.document?.text, "new")
        await runner.finish("first", text: "old\n")
        await Task.yield()
        XCTAssertEqual(model.path, "/second"); XCTAssertEqual(model.document?.text, "new")
        model.close()
        XCTAssertNil(model.document); XCTAssertFalse(model.isPresented); XCTAssertFalse(model.loading)
    }
    func testClosingWhileLoadingDiscardsLateResponse() async throws {
        let runner = DelayedPreviewRunner()
        let model = FilePreviewModel(service: FilePreviewService(runner: runner))
        model.show(host: "example", path: "/first")
        try await waitUntil { await runner.ready("first") }
        model.close()
        await runner.finish("first", text: "secret\n")
        await Task.yield()
        XCTAssertNil(model.document); XCTAssertNil(model.error); XCTAssertFalse(model.isPresented)
    }
    func testOnlyOneRegularFileCanBePreviewed() {
        let model = AppModel()
        model.host = "example"; model.path = "/"
        model.entries = DirectoryListing.parse("""
        -rw-r--r-- 1 u g 10 Jan 1 2026 file
        drwxr-xr-x 1 u g 10 Jan 1 2026 folder
        lrwxrwxrwx 1 u g 10 Jan 1 2026 link -> file
        prw-r--r-- 1 u g 0 Jan 1 2026 pipe
        """).entries
        model.selection = ["file"]; XCTAssertTrue(model.canPreview)
        let selections: [Set<String>] = [[], ["folder"], ["link"], ["pipe"], ["file", "folder"]]
        for selection in selections {
            model.selection = selection; XCTAssertFalse(model.canPreview)
        }
    }
}

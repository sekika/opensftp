import Foundation
import XCTest
@testable import SFTPCore

final class ResourceLimitsTests: XCTestCase {
    func testDefaultsPersistenceAndValidation() throws {
        let name = "ResourceLimitsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(ResourceLimits(defaults: defaults), .default)
        XCTAssertEqual(ResourceLimits.default.listingEntries, 100_000)
        XCTAssertEqual(ResourceLimits.default.listingBytes, 64 * 1_048_576)
        var limits = ResourceLimits()
        limits.listingEntries = 12
        limits.listingMiB = 2
        limits.traversalEntries = 25
        limits.traversalDepth = 3
        limits.logMiB = 2
        limits.diffMiB = 3
        limits.previewTextMiB = 2
        limits.previewTimeoutSeconds = 45
        limits.save(to: defaults)
        XCTAssertEqual(ResourceLimits(defaults: defaults), limits)
        defaults.set(Int.max, forKey: "limitListingMiB")
        defaults.set(-1, forKey: "limitTraversalDepth")
        defaults.set(0, forKey: "limitPreviewTimeoutSeconds")
        let clamped = ResourceLimits(defaults: defaults)
        XCTAssertEqual(clamped.listingMiB, 256)
        XCTAssertEqual(clamped.traversalDepth, 1)
        XCTAssertEqual(clamped.previewTimeoutSeconds, 1)
    }

    func testListingOverflowDiscardsAllEntriesAndPath() throws {
        var limits = ResourceLimits()
        limits.listingEntries = 1
        let first = "Remote working directory: /safe\n-rw-r--r-- 1 u g 1 Jan 1 2024 first\n"
        XCTAssertEqual(try DirectoryListing.parseChecked(first, limits: limits).entries.count, 1)
        let overflow = first + "-rw-r--r-- 1 u g 1 Jan 1 2024 second\n"
        let invalid = DirectoryListing.parse(overflow, limits: limits)
        XCTAssertTrue(invalid.limitExceeded)
        XCTAssertNil(invalid.path)
        XCTAssertTrue(invalid.entries.isEmpty)
        XCTAssertThrowsError(try DirectoryListing.parseChecked(overflow, limits: limits))
        limits.listingMiB = 1
        XCTAssertThrowsError(try DirectoryListing.parseChecked(first + String(repeating: "x", count: 1_048_576), limits: limits))
    }

    func testStreamingListingLinesPreserveCarriageReturnsAndBlankRows() throws {
        XCTAssertEqual(Array(LFLineSequence("first\r\nsecond\rname\n\nlast")), ["first\r", "second\rname", "", "last"])
        var limits = ResourceLimits()
        limits.listingEntries = 1
        let text = "Remote working directory: /safe\n" + String(repeating: "\n", count: 10_000)
            + "-rw-r--r-- 1 u g 1 Jan 1 2024 Icon\r\n"
        let listing = try DirectoryListing.parseChecked(text, limits: limits)
        XCTAssertEqual(listing.entries.map(\.name), ["Icon\r"])
    }

    func testTraversalCountsIncludeSkippedEntriesAndRespectBoundary() throws {
        var limits = ResourceLimits()
        limits.traversalEntries = 3
        limits.traversalDepth = 2
        var budget = TraversalBudget(limits)
        try budget.consume(1)
        try budget.consume(2)
        XCTAssertThrowsError(try budget.consume(1))
        XCTAssertEqual(budget.count, 3)
        XCTAssertNoThrow(try budget.checkDepth(1))
        XCTAssertThrowsError(try budget.checkDepth(2))
    }

    func testBoundedReaderDrainsBeyondLimitAndReportsOverflowOnlyOnce() throws {
        let pipe = Pipe()
        let writer = expectation(description: "writer finishes despite overflow")
        DispatchQueue.global().async {
            try? pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: 200_000))
            try? pipe.fileHandleForWriting.close()
            writer.fulfill()
        }
        var overflows = 0
        let captured = BoundedOutput.read(pipe.fileHandleForReading, limit: 1024, onExceeded: { overflows += 1 })
        try pipe.fileHandleForReading.close()
        wait(for: [writer], timeout: 3)
        XCTAssertEqual(captured.data.count, 1024)
        XCTAssertTrue(captured.exceeded)
        XCTAssertEqual(overflows, 1)
        XCTAssertTrue(captured.text.hasSuffix(BoundedLog.marker))
    }

    func testLogRetentionRemainsBoundedAcrossRepeatedAppendAndLoweredLimit() {
        var log = ""
        for _ in 0..<100 { log = BoundedLog.clip(log + String(repeating: "a", count: 100), limit: 256) }
        XCTAssertEqual(log.utf8.count, 256 + BoundedLog.marker.utf8.count)
        log = BoundedLog.clip(log, limit: 100)
        XCTAssertEqual(log.utf8.count, 100 + BoundedLog.marker.utf8.count)
        XCTAssertEqual(log.components(separatedBy: BoundedLog.marker).count, 2)
    }

    func testOmissionMarkSurvivesPrivateKeyRedaction() {
        let raw = "-----BEGIN OPENSSH PRIVATE KEY-----\nprivate bytes" + BoundedLog.marker
        let redacted = LogRedactor.redact(raw)
        XCTAssertFalse(redacted.contains("private bytes"))
        XCTAssertTrue(redacted.contains(BoundedLog.marker))
    }

    func testOverlongProgressDiagnosticDoesNotPreventLaterProgressUpdates() {
        var decoder = ProgressOutputDecoder(pendingLimit: 32)
        let diagnostic = decoder.consume(Data(repeating: 65, count: 100), progress: { _ in XCTFail("not progress") })
        XCTAssertTrue(diagnostic.contains(BoundedLog.marker))
        var progress: [TransferProgress] = []
        _ = decoder.consume(Data("tail\nfile 100% 1KB 1.0KB/s 00:01\n".utf8), progress: { progress.append($0) })
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.fraction, 1)
    }
}

import XCTest
@testable import SFTPCore

final class LocalDiffTests: XCTestCase {
    func testDiffReportsIdenticalDifferentAndMissingFiles() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        // Quotes, spaces and shell metacharacters must remain literal path characters.
        let original = directory.appendingPathComponent("original ' $(literal).txt")
        let saved = directory.appendingPathComponent("saved-1.txt")
        try Data("before\n".utf8).write(to: original)
        try Data("before\n".utf8).write(to: saved)
        let identical = await LocalDiff.run(original: original, saved: saved)
        XCTAssertEqual(identical.exitCode, 0)
        XCTAssertTrue(identical.stdout.isEmpty)
        XCTAssertNil(identical.failure)

        try Data("after\n".utf8).write(to: saved)
        let different = await LocalDiff.run(original: original, saved: saved)
        XCTAssertEqual(different.exitCode, 1)
        XCTAssertTrue(different.stdout.contains("-before\n"))
        XCTAssertTrue(different.stdout.contains("+after\n"))
        XCTAssertNil(different.failure)
        XCTAssertEqual(try String(contentsOf: original), "before\n")
        XCTAssertEqual(try String(contentsOf: saved), "after\n")

        try fm.removeItem(at: original)
        let missing = await LocalDiff.run(original: original, saved: saved)
        XCTAssertGreaterThan(missing.exitCode, 1)
        XCTAssertNotNil(missing.failure)
        XCTAssertFalse(missing.stderr.isEmpty)
    }

    func testLargeDiffDrainsOutputWithoutBlocking() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let original = directory.appendingPathComponent("old.txt")
        let saved = directory.appendingPathComponent("new.txt")
        try Data(String(repeating: "before\n", count: 30_000).utf8).write(to: original)
        try Data(String(repeating: "after\n", count: 30_000).utf8).write(to: saved)
        let result = await LocalDiff.run(original: original, saved: saved)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertGreaterThan(result.stdout.utf8.count, 300_000)
    }

    func testDiffLimitStopsComparisonWithoutChangingEitherFile() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let original = directory.appendingPathComponent("old.txt"), saved = directory.appendingPathComponent("new.txt")
        let before = Data(String(repeating: "before\n", count: 200_000).utf8)
        let after = Data(String(repeating: "after\n", count: 200_000).utf8)
        try before.write(to: original)
        try after.write(to: saved)
        var limits = ResourceLimits()
        limits.diffMiB = 1
        let result = await LocalDiff.run(original: original, saved: saved, limits: limits)
        XCTAssertNotNil(result.failure)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, limits.diffBytes)
        XCTAssertTrue(result.stderr.contains("差分が取得上限"))
        XCTAssertEqual(try Data(contentsOf: original), before)
        XCTAssertEqual(try Data(contentsOf: saved), after)
    }
}

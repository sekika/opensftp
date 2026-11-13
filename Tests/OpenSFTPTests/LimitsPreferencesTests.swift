import Foundation
import XCTest
import SFTPCore
@testable import OpenSFTP

@MainActor
final class LimitsPreferencesTests: XCTestCase {
    func testLimitsPersistLegacyPreviewSettingsSurviveAndResetIsScoped() throws {
        let name = "LimitsPreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(123, forKey: "previewLines")
        defaults.set(9, forKey: "previewBinaryMiB")
        defaults.set(45, forKey: "sshConnectTimeout")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.preview, PreviewPreferences(lines: 123, binaryMiB: 9))
        preferences.limits.listingEntries = 42
        preferences.limits.previewTimeoutSeconds = 7
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.limits.listingEntries, 42)
        XCTAssertEqual(restored.limits.previewTimeoutSeconds, 7)
        restored.limits.previewTimeoutSeconds = 0
        XCTAssertEqual(restored.limits.previewTimeoutSeconds, 1)
        restored.resetLimits()
        XCTAssertEqual(ResourceLimits(defaults: defaults), .default)
        XCTAssertEqual(PreviewPreferences(defaults: defaults), PreviewPreferences())
        XCTAssertEqual(ConnectionPreferences(defaults: defaults).connectTimeout, 45)
    }

    func testRepeatedJobLogUpdatesAreBoundedWithoutChangingJobState() {
        var job = JobRecord(host: "test", title: "upload", target: "/file", request: .mutation("mkdir", ["/folder"]), logLimit: 128)
        for _ in 0..<100 {
            job.stdout += String(repeating: "a", count: 100)
            job.stderr += String(repeating: "b", count: 100)
        }
        XCTAssertEqual(job.stdout.utf8.count, 128 + BoundedLog.marker.utf8.count)
        XCTAssertEqual(job.stderr.utf8.count, 128 + BoundedLog.marker.utf8.count)
        XCTAssertEqual(job.state, .waiting)
        job.stdout = ""
        job.stdout += "new log"
        XCTAssertEqual(job.stdout, "new log")
    }
}

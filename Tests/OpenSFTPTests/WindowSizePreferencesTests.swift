import XCTest
import AppKit
@testable import OpenSFTP

@MainActor
final class WindowSizePreferencesTests: XCTestCase {
    func testFirstLaunchAndSavedSizeAreRestored() throws {
        let suite = "OpenSFTP.WindowSizeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WindowSizePreferences(defaults: defaults)
        XCTAssertEqual(settings.restoredSize, CGSize(width: 1050, height: 760))
        settings.save(CGSize(width: 735, height: 615))
        XCTAssertEqual(WindowSizePreferences(defaults: defaults).restoredSize, CGSize(width: 735, height: 615))
    }

    func testMinimumIsEnforcedAndInvalidSizeDoesNotReplaceSavedSize() throws {
        let suite = "OpenSFTP.WindowSizeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WindowSizePreferences(defaults: defaults)
        settings.save(CGSize(width: 400, height: 300))
        XCTAssertEqual(settings.restoredSize, CGSize(width: 600, height: 550))
        settings.save(CGSize(width: CGFloat.nan, height: 800))
        XCTAssertEqual(settings.restoredSize, CGSize(width: 600, height: 550))
    }

    func testCustomMinimumSizeCanBeSavedAndEnforced() throws {
        let suite = "OpenSFTP.WindowSizeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WindowSizePreferences(defaults: defaults)
        XCTAssertEqual(settings.minimum, CGSize(width: 600, height: 550))

        settings.saveMinimum(CGSize(width: 700, height: 600))
        let reloaded = WindowSizePreferences(defaults: defaults)
        XCTAssertEqual(reloaded.minimum, CGSize(width: 700, height: 600))

        // Saving a size below the custom minimum clamps to the custom minimum
        reloaded.save(CGSize(width: 650, height: 500))
        XCTAssertEqual(reloaded.restoredSize, CGSize(width: 700, height: 600))
    }
}

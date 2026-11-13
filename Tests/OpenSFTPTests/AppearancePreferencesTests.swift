import XCTest
import AppKit
@testable import OpenSFTP

@MainActor
final class AppearancePreferencesTests: XCTestCase {
    func testDefaultValues() {
        let prefs = AppearancePreferences.default
        XCTAssertEqual(prefs.minWindowWidth, 600)
        XCTAssertEqual(prefs.minWindowHeight, 550)
        XCTAssertEqual(prefs.iconSize, 42)
        XCTAssertEqual(prefs.iconLabelLines, 2)
    }

    func testPersistenceToUserDefaults() throws {
        let suite = "OpenSFTP.AppearancePrefsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppearancePreferences(
            minWindowWidth: 720,
            minWindowHeight: 620,
            iconSize: 64,
            iconLabelLines: 3
        )
        prefs.save(to: defaults)

        let loaded = AppearancePreferences(defaults: defaults)
        XCTAssertEqual(loaded.minWindowWidth, 720)
        XCTAssertEqual(loaded.minWindowHeight, 620)
        XCTAssertEqual(loaded.iconSize, 64)
        XCTAssertEqual(loaded.iconLabelLines, 3)
    }

    func testPreviouslySavedLargeIconsAreClampedToNewRange() throws {
        let suite = "OpenSFTP.AppearancePrefsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(128, forKey: "iconViewIconSize")
        XCTAssertEqual(AppearancePreferences(defaults: defaults).iconSize, 128)
        defaults.set(40, forKey: "iconViewIconSize")
        XCTAssertEqual(AppearancePreferences(defaults: defaults).iconSize, 40)
    }

    func testAppPreferencesNotifiesAndResets() throws {
        let suite = "OpenSFTP.AppPrefsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = AppPreferences(defaults: defaults)

        var appearanceNotified = false
        var connectionNotified = false

        let o1 = NotificationCenter.default.addObserver(forName: .appearancePreferencesChanged, object: manager, queue: .main) { _ in
            appearanceNotified = true
        }
        let o2 = NotificationCenter.default.addObserver(forName: .connectionPreferencesChanged, object: manager, queue: .main) { _ in
            connectionNotified = true
        }
        defer {
            NotificationCenter.default.removeObserver(o1)
            NotificationCenter.default.removeObserver(o2)
        }

        manager.appearance.iconSize = 80
        XCTAssertTrue(appearanceNotified)

        manager.connection.rsyncExtendedAttributes = true
        XCTAssertTrue(connectionNotified)

        manager.resetAppearance()
        XCTAssertEqual(manager.appearance.iconSize, AppearancePreferences.defaultIconSize)

        manager.resetConnection()
        XCTAssertFalse(manager.connection.rsyncExtendedAttributes)
    }
}

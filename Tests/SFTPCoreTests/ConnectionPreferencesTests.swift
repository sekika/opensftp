import XCTest
@testable import SFTPCore

final class ConnectionPreferencesTests: XCTestCase {
    func testDefaultValues() {
        let prefs = ConnectionPreferences.default
        XCTAssertFalse(prefs.rsyncExtendedAttributes)
        XCTAssertEqual(prefs.connectTimeout, 15)
        XCTAssertEqual(prefs.serverAliveInterval, 15)
        XCTAssertEqual(prefs.serverAliveCountMax, 3)
        XCTAssertEqual(prefs.strictHostKeyChecking, "yes")
        XCTAssertTrue(prefs.rsyncCompression)
        XCTAssertEqual(prefs.extraOptions, "")
    }

    func testUserDefaultsPersistence() {
        let suite = "OpenSFTP.ConnectionPrefsTests." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = ConnectionPreferences(
            rsyncExtendedAttributes: true,
            connectTimeout: 30,
            serverAliveInterval: 60,
            serverAliveCountMax: 5,
            strictHostKeyChecking: "accept-new",
            rsyncCompression: false,
            extraOptions: "-oTCPKeepAlive=yes"
        )
        prefs.save(to: defaults)

        let restored = ConnectionPreferences(defaults: defaults)
        XCTAssertTrue(restored.rsyncExtendedAttributes)
        XCTAssertEqual(restored.connectTimeout, 30)
        XCTAssertEqual(restored.serverAliveInterval, 60)
        XCTAssertEqual(restored.serverAliveCountMax, 5)
        XCTAssertEqual(restored.strictHostKeyChecking, "accept-new")
        XCTAssertFalse(restored.rsyncCompression)
        XCTAssertEqual(restored.extraOptions, "-oTCPKeepAlive=yes")
    }


    func testRsyncRequestWithExtendedAttributes() throws {
        let prefs = ConnectionPreferences(rsyncExtendedAttributes: true)
        let request = try RsyncRequest(
            host: "host",
            local: URL(fileURLWithPath: "/tmp/source"),
            remote: "/dest",
            direction: .upload,
            files: [],
            preferences: prefs
        )
        XCTAssertTrue(request.arguments.contains("-E"))
        XCTAssertEqual(Array(request.arguments.prefix(4)), ["-avz", "-E", "--8-bit-output", "-e"])
    }

    func testRsyncRequestWithoutExtendedAttributes() throws {
        let prefs = ConnectionPreferences(rsyncExtendedAttributes: false)
        let request = try RsyncRequest(
            host: "host",
            local: URL(fileURLWithPath: "/tmp/source"),
            remote: "/dest",
            direction: .upload,
            files: [],
            preferences: prefs
        )
        XCTAssertFalse(request.arguments.contains("-E"))
        XCTAssertEqual(Array(request.arguments.prefix(3)), ["-avz", "--8-bit-output", "-e"])
    }

    func testRsyncRequestWithoutCompression() throws {
        let prefs = ConnectionPreferences(rsyncCompression: false)
        let request = try RsyncRequest(
            host: "host",
            local: URL(fileURLWithPath: "/tmp/source"),
            remote: "/dest",
            direction: .upload,
            files: [],
            preferences: prefs
        )
        XCTAssertTrue(request.arguments.contains("-av"))
        XCTAssertFalse(request.arguments.contains("-avz"))
    }

    func testRsyncRequestWithCustomSSHOptions() throws {
        let prefs = ConnectionPreferences(
            connectTimeout: 45,
            serverAliveInterval: 20,
            serverAliveCountMax: 6,
            strictHostKeyChecking: "accept-new",
            extraOptions: "-oTCPKeepAlive=yes"
        )
        let request = try RsyncRequest(
            host: "host",
            local: URL(fileURLWithPath: "/tmp/source"),
            remote: "/dest",
            direction: .upload,
            files: [],
            preferences: prefs
        )
        let sshCommand = try XCTUnwrap(request.arguments.first(where: { $0.hasPrefix("/usr/bin/ssh ") }))
        XCTAssertTrue(sshCommand.contains("-oConnectTimeout=45"))
        XCTAssertTrue(sshCommand.contains("-oServerAliveInterval=20"))
        XCTAssertTrue(sshCommand.contains("-oServerAliveCountMax=6"))
        XCTAssertTrue(sshCommand.contains("-oStrictHostKeyChecking=accept-new"))
        XCTAssertTrue(sshCommand.contains("-oTCPKeepAlive=yes"))
    }
}

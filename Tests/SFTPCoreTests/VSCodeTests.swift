import Foundation
import XCTest
@testable import SFTPCore

final class VSCodeTests: XCTestCase {
    private let application = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")

    func testExampleOpensRemoteFileAtFirstLineAndColumn() throws {
        let command = try VSCodeCommand(application: application, host: "cat", path: "/Users/seki/file.txt")
        XCTAssertEqual(command.arguments, ["-a", application.path,
            "vscode://vscode-remote/ssh-remote+cat/Users/seki/file.txt:1:1"])
    }

    func testFilenamesRemainLiteralURIPathsAndSeparateProcessArguments() throws {
        let path = "/日本語/space #?% ' $(touch injected); \\ file:12.txt"
        let command = try VSCodeCommand(application: application, host: "cat", path: path)
        let components = try XCTUnwrap(URLComponents(url: command.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "vscode")
        XCTAssertEqual(components.host, "vscode-remote")
        XCTAssertEqual(components.path, "/ssh-remote+cat" + path + ":1:1")
        XCTAssertNil(components.query)
        XCTAssertNil(components.fragment)
        XCTAssertFalse(command.arguments[2].contains(" "))
        XCTAssertTrue(command.arguments[2].contains("%23%3F%25"))
        XCTAssertEqual(command.arguments.count, 3)
        XCTAssertEqual(command.arguments[1], application.path)
    }

    func testUserAndCaseSensitiveHostsUseRemoteSSHConnectionEncoding() throws {
        let connections: [(String, String, String?)] = [
            ("seki@cat", "cat", "seki"), ("MyServer", "MyServer", nil),
            ("seki@[2001:db8::1]", "2001:db8::1", "seki"),
        ]
        for (host, hostname, user) in connections {
            let command = try VSCodeCommand(application: application, host: host, path: "/file.txt")
            let path = try XCTUnwrap(URLComponents(url: command.url, resolvingAgainstBaseURL: false)).path
            let authority = String(path.split(separator: "/")[0].dropFirst("ssh-remote+".count))
            XCTAssertEqual(authority.count % 2, 0)
            var data = Data()
            var cursor = authority.startIndex
            while cursor < authority.endIndex {
                let end = authority.index(cursor, offsetBy: 2)
                data.append(try XCTUnwrap(UInt8(authority[cursor..<end], radix: 16)))
                cursor = end
            }
            let connection = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(connection["hostName"], hostname)
            XCTAssertEqual(connection["user"], user)
        }
    }

    func testInvalidInputsAreRejected() {
        for host in ["-oProxyCommand=evil", "cat/path", "cat:22", "cat\n"] {
            XCTAssertThrowsError(try VSCodeCommand(application: application, host: host, path: "/file"))
        }
        for path in ["relative/file", "", "/file\n", "/file\u{0}"] {
            XCTAssertThrowsError(try VSCodeCommand(application: application, host: "cat", path: path))
        }
        XCTAssertThrowsError(try VSCodeCommand(application: URL(string: "https://example.com/app")!, host: "cat", path: "/file"))
    }
}

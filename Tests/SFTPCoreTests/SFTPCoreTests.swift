import XCTest
@testable import SFTPCore

final class SFTPCoreTests: XCTestCase {
    func testProcessEnvironmentUsesUTF8WithEnglishDatesAndDiagnostics() {
        let environment = SFTPService.processEnvironment([
            "LC_ALL": "C", "LANG": "ja_JP.UTF-8", "LC_CTYPE": "C",
            "LC_TIME": "ja_JP.UTF-8", "LC_MESSAGES": "ja_JP.UTF-8",
            "SSH_ASKPASS": "/askpass", "SSH_AUTH_SOCK": "/agent"
        ])
        XCTAssertNil(environment["LC_ALL"])
        XCTAssertEqual(environment["LANG"], "C")
        XCTAssertEqual(environment["LC_TIME"], "C")
        XCTAssertEqual(environment["LC_MESSAGES"], "C")
        #if canImport(Darwin)
        XCTAssertEqual(environment["LC_CTYPE"], "en_US.UTF-8")
        #else
        XCTAssertEqual(environment["LC_CTYPE"], "C.UTF-8")
        #endif
        XCTAssertNil(environment["SSH_ASKPASS"])
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "never")
        XCTAssertEqual(environment["SSH_AUTH_SOCK"], "/agent")
    }

    func testListingPreservesJapanesePathsAndLiteralBackslashes() throws {
        let name = "報告1_履修者数.xlsx"
        let literal = #"literal\345.txt"#
        let listing = DirectoryListing.parse("""
        Remote working directory: /home/日本語
        -rw-r--r-- 1 u g 42 Jan 1 2024 \(name)
        -rw-r--r-- 1 u g 1 Jan 1 2024 \(literal)
        lrwxrwxrwx 1 u g 9 Jan 1 2024 共有フォルダ -> /共有
        """)
        XCTAssertEqual(listing.path, "/home/日本語")
        XCTAssertEqual(listing.entries.map(\.name), [name, literal, "共有フォルダ"])
        XCTAssertEqual(listing.entries.map(\.owner), ["u", "u", "u"])
        XCTAssertEqual(listing.entries.map(\.size), [42, 1, 9])
        XCTAssertEqual(listing.entries.map(\.modified), ["Jan 1 2024", "Jan 1 2024", "Jan 1 2024"])
        XCTAssertTrue(listing.unparsed.isEmpty)
        XCTAssertEqual(try SFTPCommand.operation("get", SFTPCommand.join(listing.path!, name), "/tmp/" + name),
                       ["get \"/home/日本語/\(name)\" \"/tmp/\(name)\"", "bye"])
    }

    func testHostExtractionDoesNotInterpretSSHSettings() {
        let config = """
        Host production staging *.example !blocked
            HostName internal.example
            Include confidential.conf
        Match host production
            User admin
        Host=backup
        host "quoted" production
        Host ?invalid -oProxyCommand=bad
        """
        XCTAssertEqual(SSHConfig.hosts(in: config), ["backup", "production", "quoted", "staging"])
    }

    func testHostRejectsOptionsURLsAndDestinations() throws {
        for host in ["production", "user@server.example", "user@[::1]", "[2001:db8::1]"] {
            XCTAssertNoThrow(try SFTPCommand.validateHost(host))
        }
        for host in ["-oProxyCommand=bad", "server:/etc", "sftp://server/", "server\nbye", "user@-bad", "two hosts", "", "@host"] {
            XCTAssertThrowsError(try SFTPCommand.validateHost(host), host)
        }
    }

    func testQuotesPreserveLiteralGlobAndShellCharacters() throws {
        XCTAssertEqual(try SFTPCommand.quote("/a b/*?[x]#'\"\\$();!"), "\"/a b/*?[x]#'\\\"\\\\$();!\"")
        XCTAssertEqual(try SFTPCommand.operation("rm", "/root/-x *"), ["rm \"/root/-x *\"", "bye"])
        XCTAssertEqual(try SFTPCommand.listing("/a b"), ["cd \"/a b\"", "pwd", "ls -la", "bye"])
        for invalid in ["/x\ny", "/x\ry", "/x\u{0}y", "/x\ty"] {
            XCTAssertThrowsError(try SFTPCommand.quote(invalid))
        }
        for invalid in ["", ".", "..", "a/b"] { XCTAssertThrowsError(try SFTPCommand.validateName(invalid)) }
        XCTAssertEqual(SFTPCommand.join("/", "file"), "/file")
    }

    func testListingSpacesHiddenNamesKindsAndUnparsedLines() throws {
        let output = """
        sftp> pwd
        Remote working directory: /home/test user
        sftp> ls -la
        drwxr-xr-x    2 user group     4096 Jan  3 12:45 .
        drwxr-xr-x    2 user group     4096 Jan  3 12:45 ..
        -rw-r--r--    1 user group       12 Feb  2  2024 .hidden
        drwxr-xr-x    2 user group     4096 Mar  4 10:00 a folder
        -rw-------    1 1000 1000       42 Apr  5  2023 a file [1]*.txt
        lrwxrwxrwx    1 user group        9 Jan  1  2024 shortcut -> /some/path
        -rw-r--r--    1 user group        2 Jan  1  2024   leading space
        unsupported server response
        sftp> bye
        """
        let listing = DirectoryListing.parse(output)
        XCTAssertEqual(listing.path, "/home/test user")
        XCTAssertEqual(listing.entries.map(\.name), [".hidden", "a folder", "a file [1]*.txt", "shortcut", "  leading space"])
        XCTAssertTrue(listing.entries[0].isHidden)
        XCTAssertTrue(listing.entries[1].isDirectory)
        XCTAssertEqual(listing.entries[2].size, 42)
        XCTAssertNotNil(listing.entries[2].modifiedDate)
        XCTAssertFalse(listing.entries[3].isRegularFile)
        XCTAssertEqual(listing.unparsed, ["unsupported server response"])
    }

    func testListingWithUnknownHardLinkCounts() {
        let listing = DirectoryListing.parse("""
        sftp> pwd
        Remote working directory: /home/test
        sftp> ls -la
        drwxr-xr-x    ? user     staff        4960 Nov  8 03:38 .
        drwxr-xr-x    ? root     admin         224 Oct 28 01:37 ..
        -rw-r--r--    ? user     staff       18436 Nov  3 21:57 .hidden
        -rw-r--r--    ? user     staff    380566427 Sep 23  2024 large.txt
        drwx------    ? user     staff         160 Nov  3 21:57 Downloads
        drwxr-xr-x    ? user     staff         128 Mar 15  2026 Virtual Machines.localized
        lrwxr-xr-x    ? user     staff          32 Sep 21  2019 shortcut
        -rw-r--r--    1 user     staff          42 Jan  1  2024 numeric.txt
        sftp> bye
        """)
        XCTAssertEqual(listing.path, "/home/test")
        XCTAssertEqual(listing.entries.map(\.name), [".hidden", "large.txt", "Downloads", "Virtual Machines.localized", "shortcut", "numeric.txt"])
        XCTAssertTrue(listing.unparsed.isEmpty)
        XCTAssertTrue(listing.entries[0].isHidden)
        XCTAssertEqual(listing.entries[1].size, 380566427)
        XCTAssertTrue(listing.entries[1].isRegularFile)
        XCTAssertTrue(listing.entries[2].isDirectory)
        XCTAssertEqual(listing.entries[4].kind, .symbolicLink)
        XCTAssertEqual(listing.entries.filter { !$0.isHidden }.count, 5)
    }

    func testListingRejectsUnrepresentableAndDuplicateEntriesButPreservesControlCharacters() {
        // SFTP's pipe output uses LF row separators; the filename's CR remains data.
        let output = "Remote working directory: /safe\n" +
            "-rw-r--r-- 1 u g 1 Jan 1 2024 safe\n" +
            "-rw-r--r-- 1 u g 1 Jan 1 2024 safe\n" +
            "-rw-r--r-- 1 u g 1 Jan 1 2024 bad/name\n" +
            "-rw-r--r-- 1 u g 1 Jan 1 2024 bad\tname\n" +
            "-rw-r--r-- 1 u g 0 Jan 1 2024 Icon\r\n"
        let listing = DirectoryListing.parse(output)
        XCTAssertEqual(listing.entries.map(\.name), ["safe", "bad\tname", "Icon\r"])
        XCTAssertEqual(listing.unparsed.count, 2)
    }

    func testAuthenticationHostKeysAndNetworkFailuresAreDistinct() {
        XCTAssertEqual(RunResult.classify(code: 255, stdout: "", stderr: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"), .hostKeyMismatch)
        XCTAssertEqual(RunResult.classify(code: 255, stdout: "", stderr: "Host key verification failed."), .hostKeyUnknown)
        XCTAssertEqual(RunResult.classify(code: 255, stdout: "", stderr: "Permission denied (publickey)."), .authentication)
        XCTAssertEqual(RunResult.classify(code: 255, stdout: "", stderr: "Connection reset by peer"), .network)
        XCTAssertEqual(RunResult.classify(code: 1, stdout: "", stderr: "Failure"), .operation)
        XCTAssertEqual(RunResult.classify(code: 0, stdout: "", stderr: "Couldn't stat remote file: No such file or directory"), .operation)
        XCTAssertEqual(RunResult.classify(code: 0, stdout: "Failure", stderr: ""), .operation)
        XCTAssertNil(RunResult.classify(code: 0, stdout: "sftp> bye", stderr: "Warning: Permanently added an unrelated diagnostic"))
    }

    func testLogsMaskCredentialsAndPrivateKeyBodies() {
        let raw = """
        Connected
        Password: hunter2
        Enter passphrase: private
        -----BEGIN OPENSSH PRIVATE KEY-----
        c2VjcmV0
        -----END OPENSSH PRIVATE KEY-----
        token=very-secret
        done
        """
        let redacted = LogRedactor.redact(raw)
        for secret in ["hunter2", "private", "c2VjcmV0", "very-secret"] { XCTAssertFalse(redacted.contains(secret)) }
        XCTAssertTrue(redacted.contains("Connected")); XCTAssertTrue(redacted.contains("done"))
    }
}

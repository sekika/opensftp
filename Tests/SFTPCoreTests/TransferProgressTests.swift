import XCTest
@testable import SFTPCore

final class TransferProgressTests: XCTestCase {
    func testMeterSuffixAndUnknownETA() throws {
        let value = try XCTUnwrap(TransferProgress.parse("a file 99% 日本語.zip   68%  680MB  12.0MB/s   00:27 ETA"))
        XCTAssertEqual(value.fraction, 0.68)
        XCTAssertEqual(value.transferred, "680MB")
        XCTAssertEqual(value.speed, "12.0MB/s")
        XCTAssertEqual(value.remaining, "約00:27")
        XCTAssertEqual(TransferProgress.parse("file 0% 0 0.0KB/s --:-- ETA")?.remaining, "計算中")
        XCTAssertEqual(TransferProgress.parse("file 23% 123KB 0.0KB/s - stalled -")?.remaining, "—（停滞中）")
        XCTAssertEqual(TransferProgress.parse("file 100% 1MB 1.0MB/s 00:01    ")?.remaining, "—")
        XCTAssertNil(TransferProgress.parse("sftp> put \"a file 99%\" \"/destination\""))
        XCTAssertNil(TransferProgress.parse("file 101% 1MB 1.0MB/s 00:01 ETA"))
    }

    func testIncrementalUTF8CRRedrawsAndFinalDiagnostics() {
        let raw = Data("sftp> progress\r\n\r日本語.zip 0% 0 0.0KB/s --:-- ETA\r日本語.zip 50% 500KB 1.0MB/s 00:01 ETA\r\nPermission denied".utf8)
        var decoder = ProgressOutputDecoder()
        var values: [TransferProgress] = []
        var logs = ""
        for byte in raw {
            logs += decoder.consume(Data([byte])) { values.append($0) }
        }
        logs += decoder.consume(Data(), finish: true) { values.append($0) }
        XCTAssertEqual(values.map(\.fraction), [0, 0.5])
        XCTAssertEqual(logs, "sftp> progress\nPermission denied")
    }

    func testInitialMeterIsDeliveredWithoutWaitingForNextRedraw() {
        var decoder = ProgressOutputDecoder()
        var values: [TransferProgress] = []
        let logs = decoder.consume(Data("\rfile 0% 0 0.0KB/s --:-- ETA".utf8)) { values.append($0) }
        XCTAssertEqual(values.count, 1)
        XCTAssertTrue(logs.isEmpty)
    }
}

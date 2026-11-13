import XCTest
@testable import SFTPCore
#if canImport(ImageIO)
import ImageIO
#endif

private actor PreviewFixture: PreviewRunning {
    var responses: [Data]
    var commands: [String] = []
    var timeouts: [Int] = []
    init(_ responses: [Data]) { self.responses = responses }
    func read(host: String, command: String, limit: Int) async throws -> Data {
        commands.append(command)
        guard !responses.isEmpty else { throw PreviewError("Unexpected request") }
        let data = responses.removeFirst()
        guard data.count <= limit else { throw PreviewError("limit") }
        return data
    }
    func read(host: String, command: String, limit: Int, timeout: Int) async throws -> Data {
        timeouts.append(timeout)
        return try await read(host: host, command: command, limit: limit)
    }
}

private struct LocalPreviewRunner: PreviewRunning {
    func read(host: String, command: String, limit: Int) async throws -> Data {
        try await PreviewProcess.run("/bin/sh", ["-c", command], limit: limit)
    }
}

final class FilePreviewTests: XCTestCase {
    func testPDFTextDoesNotRenderImage() async throws {
        let fixture = PreviewFixture([Data("application/pdf; charset=binary".utf8), Data("extracted text".utf8)])
        let doc = try await FilePreviewService(runner: fixture).load(host: "example", path: "/doc.pdf", preferences: .init())
        XCTAssertEqual(doc.kind, .pdf)
        XCTAssertEqual(doc.text, "extracted text")
        XCTAssertNil(doc.image)
        let commands = await fixture.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[1].contains("pdftotext -f 1 -l 3 '/doc.pdf' -"))
        XCTAssertFalse(commands.contains { $0.contains("pdftoppm") })
    }

    func testPDFImageRendersOnlyFirstPageWithinConfiguredLimits() async throws {
        #if canImport(ImageIO)
        let bytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg=="))
        let fixture = PreviewFixture([Data("application/pdf; charset=binary".utf8), bytes])
        var limits = ResourceLimits.default
        limits.previewTimeoutSeconds = 7
        let doc = try await FilePreviewService(runner: fixture).load(host: "example", path: "/a'b.pdf", preferences: .init(), limits: limits, pdfTab: .firstPage)
        XCTAssertEqual(doc.kind, .pdf)
        XCTAssertEqual(doc.text, "")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(doc.image) as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let commands = await fixture.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[1].hasSuffix("pdftoppm -f 1 -l 1 -singlefile -scale-to 2048 -png '/a'\\''b.pdf'"))
        XCTAssertFalse(commands.contains { $0.contains("pdftotext") })
        let timeouts = await fixture.timeouts
        XCTAssertEqual(timeouts, [7, 7])
        #else
        throw XCTSkip("ImageIO is required for PDF image previews")
        #endif
    }

    func testPDFImageHonorsBinaryBudgetBeforeDecoding() async {
        let fixture = PreviewFixture([Data("application/pdf; charset=binary".utf8), Data(repeating: 0, count: 1_048_577)])
        do {
            _ = try await FilePreviewService(runner: fixture).load(host: "example", path: "/doc.pdf", preferences: .init(binaryMiB: 1), pdfTab: .firstPage)
            XCTFail("Expected binary limit error")
        } catch { XCTAssertEqual(error.localizedDescription, "limit") }
    }

    func testQuotingCannotExecuteFilenameAsShellCode() throws {
        let value = "/a'b/$(touch bad);*.txt"
        XCTAssertEqual(try FilePreviewService.quote(value), "'/a'\\''b/$(touch bad);*.txt'")
        XCTAssertThrowsError(try FilePreviewService.quote("-option"))
        XCTAssertThrowsError(try FilePreviewService.quote("/bad\nname"))
    }
    func testDetectionUsesMIMEAndCharset() {
        XCTAssertEqual(PreviewKind.detect("application/json", charset: "utf-8"), .text)
        XCTAssertEqual(PreviewKind.detect("image/png", charset: "binary"), .image)
        XCTAssertEqual(PreviewKind.detect("application/pdf", charset: "binary"), .pdf)
        XCTAssertEqual(PreviewKind.detect("video/mp4", charset: "binary"), .media)
        XCTAssertEqual(PreviewKind.detect("application/octet-stream", charset: "binary"), .hex)
        XCTAssertEqual(PreviewKind.detect("application/zip", charset: "binary"), .archive)
    }
    func testPagingKeepsRealLineNumbersAndDetectsEOF() async throws {
        let mime = Data("text/plain; charset=utf-8\n".utf8)
        let sample = Data("text".utf8)
        let fixture = PreviewFixture([mime, sample, Data("a\nb\nc\n".utf8), mime, sample, Data("c\n".utf8),
                                      mime, sample, Data("7\n".utf8), Data("f\ng".utf8)])
        let service = FilePreviewService(runner: fixture)
        let settings = PreviewPreferences(lines: 2)
        let first = try await service.load(host: "example", path: "/log", preferences: settings, limits: .default)
        XCTAssertEqual(first.text, "a\nb"); XCTAssertEqual(first.lineCount, 2); XCTAssertTrue(first.hasNext)
        let next = try await service.load(host: "example", path: "/log", preferences: settings, current: first, page: .next, limits: .default)
        XCTAssertEqual(next.firstLine, 3); XCTAssertFalse(next.hasNext)
        let last = try await service.load(host: "example", path: "/log", preferences: settings, current: next, page: .last, limits: .default)
        XCTAssertEqual(last.firstLine, 6); XCTAssertEqual(last.text, "f\ng"); XCTAssertFalse(last.hasNext)
        let commands = await fixture.commands
        XCTAssertTrue(commands[5].contains("head -n 5 '/log' | tail -n +3"))
        XCTAssertTrue(commands[8].contains("awk 'END { print NR }'"))
    }
    func testNULFallsBackToBoundedHexDump() async throws {
        let fixture = PreviewFixture([Data("text/plain; charset=utf-8".utf8), Data([65, 0, 66]), Data([65, 0, 66])])
        let doc = try await FilePreviewService(runner: fixture).load(host: "example", path: "/unknown.txt", preferences: .init(), limits: .default)
        XCTAssertEqual(doc.kind, .hex)
        XCTAssertTrue(doc.text.contains("41 00 42")); XCTAssertTrue(doc.text.contains("|A.B|"))
        let commands = await fixture.commands
        XCTAssertTrue(commands.last!.contains("head -c 256"))
    }
    func testTextPageAcceptsExactlyOneMiB() async throws {
        let data = Data(repeating: 65, count: 1_048_576)
        let fixture = PreviewFixture([Data("text/plain; charset=utf-8".utf8), Data("sample".utf8), data])
        let doc = try await FilePreviewService(runner: fixture).load(host: "example", path: "/text", preferences: .init(), limits: .default)
        XCTAssertEqual(doc.text.utf8.count, data.count)
        XCTAssertEqual(doc.lineCount, 1)
        XCTAssertFalse(doc.hasNext)
    }
    func testConfiguredTextSizeAndTimeoutAreApplied() async throws {
        let data = Data(repeating: 65, count: 1_048_577)
        let fixture = PreviewFixture([Data("text/plain; charset=utf-8".utf8), Data("sample".utf8), data])
        var limits = ResourceLimits()
        limits.previewTextMiB = 2
        limits.previewTimeoutSeconds = 7
        let doc = try await FilePreviewService(runner: fixture).load(host: "example", path: "/text", preferences: .init(), limits: limits)
        XCTAssertEqual(doc.text.utf8.count, data.count)
        let timeouts = await fixture.timeouts
        XCTAssertEqual(timeouts, [7, 7, 7])
    }
    func testTextPageRejectsOneByteOverLimitBeforeDecoding() async {
        var data = Data(repeating: 65, count: 1_048_576)
        data.append(0xff)
        let fixture = PreviewFixture([Data("text/plain; charset=utf-8".utf8), Data("sample".utf8), data])
        do {
            _ = try await FilePreviewService(runner: fixture).load(host: "example", path: "/text", preferences: .init(), limits: .default)
            XCTFail("Expected text size error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "テキストが1ページの取得上限（1 MiB）を超えています。ダウンロードして確認してください。")
        }
    }
    func testLongTextLineIsBoundedByRemoteCommand() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenSFTP-preview-\(UUID().uuidString).txt")
        try Data(repeating: 65, count: 2_097_152).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await FilePreviewService(runner: LocalPreviewRunner()).load(host: "example", path: url.path, preferences: .init(), limits: .default)
            XCTFail("Expected text size error")
        } catch {
            // A missing remote cap would fail in PreviewProcess with a generic
            // output-limit error instead of reaching the text overflow check.
            XCTAssertEqual(error.localizedDescription, "テキストが1ページの取得上限（1 MiB）を超えています。ダウンロードして確認してください。")
        }
    }
    func testImageRetainsBinaryWithoutUTF8Conversion() async throws {
        #if canImport(ImageIO)
        let bytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg=="))
        let fixture = PreviewFixture([Data("image/png; charset=binary".utf8), Data("\(bytes.count)\n".utf8), bytes])
        let doc = try await FilePreviewService(runner: fixture).load(host: "example", path: "/misnamed.txt", preferences: .init(), limits: .default)
        XCTAssertEqual(doc.kind, .image)
        let image = try XCTUnwrap(doc.image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(image as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 1)
        #else
        throw XCTSkip("ImageIO is required for image previews")
        #endif
    }
    func testKnownOversizedImageStopsBeforeReceivingImageBytes() async {
        let fixture = PreviewFixture([Data("image/png; charset=binary".utf8), Data("5242881\n".utf8)])
        do {
            _ = try await FilePreviewService(runner: fixture).load(host: "example", path: "/large.png", preferences: .init(), limits: .default)
            XCTFail("Expected preflight size error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("画像が取得上限")) }
        let commands = await fixture.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertFalse(commands.contains { $0.contains("head -c") })
    }
    func testInvalidImageSizeDoesNotStartImageTransfer() async {
        let fixture = PreviewFixture([Data("image/png; charset=binary".utf8), Data("not a size\n".utf8)])
        do {
            _ = try await FilePreviewService(runner: fixture).load(host: "example", path: "/bad.png", preferences: .init(), limits: .default)
            XCTFail("Expected preflight size error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("ファイルサイズを確認")) }
        let commands = await fixture.commands
        XCTAssertEqual(commands.count, 2)
    }
    func testImageThatGrowsAfterSizeCheckStillCannotExceedTransferLimit() async {
        let fixture = PreviewFixture([Data("image/png; charset=binary".utf8), Data("1\n".utf8),
                                      Data(repeating: 0, count: ImagePreview.headerBytes), Data(repeating: 0, count: 5 * 1_048_576 + 1)])
        do {
            _ = try await FilePreviewService(runner: fixture).load(host: "example", path: "/changed.png", preferences: .init(), limits: .default)
            XCTFail("Expected post-transfer size error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("画像が取得上限")) }
    }
    func testOversizedVideoKeepsMetadataWithoutRequestingAFrame() async throws {
        let info = Data(#"{"streams":[{"codec_type":"video","width":10000,"height":10000}],"format":{}}"#.utf8)
        let fixture = PreviewFixture([Data("video/mp4; charset=binary".utf8), info])
        let doc = try await FilePreviewService(runner: fixture).load(host: "example", path: "/large.mp4", preferences: .init(), limits: .default)
        XCTAssertEqual(doc.kind, .media)
        XCTAssertNil(doc.image)
        XCTAssertTrue(doc.note.contains("上限"))
        XCTAssertTrue(doc.text.contains("streams"))
        let commands = await fixture.commands
        XCTAssertFalse(commands.contains { $0.contains("ffmpeg ") })
    }
    func testSFTPOnlyResponseStopsBeforeContentRead() async {
        let fixture = PreviewFixture([Data("This service allows sftp connections only.\n".utf8)])
        do {
            _ = try await FilePreviewService(runner: fixture).load(host: "example", path: "/a", preferences: .init(), limits: .default)
            XCTFail("Expected SSH command error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("SSHコマンドが利用できない")) }
        let commands = await fixture.commands
        XCTAssertEqual(commands.count, 1)
    }
    func testEmptyFileAndUnterminatedFinalLine() async throws {
        for (data, count) in [(Data(), 0), (Data("last".utf8), 1)] {
            let fixture = PreviewFixture([Data("text/plain; charset=utf-8".utf8), data, data])
            let doc = try await FilePreviewService(runner: fixture).load(host: "example", path: "/a", preferences: .init(), limits: .default)
            XCTAssertEqual(doc.lineCount, count); XCTAssertFalse(doc.hasNext)
        }
    }
    func testPreferencesClampAndPersist() throws {
        let name = "FilePreviewTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(PreviewPreferences(defaults: defaults), .init())
        PreviewPreferences(lines: 2000, binaryMiB: -1).save(to: defaults)
        XCTAssertEqual(PreviewPreferences(defaults: defaults), .init(lines: 1000, binaryMiB: 1))
    }
    func testEncodingAndHex() throws {
        XCTAssertEqual(try FilePreviewService.decode(Data([0x63, 0x61, 0x66, 0xe9]), charset: "iso-8859-1"), "café")
        XCTAssertThrowsError(try FilePreviewService.decode(Data([0xff]), charset: "utf-8"))
        XCTAssertEqual(FilePreviewService.hex(Data()), "")
    }
    func testBoundedProcessStopsExcessiveOutput() async {
        do {
            _ = try await PreviewProcess.run("/bin/sh", ["-c", "while :; do printf 1234567890; done"], limit: 100)
            XCTFail("Expected output limit error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("上限")) }
    }
    func testConfiguredTimeoutStopsThePreviewProcessGroup() async {
        let started = Date()
        do {
            _ = try await PreviewProcess.run("/bin/sh", ["-c", "sleep 30 & wait"], limit: 100, timeout: 1)
            XCTFail("Expected preview timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("処理時間が上限"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
    func testProcessPreservesBinaryAndDrainsDiagnosticPipe() async throws {
        let data = try await PreviewProcess.run("/bin/sh", ["-c", "printf '\\000\\377'; i=0; while [ $i -lt 1000 ]; do echo warning >&2; i=$((i+1)); done"], limit: 10)
        XCTAssertEqual(data, Data([0, 255]))
    }
    func testProcessReportsFailureBeforePipelineEvenWhenHeadSucceeds() async {
        do {
            _ = try await PreviewProcess.run("/bin/sh", ["-c", "echo OPEN_SFTP_PREVIEW_COMMAND_FAILED:127 >&2; exit 0"], limit: 100)
            XCTFail("Expected upstream failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("必要なツール")) }
    }
    func testCancellationStopsProcessGroup() async throws {
        let stopped = expectation(description: "preview stopped")
        let task = Task {
            do {
                _ = try await PreviewProcess.run("/bin/sh", ["-c", "sleep 30 & wait"], limit: 100)
                XCTFail("Expected cancellation")
            } catch {}
            stopped.fulfill()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 3)
    }
}

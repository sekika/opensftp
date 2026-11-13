import XCTest
@testable import SFTPCore

final class RemoteWireTests: XCTestCase {
    private func n(_ value: UInt32) -> Data { SFTPLinkService.uint32(value) }
    private func string(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return n(UInt32(bytes.count)) + bytes
    }
    private func packet(_ value: Data) -> Data { n(UInt32(value.count)) + value }
    private func version(rename: Bool = false) -> Data {
        packet(Data([2]) + n(3) + (rename ? string("posix-rename@openssh.com") + string("1") : Data()))
    }
    private func status(_ id: UInt32, _ code: UInt32) -> Data {
        packet(Data([101]) + n(id) + n(code) + string("status") + string(""))
    }
    private func exchange(_ operation: RemoteOperation, responses: Data, limits: ResourceLimits = .default) throws -> (RemoteReply, Data) {
        let input = Pipe(), output = Pipe()
        try output.fileHandleForWriting.write(contentsOf: responses)
        try output.fileHandleForWriting.close()
        let wire = RemoteWire(input: input.fileHandleForWriting, output: output.fileHandleForReading, limits: limits)
        defer {
            try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
        }
        let reply = try wire.perform(operation)
        try input.fileHandleForWriting.close()
        return (reply, input.fileHandleForReading.readDataToEndOfFile())
    }
    func testLstatDecodesFullSizeModeAndSecondPrecisionTimestamps() throws {
        let attrs = n(1 | 4 | 8) + n(2) + n(3) + n(0o100640) + n(100) + n(101)
        let response = packet(Data([105]) + n(1) + attrs)
        let (reply, sent) = try exchange(.attributes("/a", false), responses: version() + response)
        XCTAssertEqual(reply.attributes?.size, (UInt64(2) << 32) + 3)
        XCTAssertEqual(reply.attributes?.kind, .file)
        XCTAssertEqual(reply.attributes?.modified, 101)
        XCTAssertEqual(sent, packet(Data([1]) + n(3)) + packet(Data([7]) + n(1) + string("/a")))
    }
    func testMissingIsDistinctFromPermissionDenied() throws {
        let (reply, _) = try exchange(.attributes("/missing", false), responses: version() + status(1, 2))
        XCTAssertNil(reply.attributes)
        XCTAssertThrowsError(try exchange(.attributes("/private", false), responses: version() + status(1, 3)))
    }
    func testDirectoryNamesAreExactEvenWhenLongnameIsAmbiguous() throws {
        let handle = packet(Data([102]) + n(1) + string("handle"))
        let first = string("link -> literal") + string("untrusted longname") + n(4) + n(0o120777)
        let second = string("日本語 [x].txt") + string("not an ls row") + n(4) + n(0o100644)
        let names = packet(Data([104]) + n(2) + n(2) + first + second)
        let (reply, _) = try exchange(.list("/folder"), responses: version() + handle + names + status(3, 1) + status(4, 0))
        XCTAssertEqual(reply.nodes?.map(\.name), ["link -> literal", "日本語 [x].txt"])
        XCTAssertEqual(reply.nodes?.first?.attributes.kind, .symbolicLink)
    }
    func testExclusiveTemporaryCreationUsesPrivateMode() throws {
        let handle = packet(Data([102]) + n(1) + string("handle"))
        let (_, sent) = try exchange(.create("/temp"), responses: version() + handle + status(2, 0))
        let expected = packet(Data([3]) + n(1) + string("/temp") + n(0x2 | 0x8 | 0x20) + n(4) + n(0o600))
        XCTAssertNotNil(sent.range(of: expected))
    }
    func testDirectoryEntryLimitIsCumulativeAcrossPackets() throws {
        var limits = ResourceLimits()
        limits.listingEntries = 1
        let handle = packet(Data([102]) + n(1) + string("handle"))
        func row(_ id: UInt32, _ name: String) -> Data {
            packet(Data([104]) + n(id) + n(1) + string(name) + string("display") + n(4) + n(0o100644))
        }
        XCTAssertThrowsError(try exchange(.list("/folder"), responses: version() + handle + row(2, "first") + row(3, "second"), limits: limits)) { error in
            XCTAssertTrue(error is ResourceLimitError)
        }
    }
    func testListingByteBudgetRejectsNextPacketBeforeAllocatingItsBody() throws {
        var limits = ResourceLimits()
        limits.listingMiB = 1
        let handle = packet(Data([102]) + n(1) + string("handle"))
        // The declared packet fits the fixed protocol cap, but exceeds the
        // remaining listing budget after OPENDIR's response. No body is sent.
        XCTAssertThrowsError(try exchange(.list("/folder"), responses: version() + handle + n(1_048_576), limits: limits)) { error in
            XCTAssertTrue(error is ResourceLimitError)
        }
    }
    func testOverwriteRequiresAdvertisedPosixRename() throws {
        XCTAssertThrowsError(try exchange(.rename("/temp", "/file", true), responses: version()))
        let (_, sent) = try exchange(.rename("/temp", "/file", true), responses: version(rename: true) + status(1, 0))
        XCTAssertNotNil(sent.range(of: packet(Data([200]) + n(1) + string("posix-rename@openssh.com") + string("/temp") + string("/file"))))
        let (_, ordinary) = try exchange(.rename("/temp", "/new", false), responses: version() + status(1, 0))
        XCTAssertNotNil(ordinary.range(of: packet(Data([18]) + n(1) + string("/temp") + string("/new"))))
    }
    func testSymlinkUsesOpenSSHOrderAndNeverTouchesTarget() throws {
        let (_, sent) = try exchange(.symlink("/copy/link", "../target"), responses: version() + status(1, 0))
        XCTAssertNotNil(sent.range(of: packet(Data([20]) + n(1) + string("../target") + string("/copy/link"))))
    }
}

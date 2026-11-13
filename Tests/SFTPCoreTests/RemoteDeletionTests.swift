import XCTest
@testable import SFTPCore

@MainActor
final class RemoteDeletionTests: XCTestCase {
    private func deletion(_ runner: TreeRunner) -> RemoteDeletion {
        RemoteDeletion(host: "test", service: runner, log: { _ in }, status: { _ in })
    }

    func testRecursivelyDeletesHiddenNestedAndEmptyFoldersButKeepsOutside() async throws {
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/.hidden": .init(.file, "hidden"),
                                 "/remote/tree/a empty": .init(.directory),
                                 "/remote/tree/nested": .init(.directory),
                                 "/remote/tree/nested/日本語.pdf": .init(.file, "bytes"),
                                 "/remote/keep": .init(.file, "keep")])
        let count = try await deletion(runner).removeFolder(at: "/remote/tree")
        XCTAssertEqual(count, 5)
        let tree = await runner.tree
        XCTAssertNil(tree["/remote/tree"])
        XCTAssertFalse(tree.keys.contains { $0.hasPrefix("/remote/tree/") })
        XCTAssertEqual(tree["/remote/keep"]?.data, Data("keep".utf8))
        let batches = await runner.batches
        let commands = batches.flatMap { $0 }.filter { $0.hasPrefix("rm ") || $0.hasPrefix("rmdir ") }
        XCTAssertEqual(commands, ["rm \"/remote/tree/.hidden\"", "rmdir \"/remote/tree/a empty\"",
                                  "rm \"/remote/tree/nested/日本語.pdf\"", "rmdir \"/remote/tree/nested\"", "rmdir \"/remote/tree\""])
    }

    func testDeletesLinkItselfWithoutEnumeratingTarget() async throws {
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/link": .init(.symbolicLink),
                                 "/outside": .init(.directory), "/outside/keep": .init(.file, "keep")])
        let count = try await deletion(runner).removeFolder(at: "/remote/tree")
        XCTAssertEqual(count, 2)
        let tree = await runner.tree
        XCTAssertEqual(tree["/outside/keep"]?.data, Data("keep".utf8))
        let batches = await runner.batches
        XCTAssertFalse(batches.flatMap { $0 }.contains { $0 == "cd \"/remote/tree/link\"" || $0 == "cd \"/outside\"" })
    }

    func testMalformedNestedListingPreventsAllDeletions() async throws {
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/a-file": .init(.file, "keep"),
                                 "/remote/tree/z-folder": .init(.directory)], malformedListingAt: "/remote/tree/z-folder")
        do {
            _ = try await deletion(runner).removeFolder(at: "/remote/tree")
            XCTFail("Expected enumeration failure")
        } catch { }
        let tree = await runner.tree
        XCTAssertEqual(tree.count, 4)
        let batches = await runner.batches
        XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("rm ") || $0.hasPrefix("rmdir ") })
    }

    func testAmbiguousLinkNameAbortsBeforeDeletingAnything() async throws {
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/a-file": .init(.file, "keep"),
                                 "/remote/tree/link -> name": .init(.symbolicLink)])
        do {
            _ = try await deletion(runner).removeFolder(at: "/remote/tree")
            XCTFail("Expected ambiguous link name failure")
        } catch { }
        let tree = await runner.tree
        XCTAssertEqual(tree.count, 4)
        let batches = await runner.batches
        XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("rm ") || $0.hasPrefix("rmdir ") })
    }

    func testFailureStopsDeletionAndKeepsRemainingItems() async throws {
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/a": .init(.file), "/remote/tree/b": .init(.file),
                                 "/remote/tree/c": .init(.file)], failDelete: "/remote/tree/b")
        do {
            _ = try await deletion(runner).removeFolder(at: "/remote/tree")
            XCTFail("Expected deletion failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("一部の項目は削除済み"))
        }
        let tree = await runner.tree
        XCTAssertNil(tree["/remote/tree/a"])
        XCTAssertNotNil(tree["/remote/tree/b"])
        XCTAssertNotNil(tree["/remote/tree/c"])
        XCTAssertNotNil(tree["/remote/tree"])
    }

    func testRootTraversalPathsAndTopLevelLinksAreRejectedWithoutDeleting() async throws {
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/link": .init(.symbolicLink)])
        for path in ["/", "//", "relative", "/remote/../remote", "/remote/./tree", "/remote/link"] {
            do {
                _ = try await deletion(runner).removeFolder(at: path)
                XCTFail("Unsafe path accepted: \(path)")
            } catch { }
        }
        let tree = await runner.tree
        XCTAssertEqual(tree.count, 2)
        let batches = await runner.batches
        XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("rm ") || $0.hasPrefix("rmdir ") })
    }

    func testDirectoryReplacedByLinkDuringDeletionStopsBeforeItsChildren() async throws {
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/a-file": .init(.file), "/remote/tree/z-folder": .init(.directory),
                                 "/remote/tree/z-folder/child": .init(.file, "keep")],
                                replaceDirectoryAfterRemoval: "/remote/tree/z-folder")
        do {
            _ = try await deletion(runner).removeFolder(at: "/remote/tree")
            XCTFail("Expected changed directory failure")
        } catch { }
        let tree = await runner.tree
        XCTAssertNil(tree["/remote/tree/a-file"])
        XCTAssertNotNil(tree["/remote/tree/z-folder/child"])
        let batches = await runner.batches
        XCTAssertFalse(batches.flatMap { $0 }.contains("rm \"/remote/tree/z-folder/child\""))
    }
}

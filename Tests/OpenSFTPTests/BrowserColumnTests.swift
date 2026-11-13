import XCTest
import AppKit
import SFTPCore
@testable import OpenSFTP

@MainActor
final class BrowserColumnTests: XCTestCase {
    func testDraggingHeaderBoundaryPreservesSelectionAndSortingAndSavesWidth() throws {
        let suite = "OpenSFTP.ColumnTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.entries = DirectoryListing.parse("Remote working directory: /\n-rw-r--r-- 1 u g 1 Jan 1 2024 file\n").entries
        model.selection = ["file"]
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1050, height: 400))
        let canvas = BrowserCanvas(model: model)
        scroll.documentView = canvas
        window.contentView = scroll
        canvas.update(width: scroll.contentSize.width, minimumHeight: scroll.contentSize.height)
        func mouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            let point = canvas.convert(NSPoint(x: x, y: 10), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                   clickCount: 1, pressure: 1))
        }
        for column in 0..<3 {
            let original = model.listColumnWidths[column]
            let boundary = BrowserColumnLayout(savedWidths: model.listColumnWidths.map { Double($0) }).starts[column + 1] - 6
            canvas.mouseDown(with: try mouse(.leftMouseDown, x: boundary))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, x: boundary + 80))
            canvas.mouseUp(with: try mouse(.leftMouseUp, x: boundary + 80))
            XCTAssertEqual(model.listColumnWidths[column], original + 80)
            XCTAssertEqual(model.sortColumn, 0)
            XCTAssertTrue(model.ascending)
            XCTAssertEqual(model.selection, ["file"])
            XCTAssertTrue(model.jobs.isEmpty)
        }
        model.iconView = true
        let restored = AppModel(defaults: defaults)
        XCTAssertTrue(restored.iconView)
        XCTAssertEqual(restored.listColumnWidths, model.listColumnWidths)
        restored.iconView = false
        XCTAssertEqual(restored.listColumnWidths, model.listColumnWidths)
    }

    func testNarrowColumnsAreClampedAndInvalidSavedWidthsFallBack() {
        let clamped = BrowserColumnLayout(savedWidths: [1, 2, 3])
        XCTAssertEqual(clamped.widths, BrowserColumnLayout.minimums)
        XCTAssertEqual(clamped.starts, [12, 112, 192, 262])
        XCTAssertEqual(clamped.requiredWidth, 402)
        XCTAssertEqual(BrowserColumnLayout(savedWidths: [Double.nan, 100, 100]).widths, BrowserColumnLayout.defaults)
        XCTAssertEqual(BrowserColumnLayout(savedWidths: [100, 100]).widths, BrowserColumnLayout.defaults)
    }
}

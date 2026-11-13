import AppKit
import SwiftUI

@MainActor
struct WindowSizePreferences {
    static let defaultMinimum = CGSize(width: 600, height: 550)
    static let firstLaunch = CGSize(width: 1050, height: 760)
    private let defaults: UserDefaults
    private let widthKey = "mainWindowContentWidth"
    private let heightKey = "mainWindowContentHeight"
    private let minWidthKey = "minWindowContentWidth"
    private let minHeightKey = "minWindowContentHeight"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var minimum: CGSize {
        let width = defaults.double(forKey: minWidthKey)
        let height = defaults.double(forKey: minHeightKey)
        let minW = (width.isFinite && width >= 300) ? CGFloat(width) : Self.defaultMinimum.width
        let minH = (height.isFinite && height >= 250) ? CGFloat(height) : Self.defaultMinimum.height
        return CGSize(width: minW, height: minH)
    }

    static var minimum: CGSize {
        WindowSizePreferences().minimum
    }

    var restoredSize: CGSize {
        let width = defaults.double(forKey: widthKey)
        let height = defaults.double(forKey: heightKey)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return Self.firstLaunch }
        return CGSize(width: max(CGFloat(width), minimum.width), height: max(CGFloat(height), minimum.height))
    }

    func save(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        defaults.set(Double(max(size.width, minimum.width)), forKey: widthKey)
        defaults.set(Double(max(size.height, minimum.height)), forKey: heightKey)
    }

    func saveMinimum(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width >= 300, size.height >= 250 else { return }
        defaults.set(Double(size.width), forKey: minWidthKey)
        defaults.set(Double(size.height), forKey: minHeightKey)
    }
}

/// Read this content view's window rather than NSApp.keyWindow, which may be
/// an alert or a download destination panel when the application quits.
@MainActor
struct MainWindowReader: NSViewRepresentable {
    let attach: (NSWindow) -> Void
    func makeNSView(context: Context) -> Probe { Probe(attach: attach) }
    func updateNSView(_ view: Probe, context: Context) {
        view.attach = attach
        if let window = view.window { attach(window) }
    }

    @MainActor final class Probe: NSView {
        var attach: (NSWindow) -> Void
        init(attach: @escaping (NSWindow) -> Void) { self.attach = attach; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach(window) }
        }
    }
}

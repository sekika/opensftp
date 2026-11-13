import Foundation
import SwiftUI
import SFTPCore

extension Notification.Name {
    public static let appearancePreferencesChanged = Notification.Name("OpenSFTP.appearancePreferencesChanged")
    public static let connectionPreferencesChanged = Notification.Name("OpenSFTP.connectionPreferencesChanged")
}

public struct AppearancePreferences: Sendable, Equatable {
    public var minWindowWidth: Double
    public var minWindowHeight: Double
    public var iconSize: Double
    public var iconLabelLines: Int
    public var colorTheme: AppColorTheme

    public static let defaultMinWindowWidth: Double = 600
    public static let defaultMinWindowHeight: Double = 550
    public static let iconSizeRange: ClosedRange<Double> = 24...60
    public static let defaultIconSize: Double = 42
    public static let defaultIconLabelLines: Int = 2

    public var iconTileWidth: Double { iconSize * 2 + 16 }

    public static let `default` = AppearancePreferences(
        minWindowWidth: defaultMinWindowWidth,
        minWindowHeight: defaultMinWindowHeight,
        iconSize: defaultIconSize,
        iconLabelLines: defaultIconLabelLines
    )

    public init(
        minWindowWidth: Double = defaultMinWindowWidth,
        minWindowHeight: Double = defaultMinWindowHeight,
        iconSize: Double = defaultIconSize,
        iconLabelLines: Int = defaultIconLabelLines,
        colorTheme: AppColorTheme = .system
    ) {
        self.minWindowWidth = minWindowWidth
        self.minWindowHeight = minWindowHeight
        self.iconSize = iconSize
        self.iconLabelLines = iconLabelLines
        self.colorTheme = colorTheme
    }

    public init(defaults: UserDefaults) {
        let width = defaults.double(forKey: "minWindowContentWidth")
        self.minWindowWidth = (width.isFinite && width >= 300) ? width : Self.defaultMinWindowWidth
        let height = defaults.double(forKey: "minWindowContentHeight")
        self.minWindowHeight = (height.isFinite && height >= 250) ? height : Self.defaultMinWindowHeight
        let size = defaults.double(forKey: "iconViewIconSize")
        self.iconSize = (size.isFinite && size >= 24 && size <= 256) ? size : Self.defaultIconSize
        let lines = defaults.integer(forKey: "iconViewLabelLines")
        self.iconLabelLines = (1...10).contains(lines) ? lines : Self.defaultIconLabelLines
        self.colorTheme = AppColorTheme(rawValue: defaults.string(forKey: "appearanceColorTheme") ?? "system") ?? .system
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(minWindowWidth, forKey: "minWindowContentWidth")
        defaults.set(minWindowHeight, forKey: "minWindowContentHeight")
        defaults.set(iconSize, forKey: "iconViewIconSize")
        defaults.set(iconLabelLines, forKey: "iconViewLabelLines")
        defaults.set(colorTheme.rawValue, forKey: "appearanceColorTheme")
    }

    public static var standard: AppearancePreferences {
        AppearancePreferences(defaults: .standard)
    }
}

public enum AppColorTheme: String, CaseIterable, Sendable {
    case system, light, dark

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
public final class AppPreferences: ObservableObject {
    public static let shared = AppPreferences()
    private let defaults: UserDefaults

    @Published public var appearance: AppearancePreferences {
        didSet {
            appearance.save(to: defaults)
            NotificationCenter.default.post(name: .appearancePreferencesChanged, object: self)
        }
    }

    @Published public var connection: ConnectionPreferences {
        didSet {
            connection.save(to: defaults)
            NotificationCenter.default.post(name: .connectionPreferencesChanged, object: self)
        }
    }

    @Published public var preview: PreviewPreferences {
        didSet {
            if preview != preview.validated { preview = preview.validated }
            preview.save(to: defaults)
        }
    }
    @Published public var limits: ResourceLimits {
        didSet {
            if limits != limits.validated { limits = limits.validated }
            limits.save(to: defaults)
        }
    }
    @Published public var doubleClickAction: DoubleClickAction {
        didSet { defaults.set(doubleClickAction.rawValue, forKey: "doubleClickAction") }
    }
    @Published public var downloadDirectory: URL {
        didSet { defaults.set(downloadDirectory.path, forKey: "openDownloadDirectory") }
    }

    public enum DoubleClickAction: String, CaseIterable, Sendable {
        case preview, download
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preview = PreviewPreferences(defaults: defaults)
        self.limits = ResourceLimits(defaults: defaults)
        self.doubleClickAction = DoubleClickAction(rawValue: defaults.string(forKey: "doubleClickAction") ?? "preview") ?? .preview
        self.downloadDirectory = URL(fileURLWithPath: defaults.string(forKey: "openDownloadDirectory") ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true).path,
            isDirectory: true)
        self.appearance = AppearancePreferences(defaults: defaults)
        self.connection = ConnectionPreferences(defaults: defaults)
    }

    public func resetAppearance() {
        self.appearance = .default
    }

    public func resetConnection() {
        self.connection = .default
    }

    public func resetLimits() {
        limits = .default
        preview = PreviewPreferences()
    }
}

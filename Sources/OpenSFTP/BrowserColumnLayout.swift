import Foundation

struct BrowserColumnLayout {
    static let defaults: [CGFloat] = [400, 140, 110]
    static let minimums: [CGFloat] = [100, 80, 70]
    static let leading: CGFloat = 12
    static let dateMinimum: CGFloat = 140
    let widths: [CGFloat]

    init(savedWidths: [Double]?) {
        guard let savedWidths, savedWidths.count == 3, savedWidths.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            widths = Self.defaults
            return
        }
        widths = zip(savedWidths, Self.minimums).map { max(CGFloat($0.0), $0.1) }
    }

    var starts: [CGFloat] {
        var result = [Self.leading]
        for width in widths { result.append(result.last! + width) }
        return result
    }
    var requiredWidth: CGFloat { starts.last! + Self.dateMinimum }
}

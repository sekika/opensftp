import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Fixed decoder safeguards, rather than additional user-facing preferences.
/// The configurable byte limit protects transfer buffers; these limits protect
/// decoded pixels, which can be much larger than the compressed source file.
enum ImagePreview {
    static let maximumPixels = 50_000_000
    static let maximumDimension = 16_384
    static let thumbnailDimension = 2_048
    static let headerBytes = 65_536

    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw PreviewError("画像の寸法を確認できません。") }
        // Division avoids overflowing width * height on untrusted dimensions.
        guard width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixels / height else {
            throw PreviewError("画像の寸法が上限（5,000万画素・各辺16,384ピクセル）を超えています。ダウンロードして確認してください。")
        }
    }

    static func validateHeader(_ data: Data) throws {
        #if canImport(ImageIO)
        let source = CGImageSourceCreateIncremental([kCGImageSourceShouldCache: false] as CFDictionary)
        CGImageSourceUpdateData(source, data as CFData, false)
        // Some formats keep their dimensions after the prefix. In that case,
        // defer validation until the bounded full stream arrives; never guess.
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           properties[kCGImagePropertyPixelWidth] != nil, properties[kCGImagePropertyPixelHeight] != nil {
            _ = try dimensions(properties)
        }
        #endif
    }

    static func thumbnail(_ data: Data) async throws -> Data {
        // Neither ImageIO parsing nor decoding runs on the UI actor. Cancelling
        // a preview discards the result; ImageIO itself has no cancellation API.
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try Self.makeThumbnail(data)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func makeThumbnail(_ data: Data) throws -> Data {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw PreviewError("画像の寸法を確認できません。")
        }
        let size = try dimensions(properties)
        // Use only frame/page zero and force generation from the checked source,
        // rather than trusting an embedded thumbnail. Never fall back to
        // NSImage(data: originalBytes) if validation or thumbnail creation fails.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(thumbnailDimension, max(size.width, size.height)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0,
              image.width <= thumbnailDimension, image.height <= thumbnailDimension else {
            throw PreviewError("画像の縮小表示を作成できません。")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw PreviewError("画像の縮小表示を作成できません。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PreviewError("画像の縮小表示を作成できません。") }
        return output as Data
        #else
        throw PreviewError("この画像形式を表示できません")
        #endif
    }

    #if canImport(ImageIO)
    private static func dimensions(_ properties: [CFString: Any]) throws -> (width: Int, height: Int) {
        guard let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue > 0, height.doubleValue > 0 else {
            throw PreviewError("画像の寸法を確認できません。")
        }
        // Bound before converting NSNumber, avoiding truncation of huge values.
        guard width.doubleValue <= Double(maximumDimension), height.doubleValue <= Double(maximumDimension) else {
            throw PreviewError("画像の寸法が上限（5,000万画素・各辺16,384ピクセル）を超えています。ダウンロードして確認してください。")
        }
        let w = width.intValue, h = height.intValue
        guard Double(w) == width.doubleValue, Double(h) == height.doubleValue else { throw PreviewError("画像の寸法を確認できません。") }
        try validateDimensions(width: w, height: h)
        return (w, h)
    }
    #endif
}

import Foundation
import XCTest
@testable import SFTPCore
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

final class ImagePreviewTests: XCTestCase {
    func testFixedDimensionAndPixelBoundaries() throws {
        XCTAssertNoThrow(try ImagePreview.validateDimensions(width: 10_000, height: 5_000))
        XCTAssertNoThrow(try ImagePreview.validateDimensions(width: 16_384, height: 1))
        for (width, height) in [(10_000, 5_001), (16_385, 1), (1, 16_385), (0, 1), (1, -1), (Int.max, Int.max)] {
            XCTAssertThrowsError(try ImagePreview.validateDimensions(width: width, height: height))
        }
    }

    #if canImport(ImageIO)
    private func image(width: Int, height: Int, red: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return try XCTUnwrap(context.makeImage())
    }
    private func encode(_ images: [CGImage], type: CFString = "public.png" as CFString) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, type, images.count, nil))
        for image in images { CGImageDestinationAddImage(destination, image, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testThumbnailBoundsAndAspectRatio() async throws {
        let original = try encode([image(width: 3000, height: 1500, red: 1)])
        let data = try await ImagePreview.thumbnail(original)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let thumbnail = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(thumbnail.width, 2048)
        XCTAssertEqual(thumbnail.height, 1024)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
    }
    func testAnimatedInputBecomesOneStaticPngFrame() async throws {
        let first = try image(width: 4, height: 2, red: 1)
        let second = try image(width: 4, height: 2, red: 0)
        let original = try encode([first, second], type: "com.compuserve.gif" as CFString)
        let input = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(input), 2)
        let data = try await ImagePreview.thumbnail(original)
        let output = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(output), 1)
        XCTAssertEqual(CGImageSourceGetType(output) as String?, "public.png")
    }
    func testBadImageDataIsRejectedInsteadOfPassedToTheUi() async {
        do {
            _ = try await ImagePreview.thumbnail(Data("not an image".utf8))
            XCTFail("Expected invalid image error")
        } catch { XCTAssertTrue(error is PreviewError) }
    }
    func testOversizedImageIsRejectedAndHeaderIsCheckedWhenAvailable() throws {
        // Valid PNG header/CRC with 100-million-pixel dimensions. Its tiny IDAT
        // deliberately lacks those pixels: no enormous test image is allocated.
        let data = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAJxAAACcQCAYAAAC6TmInAAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg=="))
        let source = CGImageSourceCreateIncremental([kCGImageSourceShouldCache: false] as CFDictionary)
        CGImageSourceUpdateData(source, data as CFData, false)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           properties[kCGImagePropertyPixelWidth] != nil, properties[kCGImagePropertyPixelHeight] != nil {
            XCTAssertThrowsError(try ImagePreview.validateHeader(data))
        }
        XCTAssertThrowsError(try ImagePreview.makeThumbnail(data))
    }
    #endif
}

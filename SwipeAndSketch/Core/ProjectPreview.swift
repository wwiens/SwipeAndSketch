import Foundation
import ImageIO

/// The picture saved in a project file for the document browser (October 21, 2026). The app draws
/// it when a project is left; the thumbnail extension (SwipeAndSketchThumbnails) finds it in the
/// file without decoding the model, so even a large project with imported shapes shows its picture
/// quickly and within the extension's small memory budget.
enum ProjectPreview {
    /// Bigger pictures are refused: thumbnails are small.
    static let maximumBytes = 1_048_576
    /// The picture's side, in pixels.
    static let side = 320

    /// The preview's key. Keys are written sorted, so it comes before the workspace and nothing
    /// nested ahead of it uses the same key.
    private static let key = Data("\"preview\"".utf8)

    /// The PNG saved in a project file's data, or nil when it has none.
    static func png(in data: Data) -> Data? {
        guard let found = data.firstRange(of: key) else { return nil }
        var index = found.upperBound
        // Past the colon to the opening quote.
        while index < data.endIndex, [UInt8(ascii: " "), UInt8(ascii: ":"), UInt8(ascii: "\n"), UInt8(ascii: "\t")].contains(data[index]) {
            index += 1
        }
        guard index < data.endIndex, data[index] == UInt8(ascii: "\"") else { return nil }
        let start = index + 1
        guard let end = data[start...].firstIndex(of: UInt8(ascii: "\"")), end - start <= maximumBytes * 2 else { return nil }
        // Base64, with the "\/" escapes JSON writes for slashes undone.
        let text = data[start..<end].filter { $0 != UInt8(ascii: "\\") }
        guard let png = Data(base64Encoded: text), png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        return png
    }

    /// The pictures the app saves are `side` points at the screen's scale; a file claiming more is
    /// refused unread.
    static let maximumPixels = 2048

    /// The picture decoded at most `maximumPixels` on a side, or nil when it isn't a PNG that size.
    /// A crafted file can claim any size in a few bytes, and decoding it whole would run Home or
    /// the thumbnail extension out of memory.
    static func image(from png: Data) -> CGImage? {
        guard png.count <= maximumBytes, let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetType(source).map({ $0 as String == "public.png" }) == true, CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maximumPixels).contains(width), (1...maximumPixels).contains(height) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maximumPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

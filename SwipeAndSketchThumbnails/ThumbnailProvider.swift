import QuickLookThumbnailing
import UIKit

/// Thumbnails of Swipe & Sketch projects for the document browser, Files, and anywhere else the
/// system shows files (October 21, 2026): the picture of the model the app saves in each project
/// (ProjectPreview.swift). A project saved before then, or never left since, has no picture yet and
/// shows a plain cube on the canvas color instead of its file's text.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // Mapped, not read: only the bytes up to the picture are touched.
        let data = try? Data(contentsOf: request.fileURL, options: .alwaysMapped)
        let image = data.flatMap(ProjectPreview.png(in:)).flatMap(UIImage.init(data:))
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let size = CGSize(width: side, height: side)
        handler(QLThumbnailReply(contextSize: size) { () -> Bool in
            if let image {
                image.draw(in: CGRect(origin: .zero, size: size))
            } else {
                Self.drawPlaceholder(side: side)
            }
            return true
        }, nil)
    }

    /// The canvas color with an outlined cube, in the app's gray.
    private static func drawPlaceholder(side: CGFloat) {
        UIColor(red: 0.945, green: 0.941, blue: 0.937, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
        let s = side / 32
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        let top = UIBezierPath()
        top.move(to: point(16, 6)); top.addLine(to: point(26, 11)); top.addLine(to: point(16, 16)); top.addLine(to: point(6, 11)); top.close()
        let left = UIBezierPath()
        left.move(to: point(6, 11)); left.addLine(to: point(16, 16)); left.addLine(to: point(16, 27)); left.addLine(to: point(6, 22)); left.close()
        let right = UIBezierPath()
        right.move(to: point(26, 11)); right.addLine(to: point(16, 16)); right.addLine(to: point(16, 27)); right.addLine(to: point(26, 22)); right.close()
        for (face, gray) in [(top, 0.66), (left, 0.42), (right, 0.54)] as [(UIBezierPath, CGFloat)] {
            UIColor(white: gray, alpha: 1).setFill()
            face.fill()
            UIColor(white: 0.12, alpha: 1).setStroke()
            face.lineWidth = max(1, s * 0.6)
            face.lineJoinStyle = .round
            face.stroke()
        }
    }
}

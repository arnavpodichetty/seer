import CoreGraphics
import Foundation
@testable import Seer

/// Builds an OCR result from lines laid out top to bottom, like a page.
func page(_ lines: [String], x: CGFloat = 0.1, startY: CGFloat = 0.2, lineHeight: CGFloat = 0.02, gap: CGFloat = 0.008,
          width: CGFloat = 0.6) -> OCRResult {
    var y = startY
    var result: [OCRLine] = []
    for text in lines {
        if text.isEmpty {   // blank line = paragraph gap
            y += lineHeight * 2
            continue
        }
        let w = min(width, CGFloat(text.count) * 0.008 + 0.02)
        result.append(OCRLine(text: text, box: CGRect(x: x, y: y, width: w, height: lineHeight), confidence: 0.95))
        y += lineHeight + gap
    }
    return OCRResult(lines: result, imageSize: CGSize(width: 1600, height: 1000))
}

/// Solid image with optional rectangles drawn in a second shade.
func makeImage(width: Int = 400, height: Int = 300, background: CGFloat = 1, rects: [CGRect] = [], shade: CGFloat = 0) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: background, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: shade, alpha: 1))
    for rect in rects { context.fill(rect) }
    return context.makeImage()!
}

/// Fake "text": many thin horizontal bars, like lines on a page.
func textLikeRects(rows: Int, top: CGFloat = 20, left: CGFloat = 20, seed: Int = 0) -> [CGRect] {
    (0..<rows).map { i in
        let width = CGFloat(200 + ((i * 37 + seed * 53) % 150))
        return CGRect(x: left, y: top + CGFloat(i) * 14, width: width, height: 6)
    }
}

/// Fictional person used by the live answer tests in place of a real user's context.
let sampleProfile = """
- Jordan Lee, third-year computer science student.
- Software intern at Northwind (summer): built a data pipeline that cut report generation from 2 hours to 10 minutes.
- Projects: a budgeting app used by 2,000 students (SwiftUI); a course-planning web app (React, Flask).
- Skills: Python, SQL, Swift, JavaScript.
"""

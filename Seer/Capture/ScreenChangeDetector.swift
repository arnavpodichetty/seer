import CoreGraphics
import Foundation

/// Compact visual summary of a frame used to skip OCR when nothing changed.
nonisolated struct FrameSignature: Sendable, Equatable {
    /// 64-bit difference hash (9×8 gradient).
    var dHash: UInt64
    /// 64×64 grayscale thumbnail.
    var thumbnail: [UInt8]
    var aspectRatio: Double
}

nonisolated enum ChangeLevel: Int, Sendable, Comparable {
    case none, minor, major
    static func < (lhs: ChangeLevel, rhs: ChangeLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated enum ScreenChangeDetector {
    static let thumbnailSide = 64
    /// A thumbnail pixel counts as changed if it moved by more than this (0–255).
    static let pixelDelta: UInt8 = 20

    static func signature(for image: CGImage) -> FrameSignature? {
        // Downscale the full screenshot once; the 9×8 hash input comes from the thumbnail.
        guard let thumb = ImageUtilities.grayscaleThumbnail(image, width: thumbnailSide, height: thumbnailSide) else { return nil }
        let aspect = image.height > 0 ? Double(image.width) / Double(image.height) : 1
        return FrameSignature(dHash: dHash(fromPixels9x8: boxDownsample(thumb, side: thumbnailSide, width: 9, height: 8)),
                              thumbnail: thumb, aspectRatio: aspect)
    }

    /// Averages a square grayscale buffer down to `width`×`height`.
    static func boxDownsample(_ pixels: [UInt8], side: Int, width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let y0 = row * side / height, y1 = max(y0 + 1, (row + 1) * side / height)
            for col in 0..<width {
                let x0 = col * side / width, x1 = max(x0 + 1, (col + 1) * side / width)
                var sum = 0
                for y in y0..<y1 {
                    for x in x0..<x1 { sum += Int(pixels[y * side + x]) }
                }
                out[row * width + col] = UInt8(sum / ((y1 - y0) * (x1 - x0)))
            }
        }
        return out
    }

    static func dHash(fromPixels9x8 pixels: [UInt8]) -> UInt64 {
        precondition(pixels.count == 72)
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                if pixels[row * 9 + col] > pixels[row * 9 + col + 1] { hash |= (1 << bit) }
                bit += 1
            }
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Fraction (0...1) of thumbnail pixels whose brightness changed noticeably.
    static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in 0..<a.count {
            let d = a[i] > b[i] ? a[i] - b[i] : b[i] - a[i]
            if d > pixelDelta { changed += 1 }
        }
        return Double(changed) / Double(a.count)
    }

    static func compare(_ old: FrameSignature?, _ new: FrameSignature) -> ChangeLevel {
        guard let old else { return .major }
        if abs(old.aspectRatio - new.aspectRatio) > 0.02 { return .major }
        let hamming = hammingDistance(old.dHash, new.dHash)
        let fraction = changedFraction(old.thumbnail, new.thumbnail)
        if hamming <= 1 && fraction < 0.002 { return .none }
        if hamming <= 10 && fraction < 0.06 { return .minor }
        return .major
    }
}

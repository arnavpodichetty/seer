import CoreGraphics
import Foundation
import Testing
@testable import Seer

@Suite("Screen change detection")
struct ScreenChangeDetectorTests {
    @Test func identicalFramesAreUnchanged() throws {
        let image = makeImage(rects: textLikeRects(rows: 15))
        let a = try #require(ScreenChangeDetector.signature(for: image))
        let b = try #require(ScreenChangeDetector.signature(for: image))
        #expect(ScreenChangeDetector.compare(a, b) == .none)
    }

    @Test func firstFrameIsMajor() throws {
        let sig = try #require(ScreenChangeDetector.signature(for: makeImage()))
        #expect(ScreenChangeDetector.compare(nil, sig) == .major)
    }

    @Test func smallLocalChangeIsMinor() throws {
        let base = textLikeRects(rows: 15)
        let a = try #require(ScreenChangeDetector.signature(for: makeImage(rects: base)))
        // A small blinking element (caret/spinner) in a corner.
        let b = try #require(ScreenChangeDetector.signature(for: makeImage(rects: base + [CGRect(x: 370, y: 270, width: 14, height: 14)])))
        let level = ScreenChangeDetector.compare(a, b)
        #expect(level == .minor)
    }

    @Test func newPageIsMajor() throws {
        let a = try #require(ScreenChangeDetector.signature(for: makeImage(rects: textLikeRects(rows: 15))))
        let b = try #require(ScreenChangeDetector.signature(for: makeImage(background: 0.15, rects: [CGRect(x: 40, y: 40, width: 300, height: 200)], shade: 0.9)))
        #expect(ScreenChangeDetector.compare(a, b) == .major)
    }

    @Test func aspectRatioChangeIsMajor() throws {
        let a = try #require(ScreenChangeDetector.signature(for: makeImage(width: 400, height: 300)))
        let b = try #require(ScreenChangeDetector.signature(for: makeImage(width: 400, height: 200)))
        #expect(ScreenChangeDetector.compare(a, b) == .major)
    }

    @Test func dHashOfGradient() {
        // Strictly decreasing rows → every bit set.
        let pixels = (0..<8).flatMap { _ in (0..<9).map { UInt8(255 - $0 * 20) } }
        #expect(ScreenChangeDetector.dHash(fromPixels9x8: pixels) == UInt64.max)
        let flat = [UInt8](repeating: 128, count: 72)
        #expect(ScreenChangeDetector.dHash(fromPixels9x8: flat) == 0)
        #expect(ScreenChangeDetector.hammingDistance(.max, 0) == 64)
    }

    @Test func changedFractionBounds() {
        let a = [UInt8](repeating: 0, count: 100)
        var b = a
        for i in 0..<10 { b[i] = 255 }
        #expect(ScreenChangeDetector.changedFraction(a, b) == 0.1)
        #expect(ScreenChangeDetector.changedFraction(a, []) == 1)
    }
}

@Suite("Stability gate")
struct StabilityGateTests {
    let fp = QuestionFingerprintService.make(from: "Which of the following is a prime number? A) 4 B) 6 C) 7 D) 9")

    @Test func requiresTwoSightingsAndSettleTime() {
        var gate = StabilityGate(settleInterval: 0.8)
        let t0 = Date()
        let r1 = gate.observe(fp, at: t0)
        #expect(!r1)
        #expect(gate.isPending)
        let r2 = gate.observe(fp, at: t0.addingTimeInterval(0.3))
        #expect(!r2)   // too soon
        let r3 = gate.observe(fp, at: t0.addingTimeInterval(1.0))
        #expect(r3)
    }

    @Test func changingQuestionRestartsTimer() {
        var gate = StabilityGate(settleInterval: 0.8)
        let other = QuestionFingerprintService.make(from: "Solve for x: 3x - 4 = 11")
        let t0 = Date()
        _ = gate.observe(fp, at: t0)
        let r4 = gate.observe(other, at: t0.addingTimeInterval(1))
        #expect(!r4)
        let r5 = gate.observe(other, at: t0.addingTimeInterval(2))
        #expect(r5)
    }

    @Test func nothingDetectedResets() {
        var gate = StabilityGate(settleInterval: 0)
        _ = gate.observe(fp, at: Date())
        _ = gate.observe(nil, at: Date())
        #expect(gate.pending == nil)
        let r6 = gate.observe(fp, at: Date())
        #expect(!r6)
    }

    @Test func partiallyLoadedThenCompleteCountsAsSame() {
        var gate = StabilityGate(settleInterval: 0)
        let partial = QuestionFingerprintService.make(from: "Write a SQL query that returns the second highest salary from the Employee table")
        let complete = QuestionFingerprintService.make(from: "Write a SQL query that returns the second highest salary from the Employee table. If there is none, return null")
        _ = gate.observe(partial, at: Date())
        let r7 = gate.observe(complete, at: Date())
        #expect(r7)
    }
}

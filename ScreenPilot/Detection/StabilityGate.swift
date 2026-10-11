import Foundation

/// Waits until the same question has been seen in consecutive frames over a settle
/// interval, so partially loaded pages and mid-scroll frames don't trigger inference.
nonisolated struct StabilityGate {
    var settleInterval: TimeInterval = 0.5
    var requiredSightings = 2

    private(set) var pending: QuestionFingerprint?
    private(set) var firstSeen: Date?
    private(set) var sightings = 0

    var isPending: Bool { pending != nil && sightings < requiredSightings }

    /// Records the fingerprint seen in the latest frame and returns whether it is stable.
    mutating func observe(_ fingerprint: QuestionFingerprint?, at now: Date) -> Bool {
        guard let fingerprint else {
            reset()
            return false
        }
        if let pending, QuestionFingerprintService.isSameQuestion(pending, fingerprint) {
            sightings += 1
            self.pending = fingerprint
        } else {
            pending = fingerprint
            firstSeen = now
            sightings = 1
        }
        guard let firstSeen else { return false }
        return sightings >= requiredSightings && now.timeIntervalSince(firstSeen) >= settleInterval
    }

    mutating func reset() {
        pending = nil
        firstSeen = nil
        sightings = 0
    }
}

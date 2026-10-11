import Foundation
import Testing
@testable import Seer

@Suite("Question fingerprinting")
struct QuestionFingerprintTests {
    typealias FP = QuestionFingerprintService

    let sql = """
    Write a SQL query to find the names of all employees who earn more than their managers.
    The Employee table has columns id, name, salary and managerId.
    Return the result table in any order.
    """

    @Test func identicalTextHasSameID() {
        #expect(FP.make(from: sql).id == FP.make(from: sql).id)
    }

    @Test func idIgnoresCaseWhitespaceAndPunctuation() {
        let a = FP.make(from: "What is 2 + 2?")
        let b = FP.make(from: "  what   is 2 + 2 ")
        #expect(a.id == b.id)
    }

    @Test func normalizationFoldsUnicodeOperators() {
        #expect(FP.normalize("5 − 3 × 2 ÷ 1") == "5 - 3 * 2 / 1")
        #expect(FP.normalize("Café, naïve.") == "cafe naive")
        #expect(FP.normalize("x = 3.5.") == "x = 3.5")
    }

    @Test func toleratesSmallOCRNoise() {
        let noisy = sql.replacingOccurrences(of: "employees", with: "emp1oyees").replacingOccurrences(of: "managers.", with: "managers,")
        #expect(FP.isSameQuestion(FP.make(from: sql), FP.make(from: noisy)))
    }

    @Test func scrolledPartialQuestionMatches() {
        // After scrolling, the first line is cut off.
        let partial = sql.split(separator: "\n").dropFirst().joined(separator: "\n")
        let full = sql + "\nExample: Joe earns 70000."
        #expect(FP.isSameQuestion(FP.make(from: sql), FP.make(from: partial)))
        #expect(FP.isSameQuestion(FP.make(from: sql), FP.make(from: full)))
    }

    @Test func changedNumbersMeanDifferentQuestion() {
        let a = FP.make(from: "A train travels 120 km in 2 hours. What is its average speed in km per hour?")
        let b = FP.make(from: "A train travels 150 km in 2 hours. What is its average speed in km per hour?")
        #expect(!FP.isSameQuestion(a, b))
    }

    @Test func shortEquationsDiffer() {
        #expect(!FP.isSameQuestion(FP.make(from: "Solve 2x + 3 = 7"), FP.make(from: "Solve 2x + 3 = 9")))
    }

    @Test func unrelatedQuestionsDiffer() {
        let a = FP.make(from: "Which planet is closest to the Sun? A) Venus B) Mercury C) Earth D) Mars")
        let b = FP.make(from: "Which element has the chemical symbol Fe? A) Lead B) Iron C) Tin D) Gold")
        #expect(!FP.isSameQuestion(a, b))
        #expect(FP.jaccard(a, b) < 0.3)
    }

    @Test func emptyTextIsNeverSameAsContent() {
        #expect(!FP.isSameQuestion(FP.make(from: ""), FP.make(from: "What is 2 + 2?")))
    }
}

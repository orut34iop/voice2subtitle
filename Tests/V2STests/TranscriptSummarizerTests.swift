import XCTest
@testable import v2s

final class TranscriptSummarizerTests: XCTestCase {
    func testChunksPreserveAllUnicodeWithinBudget() {
        let text = String(repeating: "中文 café 👩🏽‍💻\n", count: 2000)
        let chunks = TranscriptSummarizer.chunks(text, maxBytes: 2400)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.utf8.count <= 2400 })
    }

    func testLongTranscriptSummarizesEveryPartThenCombines() async throws {
        let text = String(repeating: "meeting transcript ", count: 1000)
        let expected = TranscriptSummarizer.chunks(text, maxBytes: 2400)
        var inputs: [String] = []
        let result = try await TranscriptSummarizer.summarize(text) { part in
            inputs.append(part)
            return "Summary \(inputs.count)"
        }
        XCTAssertEqual(Array(inputs.prefix(expected.count)), expected)
        XCTAssertEqual(inputs.last, (1...expected.count).map { "Summary \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(result, "Summary \(expected.count + 1)")
    }

    func testNonReducingGeneratorFailsInsteadOfDroppingContent() async {
        do {
            _ = try await TranscriptSummarizer.summarize(String(repeating: "a", count: 5000)) { $0 }
            XCTFail("Expected bounded failure")
        } catch { XCTAssertTrue(error is TranscriptSummarizer.SummaryError) }
    }
}

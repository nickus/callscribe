import Foundation
import Testing
@testable import CallScribeCore

/// The canned summarizer used throughout tests and the golden pipeline.
struct MockSummarizer: Summarizer {
    let result: SummaryResult
    func summarize(transcript: String, projectContext: String?) async throws -> SummaryResult { result }
}

@Suite struct SummarizerProtocolTests {
    @Test func mockReturnsCannedResultAndNameMap() async throws {
        let mock = MockSummarizer(result: SummaryResult(
            markdown: "## Summary\nTest.",
            speakerNames: ["Speaker 1": "Misha"]
        ))
        let out = try await mock.summarize(transcript: "**[00:00:00] Speaker 1:** privet")
        #expect(out.markdown.contains("## Summary"))
        #expect(out.speakerNames["Speaker 1"] == "Misha")
    }
}

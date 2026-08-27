import Testing
@testable import CallScribeCore

@Suite struct SummaryMarkdownTests {
    let sample = """
    ## Summary
    A quick sync about the launch.

    ## Agreements
    - Ship on Friday.
    - Anna writes the notes.

    ## My tasks
    - [ ] Send the recap
    - [x] Book the room
    """

    @Test func parsesSectionsInOrder() {
        let sections = SummaryMarkdown.parse(sample)
        #expect(sections.map(\.title) == ["Summary", "Agreements", "My tasks"])
    }

    @Test func summaryIsAParagraph() {
        let sections = SummaryMarkdown.parse(sample)
        #expect(sections[0].blocks == [.paragraph("A quick sync about the launch.")])
    }

    @Test func agreementsAreBullets() {
        let sections = SummaryMarkdown.parse(sample)
        #expect(sections[1].blocks == [.bullets(["Ship on Friday.", "Anna writes the notes."])])
    }

    @Test func tasksCarryDoneStateAndIndex() {
        let sections = SummaryMarkdown.parse(sample)
        guard case .tasks(let tasks) = sections[2].blocks.first else {
            Issue.record("expected tasks block"); return
        }
        #expect(tasks == [
            .init(text: "Send the recap", done: false, index: 0),
            .init(text: "Book the room", done: true, index: 1),
        ])
    }

    @Test func taskIndicesAreGlobalAcrossSections() {
        let md = """
        ## A
        - [ ] one
        ## B
        - [ ] two
        """
        let sections = SummaryMarkdown.parse(md)
        guard case .tasks(let a) = sections[0].blocks.first,
              case .tasks(let b) = sections[1].blocks.first else {
            Issue.record("expected task blocks"); return
        }
        #expect(a[0].index == 0)
        #expect(b[0].index == 1)
    }

    @Test func toggleFlipsTheAddressedTask() {
        let after = SummaryMarkdown.toggleTask(sample, index: 0)
        #expect(after.contains("- [x] Send the recap"))
        #expect(after.contains("- [x] Book the room"))   // unchanged
    }

    @Test func toggleUnchecksAlready() {
        let after = SummaryMarkdown.toggleTask(sample, index: 1)
        #expect(after.contains("- [ ] Book the room"))
    }

    @Test func toggleRoundTrips() {
        let once = SummaryMarkdown.toggleTask(sample, index: 0)
        let twice = SummaryMarkdown.toggleTask(once, index: 0)
        #expect(twice.contains("- [ ] Send the recap"))
    }

    @Test func removeTaskDropsTheLineAndRenumbers() {
        let md = """
        ## My tasks
        - [ ] first
        - [ ] second
        - [ ] third
        """
        let after = SummaryMarkdown.removeTask(md, index: 1)   // remove "second"
        #expect(!after.contains("second"))
        #expect(after.contains("- [ ] first"))
        #expect(after.contains("- [ ] third"))
        // The remaining tasks renumber 0,1 on re-parse.
        guard case .tasks(let tasks) = SummaryMarkdown.parse(after)[0].blocks.first else {
            Issue.record("expected tasks"); return
        }
        #expect(tasks.map(\.text) == ["first", "third"])
        #expect(tasks.map(\.index) == [0, 1])
    }

    @Test func italicPlaceholderIsParsedAsParagraph() {
        let md = "## My tasks\n_No action items._"
        let sections = SummaryMarkdown.parse(md)
        #expect(sections[0].blocks == [.paragraph("_No action items._")])
    }

    @Test func contentBeforeFirstHeadingBecomesUntitledSection() {
        let sections = SummaryMarkdown.parse("Loose intro.\n\n## Summary\nBody.")
        #expect(sections[0].title.isEmpty)
        #expect(sections[0].blocks == [.paragraph("Loose intro.")])
        #expect(sections[1].title == "Summary")
    }

    // MARK: - Topics (nested `###` sub-sections)

    let withTopics = """
    ## Summary
    A quick sync.

    ## Topics
    ### [00:04:12] Pricing tier
    They settled on a single mid-tier price.

    ### [00:11:40] Migration timeline
    Cutover slips to August.

    ## My tasks
    - [ ] Send the recap
    """

    @Test func topicsNestUnderTheirParentSection() {
        let sections = SummaryMarkdown.parse(withTopics)
        #expect(sections.map(\.title) == ["Summary", "Topics", "My tasks"])
        let topics = sections[1].subsections
        #expect(topics.map(\.title) == ["[00:04:12] Pricing tier", "[00:11:40] Migration timeline"])
        #expect(topics[0].blocks == [.paragraph("They settled on a single mid-tier price.")])
    }

    @Test func nestingLeavesFlatDocumentsUnchanged() {
        let sections = SummaryMarkdown.parse(sample)
        #expect(sections.map(\.title) == ["Summary", "Agreements", "My tasks"])
        #expect(sections.allSatisfy { $0.subsections.isEmpty })
    }

    @Test func taskIndicesStayGlobalAcrossNestedSections() {
        let md = """
        ## Topics
        ### One
        - [ ] alpha
        ### Two
        - [ ] beta
        ## My tasks
        - [ ] gamma
        """
        let sections = SummaryMarkdown.parse(md)
        guard case .tasks(let inTopicTwo) = sections[0].subsections[1].blocks.first,
              case .tasks(let mine) = sections[1].blocks.first else {
            Issue.record("expected task blocks"); return
        }
        #expect(inTopicTwo[0].index == 1)
        #expect(mine[0].index == 2)
    }

    @Test func orphanSubheadingBecomesATopLevelSection() {
        let sections = SummaryMarkdown.parse("### Lonely\nBody.")
        #expect(sections.map(\.title) == ["Lonely"])
        #expect(sections[0].blocks == [.paragraph("Body.")])
    }

    @Test func deeperHeadingsNestRecursively() {
        let sections = SummaryMarkdown.parse("## A\n### B\n#### C\nBody.")
        #expect(sections[0].title == "A")
        #expect(sections[0].subsections[0].title == "B")
        #expect(sections[0].subsections[0].subsections[0].title == "C")
    }

    // MARK: - Timecodes

    @Test func splitsFullTimecodeFromHeading() {
        let (start, text) = SummaryMarkdown.splitTimecode("[00:04:12] Pricing tier")
        #expect(start == 252)
        #expect(text == "Pricing tier")
    }

    @Test func splitsShortTimecodeAndSeparator() {
        #expect(SummaryMarkdown.splitTimecode("[04:12] Pricing").start == 252)
        #expect(SummaryMarkdown.splitTimecode("4:12 — Pricing").start == 252)
        #expect(SummaryMarkdown.splitTimecode("4:12 — Pricing").text == "Pricing")
    }

    @Test func splitsHoursCorrectly() {
        #expect(SummaryMarkdown.splitTimecode("[01:02:03] Long call").start == 3723)
    }

    @Test func headingWithoutTimecodeIsUnchanged() {
        let (start, text) = SummaryMarkdown.splitTimecode("Pricing tier")
        #expect(start == nil)
        #expect(text == "Pricing tier")
    }
}

import Foundation
import Testing
@testable import CallScribeCore

/// The real shape on disk: a preamble, then entries with no language suffix
/// (they predate it). Copied from an actual `dictations.md`, Cyrillic included —
/// half the real data is Russian.
private let sample = """
# Dictations

## 2026-08-10 13:01:12

Раз, да, сделай тут то-то, то-то, это сделай, сделай тут.

## 2026-08-10 13:02:36

Раз, раз, раз, два, три.

## 2026-08-10 13:05:32

Okay.

"""

private func stamp(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: text)
}

// MARK: - Parse

@Test func parsesTheRealOnDiskShape() {
    let entries = DictationLogFormat.parse(sample)
    #expect(entries.count == 3)
    #expect(entries.map(\.index) == [0, 1, 2])
    #expect(entries.map(\.language) == [nil, nil, nil])
    #expect(entries[0].text == "Раз, да, сделай тут то-то, то-то, это сделай, сделай тут.")
    #expect(entries[1].text == "Раз, раз, раз, два, три.")
    #expect(entries[2].text == "Okay.")
    #expect(entries[0].date == stamp("2026-08-10 13:01:12"))
    #expect(entries[2].date == stamp("2026-08-10 13:05:32"))
}

/// The preamble is not an entry — it has no `## ` heading to belong to.
@Test func thePreambleIsNotAnEntry() {
    #expect(DictationLogFormat.parse(DictationLogFormat.preamble).isEmpty)
    #expect(!DictationLogFormat.parse(sample).contains { $0.text.contains("# Dictations") })
}

@Test func parsesTheLanguageSuffix() {
    let entries = DictationLogFormat.parse("""
    # Dictations

    ## 2026-08-10 13:05:32 · en

    Ship it.

    ## 2026-08-10 13:06:00 · ru

    Поехали.

    """)
    #expect(entries.map(\.language) == ["en", "ru"])
    #expect(entries.map(\.text) == ["Ship it.", "Поехали."])
}

/// New entries carry a language, the six that already exist don't — a real file
/// is going to hold both for a long time.
@Test func handlesAMixOfSuffixedAndUnsuffixedEntries() {
    let entries = DictationLogFormat.parse("""
    ## 2026-08-10 13:01:12

    old, no language

    ## 2026-08-10 13:05:32 · en

    new, with one

    """)
    #expect(entries.map(\.language) == [nil, "en"])
    #expect(entries.map(\.text) == ["old, no language", "new, with one"])
}

@Test func aMultiLineBodySurvivesIntact() {
    let entries = DictationLogFormat.parse("""
    ## 2026-08-10 13:05:32

    First line.
    Second line.

    Third, after a blank.

    """)
    #expect(entries.count == 1)
    #expect(entries[0].text == "First line.\nSecond line.\n\nThird, after a blank.")
}

/// Only `## ` at line start ends an entry. A dictation that happens to mention a
/// hash must not be sliced in half.
@Test func aHashInsideTheBodyIsNotAHeading() {
    let entries = DictationLogFormat.parse("""
    ## 2026-08-10 13:05:32

    Use #hashtags and C# and issue #42.
    ### not ours either

    """)
    #expect(entries.count == 1)
    #expect(entries[0].text.contains("C#"))
    #expect(entries[0].text.contains("### not ours either"))
}

/// A hand-edited stamp shouldn't cost the user the text they dictated.
@Test func anUnparseableStampStillYieldsAnEntry() {
    let entries = DictationLogFormat.parse("""
    ## last Tuesday

    Something I said.

    """)
    #expect(entries.count == 1)
    #expect(entries[0].date == nil)
    #expect(entries[0].text == "Something I said.")
}

@Test func emptyAndGarbageInputYieldNothing() {
    #expect(DictationLogFormat.parse("").isEmpty)
    #expect(DictationLogFormat.parse("just some prose\nover two lines").isEmpty)
    #expect(DictationLogFormat.parse("#Dictations\n\n#not a heading").isEmpty)
}

// MARK: - Round trip

/// The guarantee `remove` rests on: what the writer produces is exactly what the
/// parser reads back. If this ever fails, deleting an entry corrupts the file.
@Test func renderAndParseRoundTrip() {
    let cases: [(text: String, language: String?)] = [
        ("Ship it.", "en"),
        ("Раз, раз, раз, два, три.", "ru"),
        ("No language on this one.", nil),
        ("Two lines\nin one dictation.", "en"),
        ("Punctuation: commas, dashes — and a · middle dot.", "en"),
    ]
    let dates = (0..<cases.count).map { stamp("2026-08-10 13:0\($0):00")! }

    var markdown = DictationLogFormat.preamble
    for (i, item) in cases.enumerated() {
        markdown += DictationLogFormat.render(item.text, at: dates[i], language: item.language)
    }

    let parsed = DictationLogFormat.parse(markdown)
    #expect(parsed.count == cases.count)
    for (i, item) in cases.enumerated() {
        #expect(parsed[i].text == item.text)
        #expect(parsed[i].language == item.language)
        #expect(parsed[i].date == dates[i])
        #expect(parsed[i].index == i)
    }
}

// MARK: - Remove

@Test func removingTheMiddleEntryLeavesTheOthersIntact() {
    let result = DictationLogFormat.remove(sample, index: 1)
    let entries = DictationLogFormat.parse(result)
    #expect(entries.map(\.text) == [
        "Раз, да, сделай тут то-то, то-то, это сделай, сделай тут.",
        "Okay.",
    ])
    // Reindexed against the new file, which is what a later delete addresses.
    #expect(entries.map(\.index) == [0, 1])
    #expect(result.hasPrefix(DictationLogFormat.preamble))
    #expect(!result.contains("два, три"))
}

@Test func removingTheFirstAndLastEntriesWorks() {
    let first = DictationLogFormat.parse(DictationLogFormat.remove(sample, index: 0))
    #expect(first.map(\.text) == ["Раз, раз, раз, два, три.", "Okay."])

    let last = DictationLogFormat.parse(DictationLogFormat.remove(sample, index: 2))
    #expect(last.map(\.text) == [
        "Раз, да, сделай тут то-то, то-то, это сделай, сделай тут.",
        "Раз, раз, раз, два, три.",
    ])
}

/// After removing the last entry the file must still end in a blank line, or the
/// next appended heading would be glued onto the previous entry's body.
@Test func removingTheLastEntryLeavesAnAppendableFile() {
    let trimmed = DictationLogFormat.remove(sample, index: 2)
    #expect(trimmed.hasSuffix("\n\n"))

    let appended = trimmed + DictationLogFormat.render(
        "Next one.", at: stamp("2026-08-10 14:00:00")!, language: "en")
    let entries = DictationLogFormat.parse(appended)
    #expect(entries.count == 3)
    #expect(entries.last?.text == "Next one.")
    #expect(entries.last?.language == "en")
}

@Test func removingEveryEntryLeavesJustThePreamble() {
    var markdown = sample
    for _ in 0..<3 {
        markdown = DictationLogFormat.remove(markdown, index: 0)
    }
    #expect(DictationLogFormat.parse(markdown).isEmpty)
    #expect(markdown == DictationLogFormat.preamble)
}

@Test func removingAnOutOfRangeIndexChangesNothing() {
    #expect(DictationLogFormat.remove(sample, index: 3) == sample)
    #expect(DictationLogFormat.remove(sample, index: 99) == sample)
    #expect(DictationLogFormat.remove(sample, index: -1) == sample)
    #expect(DictationLogFormat.remove("", index: 0).isEmpty)
}

/// Only the removed entry's lines change; everything else stays byte-identical,
/// including hand-edits the user made to the rest of the file.
@Test func removePreservesUnrelatedLinesByteForByte() {
    let handEdited = """
    # Dictations

    Some note I added myself.

    ## 2026-08-10 13:01:12

    keep me

    ## 2026-08-10 13:02:36

    drop me

    """
    let result = DictationLogFormat.remove(handEdited, index: 1)
    #expect(result.contains("Some note I added myself."))
    #expect(result.contains("keep me"))
    #expect(!result.contains("drop me"))
    #expect(result.hasPrefix("# Dictations\n\nSome note I added myself.\n\n## 2026-08-10 13:01:12"))
}

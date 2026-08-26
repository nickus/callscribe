import Foundation

/// The heart of the app: fuses word-timestamped Whisper output from the two
/// tracks into one interleaved, speaker-attributed transcript.
///
/// Mic-track words are all "Me" by construction; system-track words are
/// attributed to `Speaker N` by time-overlap with diarization spans. All
/// stages are pure functions over value types.
public enum TranscriptMerger {
    public static func merge(
        micWords: [Word],
        systemWords: [Word],
        spans: [SpeakerSpan],
        config: MergeConfig = MergeConfig(),
        detectedLanguage: String? = nil
    ) -> Transcript {
        let normSystem = normalize(systemWords, config: config)
        let refinedSpans = refineSpanBoundaries(spans, systemWords: normSystem, config: config)
        let system = attribute(systemWords: normSystem, spans: refinedSpans, config: config)
        // Build utterances per track *before* interleaving, so simultaneous
        // speech yields two overlapping utterances instead of shredding into
        // alternating single words.
        let systemUtterances = utterances(from: system, config: config)

        // Strip speaker bleed (the remote picked up through the speakers) at the
        // WORD level, so a mic utterance that starts as echo but continues after
        // the remote falls silent keeps its genuine tail. A leftover pass drops
        // tiny mic fragments still sitting next to remote speech (echo residue).
        let micUtterances = config.echoDedup
            ? dedupedMicUtterances(micWords, systemWords: normSystem, config: config)
            : utterances(
                from: normalize(micWords, config: config).map { AttributedWord(word: $0, speaker: .me) },
                config: config)

        let interleaved = (micUtterances + systemUtterances)
            .sorted { a, b in
                if a.start != b.start { return a.start < b.start }
                if (a.speaker == .me) != (b.speaker == .me) { return a.speaker == .me }
                return (a.end - a.start) > (b.end - b.start)
            }

        // Coalesce, fold away phantom (over-segmented) remote speakers, coalesce
        // the pieces that folding made adjacent, then renumber 1..k.
        let coalesced = coalesce(interleaved, config: config)
        let folded = foldPhantomSpeakers(coalesced, config: config)
        let final = renumberRemote(coalesce(folded, config: config))

        return Transcript(utterances: final, detectedLanguage: detectedLanguage)
    }

    // MARK: - Echo dedup

    /// Mic utterances with speaker bleed removed. Drops mic words whose midpoint
    /// lands inside remote speech (echo), builds utterances from the survivors,
    /// then drops tiny fragments still adjacent to remote speech (echo residue
    /// Whisper timed just outside the remote words). `systemWords` sorted by start.
    static func dedupedMicUtterances(
        _ micWords: [Word], systemWords: [Word], config: MergeConfig
    ) -> [Utterance] {
        let speech = speechIntervals(systemWords, bridgeGap: config.echoBridgeGap)
        let kept = normalize(micWords, config: config)
            .filter { !isEchoWord($0, speech: speech) }
            .map { AttributedWord(word: $0, speaker: .me) }
        return utterances(from: kept, config: config)
            .filter { !isEchoResidue($0, speech: speech, config: config) }
    }

    /// Merge system words into continuous speech intervals, bridging gaps up to
    /// `bridgeGap` (Whisper leaves sub-second gaps between words within a breath),
    /// so echo words landing in those gaps are still caught. `words` sorted by start.
    static func speechIntervals(_ words: [Word], bridgeGap: TimeInterval) -> [ClosedRange<TimeInterval>] {
        var result: [ClosedRange<TimeInterval>] = []
        for word in words where word.end > word.start {
            if let last = result.last, word.start - last.upperBound <= bridgeGap {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, word.end)
            } else {
                result.append(word.start...word.end)
            }
        }
        return result
    }

    /// A mic word is echo when its midpoint lands inside remote speech.
    static func isEchoWord(_ word: Word, speech: [ClosedRange<TimeInterval>]) -> Bool {
        let mid = (word.start + word.end) / 2
        for range in speech {
            if range.lowerBound > mid { break }         // sorted → nothing later contains it
            if range.contains(mid) { return true }
        }
        return false
    }

    /// A very short mic utterance sitting next to remote speech is echo residue.
    static func isEchoResidue(
        _ utterance: Utterance, speech: [ClosedRange<TimeInterval>], config: MergeConfig
    ) -> Bool {
        guard utterance.words.count <= config.echoRemnantMaxWords else { return false }
        let lo = utterance.start - config.echoRemnantPad
        let hi = utterance.end + config.echoRemnantPad
        for range in speech {
            if range.lowerBound > hi { break }
            if range.upperBound >= lo { return true }   // range overlaps [lo, hi]
        }
        return false
    }

    // MARK: - Stages

    /// Refine diarization boundaries with Whisper's word timings: speakers
    /// change in the silence between words, never mid-word, and word timings
    /// are finer than the diarizer's frames. Each boundary between adjacent
    /// different-speaker spans moves to the midpoint of the nearest inter-word
    /// silence (within `spanBoundaryRefineTolerance`), so no word straddles a
    /// boundary and turn edges stop drifting. `systemWords` sorted by start.
    static func refineSpanBoundaries(
        _ spans: [SpeakerSpan], systemWords: [Word], config: MergeConfig
    ) -> [SpeakerSpan] {
        guard config.spanBoundaryRefineTolerance > 0, spans.count > 1 else { return spans }

        // Candidate cut points: midpoints of the silences between words.
        var cuts: [TimeInterval] = []
        for (word, next) in zip(systemWords, systemWords.dropFirst()) where next.start > word.end {
            cuts.append((word.end + next.start) / 2)
        }
        guard !cuts.isEmpty else { return spans }

        var refined = spans.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        for i in 0..<(refined.count - 1) {
            let a = refined[i], b = refined[i + 1]
            guard a.speakerID != b.speakerID else { continue }
            // Same formula whether the spans leave a gap or overlap.
            let nominal = (a.end + b.start) / 2
            guard let cut = cuts.min(by: { abs($0 - nominal) < abs($1 - nominal) }),
                  abs(cut - nominal) <= config.spanBoundaryRefineTolerance,
                  cut > a.start, cut < b.end   // never invert a span
            else { continue }
            refined[i] = SpeakerSpan(speakerID: a.speakerID, start: a.start, end: cut, name: a.name)
            refined[i + 1] = SpeakerSpan(speakerID: b.speakerID, start: cut, end: b.end, name: b.name)
        }
        return refined
    }

    static func normalize(_ words: [Word], config: MergeConfig) -> [Word] {
        words
            .filter { $0.end > $0.start && $0.probability >= config.minWordProbability }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Attribute system-track words to speakers via diarization spans. A span
    /// matched to an enrolled voice becomes `.named`; the rest are `.remote(N)`,
    /// numbered by first appearance in time. A word picks the span with maximum
    /// temporal overlap; words outside every span snap to the nearest span
    /// within tolerance, else stick with the previous word's speaker. No spans
    /// at all → everything is `.participant`.
    static func attribute(
        systemWords: [Word],
        spans: [SpeakerSpan],
        config: MergeConfig
    ) -> [AttributedWord] {
        guard !spans.isEmpty else {
            return systemWords.map { AttributedWord(word: $0, speaker: .participant) }
        }

        let sortedSpans = spans.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var numbering: [String: Int] = [:]
        for span in sortedSpans where span.name == nil && numbering[span.speakerID] == nil {
            numbering[span.speakerID] = numbering.count + 1
        }
        func speaker(of span: SpeakerSpan) -> Speaker {
            if let name = span.name { return .named(name) }
            return .remote(numbering[span.speakerID] ?? 1)
        }

        var result: [AttributedWord] = []
        var previous: Speaker = speaker(of: sortedSpans[0])
        for word in systemWords {
            let best = sortedSpans
                .map { span in (span, overlap: min(word.end, span.end) - max(word.start, span.start)) }
                .max { a, b in a.overlap < b.overlap }!

            let assigned: Speaker
            if best.overlap > 0 {
                assigned = speaker(of: best.0)
            } else {
                // Distance from the word to each span (they don't overlap).
                let nearest = sortedSpans
                    .map { span in (span, distance: max(span.start - word.end, word.start - span.end)) }
                    .min { a, b in a.distance < b.distance }!
                assigned = nearest.distance <= config.spanSnapTolerance
                    ? speaker(of: nearest.0)
                    : previous
            }
            result.append(AttributedWord(word: word, speaker: assigned))
            previous = assigned
        }
        return result
    }

    /// Split one track's attributed words into utterances at speaker changes
    /// and silences longer than `utteranceGap`.
    static func utterances(from words: [AttributedWord], config: MergeConfig) -> [Utterance] {
        var result: [Utterance] = []
        var currentSpeaker: Speaker?
        var currentWords: [Word] = []

        for attributed in words {
            let isBreak = attributed.speaker != currentSpeaker
                || attributed.word.start - (currentWords.last?.end ?? 0) > config.utteranceGap
            if isBreak, let speaker = currentSpeaker, !currentWords.isEmpty {
                result.append(Utterance(speaker: speaker, words: currentWords))
                currentWords = []
            }
            currentSpeaker = attributed.speaker
            currentWords.append(attributed.word)
        }
        if let speaker = currentSpeaker, !currentWords.isEmpty {
            result.append(Utterance(speaker: speaker, words: currentWords))
        }
        return result
    }

    /// Merge adjacent same-speaker utterances separated by less than
    /// `coalesceGap` (repairs splits caused by interleaving).
    static func coalesce(_ utterances: [Utterance], config: MergeConfig) -> [Utterance] {
        var result: [Utterance] = []
        for utterance in utterances {
            if let last = result.last,
               last.speaker == utterance.speaker,
               utterance.start - last.end < config.coalesceGap {
                result[result.count - 1] = Utterance(
                    speaker: last.speaker,
                    words: last.words + utterance.words
                )
            } else {
                result.append(utterance)
            }
        }
        return result
    }

    // MARK: - Phantom speakers

    /// Diarization over-segments: clustering drift spawns short-lived phantom
    /// speaker IDs (e.g. a 1 s "Speaker 5"). Fold every remote speaker whose
    /// total talk-time is below `phantomSpeakerMinDuration` into the nearest
    /// surviving remote speaker by time — keeping the words, just relabeling.
    /// Never removes the last surviving remote speaker (a short call stays put).
    static func foldPhantomSpeakers(_ utterances: [Utterance], config: MergeConfig) -> [Utterance] {
        guard config.phantomSpeakerMinDuration > 0 else { return utterances }

        var total: [Int: TimeInterval] = [:]
        for u in utterances {
            if case .remote(let n) = u.speaker { total[n, default: 0] += u.end - u.start }
        }
        let phantoms = Set(total.filter { $0.value < config.phantomSpeakerMinDuration }.keys)
        let survivors = Set(total.keys).subtracting(phantoms)
        guard !phantoms.isEmpty, !survivors.isEmpty else { return utterances }

        return utterances.map { u in
            guard case .remote(let n) = u.speaker, phantoms.contains(n),
                  let target = nearestSurvivor(to: u, in: utterances, survivors: survivors)
            else { return u }
            return Utterance(speaker: .remote(target), words: u.words)
        }
    }

    /// The surviving remote speaker whose utterances are closest in time to `u`.
    private static func nearestSurvivor(
        to u: Utterance, in all: [Utterance], survivors: Set<Int>
    ) -> Int? {
        var best: (speaker: Int, distance: TimeInterval)?
        for other in all {
            guard case .remote(let n) = other.speaker, survivors.contains(n) else { continue }
            let distance = max(0, max(other.start - u.end, u.start - other.end))
            if best == nil || distance < best!.distance { best = (n, distance) }
        }
        return best?.speaker
    }

    /// Renumber remote speakers 1..k by first appearance, so labels stay
    /// contiguous after folding (no gaps like "Speaker 1, Speaker 4").
    static func renumberRemote(_ utterances: [Utterance]) -> [Utterance] {
        var mapping: [Int: Int] = [:]
        for u in utterances {
            if case .remote(let n) = u.speaker, mapping[n] == nil {
                mapping[n] = mapping.count + 1
            }
        }
        guard mapping.contains(where: { $0.key != $0.value }) else { return utterances }
        return utterances.map { u in
            if case .remote(let n) = u.speaker, let m = mapping[n], m != n {
                return Utterance(speaker: .remote(m), words: u.words)
            }
            return u
        }
    }
}

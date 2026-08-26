import Foundation

/// Applies LLM-inferred turn-level speaker fixes to a merged transcript.
/// Deliberately conservative: a correction is dropped unless its timecode AND
/// current label both match a turn, and both labels resolve to remote speakers
/// already present in the transcript. "Me" never moves in either direction —
/// the mic track is ground truth, diarization only errs between remote voices.
public enum SpeakerCorrections {
    public static func apply(
        _ corrections: [SpeakerCorrection],
        to transcript: Transcript,
        names: [String: String] = [:]
    ) -> Transcript {
        guard !corrections.isEmpty else { return transcript }
        var utterances = transcript.utterances

        // Resolve labels against the ORIGINAL transcript — the one the LLM saw.
        // An earlier correction may reassign a speaker's only turn, but a later
        // correction still refers to speakers by their original labels. The LLM
        // may use either the canonical label ("Speaker 2") or the display name
        // rendered in the transcript, so both resolve.
        var speakerByLabel: [String: Speaker] = [:]
        for utterance in utterances {
            speakerByLabel[utterance.speaker.label] = utterance.speaker
            if let display = names[utterance.speaker.label] {
                speakerByLabel[display] = utterance.speaker
            }
        }

        for correction in corrections {
            guard let from = speakerByLabel[correction.from], isRemote(from),
                  let to = speakerByLabel[correction.to], isRemote(to),
                  from != to
            else { continue }

            for i in utterances.indices
            where utterances[i].speaker == from
                && TranscriptMarkdownRenderer.timecode(utterances[i].start) == correction.time {
                utterances[i] = Utterance(speaker: to, words: utterances[i].words)
            }
        }
        return Transcript(utterances: utterances, detectedLanguage: transcript.detectedLanguage)
    }

    private static func isRemote(_ speaker: Speaker) -> Bool {
        switch speaker {
        case .remote, .named: true
        case .me, .participant: false
        }
    }

    /// Fold freshly inferred corrections into the stored list. Two invariants
    /// keep replay sound across re-renders, renames and re-summarizes:
    /// - Labels are canonicalized via `names` (the map the LLM's transcript was
    ///   rendered with): stored corrections say "Speaker 2", never "Misha", so
    ///   a later rename can't strand them.
    /// - Each stored entry maps a turn from its ORIGINAL merge-time speaker: a
    ///   new correction on an already-corrected turn collapses the chain
    ///   (S1→S2 then S2→S3 becomes S1→S3), and an exact revert cancels the
    ///   entry — so entries are independent and replay order never matters.
    public static func appending(
        _ new: [SpeakerCorrection],
        to stored: [SpeakerCorrection],
        names: [String: String]
    ) -> [SpeakerCorrection] {
        // Reverse the display map; on a (rare) display-name collision the last
        // label wins, same as the transcript itself would be ambiguous.
        var canonicalByDisplay: [String: String] = [:]
        for (label, name) in names { canonicalByDisplay[name] = label }
        func canon(_ label: String) -> String { canonicalByDisplay[label] ?? label }

        var result = stored
        for correction in new {
            let c = SpeakerCorrection(
                time: correction.time, from: canon(correction.from), to: canon(correction.to))
            guard c.from != c.to else { continue }
            if let i = result.firstIndex(where: { $0.time == c.time && $0.to == c.from }) {
                if result[i].from == c.to {
                    result.remove(at: i)   // full revert — the pair cancels out
                } else {
                    result[i] = SpeakerCorrection(time: c.time, from: result[i].from, to: c.to)
                }
            } else if !result.contains(c) {
                result.append(c)
            }
        }
        return result
    }
}

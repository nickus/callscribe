import Foundation

public struct MergeConfig: Sendable {
    /// Silence inside one track that splits an utterance in two.
    public var utteranceGap: TimeInterval = 1.2
    /// Adjacent same-speaker utterances closer than this are merged back.
    public var coalesceGap: TimeInterval = 0.6
    /// A system-track word outside every diarization span is snapped to the
    /// nearest span within this distance; farther words inherit the previous
    /// word's speaker.
    public var spanSnapTolerance: TimeInterval = 1.0
    /// Diarization cuts on model frames, not words, so a boundary between two
    /// speakers often lands mid-word and the first words of a reply stick to
    /// the previous speaker. Whisper's word timings are finer: each boundary
    /// between different-speaker spans is moved to the nearest silence between
    /// system-track words, when one is within this distance. 0 disables.
    public var spanBoundaryRefineTolerance: TimeInterval = 1.0
    /// Words below this Whisper probability are dropped (0 = keep all);
    /// raise to fight hallucinations on silence.
    public var minWordProbability: Float = 0.0

    /// Remove "Me" words that are just the remote voice bleeding into the mic
    /// through the speakers. On a speakerphone the mic captures the remote almost
    /// continuously, and Whisper turns that residual echo into garbled-but-
    /// plausible text — so word-matching can't catch it. Instead we suppress by
    /// TIME, per word: a mic word whose midpoint lands inside remote speech is
    /// echo. Real turn-taking speech happens while the remote is silent.
    public var echoDedup = true
    /// Remote speech is bridged across gaps up to this long into one continuous
    /// interval (Whisper leaves sub-second gaps between words within a breath),
    /// so echo words that fall in those gaps are still caught.
    public var echoBridgeGap: TimeInterval = 1.0
    /// A surviving "Me" utterance this short (in words) that still sits next to
    /// remote speech is echo residue (a stray word Whisper timed just outside the
    /// remote words) and is dropped. Genuine short backchannels happen in silence.
    public var echoRemnantMaxWords = 2
    /// How close (seconds) such a short utterance must be to remote speech to be
    /// treated as residue.
    public var echoRemnantPad: TimeInterval = 0.5

    /// Diarization sometimes invents phantom speakers from clustering drift. A
    /// remote speaker whose total talk-time is below this is folded into the
    /// nearest surviving speaker (never the last one). 0 disables the fold.
    public var phantomSpeakerMinDuration: TimeInterval = 3.0

    public init() {}
}

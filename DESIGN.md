# CallScribe — design

Local call transcription for macOS. The name `callscribe` is a working title.

## Problem

Taking notes during calls by hand is distracting. We need a desktop app that records
a call, transcribes it, and produces a summary with an action-item checklist.
Speech recognition must run strictly on-device, no network.

## Requirements

- **Languages**: Russian (primary) and English; auto-detect with manual override.
- **Modes**: live draft during the call + accurate final pass afterwards (live is
  not part of the MVP).
- **Output**: transcript with timecodes and per-speaker attribution — me plus each
  remote participant distinguished (`Speaker 1/2/3`), with names inferred from
  conversation context by the LLM where possible; summary, agreements, a
  "what I must do" checklist; Markdown export; call history.
- **Platform**: macOS only (Apple Silicon).
- **Privacy**: STT and diarization are fully offline. Summaries in v1 go through the
  locally installed `claude -p`: the transcript text is sent to the Anthropic API
  (a deliberate trade-off). The Summarizer interface allows plugging in Ollama later
  for a 100% offline setup.

## Key decisions

1. **Native Swift** (SwiftUI, menubar app), single process. macOS-only removes the
   cross-platform audio-capture pain; ScreenCaptureKit and CoreML with no glue layers.
2. **Two separate audio tracks**: microphone (me) via AVAudioEngine, system audio
   (other participants) via a Core Audio process tap (`AudioHardwareCreateProcessTap`
   + aggregate device, macOS 14.4+; AudioCap pattern). "Me vs others" attribution
   comes from the channel split — zero ML, no voice overlap between the two tracks.
   *(Changed from ScreenCaptureKit at planning stage: SCK requires the Screen
   Recording TCC with monthly re-approval nags on macOS 15+ and can't run truly
   video-free; taps use the plain Audio Recording permission. A tap-backed
   aggregate device can't be read via AVAudioEngine — IOProc callbacks only.)*
3. **WhisperKit** as the STT engine: live draft via streaming on a small model
   (base/small), final pass in batch mode on `large-v3-turbo`, each track separately.
4. **Diarization of remote participants in the MVP**: FluidAudio (pyannote models on
   CoreML, on-device) clusters voices on the system-audio track into `Speaker 1/2/3`.
   Known limits: labels are anonymous (not names), and boundaries degrade on
   overlapping speech, similar voices, and compressed conference audio. The
   diarizer cuts on model frames, so before attribution each boundary between
   different-speaker spans is snapped to the nearest inter-word silence of the
   Whisper transcription (word timings are the finer signal; speakers change
   between words, not mid-word) — reply edges stop stealing each other's words.
5. **Speaker names via the LLM**: the Summarizer prompt maps speaker labels to real
   names from conversation context ("Thanks, Misha" → Speaker 2 = Misha) —
   best-effort; manual rename in the UI is the fallback. The mapping is stored in
   `meta.json` and applied to the transcript. The same reply carries turn-level
   *speaker corrections* — lines whose attribution is clearly wrong in context
   (an answer credited to the person who asked it). Applied conservatively:
   only between remote speakers (never "Me" — the mic track is ground truth),
   and only when both the turn's timecode and its current label match. Stored
   in `meta.json` with labels canonicalized ("Speaker 2", never a display
   name, so renames can't strand them) and each entry keyed by the turn's
   original speaker (chains collapse, exact reverts cancel — replay order
   never matters). They survive every re-render; cleared when diarization
   re-runs and on Trim, whose new spans/timecodes they no longer describe.
6. **Audio is the source of truth**: written to disk continuously from the first
   second; the transcript can always be regenerated. An app crash never loses a call.
7. **Storage is plain folders, no DB**; Markdown is indexed by Spotlight (search for free).
8. **Dictation on Right Shift, hold-to-talk.** Held rather than latched, so a
   stuck session is structurally impossible. Right Shift is a *typing* key, which
   is the whole risk: guarded by a 350 ms hold threshold (ordinary shift-typing
   never crosses it), by cancelling outright when any other key or modifier goes
   down during the hold, and by never arming under a chord. Those three rules live
   in a pure `DictationGesture` state machine so they're unit-tested rather than
   hand-verified. Nothing ever consumes the keystroke — swallowing it would break
   capital letters system-wide.
8b. **The hold is detected by polling `CGEventSource`, not by an event monitor.**
   `NSEvent.addGlobalMonitorForEvents` is the obvious implementation and it
   **breaks the app** on macOS 26: with one installed, this process stops
   receiving its own mouse events — clicks go to whatever is behind our windows,
   the tray menu won't open, and no window becomes key, all while the app renders
   correctly and its main thread sits idle. It presents as a total UI freeze, and
   took a long bisection to attribute (0 clicks delivered with the monitor
   installed; 6 in as many seconds without it). So the watcher polls at 20 Hz:
   `flagsState` for Right Shift via the *device-dependent* bit `0x04` (both
   `NSEvent.modifierFlags` and `keyState(kVK_RightShift)` are useless here — the
   former is device-independent, the latter reports modifiers under the left key
   code), and `secondsSinceLastEventType(.keyDown)` to recover the
   "you were typing" abort. No event tap, and **observing needs no Accessibility
   grant** — only posting the paste does.
9. **Insertion by clipboard + synthetic ⌘V**, not the Accessibility API.
   Setting `kAXSelectedTextAttribute` is tidier but fails silently in too many of
   the places people type (Electron apps, terminals, most web views); ⌘V is what
   they all implement. The clipboard is snapshotted and restored, and the
   synthetic event uses a `.privateState` source so it can't inherit the Right
   Shift the user has just this moment been holding (⌘⇧V is a different command).
   Where posting is impossible — untrusted, or secure input on a password field —
   the text is left on the clipboard rather than dropped.
10. **Dictation keeps its own warm model instance**, separate from the pipeline's.
   Sharing one would park a two-second dictation behind an hour-long call
   transcription; the cost is both resident while a call processes, bounded by a
   10-minute idle release. The load is kicked off when recording *starts*, so the
   first-use cost overlaps the user's speech instead of following it. Dictation
   stands down entirely while a call records — one microphone, and the call wins.
11. **Echo cancellation before transcription, offline.** The mic track contains
   the remote voices bleeding in through the speakers, which the mic-side
   transcript would attribute to "Me". Apple's real-time voice processing
   removes the echo but muffles the voice; instead the pipeline runs SpeexDSP's
   adaptive filter (vendored C sources) *after* the call, using the system
   track as the clean far-end reference — possible only because both tracks
   are recorded separately and time-aligned. Falls back to the raw mic if
   either input is unusable.
12. **A persistent voice library, matched one-to-one.** Enrolling a speaker
   stores their voice embedding (`voices.json`); later calls get names
   automatically. Matching happens at the speaker level, not FluidAudio's loose
   per-segment matching (which over-matches similar voices), and assignment is
   greedy one-to-one — a wrong name is worse than a missed match.
13. **Calls are grouped into projects** — arbitrary folders the user picks; a
   "Default" project pointing at `~/Documents/CallNotes` keeps old recordings
   working. Processing runs in the background so the next call can start
   recording immediately, and a Trim tool cuts dead air off a recording and
   re-runs the pipeline (user corrections — title, speaker names — survive).

## Architecture

```
┌─ Menubar UI (SwiftUI) ──────────────────────────────────┐
│  ● Rec/Stop, live draft, transcript, history,           │
│  speaker rename                                         │
└──────┬──────────────────────────────────────────────────┘
       │
┌──────▼──────────┐  ┌──────────────────────┐
│ AudioRecorder   │→ │ Transcriber          │
│ Core Audio tap  │  │ WhisperKit           │
│ (system audio)  │  │ live: small          │
│ AVAudioEngine   │  │ final: large-v3-turbo│
│ (microphone)    │  └──────────┬───────────┘
└─────────────────┘             │ word-timestamped segments
       ↓ writes continuously    ▼
   Storage:          ┌──────────────────────┐  ┌───────────────────────────┐
   one folder        │ Diarizer             │→ │ Summarizer                │
   per call          │ FluidAudio (CoreML), │  │ claude -p / (Ollama later)│
                     │ system track only    │  │ + speaker-name inference  │
                     └──────────────────────┘  └───────────────────────────┘
```

- **AudioRecorder** — two WAV/CAF tracks, 16 kHz mono, continuous writes to disk.
- **Transcriber** — live: mixed signal → ring buffer → WhisperKit streaming (draft,
  no attribution). Final: each track separately with word timestamps.
- **Diarizer** — runs on the system-audio track, produces time-ranged speaker
  clusters; merge step snaps cluster edges to inter-word silences, then aligns
  Whisper segments with clusters by time overlap →
  `[00:12:34] Me: … / Speaker 2: …`.
- **Summarizer** — a "transcript → markdown" protocol + prompt template (summary,
  agreements, "my tasks" checklist, speaker-name mapping, turn-level speaker
  corrections). Implementation #1 shells out to `claude -p`.

macOS permissions: Microphone + System Audio Recording (`NSAudioCaptureUsageDescription`,
required by the Core Audio tap) — onboarding flow on first launch. No Screen
Recording permission needed.

## Data flow

During the call:
1. ● Rec → both captures start; audio hits the disk immediately.
2. Mixed signal → live draft in the window (marked as "draft").
3. Live degrades gracefully: if the model can't keep up, the draft lags; disk
   recording is never affected (priority #1).

After Stop:
4. Final STT pass per track; diarization on the system track; merge by time overlap
   → `transcript.md` with `Me / Speaker N` labels.
5. Transcript → Summarizer → `summary.md` + inferred speaker names + turn-level
   speaker corrections; both are applied to the transcript, manual rename
   available in the UI.
6. Window shows transcript + summary; "copy / export / open folder" actions.

## Storage

```
~/Documents/CallNotes/2026-07-14_15-30/
  mic.wav  system.wav  transcript.md  summary.md  meta.json
```

`meta.json` holds call metadata, the speaker-label → name mapping (inferred or
manually set), and the LLM's turn-level speaker corrections. In-app history = a
listing of this folder. Setting: "delete audio
after successful transcription".

## Error handling

- Permission revoked / capture died mid-call → immediate notification; everything
  recorded so far is kept.
- No `claude` CLI / no network → transcript is still produced and saved (with
  anonymous speaker labels); the summary has a "retry" button. Transcription and
  diarization never depend on summarization.
- Diarization failure → transcript falls back to `Me / Participant` labels; the
  call is not lost.
- First launch → model download (Whisper ~1.5 GB + small model + diarization models)
  with a progress bar.
- Low disk space → checked before recording starts.

## Testing

- Unit: merge logic — aligning word-timestamped Whisper segments with diarization
  clusters across two tracks (the core logic of the app).
- Golden test of the pipeline on a short two-track ru+en fixture with two remote
  speakers.
- Summarizer is mocked in tests (including the name-mapping response).
- Audio capture — manual smoke test (not verifiable in CI).
- Dictation: the Right Shift gesture is a pure state machine and unit-tested
  exhaustively (it decides what happens on every keystroke, so a regression here
  would be felt system-wide). The dictation log's format is tested too, and the
  timestamp-free decode path against the golden speech fixture (opt-in, needs the
  model). The hotkey monitor, the overlay panel and the synthetic ⌘V are all
  manual — none can be exercised without a real keyboard and a focused app.

## Phases

1. **MVP**: record two tracks → final transcript (me + Speaker 1/2/3, timecodes) →
   diarization → summary + checklist + name inference via claude → export/history.
   No live.
2. Live draft.
3. Polish: history search, audio auto-delete, Ollama backend.

## Verify at planning stage

Knowledge snapshot is early 2026: before implementation, check current docs for the
exact WhisperKit APIs (streaming, word timestamps), ScreenCaptureKit (audio-only
capture, current permission model on macOS 15+), and FluidAudio (diarization API,
model licensing).

*Verified 2026-07-14.* WhisperKit now ships inside the Argmax OSS SDK
(`github.com/argmaxinc/argmax-oss-swift`, v1.0.0, MIT); word timestamps and ru/en
auto-detect confirmed. FluidAudio v0.15.x confirmed (Apache 2.0; pyannote-derived
CoreML models are CC-BY-4.0). ScreenCaptureKit was replaced with Core Audio process
taps — see decision #2. Build system: SwiftPM only (no Xcode; CommandLineTools
toolchain), `.app` bundle assembled by the Makefile and signed with a local
self-signed certificate so TCC grants persist across rebuilds.

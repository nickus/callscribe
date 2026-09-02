# CallScribe

Local, on-device call transcription for macOS (Apple Silicon). Records your
microphone and the system audio of a call on two separate tracks, strips the
remote voices that bleed from the speakers into the mic (SpeexDSP echo
cancellation), transcribes both fully offline — WhisperKit by default, or
NVIDIA Parakeet TDT v3 (several-fold faster, a third of the size) selectable
from the tray menu — diarizes remote
participants with pyannote community-1 (Argmax SpeakerKit, on-device CoreML),
merges everything into a timecoded per-speaker
transcript, and produces a summary + action-item checklist via the local
`claude -p` CLI — the same LLM pass names the speakers and repairs turns the
diarizer attributed to the wrong person, judging by conversational context.
Calls are grouped into projects and process in the background,
so the next call can be recorded immediately; a Trim tool cuts dead air off a
recording and re-runs the pipeline on the shorter audio.

The same offline model also drives system-wide [dictation](#dictation): hold
Right Shift, speak, and the text lands wherever your cursor is.

See [DESIGN.md](DESIGN.md) for the full design.

## Build (command-line only — no Xcode required)

Needs the Command Line Tools toolchain (Swift 6+), macOS 15+.

```sh
make cert     # one-time: self-signed "CallScribe Dev" signing identity
.build/release/callscribe setup   # optional: fetch the model (~1.5 GB) up front
make run      # build, bundle, sign, and launch the menubar app
```

Other targets: `make build` (compile), `make test` (unit suite), `make app`
(assemble+sign the `.app`), `make install` (copy to ~/Applications),
`make golden` (opt-in pipeline regression test).

### Why a self-signed certificate?

macOS ties TCC permission grants (Microphone, System Audio) to a signed app's
*designated requirement*. Ad-hoc signing pins the binary's hash, so every
rebuild would re-prompt. `make cert` creates a self-signed identity in a
dedicated keychain; signing with it yields a certificate-based designated
requirement that stays constant across rebuilds, so grants persist. The cert
is untrusted (no Gatekeeper), which is fine for a local unnotarized build.

## Dictation

Hold **Right Shift**, speak, release. The recording is transcribed by the same
local model and pasted straight into whatever app owns the cursor — no cloud, no
round trip. A small overlay shows the input level while you talk, and every
dictation is appended to `dictations.md` (see below).

Past dictations live in their own **Dictations** window — tray → *Dictations…*,
or the toolbar button in the main window. They're grouped by day, newest
first, with a search field and per-entry copy and delete. It's a separate window
because dictations are global, while the main window is scoped to the selected
project. Deleting an entry rewrites `dictations.md`, so the format is defined
once, in `CallScribeCore/Dictation/DictationLogFormat.swift`, with a round-trip
test standing behind the rewrite.

Needs one extra grant, **Accessibility** (System Settings → Privacy & Security →
Accessibility), for the ⌘V that inserts the text. Noticing the hold needs no
permission at all. Without the grant dictation still transcribes and leaves the
result on the clipboard, so ⌘V by hand finishes the job. Toggle the feature, or
reopen the Accessibility pane, from the tray menu.

Right Shift is also a typing key, so three guards keep normal use intact: a hold
shorter than 350 ms does nothing, pressing any other key while it's held cancels
outright (you were typing a capital), and a chord like ⌘⇧ never arms. Nothing
swallows the keystroke, so Right Shift goes on being Shift. Dictation stands down
while a call is recording, since both want the mic.

The hold is detected by polling `CGEventSource` 20 times a second rather than with
an `NSEvent` global monitor. That is not a stylistic choice: on macOS 26 a global
monitor stops the app receiving its own mouse clicks, which presents as a
completely frozen UI. See decision 8b in [DESIGN.md](DESIGN.md).

The first dictation after launch pays a ~1 s model load, which runs while you're
still talking; the model is released again after 10 minutes idle.

## CLI

The same binary is also a CLI, so every pipeline stage is testable without the UI:

```sh
callscribe record [--duration N] [--language ru|en]   # record a call
callscribe pipeline <call-folder> [--engine parakeet] # echocancel→transcribe→diarize→merge→summarize (resumable)
callscribe echocancel|transcribe|diarize|merge|summarize <folder>  # individual stages
callscribe enroll <folder> "Speaker 2" Misha          # learn a voice; future calls name it automatically
callscribe dictate [--seconds N] [--paste]            # dictation without the hotkey
callscribe probe [--seconds N]                        # capture/permission smoke test
```

Calls are stored as plain folders under `~/Documents/CallNotes/<timestamp>/`
(`mic.wav`, `system.wav`, `transcript.md`, `summary.md`, `meta.json`).

## Files on disk

Nothing is written outside `~/Library` and the project folders you pick yourself.

**Downloaded from HuggingFace on first use** — all under
`~/Library/Application Support/CallScribe/`:

| Path | Size | Repo |
|---|---|---|
| `Models/models/argmaxinc/whisperkit-coreml/<variant>/` | ~1.5 GB | `argmaxinc/whisperkit-coreml` |
| `Models/models/openai/whisper-large-v3/` (tokenizer) | 2.7 MB | `openai/whisper-large-v3` |
| `Models/parakeet-tdt-0.6b-v3/` (only if selected) | ~0.5 GB | `FluidInference/parakeet-tdt-0.6b-v3-coreml` |
| `Models/models/argmaxinc/speakerkit-coreml/` | ~100 MB | `argmaxinc/speakerkit-coreml` |
| `Models/speaker-diarization/` (voice library embedder) | 21 MB | `FluidInference/speaker-diarization-coreml` |
| `speaker-diarization/` | 13 MB | same repo, legacy file names |

The tokenizer is a *separate* fetch from the model snapshot, which is why "the
model files exist" is not the same as "the model can load" — see the marker file
below. The fourth row is FluidAudio writing to its own default directory
regardless of the directory we pass it, so those 13 MB come back on the next
diarizer run if you delete them.

**Created by the app:**

- `projects.json` — project list and selection; `voices.json` — learned voice
  embeddings, with audible samples in `voice-samples/` (browse them via the
  People toolbar button; teach voices by clicking speaker labels in a transcript)
- `context.md` in a project's folder (toolbar → Context) — glossary/terms the
  summarizer uses to name topics correctly and fix misheard terms in the transcript
- `dictations.md` — every dictation, as a timestamped Markdown entry. Unlike the
  diagnostics log this holds **content**: the dictated text itself. That's why it
  lives here and not in `~/Library/Logs`, which `sysdiagnose` collects. Prune it
  from the Dictations window, or delete the file to drop the history entirely.
- `Models/…/<variant>/.callscribe-provisioned` — empty marker, written only after the
  model has loaded once. Its absence means "provision again", so an interrupted
  first run can't masquerade as a working install.
- `~/Library/Logs/CallScribe/callscribe.log`, rotated once at 2 MB
  (`callscribe.log.1`). Metadata only — no transcript, summary, prompt or
  dictated text.
- Per call, in the project folder: the five files listed above plus `.cache/`
  (`mic-clean.wav`, `whisper-mic.json`, `whisper-system.json`, `diarization.json`,
  `turns.json`). Audio runs ~90 MB per track per hour.

**Mostly created by macOS**: `~/Library/Preferences/com.slavayus.callscribe.plist`
(and `callscribe.plist` for the CLI) — window frames and the like, plus the two
settings the app does write there, `dictation.enabled` and
`dictation.didPromptForAccessibility`. Also `~/Library/HTTPStorages/…` and
`~/Library/Caches/com.slavayus.callscribe` — mostly `com.apple.e5rt.e5bundlecache`,
the Neural Engine compilation of the CoreML models, ~140 MB. The CLI has no bundle
identifier, so using both the app and `callscribe` builds that cache twice (~270 MB).
Deletable; it is rebuilt on the next run.

To remove everything: the `.app`, `~/Library/Application Support/CallScribe`
(this includes `dictations.md`), `~/Library/Logs/CallScribe`, both `Caches` and
`HTTPStorages` entries, both `.plist`s — and your call folders only if you want
the recordings gone too. The TCC grants (Microphone, Audio Recording,
Accessibility) are revoked separately, in System Settings → Privacy & Security.

## Architecture

- **CallScribeCore** — pure, dependency-free: the merge algorithm, transcript
  model, Markdown rendering, summary-prompt parsing, storage. Fast to unit-test.
- **CallScribeEngine** — audio capture (AVAudioEngine mic + Core Audio process
  tap for system audio), the SpeexDSP echo canceller, WhisperKit, FluidAudio,
  the `claude -p` summarizer, the resumable `PipelineRunner`, and dictation's
  capture/decode/insert pieces (`Dictation/`).
- **CSpeexDSP** — vendored SpeexDSP echo-cancellation C sources (kiss FFT +
  the MDF adaptive filter), exposed to Swift as a SwiftPM target.
- **callscribe** — the executable: ArgumentParser CLI + SwiftUI menubar app,
  plus the dictation hotkey monitor and overlay.

Dictation's own decision logic — whether a Right Shift press is a hold or a
capital letter — is a pure state machine in `CallScribeCore/Dictation`, so the
one part with real consequences for every keystroke you type is unit-tested.

## Status

MVP (design Phase 1). No live draft yet. See `scripts/smoke.md` for manual QA.
Audio-device changes mid-call (AirPods connecting, switching away, flipping
profiles) are survived: the tap and the mic engine are rebuilt on the new
route, the gap is padded with silence so the tracks stay aligned, and the
stream format is tracked so a rate flip can't corrupt a track. A track that
can't be revived is abandoned — the session keeps recording the other one and
ends only when both are dead.

# Groovecraft – notes for Claude Code sessions

A native macOS app (Swift, SwiftUI, AppKit, CoreMIDI, AVFoundation) that turns programmed drum MIDI
into convincing performances, optionally informed by a backing track, and auditions them through
the user's own drum instruments (Logic Pro etc.) over virtual MIDI.

## Hard rules

- The repository is **private** and must never be made public.
- No personal email addresses in commits, and no AI model names or identifiers in commits, code or files.
- Never use unlicensed commercial samples. The internal preview kit is synthesised in code.
- The user's original MIDI and audio files are only ever read, never changed.

## Layout

- `Sources/GrooveCore`: the platform-independent engine (Foundation only, builds and tests on Linux):
  MIDI read/write (`MIDI/`), drum maps and pattern analysis (`Drums/`), the humanisation and groove
  engines, presets, quick mode (`Humanise/`, `Library/`), backing-track analysis (`Analysis/`),
  playback scheduling and MIDI byte encoding (`Playback/`), preview drum synth (`Synth/`).
- `Sources/GroovecraftApp`: the macOS app (SwiftUI + AppKit). CoreMIDI output and AVFoundation audio
  live in `Platform/`.
- `Tests/GrooveCoreTests`: engine tests.

## Working routine

1. Engine tests run in the cloud container through Docker (no Swift on the host):
   `dockerd &` (if not running), then
   `docker run --rm -v "$PWD":/src -w /src swift:6.0-noble swift test`.
   Run them before every commit.
2. Commit to `main`, authored as `git -c user.name=Claude -c user.email=noreply@anthropic.com commit …`,
   ending with the attribution lines the session gives. Then push.
3. The Mac app only compiles on the owner's Mac (workflow `build-macos.yml`, self-hosted runner).
   Ask the owner **"Shall I build now?"** before starting a build. Keep SwiftUI expressions simple and
   give explicit types: the type checker times out on long expressions.
4. Explain changes to the owner in plain language, with short steps for testing them.

## Status (27.11.26)

- Engine complete with 59 tests (MIDI, humanisation, analysis, scheduling, documents, batch, presets).
- macOS app written but **not yet compiled**: there's no Swift for macOS in the cloud container.
  The first Mac build will likely show compile errors to fix.
- The owner's Mac needs a self-hosted runner registered for this repository (Docs/BUILDING.md).
  `compile-check.yml` is a GitHub-hosted alternative that uses paid minutes: run it only with
  the owner's agreement.

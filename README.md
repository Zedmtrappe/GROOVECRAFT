# Groovecraft

An intelligent drum MIDI humaniser for macOS. Groovecraft turns programmed, quantised drum MIDI
into a believable performance. It can listen to the rest of your song (a backing track) and it
plays the result through your own drum instrument in Logic Pro (Superior Drummer, EZdrummer,
Slate, Kontakt…) over virtual MIDI.

## What it does

- **Reads any Standard MIDI File** (type 0, 1 and 2, running status, SysEx, SMPTE time, tempo
  and metre changes). Every event is kept; exports replace only the drum notes, at ≥ 960 PPQ.
- **Understands the part:** drum tracks and channel, drum map (General MIDI or your own), grid,
  swing, quantised or played, ghost notes, accents, fills, phrase length.
- **Humanises musically.** The engine works in stages:
  - swing and data-driven groove templates (or a groove taken from another MIDI file);
  - push and pull, plus each drum's own groove position and personality;
  - correlated, per-limb timing that is steadier on the downbeats;
  - slow kit-wide drift, and fills that rush slightly;
  - metric accents, backbeat, alternating hands on repeated hits, phrase dynamics;
  - ghost-note protection, velocity curves and limits.

  Optional extras (ghost notes, flams, drags, rolls, hi-hat openings) are marked as added and
  can be left out of exports. The same seed and settings always give the same take.
- **Track-Aware Humanisation.** It analyses a backing track (tempo, beats, onsets, bass
  attacks, energy, density, plus estimated sections, chords and vocals) and lines it up with the
  MIDI. The drummer then:
  - locks the kick to the bass;
  - borrows the band's timing feel;
  - follows the energy;
  - gives verses, choruses and breakdowns their own dynamics.
- **Quick mode** (Style, Feel, six macro knobs) and **Advanced mode** (every parameter, and
  each drum on its own).
- **Takes and A/B:** every Humanise adds a take. Takes can be compared (switching is seamless
  while playing), marked as favourites, renamed and exported. The original is never changed.
  Full undo and redo.
- **Timeline and drum grid editor:**
  - backing waveform, energy curve and bass attacks;
  - section markers, loop region and playhead;
  - original and humanised positions shown together;
  - select, move, change velocity and length, add and delete notes.
- **External audition:**
  - a "Groovecraft" virtual MIDI port, or any destination including the IAC Driver;
  - sample-exact timestamps sent from a real-time thread;
  - latency compensation, channel, note remapping, test notes;
  - optional MIDI clock and transport;
  - all notes off on stop, loop and panic.
- **Built-in preview kit** (synthesised, no samples) and backing-track playback on the same clock.
- **Presets:** 12 distinct factory presets; user presets with search, favourites, categories, import and export.
- **Batch processing** of many files, with naming, overwrite protection and per-file errors.
- **Projects** (`.groovecraft`) keep the original MIDI, the analysis, every take and all settings.

## Building

See [Docs/BUILDING.md](Docs/BUILDING.md).

## What has been verified, and what hasn't

- The engine is covered by automated tests (`swift test`), run on every change: MIDI, humanisation,
  analysis on synthesised audio, MIDI scheduling and the document model.
- The macOS app compiles only on a Mac. Its first builds and the external-MIDI path into Logic
  Pro still need checking on real hardware: the virtual port appearing in Logic, timing by ear,
  and recording into Logic.
- Logic can't be started or synchronised by Groovecraft (Logic doesn't follow external MIDI
  clock). Recording into Logic works through normal MIDI recording; the in-app guide explains how.
- Section labels, chords and vocal activity are estimates and are labelled as such.

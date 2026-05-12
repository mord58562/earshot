# Earshot

A macOS menubar parametric EQ. Pick an output device, drop a few bands,
and every sound your Mac plays runs through the EQ on its way out.

## What's new in 1.0.2

- Fixed a long-session glitch where the engine watchdog's recovery path
  was a silent no-op. After enough hours the input/output ring would
  drain to zero, watchdog would try to restart routing, but the restart
  short-circuited because `AVAudioEngine.isRunning` was still true and
  neither device UID had changed - so the wedged input AUHAL was never
  actually rebuilt. After 6 failed attempts the recovery cap fired and
  EQ silently disabled itself, leaving the menubar icon green but no
  audio being processed. Recovery now forces a full teardown and
  rebuild, so transient input stalls heal in ~200 ms instead of
  cascading into a manual relaunch.

## What's new in 1.0.1

- Toggling EQ off via the popover now restores the system default
  output to your real device. Previously it stopped the engine but left
  the system default pointed at BlackHole 2ch, so audio kept playing
  into the loopback void and looked like a crash (notably after Rekordbox
  or another app briefly stalled the input AUHAL).

## Features

- **Drag-the-curve editor** - bands are dots on the frequency response.
  Drag to set freq + gain, Option / Shift to constrain to one axis,
  double-click to reset gain. Vertical guide + live freq/dB/Q readout on
  hover. Cmd-Z / Cmd-Shift-Z undo/redo. Up to 24 bands.
- **Full filter set** - every parameter `AVAudioUnitEQ` exposes: peak,
  low / high shelf, low / high pass (with resonant variants), band-pass,
  notch. Frequency, gain, Q, per-band bypass, and a global preamp.
- **Live editing** - band parameters update without engine restart, so
  dragging a slider or a dot doesn't introduce dropouts.
- **Auto preamp** - optional toggle that continuously trims preamp to
  keep peaks just below clipping. Movement is imperceptible (~0.2 dB/sec)
  at rest and a little faster during active clipping. Only attenuates;
  capped at 0 dB so it never adds make-up gain.
- **Bypass** - one-click button that routes audio to the built-in
  speakers with the EQ bypassed. Useful when you yank headphones and
  want laptop speakers without touching macOS sound settings.
- **Preset library** - save the current EQ under any name. Loaded preset
  is highlighted; the row menu has Update, Rename, Export, Delete.
  Stored at `~/Library/Application Support/Earshot/presets.json`.
- **AutoEQ import / export** - reads and writes
  [`ParametricEQ.txt`](https://github.com/jaakkopasanen/AutoEq),
  the same format AutoEQ, EqualizerAPO, Wavelet, and Poweramp Equalizer
  use, so presets carry across without a converter.
- **Find your headphone** - search the bundled AutoEQ catalog (~2000
  entries across oratory1990 + Crinacle measurements; on-demand refresh
  from GitHub), click a model, and Earshot downloads its
  ParametricEQ.txt and adds it as a preset.
- **Tahoe-styled UI** - frosted-glass popover, continuous-corner card
  surfaces, custom logo and app icon generated programmatically at build.

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (arm64)
- [BlackHole 2ch](https://existential.audio/blackhole/) installed (free,
  MIT-licensed). Earshot reads system audio out of BlackHole as a
  virtual loopback. Apple shipped a Process Tap API in macOS 14.4 that
  would in theory replace the BlackHole route, but it needs a paid
  Developer ID and entitlements I'm not paying for, so this build sticks
  with BlackHole.

## Installing

One command:

```sh
git clone https://github.com/mord58562/earshot.git
cd earshot
./install.sh
```

`install.sh` checks for [BlackHole 2ch](https://existential.audio/blackhole/)
(the free open-source virtual loopback driver Earshot uses to capture
system audio) and installs it via Homebrew if it's missing, then builds
Earshot, copies the app into `/Applications/`, and launches it.

If you don't have Homebrew, install BlackHole manually from
https://existential.audio/blackhole/ and re-run `./install.sh`.

The build is ad-hoc-signed with hardened runtime. On first launch macOS may
need a right-click → Open to bypass Gatekeeper.

To launch at login: System Settings → General → Login Items → click `+`
and add `Earshot.app`. Earshot also auto-registers as a login item on first
launch via `SMAppService`.

## Using it

1. Launch Earshot - its glyph appears in the menubar.
2. Click the glyph; pick your **Output** device (where you want the EQ'd
   audio to play - your DAC, headphone jack, etc).
3. Toggle the **EQ on/off** switch.
   - **EQ on**: Earshot sets the system default output to BlackHole 2ch,
     captures from BlackHole, EQs it, and routes to the chosen output.
   - **EQ off**: Earshot stops the engine entirely. macOS sound settings
     are left alone, audio plays normally.
4. Edit bands, save presets, or import oratory1990 measurements via
   **Find a preset**.

The app remembers your last state across launches.

## Linux

There's a Linux CLI in [`linux/`](linux/) that does the most useful piece
of what Earshot does on macOS: take an AutoEQ `ParametricEQ.txt` and
apply it system-wide. It generates a PipeWire `filter-chain` config that
creates a virtual sink called `Earshot EQ`; anything you route to that
sink gets the EQ and forwards to your real default output.

No GUI on Linux - if you want one, install
[EasyEffects](https://github.com/wwmm/easyeffects) and import the same
`ParametricEQ.txt` manually. See [`linux/README.md`](linux/README.md)
for the install + usage.

## File formats

**Internal preset library** is JSON at
`~/Library/Application Support/Earshot/presets.json`.

**Import / export** uses AutoEQ ParametricEQ.txt:

```
Preamp: -6.5 dB
Filter 1: ON PK Fc 105 Hz Gain 5.5 dB Q 0.71
Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
Filter 3: ON HSC Fc 11000 Hz Gain -4.0 dB Q 0.71
```

A preset written by AutoEQ, EqualizerAPO, Wavelet, or Poweramp Equalizer
imports here unchanged, and one written here exports out and works in
those tools the same way.

## Logs

`~/Library/Logs/Earshot/Earshot.log`. Rotates at ~512 KB.

## License

MIT - see [LICENSE](LICENSE).

## Attribution

- **BlackHole 2ch** by Existential Audio (https://existential.audio/blackhole/)
  - Required runtime dependency. Not bundled. Users install separately. MIT-licensed.
- **AutoEQ** by Jaakko Pasanen (https://github.com/jaakkopasanen/AutoEQ)
  - The "Find a preset" feature browses AutoEQ's published oratory1990
    measurements and downloads their `ParametricEQ.txt` files on demand.
    Earshot bundles a small index of URLs; the underlying measurement data
    is not included in this repository. AutoEQ is MIT-licensed.
- **oratory1990** measurements published as part of AutoEQ.
- **TPCircularBuffer** by Michael Tyson / A Tasty Pixel
  (https://github.com/michaeltyson/TPCircularBuffer) — the lock-free SPSC
  ring buffer that hands audio frames from the input AUHAL to the output
  engine. Source vendored under `Sources/Vendor/`. zlib-style license
  (notices retained in the source files).
- All remaining code in this repository is original to this project.

## Architecture

```
main.swift              NSApp + AppDelegate + status item
AppState.swift          ObservableObject - single source of truth
Models.swift            Codable models (EQBand, EQPreset, AppSettings)
Storage.swift           JSON load/save under Application Support
Devices.swift           CoreAudio device enumeration + system default output
AudioRingBuffer.swift   Swift wrapper around TPCircularBuffer (SPSC ring)
InputCapture.swift      Raw HALOutput AUHAL bound to BlackHole; producer side
EQEngine.swift          AVAudioEngine bound directly to user output device;
                        SourceNode → mixer → Varispeed → AVAudioUnitEQ
AutoEQFormat.swift      Parse / emit AutoEQ ParametricEQ.txt
HeadphoneIndex.swift    Bundled AutoEQ headphone index + on-demand refresh
Popover.swift           SwiftUI popover content + EQ curve drawing
Icon.swift              Programmatic menubar glyph
Logging.swift           Rotating file log
Tools/MakeAppIcon.swift Build-time app icon generator
Sources/Vendor/         TPCircularBuffer (vendored C source)
```

```
[Music app] → BlackHole 2ch (system default)
              ↓
   InputCapture (HALOutput AUHAL, input thread)
              ↓ writes interleaved Float32 stereo
        AudioRingBuffer (lock-free SPSC, ~250 ms)
              ↓ pulled on the output audio thread by
   AVAudioEngine: SourceNode → mixer → Varispeed → AVAudioUnitEQ → outputNode
                                                                      ↓
                                                              user output device
```

The two devices run on their own hardware clocks. Drift correction
lives inside the engine: `AVAudioUnitVarispeed`'s `rate` is updated
every 200 ms from the ratio of each device's `mRateScalar` (Apple's
CAPlayThrough approach). BlackHole's nominal sample rate is pinned to
the output's nominal rate at start, so varispeed's continuous adjustment
stays in the sub-ppm range and the SRC artifacts stay below audibility.

The `AVAudioSourceNode` render block and the input AUHAL render proc
are both real-time-safe: a `memcpy` plus an atomic add via
TPCircularBuffer's inline functions. No Swift method dispatch, no
allocation, no locks on either audio thread.

For a deeper walkthrough - the watchdog state machine, the auto-preamp
algorithm, sample-rate negotiation, the threading model, the build
system - see [ARCHITECTURE.md](ARCHITECTURE.md).


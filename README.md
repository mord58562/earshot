# Earshot

A macOS menubar parametric EQ. Pick an output device, drop a few bands,
and every sound your Mac plays runs through the EQ on its way out.

## Features

- **Parametric EQ editor** - every parameter `AVAudioUnitEQ` exposes:
  filter type (peak / low-shelf / high-shelf / low-pass / high-pass / band-pass /
  notch / resonant variants), frequency, gain, Q, per-band bypass, and global
  preamp. Up to 24 bands.
- **Live editing** - band parameters update without engine restart, so
  dragging a slider doesn't introduce dropouts.
- **Solo a band** - temporarily bypass every other band to hear what one
  filter is doing.
- **Auto preamp** - optional toggle that continuously trims preamp to keep
  peaks just below clipping. Cuts hard on real digital clipping, only
  recovers on signal (won't ramp up gain on silence). Only ever attenuates -
  gain is capped at 0 dB and Auto never adds make-up gain above unity.
- **Speakers passthrough** - one-click button that routes audio to the
  built-in speakers with the EQ bypassed. Useful when you yank headphones
  and want laptop speakers without touching macOS sound settings.
- **Preset library** - save the current EQ + output device under any name.
  Loaded preset is highlighted; "Update" overwrites; rename or delete from
  the row menu. Stored at `~/Library/Application Support/Earshot/presets.json`.
- **AutoEQ import / export** - reads and writes
  [`ParametricEQ.txt`](https://github.com/jaakkopasanen/AutoEq),
  the same format AutoEQ, EqualizerAPO, Wavelet, and Poweramp Equalizer
  use, so presets carry across without a converter.
- **Find your headphone** - search the AutoEq oratory1990 catalog (~bundled
  list + on-demand refresh from GitHub), click a model, and Earshot
  downloads its ParametricEQ.txt and adds it as a preset.
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

Install BlackHole 2ch first (one-time):

```sh
brew install blackhole-2ch
```

Then build and install Earshot:

```sh
git clone https://github.com/mord58562/earshot.git
cd earshot
./build.sh
cp -R Earshot.app /Applications/
```

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
- **AutoEq** by Jaakko Pasanen (https://github.com/jaakkopasanen/AutoEq)
  - The "Find a preset" feature browses AutoEq's published oratory1990
    measurements and downloads their `ParametricEQ.txt` files on demand.
    Earshot bundles a small index of URLs; the underlying measurement data
    is not included in this repository. AutoEq is MIT-licensed.
- **oratory1990** measurements published as part of AutoEq.
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
HeadphoneIndex.swift    Bundled AutoEq headphone index + on-demand refresh
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


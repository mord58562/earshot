# Earshot

A macOS menubar parametric EQ. Pick an output device, drop a few bands,
and every sound your Mac plays runs through the EQ on its way out.

## Screenshots

![EQ bands editor](docs/screenshots/01-eq-bands-expanded.png)

*Drag dots on the curve to shape the EQ. The hovered dot shows freq, dB, and Q.*

| | |
|---|---|
| ![Collapsed view](docs/screenshots/03-collapsed.png) | ![Preset search](docs/screenshots/02-preset-search.png) |
| Day-to-day surface: curve + presets. | Search the bundled ~2000-entry AutoEQ catalog. |
| ![Auto preamp tracking](docs/screenshots/04-preamp-meter-active.png) | ![Speaker output](docs/screenshots/05-speaker-output.png) |
| Auto-preamp tracking live levels. | Routing to MacBook speakers instead of headphones. |

## What's new in 1.0.1

- **Prebuilt download.** Grab `Earshot.app.zip` from
  [Releases](https://github.com/mord58562/earshot/releases) and drag the
  app into `/Applications/` - no Terminal, no build step. The bundle is
  ad-hoc signed, so the first launch needs one Gatekeeper override
  (see [Installing](#installing) below).
- **Bypass-toggle hang fix.** Flipping bypass on/off in quick succession
  used to wedge CoreAudio mid-teardown and stop responding. The exit
  path now does a single atomic re-routing instead of stop-then-restart,
  so the engine rebuilds exactly once per click.
- **Long-session recovery fix.** The engine watchdog's restart used to
  short-circuit because `AVAudioEngine.isRunning` was still true and
  neither device UID had changed, so the wedged input AUHAL was never
  rebuilt - eventually EQ would silently disable itself and you'd hear
  nothing. Recovery now forces a full teardown and rebuild; transient
  input stalls heal in ~200 ms.
- **System default restored on EQ off.** Toggling EQ off used to stop
  the engine but leave the system default pointed at BlackHole 2ch, so
  audio kept playing into the loopback void and looked like a crash.
  Disabling EQ now puts the system default back to your real output
  device.

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
  virtual loopback.

## Installing

Two paths, pick whichever you prefer.

### Option A — Prebuilt download (no Terminal)

1. **Install BlackHole 2ch first.** Earshot won't capture audio without
   it. Either run `brew install blackhole-2ch` once, or download the
   installer from [existential.audio/blackhole](https://existential.audio/blackhole/)
   and run it. A reboot after install is sometimes needed before macOS
   sees the new driver.
2. **Download `Earshot.app.zip`** from the [latest release](https://github.com/mord58562/earshot/releases/latest).
3. **Unzip** it (Finder does this on double-click) and drag
   `Earshot.app` into `/Applications/`.
4. **First launch — Gatekeeper.** This build is ad-hoc signed (no Apple
   Developer ID — notarisation costs $99/year and this is a hobby
   project), so the first time you open it macOS will refuse with one
   of:
   - "Earshot can't be opened because Apple cannot check it for
     malicious software."
   - "macOS cannot verify that this app is free from malware."

   Two equivalent ways past it, one-time per binary:

   - **Right-click → Open.** Right-click (Control-click) `Earshot.app`
     in `/Applications`, pick **Open**, then click **Open** in the
     dialog. macOS remembers the approval; future launches are silent.
   - **System Settings.** If macOS won't show an Open button at all
     (newer macOS releases hide it on the first attempt), go to
     **System Settings → Privacy & Security**, scroll down to a row
     reading something like *"Earshot was blocked from use because it
     is not from an identified developer"*, and click **Open Anyway**.

   If you'd rather inspect the binary before trusting it, the full
   source is in this repo's `Sources/` directory and the build is fully
   reproducible from `./build.sh`.

After first launch the menubar glyph appears and Earshot stays running
until you quit it via Cmd-Q.

### Option B — Build from source (one shell command)

```sh
git clone https://github.com/mord58562/earshot.git
cd earshot
./install.sh
```

`install.sh` checks for BlackHole 2ch (installs it via Homebrew if
missing, or prints the manual download link if Homebrew isn't on the
machine), runs `build.sh`, copies `Earshot.app` into `/Applications/`,
and launches it. The same Gatekeeper override may still apply on first
launch — see the right-click / System Settings instructions above.

### Launch at login

System Settings → General → Login Items → click `+` and add
`Earshot.app`. Earshot also auto-registers as a login item on first
launch via `SMAppService`, so this is usually already done for you.

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

## Changelog

Older release notes live on the
[GitHub Releases page](https://github.com/mord58562/earshot/releases).

## License

MIT - see [LICENSE](LICENSE).

## Attribution

- **BlackHole 2ch** by Existential Audio (https://existential.audio/blackhole/)
  - Required runtime dependency. Not bundled. Users install separately. MIT-licensed.
- **AutoEQ** by Jaakko Pasanen (https://github.com/jaakkopasanen/AutoEQ)
  - The "Find a preset" feature browses AutoEQ's published `ParametricEQ.txt`
    files on demand. Earshot bundles a small index of URLs; the underlying
    measurement data is not included in this repository. AutoEQ is
    MIT-licensed.
- **oratory1990** headphone measurements, published as part of AutoEQ
  under CC BY-NC-SA 4.0. Source: https://www.reddit.com/r/oratory1990/.
- **Crinacle** headphone measurements (in-ear and over-ear), accessed
  through AutoEQ's mirror. Originals at https://crinacle.com/. Used as
  reference points; Earshot bundles only URLs to the measurement files.
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


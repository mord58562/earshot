# Earshot - architecture

A dense walkthrough of how Earshot is wired up, for anyone reading the
source. Skim the README first; this file assumes you already know what
the app does from a user's point of view.

---

## 1. Pipeline at a glance

```
[any app playing audio]
        │
        ▼
  BlackHole 2ch          ← system default output is forced to BlackHole
   (virtual loopback        while EQ is on, so apps write into it.
    driver, software         BlackHole runs on its own software clock.)
    clock)
        │
        ▼ raw HALOutput AUHAL pulling input
   InputCapture.swift     ← runs on a dedicated CoreAudio input
        │                    thread; one render proc per IO cycle.
        ▼ memcpy + atomic add
   AudioRingBuffer        ← Swift wrapper around TPCircularBuffer.
   (TPCircularBuffer,        Lock-free SPSC, virtual-memory mirroring
    ~250 ms capacity)        means a single contiguous memcpy can walk
        │                    past the buffer end without wraparound.
        ▼
   AVAudioEngine          ← engine.outputNode bound directly to the
   on user output            user's chosen output device.
   device's clock              outputNode's audio thread pulls from
        │                       the ring buffer on every render cycle.
        ▼
   AVAudioSourceNode      ← deinterleaves the ring's stereo Float32
        │                    into the engine's non-interleaved
        │                    AudioBufferList. Real-time-safe.
        ▼
   AVAudioMixerNode       ← inserted because AVAudioSourceNode →
        │                    AVAudioUnitVarispeed needs an explicit
        │                    format-bridging mixer when the source
        │                    is stereo Float32.
        ▼
   AVAudioUnitVarispeed   ← drift-correction. rate = inScalar / outScalar
        │                    (each device's mRateScalar from CoreAudio).
        │                    Updated every 200 ms. Stays in the sub-ppm
        │                    range in steady state, so SRC artefacts
        │                    are inaudible.
        ▼
   AVAudioUnitEQ          ← up to 24 bands, every filter type
        │                    AVAudioUnitEQ exposes. Bypass + per-band
        │                    bypass + global preamp.
        ▼
   engine.outputNode      ← channel-mapped to user device's L/R.
        │
        ▼
   user's DAC / headphones / speakers
```

## 2. Why two engines instead of one aggregate

On macOS, `AVAudioEngine.inputNode` and `outputNode` share a single
audio unit. `kAudioOutputUnitProperty_CurrentDevice` can only point
at one device. So a single `AVAudioEngine` can't read from BlackHole
and write to a USB DAC at the same time.

The obvious workaround is `AudioHardwareCreateAggregateDevice` with
BlackHole and the output device as sub-devices. That route compiles,
runs, and has subtle clock problems: BlackHole's software clock and a
USB DAC's hardware crystal aren't actually synchronised. coreaudiod's
internal sub-device reconciliation accumulates phase error inside the
aggregate. `kAudioSubDeviceDriftCompensationKey` is tuned for the kind
of drift you see between two pieces of crystal-clocked hardware that
are nominally locked, not the tens-of-ppm difference between a
software clock and a crystal.

Earshot does not build an aggregate device. It runs:

- a raw HALOutput **AUHAL** in input mode bound to BlackHole, on
  BlackHole's clock; and
- an **AVAudioEngine** whose `outputNode` is bound to the user's
  output device, on that device's clock.

The two threads communicate exclusively through a lock-free ring
buffer. Drift between the two clocks is corrected inside the output
engine via `AVAudioUnitVarispeed`. This is the same separation Apple's
own [`CAPlayThrough`][caplaythrough] sample uses.

[caplaythrough]: https://developer.apple.com/library/archive/samplecode/CAPlayThrough/

## 3. Real-time safety

Two render contexts sit on real-time audio threads: the input AUHAL
render proc, and `AVAudioSourceNode`'s render block. Both of them
touch shared state and must be allocation-free, lock-free, and
dispatch-free.

### The input render proc (`InputCapture.swift`)

```c
status = AudioUnitRender(unit, ioActionFlags, inTimeStamp,
                         inBusNumber, inNumberFrames, abl);
ringBuffer.produce(abl.mBuffers.mData, frameCount: inNumberFrames);
```

- `AudioUnitRender` writes into a pre-allocated `AudioBufferList`
  whose `mData` storage lives for the lifetime of the AUHAL. No
  allocation per render.
- `ringBuffer.produce` is `@inlinable` and inlines into a single
  `memcpy` plus a `TPCircularBufferProduce` (an atomic add).
- Peak tracking is done in the same loop with stack-only floats.
- `lastPeakLeft` / `lastPeakRight` / `lastRenderAt` are `var` plain
  scalars - written from the audio thread, read from the main
  thread. The race is benign (we tolerate a torn read of a `Float`
  because the consumers only use it for diagnostics and metering).
- The `Unmanaged.passUnretained(self).toOpaque()` for the `refCon`
  is deliberate: the Swift class isn't retained, but `stop()` drives
  `AudioOutputUnitStop` + `AudioUnitUninitialize` + `AudioComponentInstanceDispose`
  before any chance of `self` being deinitialised, so the render
  proc can never see a freed pointer.

### The output source-node block (`EQEngine.swift`)

```swift
AVAudioSourceNode(format: stereoFormat) { isSilence, _, frameCount, abl in
    let availFrames = TPCircularBufferTail(ringPtr, &availBytes) / bytesPerFrame
    let toCopy = min(frameCount, availFrames)
    deinterleave(srcInterleaved → buf0, buf1, toCopy)
    TPCircularBufferConsume(ringPtr, toCopy * bytesPerFrame)
    if toCopy < frameCount { memset zero remainder; isSilence = true }
}
```

- The C ring-buffer pointer is captured by the closure, not the
  Swift wrapper. Avoids a `weak`/`strong` dance on the audio thread.
- `TPCircularBufferTail` / `Consume` are inline static functions
  that compile to a load + atomic op.
- The deinterleave loop is a tight `while i < toCopy` with two
  scalar writes per iteration.
- Underruns produce silence rather than blocking. The watchdog
  detects sustained underrun separately; the audio thread never
  has to know.

### What we don't do

- No `DispatchQueue.async`, `Thread.sleep`, `os_unfair_lock`, or
  `pthread_mutex_lock` on either render path.
- No Swift class allocation per render. The render block captures
  primitives only.
- No `print` / `NSLog` from render context. Logging happens on
  main, off the back of timer ticks.

## 4. Sample-rate handling and varispeed

Both devices have a *nominal* sample rate (`kAudioDevicePropertyNominalSampleRate`)
and an instantaneous *rate scalar* (`mRateScalar` on
`AudioTimeStamp` from `AudioDeviceGetCurrentTime`). The nominal rate
is what you set; the rate scalar is what the device's clock is
*actually* doing relative to its nominal rate, in real time.

Earshot does two things:

1. **Pin the nominal rates equal.** At engine start, BlackHole's
   nominal rate is set to match the output device's nominal rate.
   This isn't required for correctness (varispeed could absorb any
   ratio), but matching nominal rates means the steady-state
   varispeed correction stays sub-ppm rather than absorbing a
   wholesale resample, which keeps SRC artefacts inaudible.

2. **Continuously correct via varispeed.** Every 200 ms, a dispatch
   timer reads each device's `mRateScalar` and sets

   ```swift
   varispeed.rate = clamp(0.999, 1.001, inScalar / outScalar)
   ```

   The clamp is a safety: any reading outside that band is treated
   as junk (a transient device state) and skipped. In normal
   operation the ratio sits in `[1 - 1e-5, 1 + 1e-5]`.

This is what Apple's `CAPlayThrough` sample does. The only meaningful
difference here is that we sit inside a Swift dispatch timer rather
than a CoreAudio side-thread.

## 5. Watchdog and recovery

The audio system has a few independent failure modes that need
distinct detection. `AppState.runWatchdogTick` runs once per second
on the main runloop (added to `.common` so it fires while the SwiftUI
popover is open) and looks at three signals:

| failure mode                    | detection                                                                      | recovery                  |
|--------------------------------|--------------------------------------------------------------------------------|---------------------------|
| `AVAudioEngine.isRunning=false` | true for ≥ 2 s                                                                 | `handleConfigChange()`    |
| post-EQ tap stops firing        | `lastTapAt` older than 3 s while `engine.isRunning`                            | `handleConfigChange()`    |
| ring buffer empty               | `engine.ringBufferFillFrames == 0` for ≥ 5 s after the post-start settle window | `handleConfigChange()`    |

`handleConfigChange()` itself is gated: it ignores callbacks fired
within 2.5 s of a successful start (the post-start settle that
`AVAudioEngine` always produces), it doesn't run while routing is
already being applied, and it has a runaway guard - 5+ restarts
inside a 60 s rolling window flips EQ off and surfaces an error
rather than thrashing CoreAudio.

A separate listener watches
`kAudioHardwarePropertyDefaultOutputDevice`. When EQ is on, system
default needs to stay on BlackHole; if a Bluetooth wake, USB
sleep/wake, or another app's preference change moves it elsewhere,
audio silently goes to the new default and BlackHole drains zeroes.
The listener restores the default to BlackHole. There's a flap
detector: 5+ restores in 10 s means something else keeps fighting
us, and rather than escalating we tell the user.

## 6. Auto-preamp

The Auto toggle is the most "this had to feel right" part of the
project. The naive design - "watch the peak, drop preamp the moment
it touches 0 dBFS, recover slowly" - is audible. You hear the
algorithm. The whole point of an EQ preamp ride is that the listener
*shouldn't notice it happening*.

The shipping algorithm is in `AppState.autoAdjustPreamp`. Core ideas:

- **Single-rate movement.** 0.2 dB/sec, symmetric in both
  directions. There's no fast-attack path. If a sudden transient
  hits clipping, the preamp moves 0.008 dB on that 40 ms tick like
  every other tick. The peak clips on that one transient, and
  that's fine - you can't hear a momentary clip on a transient
  inside actual program material, and you absolutely *can* hear a
  fast gain duck. 0.2 dB/sec is below the perceptibility threshold
  for slow gain changes during program.

- **Slow envelope follower with anticipation.** A peak follower with
  instant attack and a 3 s exponential release tracks the program
  envelope. Once a peak has set the envelope high, the envelope
  stays high for several seconds even if the program briefly
  quiets. That means the preamp doesn't start creeping back up the
  moment a quieter passage comes through - it only recovers if the
  program *sustains* at a lower level. Free anticipation, no
  bookkeeping.

- **Aim is -3 dBFS.** Steady state with the 3 s envelope keeps
  peaks living near there. Useful safety margin without sacrificing
  loudness.

- **Hard cap at 0 dB preamp.** Auto only attenuates relative to
  unity. If your source is quiet, you set preamp by hand.

- **Noise gate.** Below ~-56 dBFS the algorithm freezes. Without
  this, paused-music silence would convince it to recover preamp
  all the way up, then hammer it back down on un-pause. The
  freeze keeps it parked.

## 7. Persistence

Two JSON files under `~/Library/Application Support/Earshot/`:

- `presets.json` — the user's saved preset library, versioned via
  `PresetFile.version` for future schema migrations.
- `settings.json` — the working EQ, currently selected devices,
  EQ on/off state, and which preset (if any) was last loaded.

Writes are atomic (`Data.write(to:options:.atomic)`). Reads use
`decodeIfPresent` for every key so that older `settings.json` files
forward-compatibly load against newer schemas.

A 5 s persist-ticker writes `settings.json` if the in-memory state
differs from the last persisted state. This is a backstop: most user
intents (toggle EQ, edit a band, change device, load a preset)
already call `persist()` directly, but a crash, kill -9, or sudden
power loss can bypass `applicationWillTerminate`, and the periodic
flush narrows the worst-case loss window.

The first launch with no preset library copies a bundled
`presets.json` from the app's Resources into Application Support.
After that, the bundled file is never read again - the user's copy
is canonical.

## 8. AutoEQ format

`AutoEQFormat.swift` reads and writes the de-facto parametric EQ
format used by AutoEQ, EqualizerAPO, Wavelet, Poweramp Equalizer,
and others.

```
Preamp: -6.5 dB
Filter 1: ON PK Fc 105 Hz Gain 5.5 dB Q 0.71
Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
Filter 3: ON HSC Fc 11000 Hz Gain -4.0 dB Q 0.71
```

Filter codes accepted on input:

| code   | filter                          | gain | Q   |
|--------|---------------------------------|------|-----|
| `PK`   | parametric / peaking            | yes  | yes |
| `LSC`, `LS` | low shelf                  | yes  | yes |
| `HSC`, `HS` | high shelf                 | yes  | yes |
| `LP`   | low pass                        | no   | no  |
| `HP`   | high pass                       | no   | no  |
| `BP`   | band pass                       | no   | yes |
| `NO`   | notch / band stop               | no   | yes |
| `RLP`/`RHP` | resonant low/high pass     | no   | yes |
| `RLS`/`RHS` | resonant low/high shelf    | yes  | yes |

Gain or Q are both optional in the regex; missing values default to
0 dB and Q=0.71. The parser is strict about lines that *look* like
filters (prefix "Filter") - they must match the regex or the import
fails with the offending line, rather than silently dropping bands.

## 9. Headphone catalog

`HeadphoneIndex.swift` keeps a curated index of ~32 popular
headphones bundled with the app, plus an on-demand refresh from the
AutoEq GitHub repository. The refresh path:

1. Fetch `api.github.com/.../results/oratory1990` for the list of
   measurement-set subdirectories (`harman_over-ear_2018`, etc.).
2. For each set, fetch its directory listing and emit a
   `HeadphoneEntry` per subfolder, deriving the raw URL of the
   `<name> ParametricEQ.txt` inside it.
3. De-dupe by name; sort.
4. Write the result to
   `~/Library/Caches/Earshot/headphones.json`.

The cached list is stale after 7 days. The search sheet
auto-refreshes once per session if the cache is stale.

`fetchPreset` downloads the `ParametricEQ.txt` for a single entry
and runs it through `AutoEQFormat.decode`. The download is cached
under `~/Library/Caches/Earshot/txt-<URL-derived key>.txt` so
repeated imports of the same headphone don't hit the network.

## 10. Login-item lifecycle

Earshot registers as a login item via `SMAppService.mainApp` on the
first launch where it isn't already registered. The registration
runs off-main on a utility queue so a stalled `service.register()`
call can never block the UI.

The app starts in whatever EQ state was persisted: if you quit while
EQ was on and that boot's saved output still exists, it auto-applies
EQ at launch. If the saved output device is missing (e.g. you took
your USB DAC to work), `handleLaunchOutputFallbackOrError` picks
some other non-loopback output and surfaces a one-time "switched to
X" message.

On first launch the user has to grant microphone permission for
Earshot to actually receive samples from the BlackHole AUHAL (macOS
classifies any audio input, real or virtual, as a microphone). The
permission prompt is requested in `applicationDidFinishLaunching`;
`AppState.checkMicPermission` updates `lastError` if the user denies
it, with the actual System Settings path the user needs to follow.

## 11. UI

SwiftUI inside an `NSPopover`, in a `LSUIElement` (menubar-only) app.
The popover content is rebuilt by SwiftUI from `AppState`'s
`@Published` properties, so any state mutation - whether from a UI
click, a CoreAudio property listener, the watchdog, or a config
change recovery - flows through the same publish-subscribe path as
everything else.

A few non-obvious UI decisions:

- The status-item button registers for both `.leftMouseUp` and
  `.rightMouseUp`. Right-click / Ctrl-click opens an `NSMenu` of
  presets; left-click opens the popover.
- The popover's open is deferred by one runloop tick after the
  click event so that AppKit can finish processing the click
  dispatch before SwiftUI tries to lay out a new window. This was
  a class of "clicks do nothing" bug in earlier iterations.
- The watchdog timer is added to `RunLoop.main` in `.common` mode
  rather than `.default`, because SwiftUI popover opens push the
  runloop into `.eventTracking`. A `.default`-mode timer would stop
  firing while the popover is open.
- Meter ballistics are drawn at 30 Hz with conventional VU
  characteristics: instantaneous attack, exponential release. A
  separate slow-decay peak-hold marker tracks the highest recent
  peak and decays over a few seconds, giving a clear read on
  transients.
- The frequency-response curve is drawn analytically in
  `EQCurveView.bandResponseDB` rather than by sampling the live
  audio - so it accurately represents the configured filter
  response even when EQ is off, the engine isn't running, or no
  audio is playing.

## 12. App icon

`Tools/MakeAppIcon.swift` is invoked at build time by `build.sh` to
generate `Resources/AppIcon.icns`. It draws into an offscreen
`NSImage` at every required iconset size (16/32/128/256/512 at 1x
and 2x), wraps the results into an `.iconset` directory, and shells
out to `iconutil -c icns` to compose the `.icns`.

The glyph itself is a lowercase "e" whose crossbar is one cycle of
a sine wave - the ring is an `appendArc(withCenter:radius:startAngle:endAngle:)`
call (real cubic-bezier arc), and the crossbar is two C1-continuous
cubic-bezier halves with the standard 4/3-amplitude / 36%-period
sine approximation handles, so the join at the midpoint of the wave
flows through without a kink.

## 13. Build system

Single-file `build.sh`. One `swiftc` invocation against every Swift
source plus the vendored TPCircularBuffer C files, with the bridging
header pulled in via `-import-objc-header`. Output is a
hand-assembled `.app` bundle: `Info.plist` + binary +
`Resources/AppIcon.icns` + bundled JSON.

Codesign is ad-hoc with hardened runtime + the audio-input
entitlement. The entitlement is required for the input AUHAL to
actually receive samples from BlackHole (macOS's mic-permission
plumbing applies to virtual inputs too); the hardened runtime is
required for the entitlement to be checked at all. There's no
notarisation - first launch needs a right-click → Open to bypass
Gatekeeper.

Tests are compiled the same way: a separate `swiftc` invocation
against the small subset of source files that don't pull in
AVAudioEngine or CoreAudio internals, plus `Tests/main.swift` (a
hand-rolled `expect()` / `check()` test runner that exits non-zero
on any failure). Run via `Tests/run.sh`.

## 14. Threading model summary

| context                  | thread                                | what runs                          |
|--------------------------|----------------------------------------|------------------------------------|
| input render proc        | CoreAudio input thread (real-time)    | `AudioUnitRender` → ring `produce` |
| output source-node block | AVAudioEngine output thread (real-time) | ring `consume` → deinterleave    |
| varispeed update         | dispatch utility queue                | every 200 ms, sets `varispeed.rate` |
| watchdog                 | main runloop, `.common` mode          | once per second, recovery checks   |
| meter ticker             | main runloop, `.common` mode          | 30 Hz VU display update            |
| persist ticker           | main runloop                          | once per 5 s, write settings if dirty |
| user intents             | main                                  | UI → `AppState` mutations + `engine.applyEQ` |
| device-change listener   | dispatched to main from CoreAudio     | refresh device list, fight default-output flips |

Real-time threads only ever touch the ring buffer and a couple of
`var` scalars (peak, last-render-at). All other state lives on
main; the watchdog and listeners marshal CoreAudio callbacks back
to main before doing anything substantial.

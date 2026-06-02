# Earshot on iOS 26 - feasibility

**Bottom line: no path to a system-wide or Apple-Music-output PEQ on
iOS 26 with a free Apple Developer account.** The closest viable
approximation is a HealthKit audiogram bridge to Headphone
Accommodations / AirPods Hearing Aid. Documented here so the question
doesn't have to be researched again.

## What blocks the obvious paths

| Approach | Status on iOS 26 |
|---|---|
| Capture Apple Music PCM in `AVAudioEngine` | DRM. `MusicKit` only exposes opaque `ApplicationMusicPlayer` / `SystemMusicPlayer` for streaming items. |
| ReplayKit broadcast loopback | Apple Music / `AVPlayer` audio is explicitly excluded from `RPBroadcastSampleHandler` capture. |
| System-audio-capture entitlement (the path djay / Serato use) | Private Apple-negotiated entitlement. Not requestable through the developer portal, full stop. |
| Programmatic `Settings > Music > EQ` preset | No public API. iOS 26 added nothing here. |
| Apple Music app hosting AUv3 | Apple Music does not host AUv3. AUM / GarageBand / Logic for iPad do, but the user has to listen inside the host - which isn't Apple Music. |
| Jailbreak / private entitlements / sideload exploits | Out of scope - free-developer-account project. |

## The one realistic approximation: HealthKit audiogram bridge

iOS 26 surfaces user-supplied audiograms via [HKAudiogramSample](https://developer.apple.com/documentation/healthkit/hkaudiogramsample),
which the system then consumes for:

- **Headphone Accommodations** (Settings > Accessibility > Audio /
  Visual), which applies a 3-band compensation to "Media Audio"
  system-wide on AirPods, Beats, and EarPods.
- **AirPods Hearing Aid** (iOS 26, AirPods Pro 2 / 3) which uses the
  same audiogram and shapes all media including Apple Music.

A companion iOS app could:

1. Show the same EQ UI as the macOS version.
2. Sample the composite magnitude response at the 9 audiometric
   frequencies (250 Hz - 8 kHz).
3. Invert: a +6 dB boost at 4 kHz becomes a -6 dB-HL "loss" at 4 kHz
   in the audiogram, which the system compensates for by boosting.
4. Write the `HKAudiogramSample` via the public HealthKit API
   (`NSHealthUpdateUsageDescription` only - free-dev-compatible).
5. Deep-link to Settings > Accessibility > Audio so the user toggles
   it on.

### Honest limits

- 9 fixed frequency points; no >8 kHz; no Q control; only positive
  "loss" values (relative-curve shaping requires lifting the baseline).
- Only takes effect on AirPods / Beats / EarPods-class hardware with
  Headphone Accommodations enabled.
- It's an approximation of a PEQ, not a PEQ. Sharp filters round off.
- App Review will reject if framed as "system EQ"; frame as
  "PEQ-to-audiogram converter for Headphone Accommodations" - which is
  what it actually is, and is a legitimate accessibility-adjacent
  use case.

### Secondary path - MusicKit + own playback

For the user's own purchased (DRM-free since iTunes 2009) and
sideloaded library items, `MPMediaItem.assetURL` is readable. Play
through `AVAudioEngine` with `AVAudioUnitEQ` for a true PEQ - but only
on those files. Useless for streaming subscribers.

## What to build

If we ship anything iOS, it should be a companion - **Earshot Tune** -
not a port. The companion:

- Reuses the Models / EQ-curve UI from macOS.
- Writes audiogram samples via HealthKit.
- Plays user library files through `AVAudioEngine` for true PEQ on
  that subset.

That covers about 70% of what a typical user wants (system tonal
shaping on AirPods Pro 2 / 3), with the right framing it stays on the
right side of Review, and the free-dev account is enough to build and
sideload it.

## Sources

- [HKAudiogramSample developer docs](https://developer.apple.com/documentation/healthkit/hkaudiogramsample)
- [iOS 26 Hearing Aid feature - Apple Support](https://support.apple.com/en-us/120992)
- [MusicKit + AVAudioEngine forum thread](https://developer.apple.com/forums/thread/94329)
- [Third-party PCM access for Apple Music](https://developer.apple.com/forums/thread/782902)
- [ReplayKit security model - Apple Support](https://support.apple.com/guide/security/replaykit-security-seca5fc039dd/web)
- [Incorporating Audio Effects (AUv3 hosts)](https://developer.apple.com/documentation/AudioToolbox/incorporating-audio-effects-and-instruments)

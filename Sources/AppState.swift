import Foundation
import AVFoundation
import AppKit
import SwiftUI
import Combine
import CoreAudio

/// Single source of truth for the user-visible state of the app. Owns:
/// - the preset library (loaded from disk, mutable)
/// - the working EQ (current preamp + bands), independent of any preset
/// - the currently chosen input device UID
/// - the currently chosen output device UID
/// - the on/off state of the EQ engine
///
/// Decoupling rules:
/// - Editing the working EQ does NOT touch any saved preset.
/// - Changing the output or input device does NOT touch the working EQ
///   (we just hot-swap the engine and re-apply the same coefficients).
/// - Changing the output or input device does NOT touch any saved preset.
/// - Loading a preset overwrites the working EQ + output (it's a snapshot
///   restore), but does not modify the preset itself.
/// - Saving captures the current working EQ + current output into a preset.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    @Published var presets: [EQPreset] = []
    @Published var loadedPresetID: UUID?

    /// Auto preamp: continuously trims `workingPreamp` to keep peak just
    /// below clipping. Only ever attenuates - gain is hard-capped at 0 dB
    /// and never adds make-up gain above unity. Engaged from the preamp row.
    @Published var autoPreampEnabled: Bool = false

    @Published var workingPreamp: Float = 0
    @Published var workingBands: [EQBand] = []

    @Published var inputDeviceUID: String?
    @Published var outputDeviceUID: String?

    @Published var eqEnabled: Bool = false

    @Published var availableInputs: [AudioDevice] = []
    @Published var availableOutputs: [AudioDevice] = []

    @Published var leftLevel: Float = 0
    @Published var rightLevel: Float = 0

    /// Smoothed display levels with conventional VU ballistics (instant rise,
    /// exponential decay). UI binds to these instead of the raw peaks.
    @Published var displayLeft: Float = 0
    @Published var displayRight: Float = 0

    /// Peak-hold markers, reset to 0 when the engine stops.
    @Published var peakHoldLeft: Float = 0
    @Published var peakHoldRight: Float = 0

    @Published var lastError: String?
    @Published var isApplyingRouting: Bool = false

    /// When non-nil, only this band is audible — every other band is treated
    /// as bypassed at the engine level. Working state is preserved; restoring
    /// solo to nil re-applies the saved band bypasses.
    @Published var soloedBandID: UUID? {
        didSet { reapplyEQ() }
    }

    @Published var headphoneIndex: [HeadphoneEntry] = []
    @Published var headphoneFetchInProgress: Bool = false

    // MARK: - Internals

    private let engine = EQEngine()
    private var cancellables = Set<AnyCancellable>()
    private var savedSystemOutputBeforeEQ: String?
    private var watchdog: Timer?
    private var meterTicker: Timer?
    private var persistTicker: Timer?
    private var lastPersistedSettings: AppSettings?
    /// Tracks whether the current launch is mid-startup. Lets us avoid
    /// flipping the user's persisted "EQ on" intent to off when the engine
    /// fails to start at launch (e.g., they last had a flaky HDMI selected).
    private var isLaunchActivation: Bool = false
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var didFirstLaunchSetup = false

    static let preferredLoopbackName = "BlackHole 2ch"

    init() {
        loadFromDisk()
        refreshDevices()
        unstrandSystemOutputIfNeeded()
        observeSystemDeviceChanges()
        wireEngineCallbacks()
        startEngineWatchdog()
        // Meter ticker isn't started here - setPopoverVisible(true)
        // starts it when the popover is actually on screen. Background
        // app runtime cost is dominated by the 30 Hz @Published storm,
        // and there's no point publishing if no one is observing.
        startPersistTicker()
        observeAppLifecycle()
        autoApplyOnLaunchIfPossible()
        headphoneIndex = HeadphoneIndex.load()
        checkMicPermission()
    }

    /// Backstop persist: a crash, kill -9, or sudden power loss won't run
    /// applicationWillTerminate. The fine-grained persist() calls scattered
    /// through user intents catch most state, but a periodic flush narrows
    /// the worst-case loss window to ~5 s of unsaved edits.
    private func startPersistTicker() {
        persistTicker = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.persistIfDirty() }
        }
    }

    private func observeAppLifecycle() {
        // Save when the user tabs away or the system is about to sleep —
        // both are good "I might lose the process soon" signals.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.persistIfDirty() }
            }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.persistIfDirty() }
            }
    }

    /// When EQ is on, system default needs to be BlackHole 2ch so apps
    /// write into the loopback that Earshot captures from. When EQ is off,
    /// system default should be a real device so audio plays normally.
    /// AppState.startRouting / disableEQ each call a more specific helper.
    private func unstrandSystemOutputIfNeeded() {
        let currentID = DeviceCatalog.currentDefaultOutput()
        guard let currentDev = DeviceCatalog.all().first(where: { $0.id == currentID }) else { return }
        guard DeviceCatalog.looksLikeLoopback(currentDev) else { return }
        let fallback = outputDeviceUID
            .flatMap { DeviceCatalog.device(uid: $0) }
            .flatMap { DeviceCatalog.looksLikeLoopback($0) ? nil : $0 }
            ?? DeviceCatalog.outputs().first(where: { !DeviceCatalog.looksLikeLoopback($0) })
        if let fallback = fallback {
            DeviceCatalog.setDefaultOutput(fallback.id)
            Log.write("system default was loopback (\(currentDev.name)) - switched to \(fallback.name) so apps write to a real device")
        }
    }

    private func checkMicPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .denied, .restricted:
            lastError = "Microphone permission denied - Earshot can't read system audio. System Settings > Privacy & Security > Microphone > enable Earshot."
            Log.write("mic permission denied/restricted")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if !granted {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.lastError = "Microphone permission denied - see System Settings > Privacy & Security > Microphone."
                        }
                    }
                }
            }
        case .authorized: break
        @unknown default: break
        }
    }

    // MARK: - Disk

    private func loadFromDisk() {
        presets = Storage.loadPresets()
        let s = Storage.loadSettings()
        workingPreamp = s.workingPreamp
        workingBands = s.workingBands
        loadedPresetID = s.loadedPresetID
        inputDeviceUID = s.inputDeviceUID
        outputDeviceUID = s.outputDeviceUID
        eqEnabled = s.eqEnabled
        autoPreampEnabled = s.autoPreampEnabled

        if workingBands.isEmpty, let first = presets.first {
            workingPreamp = first.preampDB
            workingBands = first.bands
            loadedPresetID = first.id
        }
    }

    private func persist() {
        persistIfDirty()
    }

    private func persistIfDirty() {
        let current = currentSettings()
        if current == lastPersistedSettings { return }
        Storage.saveSettings(current)
        lastPersistedSettings = current
    }

    private func currentSettings() -> AppSettings {
        AppSettings(
            inputDeviceUID: inputDeviceUID,
            outputDeviceUID: outputDeviceUID,
            eqEnabled: eqEnabled,
            workingPreamp: workingPreamp,
            workingBands: workingBands,
            loadedPresetID: loadedPresetID,
            autoPreampEnabled: autoPreampEnabled)
    }

    // MARK: - Device enumeration

    func refreshDevices() {
        let outs = DeviceCatalog.outputs()
        let ins = DeviceCatalog.inputs()
        availableOutputs = outs
        availableInputs = ins

        if inputDeviceUID == nil || DeviceCatalog.device(uid: inputDeviceUID ?? "") == nil {
            if let bh = ins.first(where: { $0.name == Self.preferredLoopbackName }) {
                inputDeviceUID = bh.uid
            } else if let firstLoopback = ins.first(where: { DeviceCatalog.looksLikeLoopback($0) }) {
                inputDeviceUID = firstLoopback.uid
            } else {
                inputDeviceUID = ins.first?.uid
            }
        }
        if outputDeviceUID == nil || DeviceCatalog.device(uid: outputDeviceUID ?? "") == nil {
            outputDeviceUID = outs.first(where: { !DeviceCatalog.looksLikeLoopback($0) })?.uid
                ?? outs.first?.uid
        }
    }

    private var defaultOutputListener: AudioObjectPropertyListenerBlock?

    private func observeSystemDeviceChanges() {
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }
        deviceListListener = devicesBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddr,
            DispatchQueue.main,
            devicesBlock)

        // When the user changes the system default output away from
        // BlackHole, disengage EQ entirely so the new device receives
        // audio normally. Re-selecting BlackHole as the default re-
        // engages EQ. (Previously we forced the default back to BlackHole
        // on every drift, making the macOS Sound menu useless while
        // Earshot was running.)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleSystemDefaultOutputChanged()
            }
        }
        defaultOutputListener = defaultBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr,
            DispatchQueue.main,
            defaultBlock)
    }

    private var lastDefaultRestoreAt: CFTimeInterval = 0
    private var defaultRestoreBurst: [CFTimeInterval] = []

    private func handleSystemDefaultOutputChanged() {
        let currentDefault = DeviceCatalog.currentDefaultOutput()
        let currentDev = DeviceCatalog.all().first { $0.id == currentDefault }
        let currentName = currentDev?.name ?? "unknown"
        Log.write("default-output listener fired: now=\(currentName)(id=\(currentDefault)) eqEnabled=\(eqEnabled) applying=\(isApplyingRouting)")

        guard !isApplyingRouting else { return }
        guard let inUID = inputDeviceUID,
              let inDev = DeviceCatalog.device(uid: inUID) else { return }

        if eqEnabled {
            if currentDefault == inDev.id { return }
            guard let newDev = currentDev else { return }
            if DeviceCatalog.looksLikeLoopback(newDev) { return }

            // User picked another output via the macOS Sound menu, Control
            // Center, or a Bluetooth/USB wake event. Get out of the way -
            // tear down the EQ pipeline so audio flows straight to their
            // pick, unprocessed.
            Log.write("system default -> \(newDev.name): disengaging EQ to let macOS route normally")
            savedSystemOutputBeforeEQ = nil
            outputDeviceUID = newDev.uid
            disableEQ(restoreSystemOutput: false)
            persist()
        } else {
            // EQ is off. If the user re-selects the loopback device that
            // Earshot captures from (BlackHole 2ch), re-engage EQ so the
            // pipeline resumes as if it had never been deselected. The
            // saved outputDeviceUID is whatever they had piping audio
            // through Earshot before they switched away.
            if currentDefault == inDev.id {
                Log.write("system default -> \(inDev.name): re-engaging EQ")
                setEQEnabled(true)
            }
        }
    }

    private func wireEngineCallbacks() {
        engine.onLevel = { [weak self] l, r in
            guard let self = self else { return }
            // Auto-preamp still runs while the popover is closed so the
            // engine keeps trimming clipping in the background. UI-only
            // state updates are gated behind popoverVisible so a
            // background app doesn't burn CPU re-publishing @Published
            // fields 30x/sec when nothing is observing them.
            if self.autoPreampEnabled && self.eqEnabled {
                self.autoAdjustPreamp(peak: max(l, r))
            }
            if self.popoverVisible {
                self.leftLevel = l
                self.rightLevel = r
            }
        }
        engine.onConfigurationChange = { [weak self] in
            guard let self = self else { return }
            self.handleConfigChange()
        }
    }

    /// Whether the popover is currently on-screen. Drives whether we run
    /// the 30 Hz meter ticker and publish level updates - both are pure
    /// UI work that costs CPU even when nothing is observing it.
    @Published private(set) var popoverVisible: Bool = false

    func setPopoverVisible(_ visible: Bool) {
        guard popoverVisible != visible else { return }
        popoverVisible = visible
        if visible {
            startMeterTicker()
        } else {
            meterTicker?.invalidate()
            meterTicker = nil
            // Drop the displayed levels to 0 immediately - when we next
            // show the popover the meter ticker will catch up from real
            // input. Leaving them at the last frozen value would briefly
            // show a stale read on re-open.
            displayLeft = 0
            displayRight = 0
            peakHoldLeft = 0
            peakHoldRight = 0
        }
    }

    /// Records when our last successful routing setup completed. Used to
    /// distinguish the inevitable post-start "settle" config change (which
    /// AVAudioEngine fires within ~1-2 s of every start as the aggregate
    /// device finishes negotiating) from genuine later device events.
    private var lastRoutingCompletedAt: CFTimeInterval = 0
    /// Restart attempt timestamps, capped to a rolling window. If we exceed
    /// the threshold we stop trying and surface the issue rather than
    /// thrashing the audio system.
    private var configChangeRestartTimes: [CFTimeInterval] = []

    private func handleConfigChange() {
        let now = CACurrentMediaTime()

        // 1. Ignore the post-start settle. AVAudioEngine reliably fires a
        //    config change ~1-2 s after a successful start, even when
        //    nothing's wrong; reacting to it produces an infinite restart
        //    loop because each restart fires another settle.
        if now - lastRoutingCompletedAt < 2.5 {
            Log.write("recovery skipped (post-start settle window)")
            return
        }

        // 2. Don't restart while we're already applying routing.
        if isApplyingRouting {
            Log.write("recovery skipped (isApplyingRouting)")
            return
        }

        // 3. Don't react if EQ is off.
        guard eqEnabled else { return }

        // 4. Runaway guard. 5+ restarts in 60 s = give up; the device is
        //    almost certainly cycling on us and continuing won't fix it.
        //    The window is wide enough that a USB-DAC sleep/wake cycle
        //    or a user toggling headphones repeatedly doesn't trip it.
        configChangeRestartTimes.append(now)
        configChangeRestartTimes.removeAll { now - $0 > 60 }
        if configChangeRestartTimes.count > 5 {
            Log.write("recovery cap hit (\(configChangeRestartTimes.count) in 60s); disabling EQ")
            lastError = "Audio device kept resetting. Try a different output device."
            disableEQ(restoreSystemOutput: true)
            persist()
            configChangeRestartTimes.removeAll()
            return
        }

        // Force=true is critical: the watchdog only fires when the engine
        // is wedged but AVAudioEngine.isRunning is still true and neither
        // device UID has changed. Without force, EQEngine.setRouting()
        // short-circuits at its "nothing changed" guard and the input
        // AUHAL never gets rebuilt, so the ring stays empty, the watchdog
        // fires again, and we burn through the recovery cap doing nothing.
        Log.write("engine recovery: restarting routing (force)")
        leftLevel = 0
        rightLevel = 0
        restartRouting(force: true)
    }

    /// Drives the smoothed display levels at 30 Hz. Conventional VU
    /// ballistics: needles snap up to instantaneous peaks but decay
    /// exponentially. Peak-hold markers track the highest recent peak and
    /// decay slowly, giving a clear read on transients. When the engine is
    /// off, both decay all the way to silence so the meter reflects reality
    /// rather than freezing on its last value.
    private func startMeterTicker() {
        meterTicker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let l = self.eqEnabled ? self.leftLevel : 0
                let r = self.eqEnabled ? self.rightLevel : 0

                let levelDecay: Float = 0.78
                self.displayLeft = max(l, self.displayLeft * levelDecay)
                self.displayRight = max(r, self.displayRight * levelDecay)

                let holdDecay: Float = 0.992
                self.peakHoldLeft = max(l, self.peakHoldLeft * holdDecay)
                self.peakHoldRight = max(r, self.peakHoldRight * holdDecay)

                if l < 1e-5 && self.displayLeft < 1e-4 { self.displayLeft = 0 }
                if r < 1e-5 && self.displayRight < 1e-4 { self.displayRight = 0 }
                if l < 1e-5 && self.peakHoldLeft < 1e-4 { self.peakHoldLeft = 0 }
                if r < 1e-5 && self.peakHoldRight < 1e-4 { self.peakHoldRight = 0 }
            }
        }
    }

    private var firstObservedEngineDownAt: CFTimeInterval = 0
    private var firstObservedTapSilenceAt: CFTimeInterval = 0
    private var lastHeartbeatLogAt: CFTimeInterval = 0
    private var firstObservedInputStallAt: CFTimeInterval = 0
    private var firstObservedRingUnderrunAt: CFTimeInterval = 0
    /// Tracks "system default has drifted away from BlackHole" so we can
    /// restore it from the watchdog without depending on the HAL listener
    /// (which macOS sometimes coalesces by tens of seconds).
    private var firstObservedDefaultDriftAt: CFTimeInterval = 0

    private func startEngineWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.runWatchdogTick()
            }
        }
        // Make sure the timer fires while the popover is open too: SwiftUI
        // popover opens push the runloop into .eventTracking mode, in which
        // .default-mode timers don't fire. Adding to .common covers both.
        if let watchdog = watchdog {
            RunLoop.main.add(watchdog, forMode: .common)
        }
    }

    private func runWatchdogTick() {
        if !eqEnabled || isApplyingRouting {
            firstObservedEngineDownAt = 0
            firstObservedTapSilenceAt = 0
            firstObservedInputStallAt = 0
            firstObservedRingUnderrunAt = 0
            firstObservedDefaultDriftAt = 0
            return
        }

        let now = CACurrentMediaTime()
        let runtime = now - lastRoutingCompletedAt
        let inputRenderAge = engine.lastInputRenderAt > 0
            ? now - engine.lastInputRenderAt : 0

        // Periodic diagnostic. inPeak is the post-EQ tap; inputRenderAge
        // is "seconds since the input AUHAL render proc last fired"
        // (the authoritative producer-alive signal). ringFrames is
        // diagnostic only — see the property comment on EQEngine for
        // why it's a poor stall signal.
        if now - lastHeartbeatLogAt > 30 {
            lastHeartbeatLogAt = now
            let defaultOut = DeviceCatalog.currentDefaultOutput()
            let defaultName = DeviceCatalog.all().first { $0.id == defaultOut }?.name ?? "?"
            let ringFill = engine.ringBufferFillFrames
            Log.write("heartbeat: running=\(engine.isRunning) inPeak=\(String(format: "%.3f", engine.lastInputPeak)) preamp=\(String(format: "%+0.2f", workingPreamp)) sysDefault=\(defaultName) uptime=\(Int(runtime))s ringFrames=\(ringFill) inputRenderAge=\(String(format: "%.2f", inputRenderAge))s")
        }

        // Failure mode 1: AVAudioEngine.isRunning has gone false. Wait
        // 2 s to dodge transient flips, then recover.
        if !engine.isRunning {
            if firstObservedEngineDownAt == 0 {
                firstObservedEngineDownAt = now
                return
            }
            if now - firstObservedEngineDownAt >= 2.0 {
                Log.write("watchdog: isRunning=false for \(now - firstObservedEngineDownAt)s - recovering")
                firstObservedEngineDownAt = 0
                firstObservedTapSilenceAt = 0
                firstObservedInputStallAt = 0
                firstObservedRingUnderrunAt = 0
                firstObservedDefaultDriftAt = 0
                handleConfigChange()
            }
            return
        }
        firstObservedEngineDownAt = 0

        let tapAge = engine.lastTapAt > 0 ? now - engine.lastTapAt : 0
        let postSettle = runtime > 3.0

        // Failure mode 2: post-EQ tap stopped firing entirely. Output
        // engine's render thread is dead — restart everything.
        if postSettle && tapAge > 3.0 {
            if firstObservedTapSilenceAt == 0 {
                firstObservedTapSilenceAt = now
                return
            }
            if now - firstObservedTapSilenceAt >= 1.0 {
                Log.write("watchdog: TAP SILENT for \(String(format: "%.2f", tapAge))s - recovering")
                firstObservedTapSilenceAt = 0
                handleConfigChange()
            }
            return
        }
        firstObservedTapSilenceAt = 0

        // Failure mode 3: input AUHAL render proc stopped firing. This
        // is the unambiguous producer-dead signal — the proc fires
        // whenever BlackHole's clock is driving (no app needs to be
        // writing audio for it to fire, since BlackHole emits zeros
        // when idle). When it stops, the input pipeline really is dead
        // (USB sleep, BlackHole driver crash, AUHAL disconnected, etc.)
        // and the only fix is restarting the routing.
        //
        // Historical note: this used to key off `ringBufferFillFrames
        // == 0`, which produced a false-positive recovery storm. With
        // balanced producer/consumer the ring oscillates between
        // near-empty and one-quantum-full; sampling at 1 Hz can
        // legitimately land at 0 on a healthy engine, especially
        // after long uptime or post-wake when the consumer is briefly
        // a hair faster than the producer. That false positive showed
        // up as "Earshot stops working overnight": 5 consecutive 1 Hz
        // samples at 0 → recovery; 6 recoveries in 60 s → recovery
        // cap → disableEQ. lastInputRenderAt has no such ambiguity.
        if postSettle && inputRenderAge > 5.0 {
            if firstObservedInputStallAt == 0 {
                firstObservedInputStallAt = now
                return
            }
            if now - firstObservedInputStallAt >= 1.0 {
                Log.write("watchdog: input render proc silent for \(String(format: "%.2f", inputRenderAge))s - recovering")
                firstObservedInputStallAt = 0
                handleConfigChange()
                return
            }
        } else {
            firstObservedInputStallAt = 0
        }

        // Failure mode 4 (separate concern): system default has drifted
        // away from BlackHole because another audio app launched and
        // grabbed the default for itself. The default-output HAL
        // listener handles this in principle, but macOS coalesces HAL
        // notifications during another app's launch and the listener
        // can arrive a full minute late. Poll for it directly so we
        // re-route within ~2 s. Decoupled from "ring empty" entirely -
        // we just check whether the system default is still BlackHole,
        // regardless of buffer state.
        if let inUID = inputDeviceUID,
           let inDev = DeviceCatalog.device(uid: inUID),
           DeviceCatalog.currentDefaultOutput() != inDev.id {
            if firstObservedDefaultDriftAt == 0 {
                firstObservedDefaultDriftAt = now
            } else if now - firstObservedDefaultDriftAt >= 2.0 {
                Log.write("watchdog: default drifted to id=\(DeviceCatalog.currentDefaultOutput()) for \(String(format: "%.2f", now - firstObservedDefaultDriftAt))s - restoring \(inDev.name)")
                firstObservedDefaultDriftAt = 0
                handleSystemDefaultOutputChanged()
            }
        } else {
            firstObservedDefaultDriftAt = 0
        }
    }

    private func autoApplyOnLaunchIfPossible() {
        if eqEnabled {
            isLaunchActivation = true
            startRouting()
        }
    }

    // MARK: - User intents (UI calls these)

    func setEQEnabled(_ on: Bool) {
        // Gate against rapid clicks - the engine isn't thread-safe and
        // concurrent main-thread stop + background setRouting from a
        // previous still-in-flight transition is what causes the crash
        // when the toggle is hammered.
        if isApplyingRouting { return }
        // Don't short-circuit on `on == eqEnabled`. Bypass mode runs
        // the engine with eqEnabled=false, so a user toggling OFF while
        // in bypass would otherwise do nothing - they'd be unable to
        // disable bypass via the toggle. Source of truth is the actual
        // engine state, not the eqEnabled flag.
        let wasRunning = engine.isRunning
        eqEnabled = on
        bypassMode = false
        if on {
            if wasRunning {
                engine.setBypass(false)
            } else {
                startRouting()
            }
        } else {
            if wasRunning {
                stopEngineOnQueue(reason: "user toggled EQ off")
            }
            restoreSystemOutputIfHijacked()
        }
        persist()
    }

    /// Stop the engine on the routing queue so we never have concurrent
    /// main-thread engine.stop() racing a background engine.setRouting()
    /// from a prior in-flight transition. Sets `isApplyingRouting` so the
    /// UI shows a brief spinner and rapid retries are gated out.
    private func stopEngineOnQueue(reason: String) {
        isApplyingRouting = true
        let engine = self.engine
        routingQueue.async { [weak self] in
            engine.stop()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.isApplyingRouting = false
                    Log.write("engine stopped (\(reason))")
                }
            }
        }
    }

    /// Speakers passthrough: engine running, EQ DSP bypassed, audio routed
    /// to the MacBook Air Speakers (built-in). One click to silence whatever
    /// fancy output you have set up and dump everything into laptop speakers
    /// with no EQ - useful when you take headphones off and want a quick
    /// override without touching macOS sound settings.
    @Published var bypassMode: Bool = false

    /// Output device the user had selected at the moment bypass was
    /// enabled, so we can restore it when bypass is turned off.
    private var preBypassOutputUID: String?
    /// EQ on/off state at the moment bypass was enabled. exitBypass
    /// restores this so that bypass-from-off returns to off (was forcing
    /// EQ on, which both wrong-behaviorised AND crashed because the
    /// engine had just stopped and immediately had to start again).
    private var preBypassEQEnabled: Bool = true

    func enableBypass() {
        // Gate rapid clicks - the crash happened when a second click
        // arrived mid-routing and tore down the engine while the previous
        // setRouting was still configuring it on the background queue.
        if isApplyingRouting { return }
        if !bypassMode {
            preBypassOutputUID = outputDeviceUID
            preBypassEQEnabled = eqEnabled
        }
        bypassMode = true
        eqEnabled = false
        // Find a built-in-speaker-ish device. Prefers an exact "MacBook Air
        // Speakers" / "MacBook Pro Speakers" / "Mac mini Speakers" match;
        // falls back to anything containing "Speakers" or "Built-in".
        let candidates = availableOutputs.filter {
            !DeviceCatalog.looksLikeLoopback($0)
        }
        let speaker = candidates.first(where: { $0.name.contains("Speakers") })
            ?? candidates.first(where: { $0.name.localizedCaseInsensitiveContains("built-in") })
            ?? candidates.first
        if let speaker = speaker {
            outputDeviceUID = speaker.uid
            Log.write("bypass: routing to \(speaker.name)")
            startRouting()
        } else {
            lastError = "Couldn't find a built-in speakers device."
        }
        persist()
    }

    /// Leave bypass and restore whatever state Earshot was in when bypass
    /// was turned on - the output device and the EQ-on/off flag.
    ///
    /// Earlier this routed through TWO separate routing-queue dispatches
    /// (a bare `engine.stop()`, then `startRouting()` from its completion
    /// which itself does another stop+startInternal). The doubled
    /// tear-down/rebuild of the AVAudioEngine + AUHAL within ~10 ms is
    /// what wedged CoreAudio on rapid bypass-toggle: the second
    /// EQEngine.stop() entered and never completed. Funnel everything
    /// through a single setRouting call instead — same shape as
    /// enableBypass — so the engine is rebuilt exactly once per click.
    func exitBypass() {
        if isApplyingRouting { return }
        let target: String? = {
            if let uid = preBypassOutputUID,
               availableOutputs.contains(where: { $0.uid == uid }) {
                return uid
            }
            return outputDeviceUID
        }()
        let restoreEnabled = preBypassEQEnabled
        preBypassOutputUID = nil

        if let target = target {
            outputDeviceUID = target
            Log.write("exitBypass: restoring output to \(target)")
        }
        bypassMode = false
        eqEnabled = restoreEnabled
        if restoreEnabled {
            // setRouting does stop+startInternal atomically on the
            // routing queue; one dispatch, no race window.
            startRouting()
        } else {
            // EQ was off before bypass - stop the engine and restore
            // whatever system default was in place pre-EQ.
            stopEngineOnQueue(reason: "exit bypass to EQ-off")
            restoreSystemOutputIfHijacked()
        }
        persist()
    }

    func setOutputDevice(uid: String) {
        guard outputDeviceUID != uid else { return }
        let from = outputDeviceUID ?? "nil"
        Log.write("setOutputDevice(\(from) -> \(uid)) eqEnabled=\(eqEnabled)")
        outputDeviceUID = uid
        if eqEnabled {
            restartRouting()
        }
        persist()
    }

    func setInputDevice(uid: String) {
        guard inputDeviceUID != uid else { return }
        let from = inputDeviceUID ?? "nil"
        Log.write("setInputDevice(\(from) -> \(uid)) eqEnabled=\(eqEnabled)")
        inputDeviceUID = uid
        if eqEnabled {
            restartRouting()
        }
        persist()
    }

    func setPreamp(_ value: Float) {
        workingPreamp = value
        loadedPresetID = nil
        reapplyEQ()
        persist()
    }

    // MARK: - Auto preamp

    private var autoEnvelope: Float = 0
    private var lastAutoAdjustAt: CFTimeInterval = 0
    /// Retained because setAutoPreampEnabled / autoAdjustPreamp once
    /// referenced these; left as ignored fields so the on/off reset
    /// path keeps compiling even though the new algorithm doesn't
    /// consult them.
    private var autoPeakHold: Float = 0
    private var autoPeakEnvelope: Float = 0
    private var autoSignalStartedAt: CFTimeInterval = 0
    private var sustainedHeadroomSince: CFTimeInterval = 0
    private var autoConsecutiveClips: Int = 0

    /// Auto-leveler tuned for IMPERCEPTIBILITY. Core philosophy: any
    /// adjustment the algorithm makes to the preamp should slip past
    /// the listener unnoticed. Brief clipping during a sudden transient
    /// is preferable to an audible pump or duck.
    ///
    /// Concretely, this means:
    ///   - Movement rate is 0.2 dB/sec in BOTH directions, well below
    ///     the ~0.4 dB/sec threshold of perceptibility for slow gain
    ///     changes during program material. There's no fast-attack
    ///     path: if a peak suddenly hits clip, we move 0.008 dB on
    ///     that tick like every other tick. The peak clips and that's
    ///     fine; the listener won't hear the gain riding.
    ///   - The peak-follower envelope has a ~3 s release time. After
    ///     a loud peak the envelope stays elevated for several seconds,
    ///     so the preamp doesn't start creeping back up the moment
    ///     program material gets briefly quieter — natural anticipation
    ///     without explicit hold-off bookkeeping. Spiky content sits
    ///     at the peak preamp position; sustainably quiet content
    ///     drifts up only after the envelope has had time to fall.
    ///   - Aim is -3 dBFS. Steady state with the 3 s envelope keeps
    ///     peaks living near there, leaving a small but useful safety
    ///     margin without sacrificing loudness.
    ///   - Hard-capped at 0 dB preamp. Auto only attenuates relative
    ///     to unity; if the source is quiet, raise preamp by hand.
    private func autoAdjustPreamp(peak linearPeak: Float) {
        let now = CACurrentMediaTime()
        guard now - lastAutoAdjustAt > 0.04 else { return }   // ~25 Hz
        lastAutoAdjustAt = now

        // Peak-follower with instant attack and ~3 s exponential
        // release. The slow release is what gives the system its
        // anticipation: once a peak has set the envelope high, it
        // stays high for several seconds even if the program briefly
        // quiets, so we don't recover preamp into the next transient.
        if linearPeak > autoEnvelope {
            autoEnvelope = linearPeak
        } else {
            autoEnvelope *= 0.987   // ≈ 3 s time constant at 25 Hz
        }

        // Noise gate: freeze during true silence so we don't drift
        // upward whenever the user pauses music.
        let signalFloorLinear: Float = 0.0015   // ~ -56 dBFS
        if autoEnvelope <= signalFloorLinear { return }

        let envelopeDB = 20 * log10f(max(autoEnvelope, 1e-5))
        let aimDB: Float = -3.0
        let delta = aimDB - envelopeDB   // +ve: should raise; -ve: should lower

        // Movement cap: 0.2 dB/sec (0.008 dB per 40 ms tick) for normal
        // operation and recovery. When the input is actively clipping
        // (peak basically at full scale) we let the algorithm pull down
        // ~2.5x faster - still well under the JND for loudness changes
        // in program material, but enough to escape sustained clipping
        // in a second or two instead of five. Recovery rate is unchanged
        // so quiet-then-loud transients still get the slow anticipation.
        let isClipping = linearPeak >= 0.995
        let maxUp: Float = 0.008
        let maxDown: Float = isClipping ? 0.020 : 0.008
        let step: Float
        if delta > maxUp {
            step = maxUp
        } else if delta < -maxDown {
            step = -maxDown
        } else {
            step = delta
        }

        let target = max(-24, min(0, workingPreamp + step))
        if abs(target - workingPreamp) > 0.0005 {
            workingPreamp = target
            reapplyEQ()
        }
    }

    func setAutoPreampEnabled(_ on: Bool) {
        autoPreampEnabled = on
        autoEnvelope = 0
        lastAutoAdjustAt = 0
        if on && workingPreamp > 0 {
            // Auto never operates above unity. Snap down on engage.
            workingPreamp = 0
            reapplyEQ()
        }
        // Always persist so the next launch restores whatever the user
        // last had set (matches loadedPresetID + workingBands treatment).
        persist()
    }

    func updateBand(id: UUID, transform: (inout EQBand) -> Void) {
        guard let i = workingBands.firstIndex(where: { $0.id == id }) else { return }
        recordUndoSnapshot()
        transform(&workingBands[i])
        loadedPresetID = nil
        reapplyEQ()
        persist()
    }

    /// Mutate a band's parameters without writing settings to disk. For use
    /// inside high-frequency interactions (e.g. dragging an EQ dot) where we
    /// would otherwise issue dozens of JSON writes per second. Call
    /// `commitBandEdits()` once the gesture ends to flush the final state.
    /// Snapshots for undo are NOT taken here — the caller should call
    /// `recordUndoSnapshot()` once at the start of the gesture so a single
    /// undo unwinds the whole drag.
    func updateBandTransient(id: UUID, transform: (inout EQBand) -> Void) {
        guard let i = workingBands.firstIndex(where: { $0.id == id }) else { return }
        transform(&workingBands[i])
        loadedPresetID = nil
        reapplyEQ()
    }

    /// Flush pending transient band edits to disk.
    func commitBandEdits() {
        persist()
    }

    // MARK: - Undo / redo

    private struct EQSnapshot: Equatable {
        let bands: [EQBand]
        let preamp: Float
        let loadedPresetID: UUID?
    }

    private var undoStack: [EQSnapshot] = []
    private var redoStack: [EQSnapshot] = []
    private let undoLimit = 100

    private func currentSnapshot() -> EQSnapshot {
        EQSnapshot(bands: workingBands,
                   preamp: workingPreamp,
                   loadedPresetID: loadedPresetID)
    }

    /// Capture the current EQ state as a single undoable step. Call before
    /// mutations the user should be able to revert. Identical consecutive
    /// snapshots are deduped so a no-op edit doesn't bury real history.
    func recordUndoSnapshot() {
        let snap = currentSnapshot()
        if undoStack.last == snap { return }
        undoStack.append(snap)
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        apply(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        apply(next)
    }

    private func apply(_ s: EQSnapshot) {
        workingBands = s.bands
        workingPreamp = s.preamp
        loadedPresetID = s.loadedPresetID
        reapplyEQ()
        persist()
    }

    func addBand() {
        addBand(at: 1000, gain: 0)
    }

    /// Spawn a parametric band anchored to a specific frequency and gain.
    /// Used by click-on-empty-canvas; falls through to the default
    /// 1 kHz / 0 dB band when called without args.
    func addBand(at frequency: Float, gain: Float) {
        guard workingBands.count < EQEngine.maxBands else { return }
        recordUndoSnapshot()
        let q: Float = 1.0
        let f = max(20, min(22000, frequency))
        let g = max(-24, min(24, gain))
        workingBands.append(EQBand(type: .parametric, frequency: f, gain: g, q: q))
        loadedPresetID = nil
        reapplyEQ()
        persist()
    }

    func removeBand(id: UUID) {
        recordUndoSnapshot()
        workingBands.removeAll { $0.id == id }
        loadedPresetID = nil
        if soloedBandID == id { soloedBandID = nil }
        reapplyEQ()
        persist()
    }

    func resetWorkingEQ() {
        recordUndoSnapshot()
        workingPreamp = 0
        workingBands = []
        loadedPresetID = nil
        soloedBandID = nil
        reapplyEQ()
        persist()
    }

    // MARK: - Presets

    func loadPreset(_ id: UUID) {
        guard let p = presets.first(where: { $0.id == id }) else { return }
        recordUndoSnapshot()
        workingPreamp = p.preampDB
        workingBands = p.bands.map { EQBand(id: UUID(), type: $0.type,
                                            frequency: $0.frequency, gain: $0.gain,
                                            q: $0.q, bypass: $0.bypass) }
        loadedPresetID = id
        // Presets don't carry an output device any more, so a load is
        // always just a live coefficient update on the current output.
        if eqEnabled { reapplyEQ() }
        persist()
    }

    /// Save the current working EQ under `name` as a new preset.
    func saveCurrentAsNewPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Untitled \(presets.count + 1)" : trimmed
        let preset = EQPreset(
            id: UUID(),
            name: finalName,
            preampDB: workingPreamp,
            bands: workingBands)
        presets.append(preset)
        loadedPresetID = preset.id
        Storage.savePresets(presets)
        persist()
    }

    /// Overwrite the existing preset with the current working EQ.
    func updatePreset(_ id: UUID) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].preampDB = workingPreamp
        presets[i].bands = workingBands
        loadedPresetID = id
        Storage.savePresets(presets)
        persist()
    }

    func renamePreset(_ id: UUID, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        presets[i].name = trimmed
        Storage.savePresets(presets)
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if loadedPresetID == id { loadedPresetID = nil }
        Storage.savePresets(presets)
        persist()
    }

    // MARK: - Engine control

    private func applyEnabledState() {
        if eqEnabled || bypassMode {
            startRouting()
        } else {
            engine.stop()
        }
    }

    private func startRouting() {
        guard let outUID = outputDeviceUID,
              let outDev = DeviceCatalog.device(uid: outUID) else {
            lastError = "Pick an output device first."
            eqEnabled = false
            persist()
            return
        }

        // BlackHole pipeline needs system default = BlackHole so apps
        // write where we capture. Save the prior default so we can put it
        // back when the user toggles off.
        if let blackHoleUID = EQEngine.findBlackHoleUID(),
           let blackHoleDev = DeviceCatalog.device(uid: blackHoleUID) {
            let priorID = DeviceCatalog.currentDefaultOutput()
            if priorID != 0, priorID != blackHoleDev.id,
               let priorDev = DeviceCatalog.all().first(where: { $0.id == priorID }) {
                savedSystemOutputBeforeEQ = priorDev.uid
            }
            DeviceCatalog.setDefaultOutput(blackHoleDev.id)
        }

        let preamp = workingPreamp
        let bands = effectiveBands()
        let preserveIntent = isLaunchActivation
        isLaunchActivation = false
        applyRoutingOffMain(outUID: outUID,
                            preamp: preamp, bands: bands,
                            successLogContext: "EQ enabled out=\(outDev.name)",
                            failureRecovery: { [weak self] in
            guard let self = self else { return }
            // engine.stop() can block on coreaudiod IPC; on main thread
            // that triggers the macOS UI hang killer (SIGKILL after 20s).
            // Funnel through the routing queue.
            let engine = self.engine
            self.routingQueue.async { engine.stop() }
            if preserveIntent {
                Log.write("launch-time engine failure - attempting auto-fallback to a working output")
                self.handleLaunchOutputFallbackOrError(self.lastError ?? "EQ couldn't start on the saved output.")
            } else {
                self.eqEnabled = false
                self.persist()
            }
        })
    }

    /// Try once to recover from a launch-time engine failure by picking a
    /// different non-loopback output device. If we already tried a fallback
    /// or there's nothing else available, just leave the error showing and
    /// flip EQ off so the popover isn't stuck spinning.
    private var didAttemptLaunchFallback = false
    private func handleLaunchOutputFallbackOrError(_ messageIfNoFallback: String) {
        let failed = outputDeviceUID
        let candidates = availableOutputs.filter {
            $0.uid != failed && !DeviceCatalog.looksLikeLoopback($0)
        }
        if !didAttemptLaunchFallback, let fallback = candidates.first {
            didAttemptLaunchFallback = true
            let failedName = availableOutputs.first { $0.uid == failed }?.name ?? "saved output"
            outputDeviceUID = fallback.uid
            lastError = "EQ couldn't start on \(failedName). Switched to \(fallback.name)."
            Log.write("launch-fallback: \(failedName) → \(fallback.name)")
            isLaunchActivation = true
            startRouting()
        } else {
            lastError = messageIfNoFallback
            eqEnabled = false
            persist()
        }
    }

    private func restartRouting(force: Bool = false) {
        guard let outUID = outputDeviceUID else { return }
        _ = force
        _ = outUID
        startRouting()
    }

    private let routingQueue = DispatchQueue(label: "com.mord58562.Earshot.routing", qos: .userInitiated)
    private var currentRoutingWatchdogID: UUID?

    private func applyRoutingOffMain(outUID: String,
                                     preamp: Float, bands: [EQBand],
                                     successLogContext: String,
                                     force: Bool = false,
                                     failureRecovery: @escaping () -> Void) {
        isApplyingRouting = true

        // Watchdog: if engine.setRouting hangs in coreaudiod IPC, the
        // completion handler never runs and the UI shows a permanent
        // spinner. Force-clear after 5 s. We do NOT switch to a fallback
        // output here — coreaudiod stalls during startup are usually
        // transient (a timing race with another process's audio init,
        // not a real device problem), and silently rewriting the user's
        // saved output to "whatever non-loopback device was first in the
        // list" was a worse failure than the stall itself: relaunching
        // works, but their next session starts on HDMI instead of their
        // headphones. Just unstick the UI, surface the error, leave the
        // saved output alone.
        let watchdogID = UUID()
        currentRoutingWatchdogID = watchdogID
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            guard self.currentRoutingWatchdogID == watchdogID else { return }
            guard self.isApplyingRouting else { return }
            Log.write("routing watchdog: still applying after 5s; forcing UI back without changing saved output")
            self.isApplyingRouting = false
            self.currentRoutingWatchdogID = nil
            self.lastError = "Audio engine didn't start in time. Try toggling EQ off and on, or relaunch Earshot."
            self.eqEnabled = false
        }

        let engine = self.engine
        routingQueue.async { [weak self] in
            do {
                try engine.setRouting(outputUID: outUID, force: force)
                engine.applyEQ(preamp: preamp, bands: bands)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self = self else { return }
                        engine.setBypass(self.bypassMode || !self.eqEnabled)
                        self.lastError = nil
                        self.isApplyingRouting = false
                        self.currentRoutingWatchdogID = nil
                        self.lastRoutingCompletedAt = CACurrentMediaTime()
                        Log.write(successLogContext)
                    }
                }
            } catch {
                Log.write("engine start failed: \(error.localizedDescription)")
                let friendly = Self.friendlyEngineError(error)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self = self else { return }
                        self.lastError = friendly
                        self.isApplyingRouting = false
                        self.currentRoutingWatchdogID = nil
                        failureRecovery()
                    }
                }
            }
        }
    }

    nonisolated private static func friendlyEngineError(_ error: Error) -> String {
        let ns = error as NSError
        let raw = ns.localizedDescription
        if ns.code == 1937010544 || raw.contains("1937010544") {
            return "This output device refuses the sample rate Earshot tried (HDMI displays often do this). Try a different output, or change the device's rate in Audio MIDI Setup."
        }
        return raw
    }

    private func disableEQ(restoreSystemOutput: Bool) {
        // Don't call engine.stop() on the main thread: the CoreAudio teardown
        // inside can block on coreaudiod IPC long enough to trip macOS's UI
        // hang killer (SIGKILL after ~20s). stopEngineOnQueue dispatches to
        // the routing queue and flips isApplyingRouting for UI feedback.
        stopEngineOnQueue(reason: "disableEQ")
        if restoreSystemOutput {
            restoreSystemOutputIfHijacked()
        }
        eqEnabled = false
    }

    private func restoreSystemOutputIfHijacked() {
        guard let inUID = inputDeviceUID,
              let inDev = DeviceCatalog.device(uid: inUID) else { return }
        guard DeviceCatalog.currentDefaultOutput() == inDev.id else { return }
        if let saved = savedSystemOutputBeforeEQ,
           let dev = DeviceCatalog.device(uid: saved), dev.hasOutput {
            DeviceCatalog.setDefaultOutput(dev.id)
        } else if let outUID = outputDeviceUID,
                  let outDev = DeviceCatalog.device(uid: outUID) {
            DeviceCatalog.setDefaultOutput(outDev.id)
        }
        savedSystemOutputBeforeEQ = nil
    }

    // MARK: - Lifecycle

    func appWillTerminate() {
        engine.stop()
        restoreSystemOutputIfHijacked()
        persist()
    }

    /// True if the chosen input is missing from the system (e.g. BlackHole
    /// not installed). Drives the first-run warning UI.
    var inputMissing: Bool {
        guard let uid = inputDeviceUID else { return true }
        return DeviceCatalog.device(uid: uid) == nil
    }

    var preferredLoopbackInstalled: Bool {
        DeviceCatalog.inputs().contains { $0.name == Self.preferredLoopbackName }
    }

    // MARK: - AutoEQ import / export

    /// Parse an AutoEQ ParametricEQ.txt file and add it as a new preset.
    func importAutoEQ(text: String, defaultName: String) -> Result<EQPreset, AutoEQFormat.ParseError> {
        let result = AutoEQFormat.decode(text: text, defaultName: defaultName)
        if case .success(let preset) = result {
            presets.append(preset)
            Storage.savePresets(presets)
            return .success(preset)
        }
        return result
    }

    /// Render a preset (or the working EQ) as AutoEQ ParametricEQ.txt.
    func exportAutoEQ(preset: EQPreset) -> String {
        AutoEQFormat.encode(preset)
    }

    func exportWorkingAutoEQ(name: String = "Earshot working EQ") -> String {
        let p = EQPreset(id: UUID(), name: name,
                         preampDB: workingPreamp,
                         bands: workingBands)
        return AutoEQFormat.encode(p)
    }

    /// Load directly into the working EQ instead of saving as a preset.
    func loadWorkingFromAutoEQ(text: String) -> Result<Void, AutoEQFormat.ParseError> {
        switch AutoEQFormat.decode(text: text, defaultName: "Imported") {
        case .success(let p):
            recordUndoSnapshot()
            workingPreamp = p.preampDB
            workingBands = p.bands
            loadedPresetID = nil
            reapplyEQ()
            persist()
            return .success(())
        case .failure(let e):
            return .failure(e)
        }
    }

    // MARK: - Headphone search

    func searchHeadphones(_ query: String) -> [HeadphoneEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return headphoneIndex }
        return headphoneIndex.filter { $0.name.lowercased().contains(q) }
    }

    /// Fetch the live AutoEQ oratory1990 catalog from GitHub. Replaces the
    /// bundled list with the full set (~hundreds of headphones). Failure
    /// (offline, rate-limited) leaves the existing list intact.
    func refreshHeadphoneIndex() async {
        headphoneFetchInProgress = true
        defer { headphoneFetchInProgress = false }
        do {
            let fresh = try await HeadphoneIndex.refreshFromNetwork()
            if !fresh.isEmpty {
                headphoneIndex = fresh
                Log.write("headphone index refreshed: \(fresh.count) entries")
            }
        } catch {
            lastError = "Couldn't refresh headphone catalog: \(error.localizedDescription)"
            Log.write("headphone refresh failed: \(error)")
        }
    }

    /// Download the AutoEQ preset for an entry and add it to the library.
    func importFromHeadphone(_ entry: HeadphoneEntry) async {
        headphoneFetchInProgress = true
        defer { headphoneFetchInProgress = false }
        do {
            let preset = try await HeadphoneIndex.fetchPreset(for: entry)
            presets.append(preset)
            loadedPresetID = preset.id
            workingPreamp = preset.preampDB
            workingBands = preset.bands
            Storage.savePresets(presets)
            persist()
            reapplyEQ()
            Log.write("imported headphone preset: \(entry.name)")
        } catch {
            lastError = "Couldn't fetch \(entry.name): \(error.localizedDescription)"
            Log.write("headphone fetch failed: \(error)")
        }
    }

    // MARK: - Solo

    func toggleSolo(_ id: UUID) {
        soloedBandID = (soloedBandID == id) ? nil : id
    }

    private func reapplyEQ() {
        guard eqEnabled else { return }
        let bands = effectiveBands()
        engine.applyEQ(preamp: workingPreamp, bands: bands)
    }

    private func effectiveBands() -> [EQBand] {
        guard let solo = soloedBandID else { return workingBands }
        return workingBands.map { b in
            var c = b
            c.bypass = (b.id != solo)
            return c
        }
    }
}

import Foundation
import AVFoundation
import CoreAudio

/// Earshot's audio pipeline (CAPlayThrough-derived).
///
/// Architecture
/// ============
///
///     [Music app] → BlackHole 2ch (system default)
///                   ↓
///     [InputCapture]   raw HALOutput AUHAL bound to BlackHole
///                   ↓ writes Float32 stereo into
///     [AudioRingBuffer]   lock-free SPSC, ~1 sec capacity
///                   ↓ pulled by
///     [AVAudioEngine]   outputNode bound DIRECTLY to user's output device
///         AVAudioSourceNode → mixer → AVAudioUnitVarispeed → AVAudioUnitEQ → outputNode
///         • Varispeed rate continuously updated from
///           inputDevice.mRateScalar / outputDevice.mRateScalar — this
///           is Apple's CAPlayThrough drift-correction approach.
///                   ↓ channel-mapped to user device's L/R
///     [Output device]
///
/// Why this shape
/// --------------
/// The two devices stay on independent clocks. Drift reconciliation
/// happens inside this engine via AVAudioUnitVarispeed, with the rate
/// updated continuously from each device's mRateScalar — the same
/// signal Apple's own CAPlayThrough sample uses. No aggregate device,
/// so coreaudiod doesn't try to reconcile the two sub-device clocks
/// itself; that path turned out to accumulate phase error and is what
/// the BlackHole-driver docs warn about under "drift compensation."
///
/// Real-time safety
/// ----------------
/// The AVAudioSourceNode render block runs on the output audio thread.
/// It calls only into AudioRingBuffer.consume — which inlines into a
/// memcpy + atomic load (TPCircularBuffer). No Swift method dispatch,
/// no allocation, no locks. The InputCapture render proc on the input
/// audio thread is similarly tight.
final class EQEngine: @unchecked Sendable {

    static let maxBands = 24

    var isRunning: Bool { engine?.isRunning ?? false }

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var mixer: AVAudioMixerNode?
    private var varispeed: AVAudioUnitVarispeed?
    private var eq: AVAudioUnitEQ?
    private var configChangeObserver: NSObjectProtocol?
    private var fadeTimer: DispatchSourceTimer?
    private var rateUpdateTimer: DispatchSourceTimer?

    private var ringBuffer: AudioRingBuffer?
    private var inputCapture: InputCapture?

    private var currentInputUID: String?
    private var currentOutputUID: String?
    private(set) var inputDeviceID: AudioDeviceID = 0
    private(set) var outputDeviceID: AudioDeviceID = 0

    var onLevel: ((Float, Float) -> Void)?
    var onConfigurationChange: (() -> Void)?

    private(set) var lastTapAt: CFTimeInterval = 0
    private(set) var lastInputPeak: Float = 0
    private(set) var startedAt: CFTimeInterval = 0

    /// Most recent output sample-time as observed at the outputNode.
    /// Same shape as before so the watchdog reads the same property.
    var outputSampleTime: AVAudioFramePosition? {
        guard let t = engine?.outputNode.lastRenderTime, t.isSampleTimeValid else { return nil }
        return t.sampleTime
    }

    /// Number of frames currently in the ring buffer. Watchdog reads
    /// this to detect underruns (consistently low fill = consumer is
    /// outpacing producer = stalled input).
    var ringBufferFillFrames: UInt32 { ringBuffer?.fillFrames ?? 0 }

    private let levelDispatchInterval: CFTimeInterval = 1.0 / 30.0
    private var lastLevelDispatch: CFTimeInterval = 0

    // MARK: - Public API

    func setRouting(outputUID: String,
                    sampleRate: Double? = nil, force: Bool = false) throws {
        guard let inputUID = Self.findBlackHoleUID() else {
            throw NSError(domain: "EQEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "BlackHole 2ch isn't installed. Earshot needs a virtual loopback driver to capture system audio. Install from existential.audio/blackhole."])
        }
        if !force, isRunning, currentInputUID == inputUID, currentOutputUID == outputUID { return }
        stop()
        try startInternal(inputUID: inputUID, outputUID: outputUID, sampleRate: sampleRate)
    }

    func setBypass(_ bypass: Bool) {
        eq?.bypass = bypass
        Log.write("EQ bypass = \(bypass)")
    }

    func applyEQ(preamp: Float, bands: [EQBand]) {
        guard let eq = eq else { return }
        eq.globalGain = max(-96, min(24, preamp))
        for i in 0..<Self.maxBands {
            let auBand = eq.bands[i]
            if i < bands.count {
                let b = bands[i]
                auBand.bypass = b.bypass
                auBand.filterType = b.type.au
                auBand.frequency = max(20, min(22000, b.frequency))
                if b.type.usesGain {
                    auBand.gain = max(-24, min(24, b.gain))
                } else {
                    auBand.gain = 0
                }
                if b.type.usesQ {
                    auBand.bandwidth = bandwidthOctaves(forQ: b.q)
                }
            } else {
                auBand.bypass = true
            }
        }
    }

    func stop() {
        Log.write("EQEngine.stop() entered (running=\(isRunning))")
        rateUpdateTimer?.cancel()
        rateUpdateTimer = nil
        fadeTimer?.cancel()
        fadeTimer = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        // Stop input first (no more producer); drain by stopping engine
        // immediately after — anything left in the ring buffer would just
        // tail off into silence.
        inputCapture?.stop()
        inputCapture = nil
        if let eq = eq {
            eq.removeTap(onBus: 0)
        }
        usleep(15_000)
        if let e = engine, e.isRunning { e.stop() }
        engine?.reset()
        engine = nil
        sourceNode = nil
        eq = nil
        mixer = nil
        varispeed = nil
        ringBuffer = nil
        inputDeviceID = 0
        outputDeviceID = 0
        currentInputUID = nil
        currentOutputUID = nil
        startedAt = 0
        onLevel?(0, 0)
        Log.write("EQEngine.stop() complete")
    }

    // MARK: - BlackHole detection

    static func findBlackHoleUID() -> String? {
        let candidates = ["BlackHole 2ch", "BlackHole 16ch", "BlackHole 64ch"]
        for name in candidates {
            if let dev = DeviceCatalog.device(named: name), dev.hasInput {
                return dev.uid
            }
        }
        for dev in DeviceCatalog.inputs() where dev.name.contains("BlackHole") {
            return dev.uid
        }
        return nil
    }

    // MARK: - Startup

    private func startInternal(inputUID: String, outputUID: String, sampleRate: Double?) throws {
        guard let inDev = DeviceCatalog.device(uid: inputUID) else {
            throw NSError(domain: "EQEngine", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Input device not found: \(inputUID)"])
        }
        guard let outDev = DeviceCatalog.device(uid: outputUID) else {
            throw NSError(domain: "EQEngine", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "Output device not found: \(outputUID)"])
        }

        // Sample rate negotiation. We pin BlackHole to match the
        // output's nominal rate; with the new architecture this isn't
        // strictly required for correctness (varispeed handles any
        // mismatch), but matching nominal rates means varispeed's
        // continuous adjustment stays in the sub-ppm range and produces
        // lower SRC artifacts than a wholesale-resample.
        if let target = sampleRate {
            DeviceCatalog.setNominalSampleRate(outDev.id, target)
        }
        let outSR = Self.nominalSampleRate(of: outDev.id)
        let pinOK = DeviceCatalog.setNominalSampleRate(inDev.id, outSR)
        Log.write("pinned BlackHole to \(outSR) Hz to match \(outDev.name): \(pinOK ? "ok" : "refused")")

        // Stereo Float32 is the canonical format throughout the chain.
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: outSR, channels: 2) else {
            throw NSError(domain: "EQEngine", code: -12,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create stereo Float32 format"])
        }

        // Ring buffer sized for ~250 ms of audio. Big enough to absorb
        // typical OS jitter (up to ~50 ms scheduling delays under load),
        // small enough that the introduced latency stays under what a
        // user would notice while DJing or watching video.
        let ringFrames = UInt32(outSR * 0.25)
        guard let ring = AudioRingBuffer(capacityFrames: ringFrames) else {
            throw NSError(domain: "EQEngine", code: -13,
                          userInfo: [NSLocalizedDescriptionKey: "Ring buffer allocation failed"])
        }
        self.ringBuffer = ring

        // Input AUHAL: bound to BlackHole, writes captured Float32
        // stereo into the ring buffer at the chosen rate.
        let capture = InputCapture(ringBuffer: ring)
        guard let capture = capture else {
            throw NSError(domain: "EQEngine", code: -14,
                          userInfo: [NSLocalizedDescriptionKey: "InputCapture init failed"])
        }
        try capture.start(deviceID: inDev.id, sampleRate: outSR)
        self.inputCapture = capture
        self.inputDeviceID = inDev.id

        // Build the AVAudioEngine for the output side.
        let engine = AVAudioEngine()
        self.engine = engine

        // Pre-fill the ring buffer briefly before the engine starts so
        // the first few output renders have data to consume.
        usleep(50_000)

        // Bind the output node to the user's chosen output device. On
        // macOS, AVAudioEngine.inputNode and outputNode share one audio
        // unit; we don't use inputNode at all (our input comes via the
        // separate AUHAL above), so binding the unit to the output
        // device is correct — the engine drives its IO loop from this
        // device's hardware clock.
        try setDevice(outDev.id, on: engine.outputNode.audioUnit)
        self.outputDeviceID = outDev.id

        // Allocate the chain.
        // Capture the C ring-buffer pointer here so the render block
        // doesn't need to retain the Swift wrapper — the wrapper's
        // lifetime is bounded by the engine's lifetime, and the C
        // pointer stays stable until our `stop()` runs.
        let ringPtr = ring.rawPointer
        let sourceNode = AVAudioSourceNode(format: stereoFormat) {
            (isSilence, _, frameCount, audioBufferList) -> OSStatus in
            // Real-time-safe: no Swift class dispatch, no allocation,
            // no locks. TPCircularBufferTail/Consume are inline static
            // functions that compile down to a load + atomic op.
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            // standardFormatWithSampleRate(channels: 2) on macOS gives
            // non-interleaved Float32 — two single-channel buffers in
            // the AudioBufferList. The ring buffer stores INTERLEAVED
            // stereo; deinterleave during the copy.
            let buf0 = abl[0].mData!.assumingMemoryBound(to: Float32.self)
            let buf1 = abl[1].mData!.assumingMemoryBound(to: Float32.self)
            var availBytes: UInt32 = 0
            let tail = TPCircularBufferTail(ringPtr, &availBytes)
            let availFrames = availBytes / AudioRingBuffer.bytesPerFrame
            let toCopy = min(frameCount, availFrames)
            if let tail = tail, toCopy > 0 {
                let src = tail.assumingMemoryBound(to: Float32.self)
                var i: UInt32 = 0
                while i < toCopy {
                    buf0[Int(i)] = src[Int(i) * 2]
                    buf1[Int(i)] = src[Int(i) * 2 + 1]
                    i &+= 1
                }
                TPCircularBufferConsume(ringPtr, toCopy * AudioRingBuffer.bytesPerFrame)
            }
            // Zero any frames we couldn't fill (underrun → silence).
            if toCopy < frameCount {
                let remaining = Int(frameCount - toCopy)
                memset(buf0.advanced(by: Int(toCopy)), 0, remaining * MemoryLayout<Float32>.size)
                memset(buf1.advanced(by: Int(toCopy)), 0, remaining * MemoryLayout<Float32>.size)
                if toCopy == 0 { isSilence.pointee = true }
            }
            return noErr
        }
        self.sourceNode = sourceNode
        engine.attach(sourceNode)

        // No mixer: a single-source linear chain doesn't need one, and
        // AVAudioMixerNode silently inserts a small upsample/downsample
        // stage at certain sample rates even when in/out formats match.
        // Users reported the engine sounding subtly worse at 48 kHz than
        // 44.1 kHz; removing the mixer removed that difference.

        let varispeed = AVAudioUnitVarispeed()
        varispeed.rate = 1.0
        engine.attach(varispeed)
        self.varispeed = varispeed

        let eq = AVAudioUnitEQ(numberOfBands: Self.maxBands)
        for i in 0..<Self.maxBands { eq.bands[i].bypass = true }
        engine.attach(eq)
        self.eq = eq

        // Output channel map: send our stereo into the user's output
        // device's L/R channels (typically channels 0,1 — but multi-
        // channel devices like an HDMI receiver want us mapped to a
        // specific pair).
        let outChannels = Self.deviceChannelCount(outDev.id, scope: kAudioObjectPropertyScopeOutput)
        if outChannels > 0 {
            var channelMap = [Int32](repeating: -1, count: outChannels)
            // For a direct-bound device (no aggregate), L/R are at
            // channel offset 0. We still build the map so that any
            // extra channels (4/6/8-channel devices) are explicitly
            // silenced rather than left to whatever junk the engine
            // happens to put there.
            if outChannels >= 2 {
                channelMap[0] = 0
                channelMap[1] = 1
            }
            do {
                try Self.setChannelMap(channelMap, on: engine.outputNode.audioUnit,
                                       scope: kAudioUnitScope_Output, bus: 0)
            } catch {
                Log.write("channel map skipped: \(error.localizedDescription)")
            }
        }

        engine.connect(sourceNode, to: varispeed, format: stereoFormat)
        engine.connect(varispeed, to: eq, format: stereoFormat)
        engine.connect(eq, to: engine.outputNode, format: stereoFormat)

        eq.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.processLevelTap(buffer)
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                Log.write("AVAudioEngineConfigurationChange (running=\(self?.isRunning ?? false))")
                self?.onConfigurationChange?()
            }

        try engine.start()
        currentInputUID = inputUID
        currentOutputUID = outputUID
        startedAt = CACurrentMediaTime()

        // Continuous drift-correction loop. Every 200 ms we sample
        // each device's mRateScalar and set varispeed.rate to the
        // ratio. Per CAPlayThrough, this keeps the two clocks aligned
        // without ever letting drift accumulate into an audible
        // offset. The varispeed unit performs a high-quality real-time
        // SRC for the small adjustment (sub-ppm in steady state).
        startRateUpdates()

        Log.write("engine started in=\(inputUID) out=\(outputUID) sr=\(outSR) outCh=\(outChannels) ringFrames=\(ring.capacityFrames)")
    }

    private func startRateUpdates() {
        rateUpdateTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self = self,
                  let varispeed = self.varispeed,
                  let capture = self.inputCapture else { return }
            capture.refreshRateScalar()
            let inScalar = capture.lastRateScalar
            let outScalar = self.currentOutputRateScalar()
            // Sanity: if either reads as zero or absurd, skip this tick.
            guard inScalar > 0.5, inScalar < 1.5, outScalar > 0.5, outScalar < 1.5 else { return }
            let ratio = Float(inScalar / outScalar)
            // Varispeed accepts 0.25..4.0 in principle; we expect ratios
            // within ~1e-4 of unity. Clamp tightly to refuse anything
            // out-of-band as a safety.
            let clamped = max(0.999, min(1.001, ratio))
            varispeed.rate = clamped
        }
        timer.resume()
        rateUpdateTimer = timer
    }

    private func currentOutputRateScalar() -> Float64 {
        guard outputDeviceID != 0 else { return 1.0 }
        var ts = AudioTimeStamp()
        let status = AudioDeviceGetCurrentTime(outputDeviceID, &ts)
        if status == noErr, ts.mFlags.contains(.rateScalarValid), ts.mRateScalar > 0 {
            return ts.mRateScalar
        }
        return 1.0
    }

    private func processLevelTap(_ buffer: AVAudioPCMBuffer) {
        guard engine != nil, eq != nil else { return }
        lastTapAt = CACurrentMediaTime()
        guard let channels = buffer.floatChannelData else { return }
        let now = lastTapAt
        guard now - lastLevelDispatch >= levelDispatchInterval else { return }
        lastLevelDispatch = now

        let frames = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)

        var leftPeak: Float = 0
        if chCount >= 1 {
            let data = channels[0]
            for i in 0..<frames {
                let v = abs(data[i])
                if v > leftPeak { leftPeak = v }
            }
        }
        var rightPeak: Float = 0
        if chCount >= 2 {
            let data = channels[1]
            for i in 0..<frames {
                let v = abs(data[i])
                if v > rightPeak { rightPeak = v }
            }
        } else {
            rightPeak = leftPeak
        }
        let l = min(leftPeak, 1)
        let r = min(rightPeak, 1)
        lastInputPeak = max(l, r)
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(l, r)
        }
    }

    // MARK: - Helpers

    private static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double {
        var sr: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &sr)
        return (status == noErr && sr > 0) ? Double(sr) : 48000
    }

    private static func deviceChannelCount(_ deviceID: AudioDeviceID,
                                           scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 4)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, buf) == noErr else {
            return 0
        }
        let bufList = buf.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func setChannelMap(_ map: [Int32],
                                      on audioUnit: AudioUnit?,
                                      scope: AudioUnitScope,
                                      bus: AudioUnitElement) throws {
        guard let au = audioUnit else { return }
        var copy = map
        let byteSize = UInt32(map.count * MemoryLayout<Int32>.size)
        let status = copy.withUnsafeMutableBufferPointer { bp -> OSStatus in
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_ChannelMap,
                                 scope, bus, bp.baseAddress, byteSize)
        }
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to set channel map (status \(status))"])
        }
    }

    private func setDevice(_ deviceID: AudioDeviceID, on audioUnit: AudioUnit?) throws {
        guard let au = audioUnit else {
            throw NSError(domain: "EQEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "AudioUnit unavailable"])
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to set audio device (status \(status))"])
        }
    }
}

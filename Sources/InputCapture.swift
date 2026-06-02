import Foundation
import AVFoundation
import CoreAudio
import AudioUnit

/// Raw HALOutput audio unit used as INPUT-only, bound to a specific
/// CoreAudio device (BlackHole 2ch in our case). Captured frames are
/// pushed into a shared `AudioRingBuffer`; the output engine's
/// AVAudioSourceNode pulls from the same buffer.
///
/// Why a raw AUHAL instead of using AVAudioEngine.inputNode: on macOS,
/// AVAudioEngine.inputNode and outputNode share a single audio unit
/// whose CurrentDevice can only point to one device - so we cannot
/// have an AVAudioEngine that takes input from BlackHole and writes
/// output to a different USB DAC. Using a raw input AUHAL alongside a
/// separate AVAudioEngine for output is Apple's own pattern (see the
/// CAPlayThrough sample) and the only supported path that gets us off
/// the buggy aggregate-device approach.
///
/// The render proc runs on a real-time audio thread. It calls
/// `AudioUnitRender` into a pre-allocated AudioBufferList, then
/// `ringBuffer.produce` to copy into the shared circular buffer. Both
/// are real-time-safe: no Swift method dispatch (the produce call
/// inlines into a memcpy + atomic add), no allocation, no locks.
final class InputCapture {

    /// Latest input device sample-rate scalar (1.0 nominal). Updated by
    /// the engine watchdog; read by the output engine for varispeed
    /// drift compensation.
    private(set) var lastRateScalar: Float64 = 1.0

    /// Latest moment the input render proc was called. Engine watchdog
    /// uses this to detect "input has stalled."
    private(set) var lastRenderAt: CFTimeInterval = 0

    /// Latest peak level seen on the input side. Drives the input-side
    /// portion of metering and the auto-preamp clip detector.
    private(set) var lastPeakLeft: Float = 0
    private(set) var lastPeakRight: Float = 0

    private(set) var deviceID: AudioDeviceID = 0
    private var unit: AudioUnit?
    private var inputBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var inputBufferStorage: [UnsafeMutableRawPointer] = []
    private var inputBufferCapacityFrames: UInt32 = 0
    let ringBuffer: AudioRingBuffer
    private(set) var sampleRate: Float64 = 0

    init?(ringBuffer: AudioRingBuffer) {
        self.ringBuffer = ringBuffer
    }

    deinit {
        stop()
    }

    /// Open and start the AUHAL bound to `deviceID` running at
    /// `sampleRate` Hz, Float32 stereo interleaved. Returns nil on
    /// failure.
    func start(deviceID: AudioDeviceID, sampleRate: Float64) throws {
        try open(deviceID: deviceID, sampleRate: sampleRate)
        guard let unit = unit else {
            throw NSError(domain: "InputCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "AUHAL is nil after open"])
        }
        let status = AudioOutputUnitStart(unit)
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "AudioOutputUnitStart failed (\(status))"])
        }
    }

    func stop() {
        if let u = unit {
            // Null the input callback BEFORE AudioOutputUnitStop. Any
            // render in flight finishes against still-valid pointers,
            // but no new callback can be scheduled that would re-enter
            // capture state after we tear down inputBufferList. Without
            // this, AudioOutputUnitStop could return while a callback
            // is still mid-flight, and freeing inputBufferList below
            // pulls the rug out from under it (use-after-free).
            var nullCallback = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
            _ = AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback,
                                     kAudioUnitScope_Global, 0,
                                     &nullCallback,
                                     UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            AudioOutputUnitStop(u)
            // Drain window. AudioUnitUninitialize is documented to wait
            // for in-flight renders, but historically that hasn't been
            // reliable across macOS releases. 20 ms is 2-3 IO cycles at
            // typical buffer sizes - enough for the last callback to
            // exit cleanly.
            usleep(20_000)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        unit = nil
        if let abl = inputBufferList {
            free(abl)
        }
        inputBufferList = nil
        for ptr in inputBufferStorage {
            ptr.deallocate()
        }
        inputBufferStorage.removeAll()
        deviceID = 0
        sampleRate = 0
        lastRateScalar = 1.0
        lastRenderAt = 0
        lastPeakLeft = 0
        lastPeakRight = 0
    }

    /// Sampled by the watchdog to update varispeed in the output engine.
    /// Reads the input device's current rate scalar via
    /// `AudioDeviceGetCurrentTime`. If the device is idle this can fail
    /// (returns 1.0 in that case so we don't multiply varispeed by zero).
    func refreshRateScalar() {
        guard deviceID != 0 else { return }
        var ts = AudioTimeStamp()
        let status = AudioDeviceGetCurrentTime(deviceID, &ts)
        if status == noErr, ts.mFlags.contains(.rateScalarValid), ts.mRateScalar > 0 {
            lastRateScalar = ts.mRateScalar
        }
    }

    // MARK: - Private setup

    private func open(deviceID: AudioDeviceID, sampleRate: Float64) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "InputCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "HALOutput component not found"])
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
        guard let unit = au else {
            throw NSError(domain: "InputCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "AUHAL instance is nil"])
        }
        self.unit = unit

        // Enable input on bus 1, disable output on bus 0.
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1,
                                       &enable, UInt32(MemoryLayout<UInt32>.size)),
                  "EnableIO input")
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0,
                                       &disable, UInt32(MemoryLayout<UInt32>.size)),
                  "DisableIO output")

        // Bind the device.
        var devID = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0,
                                       &devID, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "Set CurrentDevice (input)")
        self.deviceID = deviceID

        // Set the format we want the AUHAL to deliver to us: Float32
        // interleaved stereo at the chosen sample rate. AUHAL converts
        // from the device's native format internally.
        let bytesPerSample = UInt32(MemoryLayout<Float32>.size)
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerSample * 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample * 2,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1,
                                       &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "Set input AUHAL stream format")
        self.sampleRate = sampleRate

        // Pre-allocate the AudioBufferList we'll hand to AudioUnitRender.
        // For interleaved stereo we use a single buffer with 2 channels.
        // Capacity must be at least the largest IO buffer the device may
        // request - query it; default to 4096 frames if unavailable.
        var bufferFrames: UInt32 = 4096
        var sizeBufferFrames = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize,
                             kAudioUnitScope_Global, 0,
                             &bufferFrames, &sizeBufferFrames)
        // Round up generously to absorb the occasional larger request.
        let capacityFrames = max(bufferFrames, 1024) * 4
        inputBufferCapacityFrames = capacityFrames
        let bytes = Int(capacityFrames) * Int(format.mBytesPerFrame)

        let ablSize = MemoryLayout<AudioBufferList>.size  // 1 buffer in this struct
        let ablRaw = malloc(ablSize)!
        let abl = ablRaw.assumingMemoryBound(to: AudioBufferList.self)
        abl.pointee.mNumberBuffers = 1
        let storage = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        inputBufferStorage = [storage]
        abl.pointee.mBuffers.mNumberChannels = 2
        abl.pointee.mBuffers.mDataByteSize = UInt32(bytes)
        abl.pointee.mBuffers.mData = storage
        inputBufferList = abl

        // Install the input render proc.
        var callback = AURenderCallbackStruct(
            inputProc: InputCapture.renderProc,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "Set input callback")

        try check(AudioUnitInitialize(unit), "AudioUnitInitialize")
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "InputCapture: \(what) failed (\(status))"])
        }
    }

    // MARK: - Render proc (real-time audio thread)

    private static let renderProc: AURenderCallback = {
        (refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ /* ioData is nil for input */) -> OSStatus in

        let capture = Unmanaged<InputCapture>.fromOpaque(refCon).takeUnretainedValue()
        guard let unit = capture.unit, let abl = capture.inputBufferList else {
            return noErr
        }
        // Pull samples from the device into our pre-allocated buffer.
        // (mDataByteSize must be reset before each call; AudioUnitRender
        // uses it as both an input cap and an output count.)
        let perFrame = UInt32(MemoryLayout<Float32>.size) * 2
        abl.pointee.mBuffers.mDataByteSize = inNumberFrames * perFrame
        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp,
                                     inBusNumber, inNumberFrames, abl)
        if status != noErr { return status }

        // Real-time-safe: a single memcpy + atomic add inside produce().
        let bytes = abl.pointee.mBuffers.mData!
        _ = capture.ringBuffer.produce(bytes, frameCount: inNumberFrames)

        // Track peak for the metering UI / auto-preamp.
        let samples = bytes.assumingMemoryBound(to: Float32.self)
        var l: Float = 0, r: Float = 0
        let total = Int(inNumberFrames) * 2
        var i = 0
        while i < total {
            let lv = abs(samples[i]); if lv > l { l = lv }
            let rv = abs(samples[i+1]); if rv > r { r = rv }
            i += 2
        }
        capture.lastPeakLeft = l
        capture.lastPeakRight = r
        capture.lastRenderAt = CACurrentMediaTime()
        return noErr
    }
}

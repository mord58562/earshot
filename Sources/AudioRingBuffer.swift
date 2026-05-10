import Foundation

/// Swift wrapper around TPCircularBuffer (lock-free SPSC ring buffer).
///
/// Stores interleaved Float32 stereo audio frames. One thread (the
/// input AUHAL render proc) calls `produce(...)` from the input audio
/// thread; another thread (the output engine's AVAudioSourceNode
/// render block) reads via the exposed `rawPointer` and TPCircular's
/// inline tail/consume functions. No locks, no allocations on either
/// thread; safe at real-time priority.
///
/// The TPCircularBuffer "virtual memory mirroring" trick guarantees
/// that the contiguous read/write pointers it returns can be used
/// with a single memcpy that walks past the buffer's end without
/// special-casing wraparound.
final class AudioRingBuffer {

    /// Bytes per stereo frame (2 channels × 4 bytes per Float32 sample).
    static let bytesPerFrame: UInt32 = 8

    /// Heap-allocated TPCircularBuffer struct. Stable for the lifetime
    /// of this object so the audio threads can pass the pointer to the
    /// inline TPCircularBuffer functions without worrying about Swift
    /// inout lifetime.
    let rawPointer: UnsafeMutablePointer<TPCircularBuffer>
    let capacityBytes: UInt32
    let capacityFrames: UInt32

    init?(capacityFrames: UInt32) {
        let requestedBytes = capacityFrames * Self.bytesPerFrame
        let ptr = UnsafeMutablePointer<TPCircularBuffer>.allocate(capacity: 1)
        ptr.initialize(to: TPCircularBuffer())
        let ok = TPCBSwiftInit(ptr, requestedBytes)
        guard ok else {
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            return nil
        }
        self.rawPointer = ptr
        self.capacityBytes = TPCBSwiftLengthBytes(ptr)
        self.capacityFrames = self.capacityBytes / Self.bytesPerFrame
    }

    deinit {
        TPCircularBufferCleanup(rawPointer)
        rawPointer.deinitialize(count: 1)
        rawPointer.deallocate()
    }

    var fillBytes: UInt32 { TPCBSwiftFillBytes(rawPointer) }
    var fillFrames: UInt32 { fillBytes / Self.bytesPerFrame }
    var freeFrames: UInt32 { (capacityBytes - fillBytes) / Self.bytesPerFrame }

    func clear() { TPCircularBufferClear(rawPointer) }

    /// Producer side: copy `frameCount` interleaved Float32 stereo
    /// frames from `src` into the buffer. Returns the number of frames
    /// actually written. Real-time-safe.
    @inlinable
    func produce(_ src: UnsafeRawPointer, frameCount: UInt32) -> UInt32 {
        let needed = frameCount * Self.bytesPerFrame
        var available: UInt32 = 0
        guard let head = TPCircularBufferHead(rawPointer, &available) else { return 0 }
        let toCopy = min(needed, available)
        if toCopy == 0 { return 0 }
        memcpy(head, src, Int(toCopy))
        TPCircularBufferProduce(rawPointer, toCopy)
        return toCopy / Self.bytesPerFrame
    }
}

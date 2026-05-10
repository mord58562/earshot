import Foundation
import CoreAudio

struct AudioDevice: Hashable, Identifiable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let hasOutput: Bool
    let hasInput: Bool
}

enum DeviceCatalog {

    static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr
        else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr
        else { return [] }

        return ids.compactMap { devID in
            guard let name = stringProperty(devID, selector: kAudioObjectPropertyName) else { return nil }
            let uid = stringProperty(devID, selector: kAudioDevicePropertyDeviceUID) ?? ""
            let hasOut = streamCount(devID, scope: kAudioObjectPropertyScopeOutput) > 0
            let hasIn  = streamCount(devID, scope: kAudioObjectPropertyScopeInput)  > 0
            return AudioDevice(id: devID, name: name, uid: uid, hasOutput: hasOut, hasInput: hasIn)
        }
    }

    static func outputs() -> [AudioDevice] {
        all().filter { $0.hasOutput }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func inputs() -> [AudioDevice] {
        all().filter { $0.hasInput }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func device(uid: String) -> AudioDevice? {
        all().first(where: { $0.uid == uid })
    }

    static func device(named name: String) -> AudioDevice? {
        all().first(where: { $0.name == name })
    }

    static func currentDefaultOutput() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    /// Best-effort: attempt to set a device's nominal sample rate. Returns
    /// true if the device accepted the rate (or already had it). Many real
    /// devices (Bluetooth, HDMI) refuse arbitrary rates — caller should not
    /// treat failure as fatal.
    @discardableResult
    static func setNominalSampleRate(_ deviceID: AudioDeviceID, _ rate: Double) -> Bool {
        var sr: Float64 = rate
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(
            deviceID, &addr, 0, nil,
            UInt32(MemoryLayout<Float64>.size), &sr)
        return status == noErr
    }

    @discardableResult
    static func setDefaultOutput(_ deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        return status == noErr
    }

    /// Conventional names used by virtual-audio loopback drivers. Matches
    /// surface a "looks like a loopback" hint in the input picker.
    static let loopbackDeviceNameHints = [
        "BlackHole", "Loopback", "Soundflower", "Existential Audio", "VB-Cable", "Aggregate"
    ]

    static func looksLikeLoopback(_ d: AudioDevice) -> Bool {
        loopbackDeviceNameHints.contains { d.name.localizedCaseInsensitiveContains($0) }
    }

    // MARK: private

    private static func stringProperty(_ devID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(devID, &address, 0, nil, &size) == noErr else { return nil }
        var cfStr: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { rawPtr in
                AudioObjectGetPropertyData(devID, &address, 0, nil, &size, rawPtr)
            }
        }
        guard status == noErr, let cf = cfStr?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func streamCount(_ devID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(devID, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

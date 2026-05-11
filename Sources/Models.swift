import Foundation
import AVFoundation

/// Filter types we expose. Maps 1:1 to the AVAudioUnitEQ filter set so the
/// editor offers the full native capability.
enum EQFilter: String, Codable, CaseIterable, Identifiable {
    case parametric
    case lowPass
    case highPass
    case resonantLowPass
    case resonantHighPass
    case bandPass
    case bandStop
    case lowShelf
    case highShelf
    case resonantLowShelf
    case resonantHighShelf

    var id: String { rawValue }

    var au: AVAudioUnitEQFilterType {
        switch self {
        case .parametric:         return .parametric
        case .lowPass:            return .lowPass
        case .highPass:           return .highPass
        case .resonantLowPass:    return .resonantLowPass
        case .resonantHighPass:   return .resonantHighPass
        case .bandPass:           return .bandPass
        case .bandStop:           return .bandStop
        case .lowShelf:           return .lowShelf
        case .highShelf:          return .highShelf
        case .resonantLowShelf:   return .resonantLowShelf
        case .resonantHighShelf:  return .resonantHighShelf
        }
    }

    /// Whether the filter takes a Q / bandwidth parameter. Pass-style filters
    /// (lowPass / highPass / bandPass / bandStop without "resonant") ignore
    /// gain too — but AVAudioUnitEQ won't reject the property, it just no-ops.
    var usesQ: Bool {
        switch self {
        case .parametric, .resonantLowPass, .resonantHighPass,
             .resonantLowShelf, .resonantHighShelf, .bandPass, .bandStop:
            return true
        case .lowShelf, .highShelf:
            return true
        case .lowPass, .highPass:
            return false
        }
    }

    var usesGain: Bool {
        switch self {
        case .parametric, .lowShelf, .highShelf,
             .resonantLowShelf, .resonantHighShelf:
            return true
        case .lowPass, .highPass, .resonantLowPass, .resonantHighPass,
             .bandPass, .bandStop:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .parametric:         return "Peak"
        case .lowPass:            return "Low-pass"
        case .highPass:           return "High-pass"
        case .resonantLowPass:    return "Low-pass (resonant)"
        case .resonantHighPass:   return "High-pass (resonant)"
        case .bandPass:           return "Band-pass"
        case .bandStop:           return "Notch"
        case .lowShelf:           return "Low shelf"
        case .highShelf:          return "High shelf"
        case .resonantLowShelf:   return "Low shelf (resonant)"
        case .resonantHighShelf:  return "High shelf (resonant)"
        }
    }
}

struct EQBand: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: EQFilter
    var frequency: Float
    var gain: Float
    var q: Float
    var bypass: Bool

    enum CodingKeys: String, CodingKey {
        case type, frequency, gain, q, bypass
    }

    init(id: UUID = UUID(), type: EQFilter, frequency: Float, gain: Float, q: Float, bypass: Bool = false) {
        self.id = id
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.bypass = bypass
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.type = try c.decode(EQFilter.self, forKey: .type)
        self.frequency = try c.decode(Float.self, forKey: .frequency)
        self.gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 0
        self.q = try c.decodeIfPresent(Float.self, forKey: .q) ?? 0.71
        self.bypass = try c.decodeIfPresent(Bool.self, forKey: .bypass) ?? false
    }

    static let defaultPeak = EQBand(type: .parametric, frequency: 1000, gain: 0, q: 1.0)
}

struct EQPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var preampDB: Float
    var bands: [EQBand]

    enum CodingKeys: String, CodingKey {
        case id, name, preampDB, bands
    }

    init(id: UUID, name: String, preampDB: Float, bands: [EQBand]) {
        self.id = id
        self.name = name
        self.preampDB = preampDB
        self.bands = bands
    }

    /// Decode older preset files that included a per-preset output device
    /// UID. We silently drop that field - the current output is a
    /// system-wide setting, not a preset attribute.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.preampDB = try c.decode(Float.self, forKey: .preampDB)
        self.bands = try c.decode([EQBand].self, forKey: .bands)
    }
}

struct PresetFile: Codable {
    var version: Int
    var presets: [EQPreset]
}

/// Persistent app settings: which devices were last in use, EQ on/off state,
/// what the working EQ was at quit, what preset (if any) was loaded.
struct AppSettings: Codable, Equatable {
    var inputDeviceUID: String?
    var outputDeviceUID: String?
    var eqEnabled: Bool
    var workingPreamp: Float
    var workingBands: [EQBand]
    /// The id of the preset most recently loaded. Cleared when the user edits
    /// or saves; purely a UI hint, not authoritative.
    var loadedPresetID: UUID?
    /// Auto-preamp on/off, persisted so the next launch restores whatever
    /// the user last had set (same treatment as the loaded preset and
    /// working bands).
    var autoPreampEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case inputDeviceUID, outputDeviceUID, eqEnabled, workingPreamp,
             workingBands, loadedPresetID, autoPreampEnabled
    }

    init(inputDeviceUID: String?, outputDeviceUID: String?, eqEnabled: Bool,
         workingPreamp: Float, workingBands: [EQBand],
         loadedPresetID: UUID?, autoPreampEnabled: Bool) {
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self.eqEnabled = eqEnabled
        self.workingPreamp = workingPreamp
        self.workingBands = workingBands
        self.loadedPresetID = loadedPresetID
        self.autoPreampEnabled = autoPreampEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        self.outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        self.eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? false
        self.workingPreamp = try c.decodeIfPresent(Float.self, forKey: .workingPreamp) ?? 0
        self.workingBands = try c.decodeIfPresent([EQBand].self, forKey: .workingBands) ?? []
        self.loadedPresetID = try c.decodeIfPresent(UUID.self, forKey: .loadedPresetID)
        self.autoPreampEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoPreampEnabled) ?? false
    }

    static let empty = AppSettings(
        inputDeviceUID: nil,
        outputDeviceUID: nil,
        eqEnabled: false,
        workingPreamp: 0,
        workingBands: [],
        loadedPresetID: nil,
        autoPreampEnabled: false)
}

/// Convert EQ Q to bandwidth in octaves (the unit AVAudioUnitEQ uses for
/// peak / resonant filters). Standard parametric filter formula.
func bandwidthOctaves(forQ q: Float) -> Float {
    guard q > 0 else { return 1.0 }
    let v = asinhf(0.5 / q) * (2.0 / Float(log(2.0)))
    return min(max(v, 0.05), 5.0)
}

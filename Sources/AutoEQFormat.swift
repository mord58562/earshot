import Foundation

/// Reads and writes the AutoEQ / oratory1990 ParametricEQ.txt format. This is
/// the de-facto industry standard for parametric headphone EQ presets and is
/// produced by the AutoEQ project (oratory1990, Crinacle, harman, etc.) plus
/// EqualizerAPO, Wavelet, Poweramp, and others.
///
/// Format:
///
///     Preamp: -6.5 dB
///     Filter 1: ON PK Fc 105 Hz Gain 5.5 dB Q 0.71
///     Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
///     Filter 3: ON HSC Fc 11000 Hz Gain -4.0 dB Q 0.71
///
/// Filter codes: PK (peak / parametric), LSC (low shelf), HSC (high shelf),
/// LS (low shelf alias), HS (high shelf alias), LP (low pass), HP (high pass),
/// BP (band pass), NO (notch / band stop), AP (all pass — not supported).
enum AutoEQFormat {

    enum ParseError: Error, LocalizedError {
        case empty
        case malformedLine(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "The file didn't contain any filters."
            case .malformedLine(let l): return "Couldn't parse line: \(l)"
            }
        }
    }

    // MARK: - Decode

    static func decode(text: String, defaultName: String = "Imported preset") -> Result<EQPreset, ParseError> {
        var preamp: Float = 0
        var bands: [EQBand] = []

        let lines = text.split(whereSeparator: { $0.isNewline })
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if let p = matchPreamp(line) {
                preamp = p
                continue
            }
            if let b = matchFilter(line) {
                bands.append(b)
                continue
            }
            if line.lowercased().hasPrefix("filter") {
                // It's labelled as a filter but didn't parse — report it.
                return .failure(.malformedLine(line))
            }
        }

        if bands.isEmpty { return .failure(.empty) }
        let preset = EQPreset(
            id: UUID(),
            name: defaultName,
            preampDB: preamp,
            outputDeviceUID: nil,
            bands: bands)
        return .success(preset)
    }

    private static func matchPreamp(_ line: String) -> Float? {
        guard line.lowercased().hasPrefix("preamp") else { return nil }
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = CharacterSet.whitespaces
                .union(CharacterSet(charactersIn: ":dB"))
        _ = scanner.scanCharacters(from: CharacterSet.letters)
        var v: Double = 0
        if scanner.scanDouble(&v) { return Float(v) }
        return nil
    }

    private static let filterRegex: NSRegularExpression? = {
        // "Filter <n>: ON <CODE> Fc <freq> Hz Gain <gain> dB Q <q>"
        // Some exporters omit Gain or Q for non-applicable filter types.
        let pattern = #"Filter\s+\d+\s*:\s*(ON|OFF)\s+([A-Z]+)\s+Fc\s+([\d.]+)\s*Hz(?:\s+Gain\s+(-?[\d.]+)\s*dB)?(?:\s+Q\s+([\d.]+))?"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func matchFilter(_ line: String) -> EQBand? {
        guard let re = filterRegex else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        guard m.numberOfRanges >= 4 else { return nil }
        let onOff = ns.substring(with: m.range(at: 1)).uppercased()
        let codeRaw = ns.substring(with: m.range(at: 2)).uppercased()
        let freqStr = ns.substring(with: m.range(at: 3))
        guard let freq = Float(freqStr) else { return nil }

        let gainStr: String? = m.range(at: 4).location == NSNotFound ? nil : ns.substring(with: m.range(at: 4))
        let qStr: String? = m.range(at: 5).location == NSNotFound ? nil : ns.substring(with: m.range(at: 5))

        let gain: Float = gainStr.flatMap { Float($0) } ?? 0
        let q: Float = qStr.flatMap { Float($0) } ?? 0.71

        guard let type = decodeCode(codeRaw) else { return nil }
        return EQBand(type: type, frequency: freq, gain: gain, q: q, bypass: onOff != "ON")
    }

    private static func decodeCode(_ code: String) -> EQFilter? {
        switch code {
        case "PK": return .parametric
        case "LSC", "LS": return .lowShelf
        case "HSC", "HS": return .highShelf
        case "LP": return .lowPass
        case "HP": return .highPass
        case "BP": return .bandPass
        case "NO": return .bandStop
        case "RLP": return .resonantLowPass
        case "RHP": return .resonantHighPass
        case "RLS": return .resonantLowShelf
        case "RHS": return .resonantHighShelf
        default: return nil
        }
    }

    // MARK: - Encode

    static func encode(_ preset: EQPreset) -> String {
        var out = ""
        out += String(format: "Preamp: %0.1f dB\n", Double(preset.preampDB))
        for (i, b) in preset.bands.enumerated() {
            let freqStr: String
            if b.frequency >= 100 {
                freqStr = String(format: "%.0f", Double(b.frequency))
            } else {
                freqStr = String(format: "%g", Double(b.frequency))
            }
            out += "Filter \(i + 1): \(b.bypass ? "OFF" : "ON") \(encodeCode(b.type)) Fc \(freqStr) Hz"
            if b.type.usesGain {
                out += String(format: " Gain %0.1f dB", Double(b.gain))
            }
            if b.type.usesQ {
                out += String(format: " Q %0.2f", Double(b.q))
            }
            out += "\n"
        }
        return out
    }

    private static func encodeCode(_ t: EQFilter) -> String {
        switch t {
        case .parametric: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        case .lowPass: return "LP"
        case .highPass: return "HP"
        case .bandPass: return "BP"
        case .bandStop: return "NO"
        case .resonantLowPass: return "RLP"
        case .resonantHighPass: return "RHP"
        case .resonantLowShelf: return "RLS"
        case .resonantHighShelf: return "RHS"
        }
    }
}

private extension Scanner {
    func scanDouble(_ value: inout Double) -> Bool {
        if let d = scanDouble() { value = d; return true }
        return false
    }
}

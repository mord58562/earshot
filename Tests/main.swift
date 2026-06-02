import Foundation

// Tiny standalone test runner — compiled and executed directly via swift, not
// XCTest, so there's no project file to maintain. Run with `./Tests/run.sh`.

var failures: [String] = []

func expect(_ ok: Bool, _ msg: String, _ file: String = #fileID, _ line: Int = #line) {
    if !ok { failures.append("\(file):\(line): \(msg)") }
}

func check<T: Equatable>(_ actual: T, _ expected: T, _ desc: String, _ file: String = #fileID, _ line: Int = #line) {
    if actual != expected {
        failures.append("\(file):\(line): \(desc): got \(actual), expected \(expected)")
    }
}

// MARK: - Bandwidth conversion

do {
    let bw1 = bandwidthOctaves(forQ: 1.0)
    expect(abs(bw1 - 1.39) < 0.05, "Q=1 ≈ 1.39 octaves (got \(bw1))")

    let bw07 = bandwidthOctaves(forQ: 0.71)
    expect(abs(bw07 - 1.99) < 0.1, "Q=0.71 ≈ 2 octaves (got \(bw07))")

    let clampedHi = bandwidthOctaves(forQ: 10000)
    expect(clampedHi >= 0.05, "very-high Q clamps to floor (got \(clampedHi))")

    let clampedLo = bandwidthOctaves(forQ: 0.01)
    expect(clampedLo <= 5.0, "very-low Q clamps to ceiling (got \(clampedLo))")
}

// MARK: - AutoEQ round-trip

do {
    let original = EQPreset(
        id: UUID(),
        name: "Round-trip",
        preampDB: -6.5,
        bands: [
            EQBand(type: .parametric, frequency: 105, gain: 5.5, q: 0.71),
            EQBand(type: .lowShelf, frequency: 105, gain: 5.5, q: 0.71),
            EQBand(type: .highShelf, frequency: 11000, gain: -4.0, q: 0.71),
        ])
    let text = AutoEQFormat.encode(original)
    expect(text.contains("Preamp: -6.5"), "encodes preamp")
    expect(text.contains("Filter 1: ON PK Fc 105"), "encodes peak filter")
    expect(text.contains("Filter 2: ON LSC"), "encodes low shelf as LSC")
    expect(text.contains("Filter 3: ON HSC"), "encodes high shelf as HSC")

    switch AutoEQFormat.decode(text: text) {
    case .success(let parsed):
        check(parsed.bands.count, 3, "round-trip band count")
        check(parsed.preampDB, -6.5, "round-trip preamp")
        check(parsed.bands[0].type, EQFilter.parametric, "round-trip type 0")
        check(parsed.bands[1].type, EQFilter.lowShelf, "round-trip type 1")
        check(parsed.bands[2].type, EQFilter.highShelf, "round-trip type 2")
        check(parsed.bands[0].frequency, 105, "round-trip freq 0")
    case .failure(let e):
        failures.append("decode failed: \(e.localizedDescription)")
    }
}

// MARK: - Real oratory1990 sample

do {
    let sample = """
    Preamp: -6.5 dB
    Filter 1: ON PK Fc 20 Hz Gain 4.0 dB Q 1.10
    Filter 2: ON PK Fc 97 Hz Gain -2.5 dB Q 0.70
    Filter 3: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
    Filter 4: ON HSC Fc 11000 Hz Gain -4.0 dB Q 0.71
    """
    switch AutoEQFormat.decode(text: sample, defaultName: "HD 600") {
    case .success(let p):
        check(p.bands.count, 4, "sample band count")
        check(p.preampDB, -6.5, "sample preamp")
        check(p.name, "HD 600", "sample default name")
    case .failure(let e):
        failures.append("oratory sample decode: \(e.localizedDescription)")
    }
}

// MARK: - Settings JSON round-trip

do {
    let original = AppSettings(
        inputDeviceUID: "UID-1",
        outputDeviceUID: "UID-2",
        eqEnabled: true,
        workingPreamp: 1.5,
        workingBands: [EQBand(type: .parametric, frequency: 1000, gain: 2, q: 1.0)],
        loadedPresetID: UUID(),
        autoPreampEnabled: false)
    let data = try JSONEncoder().encode(original)
    let parsed = try JSONDecoder().decode(AppSettings.self, from: data)
    check(parsed.inputDeviceUID, original.inputDeviceUID, "settings input uid")
    check(parsed.outputDeviceUID, original.outputDeviceUID, "settings output uid")
    check(parsed.eqEnabled, true, "settings eqEnabled")
    check(parsed.workingPreamp, 1.5, "settings preamp")
    check(parsed.workingBands.count, 1, "settings band count")
}

if failures.isEmpty {
    print("All tests passed.")
    exit(0)
} else {
    for f in failures { print("FAIL  \(f)") }
    print("\(failures.count) failure(s).")
    exit(1)
}

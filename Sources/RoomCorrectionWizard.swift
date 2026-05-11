import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Multi-step sheet that walks the user from "I have a REW measurement
/// of my speakers / headphones" to "here's a preset that corrects it
/// toward my chosen target". Drives `CurveMatcher` under the hood.
///
/// Steps:
///   1. Load measured frequency response (REW TXT export, or any CSV-ish
///      format with freq + dB columns).
///   2. Choose a target curve (Flat / B&K 1974 / Harman 2018 / Custom file).
///   3. Preview the fitted bands. Tweak max-band count + smoothing if
///      desired.
///   4. Name the preset and save. The new preset is loaded immediately.
struct RoomCorrectionWizard: View {
    @ObservedObject var state: AppState
    var onClose: () -> Void

    enum Step { case measurement, target, preview, save }

    @State private var step: Step = .measurement
    @State private var measuredFreqs: [Float] = []
    @State private var measuredDB: [Float] = []
    @State private var measurementName: String = ""
    @State private var targetChoice: TargetChoice = .bk1974
    @State private var customTargetFreqs: [Float] = []
    @State private var customTargetDB: [Float] = []
    @State private var maxBands: Double = 8
    @State private var fittedBands: [EQBand] = []
    @State private var presetName: String = ""
    @State private var errorMessage: String?

    enum TargetChoice: String, CaseIterable, Identifiable {
        case flat, bk1974, harman, custom
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .flat:    return "Flat"
            case .bk1974:  return "B&K 1974"
            case .harman:  return "Harman 2018 over-ear"
            case .custom:  return "Custom (load from file)"
            }
        }
        var curve: TargetCurve? {
            switch self {
            case .flat:   return .flat
            case .bk1974: return .bk1974
            case .harman: return .harman
            case .custom: return nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().opacity(0.2)
            content
            Divider().opacity(0.2)
            footer
        }
        .padding(20)
        .frame(width: 540)
        .alert("Couldn't load file",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Room correction")
                .font(.headline)
            Text(stepLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            ProgressView(value: stepProgress)
                .frame(width: 80)
        }
    }

    private var stepLabel: String {
        switch step {
        case .measurement: return "1 of 4 - load measurement"
        case .target:      return "2 of 4 - choose target curve"
        case .preview:     return "3 of 4 - preview correction"
        case .save:        return "4 of 4 - save as preset"
        }
    }
    private var stepProgress: Double {
        switch step {
        case .measurement: return 0.25
        case .target:      return 0.50
        case .preview:     return 0.75
        case .save:        return 1.0
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .measurement: measurementStep
        case .target:      targetStep
        case .preview:     previewStep
        case .save:        saveStep
        }
    }

    // MARK: - Step 1: measurement

    private var measurementStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Load a frequency-response measurement.")
                .font(.system(size: 12))
            Text("Use REW (Room EQ Wizard) to measure your speakers at the listening position, or use a published headphone measurement. Export from REW: File → Export → Export Measurement as Text.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose measurement file…") { pickMeasurement() }
                if !measurementName.isEmpty {
                    Text(measurementName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !measuredFreqs.isEmpty {
                CurvePreview(freqs: measuredFreqs, dB: measuredDB,
                             secondFreqs: nil, secondDB: nil,
                             color: .accentColor, label: "Measured")
                    .frame(height: 100)
            }
        }
    }

    private func pickMeasurement() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "txt")!]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a REW measurement or any freq/dB text file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try parseFRText(text)
            measuredFreqs = parsed.freqs
            measuredDB = parsed.dB
            measurementName = url.lastPathComponent
        } catch {
            errorMessage = "Couldn't parse \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Step 2: target curve

    private var targetStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a target. Earshot will fit bands so the measured response matches this curve as closely as possible.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Picker("Target", selection: $targetChoice) {
                ForEach(TargetChoice.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            if targetChoice == .custom {
                HStack {
                    Button("Choose target file…") { pickCustomTarget() }
                    if !customTargetFreqs.isEmpty {
                        Text("\(customTargetFreqs.count) points loaded")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            let curveFreqs = CurveMatcher.logFreqGrid()
            let curveDB = currentTargetDB(at: curveFreqs)
            if let curveDB = curveDB {
                CurvePreview(freqs: curveFreqs, dB: curveDB,
                             secondFreqs: nil, secondDB: nil,
                             color: .green, label: "Target")
                    .frame(height: 100)
            }
        }
    }

    private func pickCustomTarget() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "txt")!]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a target frequency-response file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try parseFRText(text)
            customTargetFreqs = parsed.freqs
            customTargetDB = parsed.dB
        } catch {
            errorMessage = "Couldn't parse target: \(error.localizedDescription)"
        }
    }

    private func currentTargetDB(at freqs: [Float]) -> [Float]? {
        if targetChoice == .custom {
            guard !customTargetFreqs.isEmpty else { return nil }
            return freqs.map { interp($0, xs: customTargetFreqs, ys: customTargetDB) }
        }
        guard let c = targetChoice.curve else { return nil }
        return freqs.map { c.dB($0) }
    }

    // MARK: - Step 3: preview

    private var previewStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bands")
                    .font(.system(size: 11))
                // .onChange(of:_:) (no `initial:`) is the macOS 13 form;
                // the two-arg modifier shipped in macOS 14 and would fail
                // to build on our deployment target.
                Slider(value: $maxBands, in: 1...10, step: 1)
                    .onChange(of: maxBands) { _ in recomputeFit() }
                Text("\(Int(maxBands))").monospacedDigit().font(.system(size: 11))
            }
            let grid = CurveMatcher.logFreqGrid()
            let measuredInterp = grid.map { interp($0, xs: measuredFreqs, ys: measuredDB) }
            let targetInterp = currentTargetDB(at: grid) ?? Array(repeating: 0, count: grid.count)
            let correction = zip(targetInterp, measuredInterp).map { $0 - $1 }
            let fitted = grid.map { f in fittedBands.reduce(Float(0)) { $0 + bandResp($1, at: f) } }
            CurvePreview(freqs: grid,
                         dB: correction,
                         secondFreqs: grid,
                         secondDB: fitted,
                         color: .accentColor,
                         label: "Needed correction vs fitted")
                .frame(height: 140)
            Text("Bands fitted: \(fittedBands.count). Solid line = correction needed (target - measured). Filled area = what the fitted bands deliver.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            recomputeFit()
            // Default preset name from the measurement filename.
            if presetName.isEmpty {
                let base = (measurementName as NSString).deletingPathExtension
                presetName = "\(base) corrected"
            }
        }
    }

    private func recomputeFit() {
        let grid = CurveMatcher.logFreqGrid()
        let measuredInterp = grid.map { interp($0, xs: measuredFreqs, ys: measuredDB) }
        let targetInterp = currentTargetDB(at: grid) ?? Array(repeating: 0, count: grid.count)
        let correction = zip(targetInterp, measuredInterp).map { $0 - $1 }
        fittedBands = CurveMatcher.fitBands(freqs: grid,
                                            target: correction,
                                            maxBands: Int(maxBands))
    }

    // MARK: - Step 4: save

    private var saveStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save this correction as a preset. It loads immediately.")
                .font(.system(size: 12))
            TextField("Preset name", text: $presetName)
                .textFieldStyle(.roundedBorder)
            Text("\(fittedBands.count) bands - preamp will be set to keep peaks under 0 dBFS.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer (back / next)

    private var footer: some View {
        HStack {
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Back") { back() }
                .disabled(step == .measurement)
            Button(step == .save ? "Save" : "Next") { advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .measurement: return !measuredFreqs.isEmpty
        case .target:
            if targetChoice == .custom { return !customTargetFreqs.isEmpty }
            return true
        case .preview:     return !fittedBands.isEmpty
        case .save:        return !presetName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func advance() {
        switch step {
        case .measurement: step = .target
        case .target:      step = .preview
        case .preview:     step = .save
        case .save:
            commit()
            onClose()
        }
    }

    private func back() {
        switch step {
        case .target:      step = .measurement
        case .preview:     step = .target
        case .save:        step = .preview
        case .measurement: break
        }
    }

    private func commit() {
        // Conservative preamp: -|max positive band gain|, so the EQ
        // doesn't push peaks past 0 dBFS even if all positive bands sum
        // constructively at one frequency. Underestimates headroom needed
        // sometimes but never overshoots.
        let positiveSum = fittedBands.map { max(0, $0.gain) }.reduce(0, +)
        let preamp = -positiveSum
        let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Room correction" : trimmed
        state.commitFittedPreset(name: finalName,
                                 bands: fittedBands,
                                 preampDB: preamp)
    }

    // MARK: - Helpers

    private func bandResp(_ b: EQBand, at f: Float) -> Float {
        let fc = b.frequency
        let bw = bandwidthOctaves(forQ: max(0.1, b.q))
        let lf = log2f(f / fc)
        let env = expf(-powf(lf / max(0.1, bw / 2), 2))
        return b.gain * env
    }
}

// MARK: - Frequency-response file parsing

/// Parses a freq + dB text file (REW exports, two-column CSV, or
/// whitespace-separated columns). Tolerates header lines and comment
/// lines starting with `*` or `#`.
private func parseFRText(_ text: String) throws -> (freqs: [Float], dB: [Float]) {
    var freqs: [Float] = []
    var dBs: [Float] = []
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("*") || line.hasPrefix("#") { continue }
        // Split on whitespace or comma. Use a regex-free splitter so we
        // accept either delimiter.
        let cols = line.split(whereSeparator: { $0 == "," || $0 == "\t" || $0 == " " })
        guard cols.count >= 2 else { continue }
        guard let f = Float(cols[0]), let v = Float(cols[1]) else { continue }
        if f <= 0 { continue }
        freqs.append(f)
        dBs.append(v)
    }
    guard freqs.count >= 8 else {
        throw NSError(domain: "RoomCorrectionWizard", code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                                    "Couldn't parse enough freq/dB data points (need at least 8)."])
    }
    // Sort by frequency just in case.
    let pairs = zip(freqs, dBs).sorted { $0.0 < $1.0 }
    return (pairs.map { $0.0 }, pairs.map { $0.1 })
}

/// Linear interpolation in log-frequency space. The input arrays are
/// assumed sorted ascending by `xs`.
private func interp(_ x: Float, xs: [Float], ys: [Float]) -> Float {
    if xs.isEmpty { return 0 }
    if x <= xs.first! { return ys.first! }
    if x >= xs.last!  { return ys.last! }
    // Binary search for the first xs[i] > x
    var lo = 0
    var hi = xs.count - 1
    while lo + 1 < hi {
        let m = (lo + hi) / 2
        if xs[m] > x { hi = m } else { lo = m }
    }
    let x0 = xs[lo], x1 = xs[hi]
    let y0 = ys[lo], y1 = ys[hi]
    let lx = log10f(x), lx0 = log10f(x0), lx1 = log10f(x1)
    let t = (lx - lx0) / (lx1 - lx0)
    return y0 + (y1 - y0) * t
}

// MARK: - Curve preview

/// Lightweight Canvas-based curve plot for one or two FR series. Just
/// enough to visually verify the measurement, target, and fit at each
/// wizard step.
private struct CurvePreview: View {
    let freqs: [Float]
    let dB: [Float]
    let secondFreqs: [Float]?
    let secondDB: [Float]?
    let color: Color
    let label: String

    var body: some View {
        Canvas { ctx, size in
            let dbMax: Float = 12, dbMin: Float = -12
            let fMin: Float = 20, fMax: Float = 20000

            // Grid: 0 dB centre line + the popover's 6 dB ticks.
            for db in [-12, -6, 0, 6, 12] {
                let y = yFor(db: Float(db), height: size.height,
                             dbMin: dbMin, dbMax: dbMax)
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(.secondary.opacity(db == 0 ? 0.4 : 0.12)),
                           lineWidth: 0.5)
            }

            // Primary series (filled).
            if let path = curvePath(freqs: freqs, dB: dB,
                                    size: size, fMin: fMin, fMax: fMax,
                                    dbMin: dbMin, dbMax: dbMax,
                                    closeToBaseline: true) {
                ctx.fill(path, with: .color(color.opacity(0.18)))
            }

            // Secondary series (line on top).
            if let sf = secondFreqs, let sd = secondDB,
               let path = curvePath(freqs: sf, dB: sd,
                                    size: size, fMin: fMin, fMax: fMax,
                                    dbMin: dbMin, dbMax: dbMax,
                                    closeToBaseline: false) {
                ctx.stroke(path, with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                              lineJoin: .round))
            } else if let path = curvePath(freqs: freqs, dB: dB,
                                           size: size, fMin: fMin, fMax: fMax,
                                           dbMin: dbMin, dbMax: dbMax,
                                           closeToBaseline: false) {
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round,
                                              lineJoin: .round))
            }
        }
        .overlay(alignment: .topLeading) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    private func yFor(db: Float, height: CGFloat,
                      dbMin: Float, dbMax: Float) -> CGFloat {
        let clamped = max(dbMin, min(dbMax, db))
        let n = (dbMax - clamped) / (dbMax - dbMin)
        return CGFloat(n) * height
    }

    private func xFor(f: Float, width: CGFloat, fMin: Float, fMax: Float) -> CGFloat {
        let logMin = log10f(fMin), logMax = log10f(fMax)
        let n = (log10f(max(fMin, min(fMax, f))) - logMin) / (logMax - logMin)
        return CGFloat(n) * width
    }

    private func curvePath(freqs: [Float], dB: [Float],
                           size: CGSize, fMin: Float, fMax: Float,
                           dbMin: Float, dbMax: Float,
                           closeToBaseline: Bool) -> Path? {
        guard freqs.count == dB.count, !freqs.isEmpty else { return nil }
        var p = Path()
        let baselineY = yFor(db: 0, height: size.height, dbMin: dbMin, dbMax: dbMax)
        for (i, f) in freqs.enumerated() {
            let x = xFor(f: f, width: size.width, fMin: fMin, fMax: fMax)
            let y = yFor(db: dB[i], height: size.height, dbMin: dbMin, dbMax: dbMax)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else      { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        if closeToBaseline {
            let lastX = xFor(f: freqs.last!, width: size.width, fMin: fMin, fMax: fMax)
            let firstX = xFor(f: freqs.first!, width: size.width, fMin: fMin, fMax: fMax)
            p.addLine(to: CGPoint(x: lastX, y: baselineY))
            p.addLine(to: CGPoint(x: firstX, y: baselineY))
            p.closeSubpath()
        }
        return p
    }
}

import SwiftUI
import AVFoundation

// MARK: - Root popover

struct PopoverRoot: View {
    @ObservedObject var state: AppState
    @State private var isExpanded = false
    @State private var savePresetName = ""
    @State private var showingSaveSheet = false
    @State private var renameTarget: EQPreset?
    @State private var showingHeadphoneSearch = false
    @State private var importErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(state: state)

            VStack(spacing: 14) {
                HowItWorksHint()
                RoutingRow(state: state)

                Divider().opacity(0.18)

                if isExpanded {
                    EQEditor(state: state)
                } else {
                    HeroCurveView(state: state)
                }

                PreampRow(state: state)

                ToolbarRow(state: state,
                           isExpanded: $isExpanded,
                           showingSaveSheet: $showingSaveSheet,
                           savePresetName: $savePresetName,
                           showingHeadphoneSearch: $showingHeadphoneSearch,
                           importErrorMessage: $importErrorMessage)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Divider().opacity(0.18)

            PresetList(state: state, renameTarget: $renameTarget)

            FooterBar(state: state)
        }
        .frame(width: 480)
        .background(.thickMaterial)
        .sheet(isPresented: $showingSaveSheet) {
            SavePresetSheet(name: $savePresetName) { final in
                state.saveCurrentAsNewPreset(name: final)
                showingSaveSheet = false
            } onCancel: {
                showingSaveSheet = false
            }
        }
        .sheet(item: $renameTarget) { preset in
            RenamePresetSheet(initialName: preset.name) { newName in
                state.renamePreset(preset.id, to: newName)
                renameTarget = nil
            } onCancel: {
                renameTarget = nil
            }
        }
        .sheet(isPresented: $showingHeadphoneSearch) {
            HeadphoneSearchSheet(state: state) {
                showingHeadphoneSearch = false
            }
        }
        .alert("Couldn't import", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } })) {
            Button("OK") { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            EQGlyph()
                .stroke(.primary.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text("Earshot").font(.system(size: 14, weight: .semibold))
                if state.passthroughMode {
                    Text("Speakers passthrough")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(state.eqEnabled ? "EQ on" : "Off")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if state.isApplyingRouting {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }

            // Bypass toggle: in passthrough → return to EQ mode; otherwise
            // route audio to built-in speakers with no EQ.
            Button {
                if state.passthroughMode {
                    state.exitPassthrough()
                } else {
                    state.enableSpeakersPassthrough()
                }
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state.passthroughMode ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.passthroughMode
                  ? "Bypass on - click to return to EQ"
                  : "Bypass: route audio to built-in speakers with no EQ")

            // Toggle is "Earshot active" - shows ON for either EQ or
            // passthrough mode, since both have the engine running. Off
            // fully disables Earshot.
            Toggle("", isOn: Binding(
                get: { state.eqEnabled || state.passthroughMode },
                set: { state.setEQEnabled($0) }))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(state.eqEnabled || state.passthroughMode ? "On (turn off to fully disable Earshot)" : "Off (Earshot is not intercepting audio)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

// MARK: - How it works

private struct HowItWorksHint: View {
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: 10,
             verticalSpacing: 4) {
            GridRow {
                HintLabel("EQ on")
                Text("Captures all system audio, applies the EQ, plays through the output below.")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                HintLabel("EQ off")
                Text("Audio plays via your macOS sound settings as normal.")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                HintLabel("Bypass")
                Text("The speaker button next to the on/off switch routes audio to built-in speakers with no EQ.")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }
}

private struct HintLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.primary.opacity(0.75))
            .frame(width: 42, alignment: .leading)
    }
}

// MARK: - Routing row

/// Audio capture is internal (Earshot owns the loopback path); the only
/// configurable side of the route is the output device, which gets a
/// labelled, left-aligned picker.
private struct RoutingRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            OutputPicker(
                binding: Binding(
                    get: { state.outputDeviceUID ?? "" },
                    set: { state.setOutputDevice(uid: $0) }),
                devices: state.availableOutputs,
                allowMissing: !state.availableOutputs.contains { $0.uid == state.outputDeviceUID })
            Spacer(minLength: 0)
        }
    }
}

private struct OutputPicker: View {
    @Binding var binding: String
    let devices: [AudioDevice]
    let allowMissing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Output")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)

            HStack(spacing: 6) {
                Image(systemName: "headphones")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $binding) {
                    ForEach(devices) { d in
                        Text(d.name).tag(d.uid)
                    }
                    if allowMissing {
                        Text("(none)").tag("")
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quinary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.55), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - Hero curve (compact)

private struct HeroCurveView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EQCurveView(bands: state.workingBands, preamp: state.workingPreamp)
                .frame(height: 132)
            FrequencyAxis()
        }
    }
}

// MARK: - Expanded EQ editor

private struct EQEditor: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EQCurveView(bands: state.workingBands, preamp: state.workingPreamp)
                .frame(height: 132)
            FrequencyAxis()
            BandList(state: state)
            HStack(spacing: 8) {
                Button {
                    state.addBand()
                } label: {
                    Label("Add band", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(state.workingBands.count >= EQEngine.maxBands)
                Button("Reset") { state.resetWorkingEQ() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                Spacer()
                if state.soloedBandID != nil {
                    Button {
                        state.soloedBandID = nil
                    } label: {
                        Label("Clear solo", systemImage: "speaker.wave.2.fill")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct BandList: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 4) {
            ForEach(state.workingBands) { band in
                BandRow(band: band, state: state)
            }
            if state.workingBands.isEmpty {
                Text("No bands. Click Add band to start.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
    }
}

private struct BandRow: View {
    let band: EQBand
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            Button {
                state.toggleSolo(band.id)
            } label: {
                Image(systemName: state.soloedBandID == band.id ? "s.square.fill" : "s.square")
                    .foregroundStyle(state.soloedBandID == band.id ? Color.accentColor : Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Solo this band")

            Toggle("", isOn: Binding(
                get: { !band.bypass },
                set: { v in state.updateBand(id: band.id) { $0.bypass = !v } }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Picker("", selection: Binding(
                get: { band.type },
                set: { v in state.updateBand(id: band.id) { $0.type = v } })) {
                ForEach(EQFilter.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            .controlSize(.small)

            stepperBox(label: "Hz", value: band.frequency,
                       format: { freqString($0) },
                       step: { dir, fast in
                           let mul: Float = fast ? 1.20 : 1.05
                           return dir > 0 ? band.frequency * mul : band.frequency / mul
                       },
                       commit: { v in state.updateBand(id: band.id) {
                           $0.frequency = max(20, min(22000, v))
                       }},
                       width: 70)

            stepperBox(label: "dB", value: band.gain,
                       format: { String(format: "%+0.1f", Double($0)) },
                       step: { dir, _ in
                           band.gain + Float(dir) * 0.5
                       },
                       commit: { v in state.updateBand(id: band.id) {
                           $0.gain = max(-24, min(24, v))
                       }},
                       width: 60,
                       enabled: band.type.usesGain)

            stepperBox(label: "Q", value: band.q,
                       format: { String(format: "%0.2f", Double($0)) },
                       step: { dir, _ in band.q + Float(dir) * 0.1 },
                       commit: { v in state.updateBand(id: band.id) {
                           $0.q = max(0.1, min(50, v))
                       }},
                       width: 60,
                       enabled: band.type.usesQ)

            Spacer(minLength: 0)

            Button {
                state.removeBand(id: band.id)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove band")
        }
        .padding(.vertical, 1)
        .opacity(band.bypass ? 0.45 : 1.0)
    }

    private func freqString(_ f: Float) -> String {
        if f >= 1000 { return String(format: "%0.2fk", Double(f) / 1000) }
        return String(format: "%.0f", Double(f))
    }

    @ViewBuilder
    private func stepperBox(label: String,
                            value: Float,
                            format: (Float) -> String,
                            step: @escaping (Int, Bool) -> Float,
                            commit: @escaping (Float) -> Void,
                            width: CGFloat,
                            enabled: Bool = true) -> some View {
        HStack(spacing: 2) {
            Text(format(value))
                .monospacedDigit()
                .font(.system(size: 11))
                .frame(width: width - 26, alignment: .trailing)
            VStack(spacing: 0) {
                Button {
                    commit(step(1, NSEvent.modifierFlags.contains(.shift)))
                } label: { Image(systemName: "chevron.up").imageScale(.small) }
                Button {
                    commit(step(-1, NSEvent.modifierFlags.contains(.shift)))
                } label: { Image(systemName: "chevron.down").imageScale(.small) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 14)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(.quinary))
        .opacity(enabled ? 1.0 : 0.4)
    }
}

// MARK: - Preamp + meters row

private struct PreampRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Text("Preamp")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
            Slider(value: Binding(
                get: { Double(state.workingPreamp) },
                set: { state.setPreamp(Float($0)) }),
                   in: -24...12)
                .disabled(state.autoPreampEnabled)
                .opacity(state.autoPreampEnabled ? 0.55 : 1.0)
            HStack(spacing: 2) {
                Text(String(format: "%+0.1f dB", Double(state.workingPreamp)))
                    .monospacedDigit()
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                VStack(spacing: 0) {
                    Button {
                        state.setPreamp(min(12, state.workingPreamp + 0.1))
                    } label: { Image(systemName: "chevron.up").imageScale(.small) }
                    Button {
                        state.setPreamp(max(-24, state.workingPreamp - 0.1))
                    } label: { Image(systemName: "chevron.down").imageScale(.small) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .disabled(state.autoPreampEnabled)
                .opacity(state.autoPreampEnabled ? 0.5 : 1.0)
            }
            Toggle(isOn: Binding(
                get: { state.autoPreampEnabled },
                set: { state.setAutoPreampEnabled($0) })) {
                Text("Auto").font(.system(size: 10, weight: .medium))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Auto-trim preamp to stay just below clipping. Only attenuates - never raises gain above 0 dB.")
            StereoMeter(left: state.displayLeft, right: state.displayRight,
                        peakLeft: state.peakHoldLeft, peakRight: state.peakHoldRight)
                .frame(width: 90, height: 14)
        }
    }
}

// MARK: - Toolbar (single row of icon buttons)

private struct ToolbarRow: View {
    @ObservedObject var state: AppState
    @Binding var isExpanded: Bool
    @Binding var showingSaveSheet: Bool
    @Binding var savePresetName: String
    @Binding var showingHeadphoneSearch: Bool
    @Binding var importErrorMessage: String?

    var body: some View {
        HStack(spacing: 4) {
            ToolbarButton(systemImage: "magnifyingglass", help: "Find your headphone") {
                showingHeadphoneSearch = true
            }
            ToolbarButton(systemImage: "square.and.arrow.down", help: "Import a ParametricEQ.txt") {
                importAutoEQ()
            }
            if let id = state.loadedPresetID,
               let p = state.presets.first(where: { $0.id == id }) {
                ToolbarButton(systemImage: "square.and.arrow.up", help: "Export “\(p.name)” as ParametricEQ.txt") {
                    exportPresetToFile(p)
                }
            }
            Spacer()
            if let id = state.loadedPresetID,
               let p = state.presets.first(where: { $0.id == id }) {
                Button("Update “\(p.name)”") { state.updatePreset(id) }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
            Button {
                savePresetName = ""
                showingSaveSheet = true
            } label: {
                Label("Save", systemImage: "plus")
            }
            .controlSize(.small)

            ToolbarButton(systemImage: isExpanded ? "chevron.up" : "slider.horizontal.3",
                          help: isExpanded ? "Hide bands" : "Edit bands") {
                withAnimation(.smooth(duration: 0.18)) { isExpanded.toggle() }
            }
        }
    }

    private func importAutoEQ() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Select a ParametricEQ.txt file (AutoEQ / oratory1990 format)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importErrorMessage = "Couldn't read the file."
            return
        }
        let defaultName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ParametricEQ", with: "")
        let r = state.importAutoEQ(text: text, defaultName: defaultName)
        if case .failure(let e) = r {
            importErrorMessage = e.errorDescription
        }
    }

    private func exportPresetToFile(_ preset: EQPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(preset.name) ParametricEQ.txt"
        panel.message = "Save as AutoEQ ParametricEQ format."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = state.exportAutoEQ(preset: preset)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            importErrorMessage = "Couldn't write the file: \(error.localizedDescription)"
        }
    }
}

private struct ToolbarButton: View {
    let systemImage: String
    let help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

// MARK: - Preset list

private struct PresetList: View {
    @ObservedObject var state: AppState
    @Binding var renameTarget: EQPreset?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(state.presets) { p in
                    PresetRow(preset: p, state: state, renameTarget: $renameTarget)
                    if p.id != state.presets.last?.id {
                        Divider().opacity(0.12)
                    }
                }
                if state.presets.isEmpty {
                    Text("No saved presets yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 14)
                }
            }
        }
        .frame(maxHeight: 180)
    }
}

private struct PresetRow: View {
    let preset: EQPreset
    @ObservedObject var state: AppState
    @Binding var renameTarget: EQPreset?

    var body: some View {
        let isLoaded = state.loadedPresetID == preset.id
        HStack(spacing: 10) {
            Rectangle()
                .fill(isLoaded ? Color.accentColor : Color.clear)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.system(size: 12, weight: isLoaded ? .semibold : .regular))
                if let outUID = preset.outputDeviceUID,
                   let dev = state.availableOutputs.first(where: { $0.uid == outUID }) {
                    Text(dev.name).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("Load") { state.loadPreset(preset.id) }
                Button("Update with current EQ") { state.updatePreset(preset.id) }
                Button("Rename…") { renameTarget = preset }
                Divider()
                Button("Delete", role: .destructive) { state.deletePreset(preset.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.vertical, 7)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .background(isLoaded ? Color.accentColor.opacity(0.06) : Color.clear)
        .onTapGesture { state.loadPreset(preset.id) }
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            if let err = state.lastError {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    state.lastError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Menu {
                Button("Quit Earshot") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }
}

// MARK: - EQ curve drawing

private struct EQCurveView: View {
    let bands: [EQBand]
    let preamp: Float

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.08), Color.accentColor.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))

                ForEach(gridLines, id: \.self) { db in
                    let y = yFor(db: Float(db), height: geo.size.height)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.secondary.opacity(db == 0 ? 0.32 : 0.08),
                            style: StrokeStyle(lineWidth: 0.5, dash: db == 0 ? [] : [2, 4]))
                }

                let curvePoints = curvePoints(width: geo.size.width, height: geo.size.height)
                Path { p in
                    guard let first = curvePoints.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    for pt in curvePoints { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom))

                Path { p in
                    guard let first = curvePoints.first else { return }
                    p.move(to: first)
                    for pt in curvePoints.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(LinearGradient(
                    colors: [Color.accentColor.opacity(0.95), Color.accentColor],
                    startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private let gridLines: [Int] = [-12, -6, 0, 6, 12]
    private let fMin: Float = 20
    private let fMax: Float = 20000
    private let dbRange: Float = 18

    private func curvePoints(width: CGFloat, height: CGFloat) -> [CGPoint] {
        let count = 256
        var pts: [CGPoint] = []
        pts.reserveCapacity(count + 1)
        for i in 0...count {
            let t = Float(i) / Float(count)
            let f = freqAt(t: t)
            let db = totalGainDB(at: f) + preamp
            pts.append(CGPoint(x: CGFloat(t) * width, y: yFor(db: db, height: height)))
        }
        return pts
    }

    private func freqAt(t: Float) -> Float {
        let logMin = log10f(fMin)
        let logMax = log10f(fMax)
        return powf(10, logMin + t * (logMax - logMin))
    }

    private func yFor(db: Float, height: CGFloat) -> CGFloat {
        let clamped = max(-dbRange, min(dbRange, db))
        let n = (dbRange - clamped) / (2 * dbRange)
        return CGFloat(n) * height
    }

    private func totalGainDB(at f: Float) -> Float {
        var total: Float = 0
        for b in bands where !b.bypass {
            total += bandResponseDB(b, at: f)
        }
        return total
    }

    private func bandResponseDB(_ b: EQBand, at f: Float) -> Float {
        let fc = b.frequency
        switch b.type {
        case .parametric, .resonantLowShelf, .resonantHighShelf, .bandPass, .bandStop:
            let bw = bandwidthOctaves(forQ: max(0.1, b.q))
            let lf = log2f(f / fc)
            let g = b.type.usesGain ? b.gain : 0
            let env = expf(-powf(lf / max(0.1, bw / 2), 2))
            return g * env
        case .lowShelf:
            let lf = log2f(f / fc)
            let s = 1.0 / (1.0 + expf(lf * 4))
            return b.gain * s
        case .highShelf:
            let lf = log2f(f / fc)
            let s = 1.0 / (1.0 + expf(-lf * 4))
            return b.gain * s
        case .lowPass, .resonantLowPass:
            let lf = log2f(f / fc)
            return lf > 0 ? -lf * 6 : 0
        case .highPass, .resonantHighPass:
            let lf = log2f(f / fc)
            return lf < 0 ? lf * 6 : 0
        }
    }
}

private struct FrequencyAxis: View {
    private let ticks: [(label: String, t: Float)] = {
        let fMin: Float = 20, fMax: Float = 20000
        let logMin = log10f(fMin), logMax = log10f(fMax)
        let freqs: [Float] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        return freqs.map { f in
            let t = (log10f(f) - logMin) / (logMax - logMin)
            let label: String
            if f >= 1000 {
                label = "\(Int(f / 1000))k"
            } else {
                label = "\(Int(f))"
            }
            return (label, t)
        }
    }()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.label) { tick in
                    Text(tick.label)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .position(x: CGFloat(tick.t) * geo.size.width, y: 6)
                }
            }
        }
        .frame(height: 12)
    }
}

// MARK: - Stereo meter (calibrated dBFS)

private struct StereoMeter: View {
    let left: Float
    let right: Float
    let peakLeft: Float
    let peakRight: Float

    private let floorDB: Float = -60

    var body: some View {
        VStack(spacing: 2) {
            meterBar(level: left, peak: peakLeft)
            meterBar(level: right, peak: peakRight)
        }
    }

    private func meterBar(level: Float, peak: Float) -> some View {
        GeometryReader { geo in
            let total = geo.size.width
            let levelW = barWidth(level, in: total)
            let tickX = barWidth(linearForDB(-6), in: total)

            ZStack(alignment: .leading) {
                // Track. Quaternary picks up the popover's frosted-glass
                // surface; the meter reads as part of the chrome rather
                // than a colored island.
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)

                // Active fill. The gradient is laid out across the FULL
                // bar width (anchored to dBFS positions) and masked to the
                // current level, so colors stay tied to absolute level
                // rather than the visible fill's own width. Three zones:
                //
                //     -60 ────── -18 ──── -6 ── 0  dBFS
                //     │  accent   │ orange │ red │
                //     0.0       0.70    0.90  1.00 (bar fraction)
                //
                // Double-stop at 0.70 holds accent flat across the safe
                // zone, then the gradient warms smoothly through orange
                // and into red only inside the top decade. System colors
                // (accentColor / orange / red) so the meter follows the
                // user's tint and adapts to light/dark mode like the
                // rest of the popover chrome.
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        stops: [
                            .init(color: Color.accentColor, location: 0.00),
                            .init(color: Color.accentColor, location: 0.70),
                            .init(color: .orange,           location: 0.90),
                            .init(color: .red,              location: 1.00),
                        ],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: total)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: levelW)
                    }

                // -6 dBFS reference tick. Subtle hairline; sits on top of
                // the fill so it remains visible whether the bar is below
                // or past the threshold.
                Rectangle()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 0.5)
                    .offset(x: tickX)

                // Peak hold: a 1.5pt vertical line at the highest recent
                // peak. Decays slowly via peakHoldDecay in AppState so
                // transients leave a visible trace.
                if peak > 1e-4 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 1.5)
                        .offset(x: max(0, barWidth(peak, in: total) - 1.5))
                }
            }
        }
    }

    private func barWidth(_ peak: Float, in total: CGFloat) -> CGFloat {
        let dB: Float = peak > 1e-5 ? max(floorDB, 20 * log10f(peak)) : floorDB
        let n = (dB - floorDB) / -floorDB
        return CGFloat(max(0, min(1, n))) * total
    }

    private func linearForDB(_ dB: Float) -> Float {
        powf(10, dB / 20)
    }
}

// MARK: - Sheets

private struct SavePresetSheet: View {
    @Binding var name: String
    var onSave: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save preset").font(.headline)
            Text("The current EQ and output device will be saved together.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSave(name) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct RenamePresetSheet: View {
    @State var name: String
    var onRename: (String) -> Void
    var onCancel: () -> Void

    init(initialName: String, onRename: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _name = State(initialValue: initialName)
        self.onRename = onRename
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename preset").font(.headline)
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onRename(name) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Rename") { onRename(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct HeadphoneSearchSheet: View {
    @ObservedObject var state: AppState
    var onClose: () -> Void
    @State private var query: String = ""
    @State private var didAutoRefresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Find a preset").font(.headline)
                Spacer()
                Button {
                    Task { await state.refreshHeadphoneIndex() }
                } label: {
                    Label("Refresh catalog", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(state.headphoneFetchInProgress)
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            Text("Searches your saved presets and the AutoEq oratory1990 catalog (\(state.headphoneIndex.count) headphones). Refresh re-fetches the live catalog from GitHub.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Sennheiser HD 600, AirPods Max, my custom preset…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let userMatches = matchingUserPresets()
                    if !userMatches.isEmpty {
                        SectionHeader("Your presets · \(userMatches.count)")
                        ForEach(userMatches) { p in
                            UserPresetSearchRow(preset: p, state: state, onClose: onClose)
                            Divider().opacity(0.4)
                        }
                    }
                    let catalogMatches = state.searchHeadphones(query)
                    SectionHeader("AutoEq catalog · \(catalogMatches.count)")
                    if catalogMatches.isEmpty {
                        Text("No catalog matches. Try Refresh, or check spelling.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(catalogMatches) { entry in
                            CatalogSearchRow(entry: entry, state: state, onClose: onClose)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            .frame(height: 320)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            if state.headphoneFetchInProgress {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Fetching…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            // Auto-refresh once per session if the cache is empty or stale,
            // so the bundled ~32-entry list isn't a permanent ceiling.
            if !didAutoRefresh, HeadphoneIndex.cacheIsStale() {
                didAutoRefresh = true
                await state.refreshHeadphoneIndex()
            }
        }
    }

    private func matchingUserPresets() -> [EQPreset] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return state.presets }
        return state.presets.filter { $0.name.lowercased().contains(q) }
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UserPresetSearchRow: View {
    let preset: EQPreset
    @ObservedObject var state: AppState
    var onClose: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "star.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).font(.system(size: 12, weight: .medium))
                Text("\(preset.bands.count) bands · preamp \(String(format: "%+0.1f", Double(preset.preampDB))) dB")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Load") {
                state.loadPreset(preset.id)
                onClose()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }
}

private struct CatalogSearchRow: View {
    let entry: HeadphoneEntry
    @ObservedObject var state: AppState
    var onClose: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "headphones")
                .foregroundStyle(.secondary)
                .font(.system(size: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 12, weight: .medium))
                Text("by \(entry.measurer)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Import") {
                Task {
                    await state.importFromHeadphone(entry)
                    onClose()
                }
            }
            .controlSize(.small)
            .disabled(state.headphoneFetchInProgress)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }
}

// MARK: - Header glyph

/// Lowercase "e" whose crossbar is a soundwave - matches the menubar glyph.
/// Ring drawn as an explicit polyline so I don't have to argue with
/// SwiftUI's angle direction conventions for an open arc.
private struct EQGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX
        let cy = rect.midY
        let radius = min(rect.width, rect.height) * 0.44

        // Outer ring: 330° polyline from 3 o'clock counterclockwise (visual)
        // around to ~5 o'clock. Y-down screen coords, so we negate sin.
        let n = 96
        let startDeg: CGFloat = 0
        let sweepDeg: CGFloat = 330
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let rad = (startDeg + sweepDeg * t) * .pi / 180
            let x = cx + cos(rad) * radius
            let y = cy - sin(rad) * radius   // y-flip for SwiftUI screen coords
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }

        // Crossbar soundwave: lands EXACTLY at the ring's right tip (the
        // arc starts at angle 0 = (cx + radius, cy)) with horizontal
        // tangent, so there's no ledge between the wave and the ring.
        let leftX = cx - radius
        let rightX = cx + radius
        let amp = radius * 0.28
        p.move(to: CGPoint(x: leftX, y: cy))
        p.addCurve(to: CGPoint(x: cx, y: cy),
                   control1: CGPoint(x: leftX + radius * 0.30, y: cy + amp),
                   control2: CGPoint(x: cx - radius * 0.30, y: cy - amp))
        p.addCurve(to: CGPoint(x: rightX, y: cy),
                   control1: CGPoint(x: cx + radius * 0.30, y: cy + amp),
                   control2: CGPoint(x: rightX - radius * 0.10, y: cy))
        return p
    }
}

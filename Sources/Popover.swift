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
    /// Local NSEvent monitor installed while the popover is visible so
    /// Cmd-Z / Cmd-Shift-Z reach the EQ even though we're inside an
    /// NSPopover (which doesn't forward to the standard responder chain).
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(state: state)

            VStack(spacing: 12) {
                // Output picker moved into HeaderBar; no separate routing row.

                Divider().opacity(0.18)

                if isExpanded {
                    EQEditor(state: state, isExpanded: $isExpanded)
                } else {
                    HeroCurveView(state: state, isExpanded: $isExpanded)
                }

                PreampRow(state: state)

                ToolbarRow(state: state,
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

            ErrorStrip(state: state)
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
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Local monitor: fires for key events targeted at this app's
        // windows. Returning nil swallows the event; returning it lets it
        // propagate normally.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            guard mods.contains(.command) else { return event }
            switch chars {
            case "z":
                if mods.contains(.shift) { state.redo() }
                else                     { state.undo() }
                return nil
            case "q":
                // Cmd-Q only fires while Earshot's popover window is key,
                // not while another app is focused. First press warns;
                // subsequent presses quit immediately. We have to use a
                // UserDefaults flag rather than @State because the
                // confirmation has to persist across runs.
                if UserDefaults.standard.bool(forKey: "earshot.cmdQAcknowledged") {
                    NSApp.terminate(nil)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Quit Earshot?"
                    alert.informativeText = "Quitting will disable EQ until you reopen the app. Earshot lives in the menubar — closing the popover doesn't quit it."
                    alert.addButton(withTitle: "Quit")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        UserDefaults.standard.set(true, forKey: "earshot.cmdQAcknowledged")
                        NSApp.terminate(nil)
                    }
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

// MARK: - Painted switch

/// Pure-SwiftUI replacement for `Toggle(.switch)`. Renders a pill +
/// knob in the accent color; matches the popover's hand-drawn chrome
/// more closely than the native macOS NSSwitch.
private struct PaintedSwitch: View {
    @Binding var isOn: Bool
    var tint: Color
    var width: CGFloat = 36
    var height: CGFloat = 20

    var body: some View {
        let knobInset: CGFloat = 2
        let knobSize = height - knobInset * 2
        let travel = width - knobSize - knobInset * 2

        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                .frame(width: width, height: height)

            Circle()
                .fill(Color.white)
                .frame(width: knobSize, height: knobSize)
                .shadow(color: .black.opacity(0.22), radius: 1.2, x: 0, y: 0.5)
                .offset(x: knobInset + (isOn ? travel : 0))
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isOn)
        .onTapGesture { isOn.toggle() }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        // Every item gets the same explicit height frame and HStack uses
        // .center alignment, so the glyph / title / icons / toggle all
        // share one baseline regardless of their intrinsic sizes.
        HStack(alignment: .center, spacing: 10) {
            // Glyph turns accent-blue when bypass is engaged. Previously
            // a "Bypass" subtitle carried that signal; with the subtitle
            // removed the glyph itself does the indicating.
            EQGlyph()
                .stroke(
                    state.bypassMode
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(.primary.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 22)

            // Just the title - the on/off/bypass state is already conveyed
            // by the toggle position and the bypass icon's accent fill,
            // so a duplicate subtitle was redundant.
            Text("Earshot")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()

            // Inline output picker, flexes to absorb the slack between
            // the title and the right-hand controls so the header doesn't
            // leave a big gap before the bypass button. Borderless menu
            // keeps it visually quiet; the headphones icon makes the role
            // explicit without needing an "OUTPUT" label above it.
            HStack(alignment: .center, spacing: 1) {
                Image(systemName: "headphones")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 22)
                Picker("", selection: Binding(
                    get: { state.outputDeviceUID ?? "" },
                    set: { state.setOutputDevice(uid: $0) })) {
                    ForEach(state.availableOutputs) { d in
                        Text(d.name).tag(d.uid)
                    }
                    if !state.availableOutputs.contains(where: { $0.uid == state.outputDeviceUID }) {
                        Text("(none)").tag("")
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                // Override the inherited orange tint so the device
                // name reads as standard primary text in both themes -
                // matches the white-ish look of the default popover.
                .tint(.primary)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Output device - where Earshot sends the EQ'd audio")

            if state.isApplyingRouting {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }

            // Bypass toggle: in bypass mode → return to EQ mode; otherwise
            // route audio to built-in speakers with no EQ.
            Button {
                if state.bypassMode {
                    state.exitBypass()
                } else {
                    state.enableBypass()
                }
            } label: {
                // hifispeaker is a literal speaker-box glyph - reads as
                // "speakers" at a glance where speaker.wave.2 looked like
                // a volume/mute icon and was ambiguous about its function.
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(state.bypassMode ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.bypassMode
                  ? "Bypass on - click to return to EQ"
                  : "Bypass: route audio to built-in speakers with no EQ")

            // "Earshot active" switch. Hand-drawn (PaintedSwitch) to
            // sit cleanly inside the popover's hand-drawn chrome.
            PaintedSwitch(
                isOn: Binding(
                    get: { state.eqEnabled || state.bypassMode },
                    set: { state.setEQEnabled($0) }),
                tint: Color.accentColor)
            .help(state.eqEnabled || state.bypassMode ? "On (turn off to fully disable Earshot)" : "Off (Earshot is not intercepting audio)")
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
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                // Compact view: curve only, no dots, no readout. Keeps the
                // menubar glance read uncluttered. The chip on the right is
                // the single entry point into the editor.
                EQCurveView(state: state, interactive: false)
                    .frame(height: 132)

                EditBandsChip {
                    withAnimation(.smooth(duration: 0.18)) { isExpanded = true }
                }
                .padding(8)
            }
            FrequencyAxis()
        }
    }
}

/// Curve renderer. Uses SwiftUI's `Canvas` so the path is drawn directly at
/// native display resolution (avoids `drawingGroup`'s bitmap pixelation on
/// Retina) and the GPU handles the per-frame stroke/fill in one pass —
/// faster than two separate `Path` views for drag-time redraws.
private struct CurveLayer: View {
    let bands: [EQBand]
    let preamp: Float
    var accent: Color = .accentColor

    var body: some View {
        Canvas { ctx, size in
            let pts = EQCurveView.curvePoints(
                bands: bands, preamp: preamp,
                width: size.width, height: size.height)
            guard let first = pts.first else { return }

            var fill = Path()
            fill.move(to: CGPoint(x: first.x, y: size.height))
            for pt in pts { fill.addLine(to: pt) }
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [accent.opacity(0.22),
                                  accent.opacity(0.0)]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)))

            var stroke = Path()
            stroke.move(to: first)
            for pt in pts.dropFirst() { stroke.addLine(to: pt) }
            ctx.stroke(stroke, with: .linearGradient(
                Gradient(colors: [accent.opacity(0.95), accent]),
                startPoint: CGPoint(x: 0, y: size.height / 2),
                endPoint: CGPoint(x: size.width, y: size.height / 2)),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

private struct EditBandsChip: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Edit bands", systemImage: "slider.horizontal.3")
        }
        .controlSize(.small)
        .help("Open the band editor")
    }
}

private struct CollapseChip: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Done", systemImage: "chevron.up")
        }
        .controlSize(.small)
        .help("Hide the band editor")
    }
}

// MARK: - Expanded EQ editor

private struct EQEditor: View {
    @ObservedObject var state: AppState
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                EQCurveView(state: state, interactive: true)
                    .frame(height: 132)
                CollapseChip {
                    withAnimation(.smooth(duration: 0.18)) { isExpanded = false }
                }
                .padding(8)
            }
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
            Toggle("", isOn: Binding(
                get: { !band.bypass },
                set: { v in state.updateBand(id: band.id) { $0.bypass = !v } }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            // Picker absorbs the slack so the row has no trailing dead
            // space. Filter-type names vary in length anyway, so giving
            // the dropdown the leftover width is the natural fit.
            Picker("", selection: Binding(
                get: { band.type },
                set: { v in state.updateBand(id: band.id) { $0.type = v } })) {
                ForEach(EQFilter.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .labelsHidden()
            .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
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
                       width: 80)

            stepperBox(label: "dB", value: band.gain,
                       format: { String(format: "%+0.1f", Double($0)) },
                       step: { dir, _ in
                           band.gain + Float(dir) * 0.5
                       },
                       commit: { v in state.updateBand(id: band.id) {
                           $0.gain = max(-24, min(24, v))
                       }},
                       width: 68,
                       enabled: band.type.usesGain)

            stepperBox(label: "Q", value: band.q,
                       format: { String(format: "%0.2f", Double($0)) },
                       step: { dir, _ in band.q + Float(dir) * 0.1 },
                       commit: { v in state.updateBand(id: band.id) {
                           $0.q = max(0.1, min(50, v))
                       }},
                       width: 64,
                       enabled: band.type.usesQ)

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

private struct PreampStepper: View {
    @ObservedObject var state: AppState

    var body: some View {
        let enabled = !state.autoPreampEnabled
        // The original chevron glyphs were only ~8pt tall so their hit
        // area was a thin slice that the user had to aim at precisely.
        // Each chevron button is now a fixed-height stripe spanning the
        // full pill width, with .contentShape(Rectangle()) so the whole
        // stripe is clickable instead of just the glyph pixels.
        VStack(spacing: 0) {
            chevron("chevron.up") {
                state.recordUndoSnapshot()
                state.setPreamp(min(12, state.workingPreamp + 0.1))
            }

            Text(String(format: "%+0.1f dB", Double(state.workingPreamp)))
                .monospacedDigit()
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 1)

            chevron("chevron.down") {
                state.recordUndoSnapshot()
                state.setPreamp(max(-24, state.workingPreamp - 0.1))
            }
        }
        .frame(width: 60)
        .background(RoundedRectangle(cornerRadius: 5).fill(.quinary))
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .help("Preamp gain - adjusts overall level before EQ.")
    }

    @ViewBuilder
    private func chevron(_ systemName: String, _ action: @escaping () -> Void) -> some View {
        ChevronButton(systemName: systemName, action: action)
    }
}

/// Stepper chevron. Adds a subtle background highlight on hover so it
/// reads as a discrete button instead of a free-floating arrow glyph.
private struct ChevronButton: View {
    let systemName: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 14)
                .background(hovering ? Color.primary.opacity(0.08)
                                     : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.08), value: hovering)
    }
}

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
                   in: -24...12,
                   onEditingChanged: { editing in
                       // Snapshot once at drag start so a single undo
                       // reverts the whole slider gesture.
                       if editing { state.recordUndoSnapshot() }
                   })
                .disabled(state.autoPreampEnabled)
                .opacity(state.autoPreampEnabled ? 0.55 : 1.0)
            // dB readout with the +/- chevrons stacked above and below it,
            // centered on the value. Reads as a single unit instead of a
            // "value + dropdown chevron" combo which is what the inline
            // version looked like.
            PreampStepper(state: state)
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
    @Binding var showingSaveSheet: Bool
    @Binding var savePresetName: String
    @Binding var showingHeadphoneSearch: Bool
    @Binding var importErrorMessage: String?

    var body: some View {
        HStack(spacing: 4) {
            // Icon-only buttons were ambiguous; matching the "Save" button's
            // icon-plus-label pattern keeps each entry point self-explanatory.
            Button {
                showingHeadphoneSearch = true
            } label: {
                Label("Find headphone…", systemImage: "headphones")
            }
            .controlSize(.small)
            .help("Search the bundled AutoEQ headphone catalog")

            Button {
                importAutoEQ()
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .controlSize(.small)
            .help("Load a ParametricEQ.txt file from disk")

            // Export moved to the per-preset menu (... > Export...) so
            // any preset can be exported, not just the currently loaded
            // one, and so this row stops re-flowing when the loaded
            // preset state changes.
            Spacer()
            Button {
                savePresetName = ""
                showingSaveSheet = true
            } label: {
                Label("Save", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    private func importAutoEQ() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Select a ParametricEQ.txt file (AutoEQ format)."
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

}

/// Shared preset export helper. Used by the per-preset menu in PresetRow.
/// On error returns the message string; on success returns nil.
@MainActor
private func exportPresetToFile(_ preset: EQPreset, state: AppState) -> String? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "\(preset.name) ParametricEQ.txt"
    panel.message = "Save as AutoEQ ParametricEQ format."
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    let text = state.exportAutoEQ(preset: preset)
    do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        return nil
    } catch {
        return "Couldn't write the file: \(error.localizedDescription)"
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
            Text(preset.name)
                .font(.system(size: 12, weight: isLoaded ? .semibold : .regular))
            Spacer()
            Menu {
                Button("Update with current EQ") { state.updatePreset(preset.id) }
                Button("Rename…") { renameTarget = preset }
                Button("Export…") { _ = exportPresetToFile(preset, state: state) }
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
        // Content text aligns at x=16 to match the EQ ON / EQ OFF headings
        // and OUTPUT block above. The loaded-state indicator is an overlay
        // pinned to the popover's left edge so it still reads as a flush
        // accent strip without shifting the text.
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(isLoaded ? Color.accentColor.opacity(0.06) : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isLoaded ? Color.accentColor : Color.clear)
                .frame(width: 2)
        }
        .onTapGesture { state.loadPreset(preset.id) }
    }
}

// MARK: - Footer

/// Inline error strip that appears at the bottom of the popover only
/// when there's actually an error to surface. Replaces the old FooterBar
/// (which was permanent chrome just to host a "Quit" menu - quit is now
/// reachable via right-click on the menubar icon and Cmd-Q while the
/// popover is focused).
private struct ErrorStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let err = state.lastError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    state.lastError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4))
        }
    }
}

// MARK: - EQ curve drawing

private struct EQCurveView: View {
    @ObservedObject var state: AppState
    /// When false, the curve renders as a glance read: no dots, no
    /// gestures, no readout. Used in the compact hero view so the menubar
    /// popover stays uncluttered.
    var interactive: Bool = true

    @State private var hoveredBandID: UUID? = nil
    @State private var draggingBandID: UUID? = nil
    /// Captured at drag start so a single drag translation can be applied to a
    /// stable origin, instead of compounding tiny per-event mutations into
    /// rounding drift.
    @State private var dragAnchor: DragAnchor? = nil

    private struct DragAnchor {
        let bandID: UUID
        let startFrequency: Float
        let startGain: Float
        let startPoint: CGPoint
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.08), Color.accentColor.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))

                ForEach(EQCurveView.gridLines, id: \.self) { db in
                    let y = EQCurveView.yFor(db: Float(db), height: geo.size.height)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.secondary.opacity(db == 0 ? 0.32 : 0.08),
                            style: StrokeStyle(lineWidth: 0.5, dash: db == 0 ? [] : [2, 4]))
                }

                // The curve is recomputed on every band change. Rasterizing
                // it to a single Metal layer (drawingGroup) keeps the cost
                // of drag-time redraws bounded — without it, both the fill
                // and stroke paths re-tessellate on every gesture event.
                CurveLayer(
                    bands: state.workingBands,
                    preamp: state.workingPreamp,
                    accent: Color.accentColor)

                // Interactive dots only when the parent view enables it.
                // Drawn above the curve so the user can grab a band even
                // where two bands cross. Hovered/dragged dots float up via
                // zIndex (not view reordering) so the active DragGesture
                // isn't torn down mid-drag.
                if interactive {
                    let bands = state.workingBands

                    // Vertical guide through the active dot — strongest
                    // possible "this is the one you're touching" signal.
                    if let id = draggingBandID ?? hoveredBandID,
                       let band = bands.first(where: { $0.id == id }) {
                        let x = CGFloat(EQCurveView.tFor(freq: band.frequency)) * geo.size.width
                        Path { p in
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x, y: geo.size.height))
                        }
                        .stroke(Color.accentColor.opacity(0.35),
                                style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                        .allowsHitTesting(false)
                    }

                    // Dots are visual only. The interaction layer above
                    // catches all events so there's no chance of a missed
                    // SwiftUI .onHover exit leaving the cursor as a hand
                    // outside a dot's hit area.
                    ForEach(bands) { band in
                        bandDot(band: band, viewSize: geo.size)
                            .zIndex(band.id == draggingBandID ? 2
                                    : (band.id == hoveredBandID ? 1 : 0))
                            .allowsHitTesting(false)
                    }

                    // Single interaction layer: every mouse-move event
                    // updates cursor + highlight via .onContinuousHover,
                    // which fires continuously rather than only at
                    // enter/exit (the unreliable .onHover that was
                    // dropping exits). A strict 8pt-radius test means the
                    // hand cursor and highlight appear ONLY when the
                    // pointer is literally within a dot's 16pt-diameter
                    // hit zone — identical area to the click target.
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p):
                                let hit = EQCurveView.strictHit(
                                    at: p, bands: bands,
                                    viewSize: geo.size, radius: 8)
                                hoveredBandID = hit?.id
                                if hit != nil { NSCursor.pointingHand.set() }
                                else          { NSCursor.arrow.set() }
                            case .ended:
                                hoveredBandID = nil
                                NSCursor.arrow.set()
                            }
                        }
                        .gesture(layerDragGesture(bands: bands, viewSize: geo.size))
                        .contextMenu { dotContextMenu(bands: bands) }
                        .onTapGesture(count: 2) {
                            if let id = hoveredBandID,
                               let b = bands.first(where: { $0.id == id }),
                               b.type.usesGain {
                                state.updateBand(id: id) { $0.gain = 0 }
                            }
                        }

                    // Readout shows on hover OR drag - same trigger as the
                    // hand cursor (both fire from .onContinuousHover above,
                    // which is reliable, so the stale-text problem from
                    // earlier per-dot .onHover isn't a concern here).
                    if let id = draggingBandID ?? hoveredBandID,
                       let band = bands.first(where: { $0.id == id }) {
                        tooltip(for: band)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topLeading)
                            .padding(6)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
            // No implicit ZStack-wide animations: with a drag changing
            // band position 60-120Hz, those animations would try to
            // interpolate dot positions on every event and fight the
            // gesture. Hover affordances are animated locally on the dot.
        }
    }

    // MARK: Dot

    @ViewBuilder
    private func bandDot(band: EQBand, viewSize: CGSize) -> some View {
        let pt = EQCurveView.pointForBand(band, viewSize: viewSize)
        let isHovered = hoveredBandID == band.id
        let isDragging = draggingBandID == band.id
        let isActive = isHovered || isDragging

        // Subtle: dot grows slightly and its outline brightens. The dashed
        // vertical guide line on the parent ZStack is what spatially
        // identifies the active dot; the dot itself stays understated.
        let dotSize: CGFloat = isDragging ? 13 : (isActive ? 11 : 9)
        let dotFill: Color = band.bypass
            ? Color.secondary.opacity(0.55)
            : Color.accentColor
        let outlineOpacity: Double = isActive ? 1.0 : 0.85
        let outlineWidth: CGFloat = isActive ? 1.4 : 1.0

        let allFull = state.workingBands.count >= EQEngine.maxBands

        if allFull {
            Image(systemName: "hand.thumbsup.fill")
                .font(.system(size: dotSize * 1.6, weight: .semibold))
                .foregroundStyle(dotFill)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                .opacity(band.bypass ? 0.55 : 1)
                .position(pt)
        } else {
            Circle()
                .fill(dotFill)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(outlineOpacity),
                                          lineWidth: outlineWidth)
                )
                .frame(width: dotSize, height: dotSize)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                .opacity(band.bypass ? 0.55 : 1)
                .position(pt)
        }
    }

    /// Right-click menu shared by every dot. Operates on the band the
    /// interaction layer's hover tracker last identified, so right-click
    /// over a specific dot opens its menu — and a right-click over empty
    /// space opens an empty menu (effectively a no-op).
    @ViewBuilder
    private func dotContextMenu(bands: [EQBand]) -> some View {
        if let id = hoveredBandID, let band = bands.first(where: { $0.id == id }) {
            Button {
                state.updateBand(id: band.id) { $0.bypass.toggle() }
            } label: {
                if band.bypass { Label("Bypass band", systemImage: "checkmark") }
                else           { Text("Bypass band") }
            }
            Button {
                state.toggleSolo(band.id)
            } label: {
                if state.soloedBandID == band.id {
                    Label("Solo band", systemImage: "checkmark")
                } else {
                    Text("Solo band")
                }
            }
            Button("Reset gain") {
                state.updateBand(id: band.id) { $0.gain = 0 }
            }
            Divider()
            Button("Remove band", role: .destructive) {
                state.removeBand(id: band.id)
            }
        }
    }

    /// Drag handler attached to the interaction layer. On the first event,
    /// uses the press location to find which dot was grabbed (strict 8pt
    /// hit) and captures the anchor; later events apply the translation.
    /// A press not on any dot is a no-op — no anchor is captured so
    /// subsequent .onChanged events early-return.
    private func layerDragGesture(bands: [EQBand], viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragAnchor == nil {
                    guard let band = EQCurveView.strictHit(
                        at: value.startLocation, bands: bands,
                        viewSize: viewSize, radius: 8) else { return }
                    state.recordUndoSnapshot()
                    dragAnchor = DragAnchor(
                        bandID: band.id,
                        startFrequency: band.frequency,
                        startGain: band.gain,
                        startPoint: EQCurveView.pointForBand(band, viewSize: viewSize))
                    draggingBandID = band.id
                    NSCursor.pointingHand.set()
                }
                guard let anchor = dragAnchor else { return }

                let mods = NSEvent.modifierFlags
                let lockX = mods.contains(.option)
                let lockY = mods.contains(.shift)
                let dx = lockX ? 0 : value.translation.width
                let dy = lockY ? 0 : value.translation.height
                let newX = min(max(anchor.startPoint.x + dx, 0), viewSize.width)
                let newY = min(max(anchor.startPoint.y + dy, 0), viewSize.height)
                let t = viewSize.width > 0 ? Float(newX / viewSize.width) : 0
                let newFreq = EQCurveView.freqAt(t: t)
                state.updateBandTransient(id: anchor.bandID) { b in
                    b.frequency = max(20, min(22000, newFreq))
                    if b.type.usesGain && !lockY {
                        let g = EQCurveView.dbFor(y: newY, height: viewSize.height)
                        b.gain = max(-EQCurveView.dbRange,
                                     min(EQCurveView.dbRange, g))
                    }
                }
            }
            .onEnded { _ in
                if dragAnchor != nil { state.commitBandEdits() }
                dragAnchor = nil
                draggingBandID = nil
            }
    }

    /// Find the band whose dot strictly contains `point`, where "contains"
    /// is `distance <= radius`. Returns nil when the cursor isn't on any
    /// dot. Used identically for both hover-cursor decisions and drag
    /// dispatch so the hand cursor and the click target are the same
    /// region by construction.
    fileprivate static func strictHit(at point: CGPoint, bands: [EQBand],
                                      viewSize: CGSize, radius: CGFloat) -> EQBand? {
        let r2 = radius * radius
        var bestID: UUID? = nil
        var bestSq = r2
        for b in bands {
            let p = EQCurveView.pointForBand(b, viewSize: viewSize)
            let dx = p.x - point.x
            let dy = p.y - point.y
            let sq = dx * dx + dy * dy
            if sq <= bestSq { bestSq = sq; bestID = b.id }
        }
        return bestID.flatMap { id in bands.first { $0.id == id } }
    }

    // MARK: Tooltip

    @ViewBuilder
    private func tooltip(for band: EQBand) -> some View {
        let parts: [String] = {
            var out: [String] = [Self.freqLabel(band.frequency)]
            if band.type.usesGain {
                out.append(String(format: "%+.1f dB", Double(band.gain)))
            }
            if band.type.usesQ {
                out.append(String(format: "Q %.2f", Double(band.q)))
            }
            return out
        }()
        Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            )
    }

    // MARK: Coordinate math (static so call sites don't need an instance)

    fileprivate static let gridLines: [Int] = [-12, -6, 0, 6, 12]
    fileprivate static let fMin: Float = 20
    fileprivate static let fMax: Float = 20000
    fileprivate static let dbRange: Float = 18

    fileprivate static func freqAt(t: Float) -> Float {
        let logMin = log10f(fMin)
        let logMax = log10f(fMax)
        return powf(10, logMin + max(0, min(1, t)) * (logMax - logMin))
    }

    fileprivate static func tFor(freq: Float) -> Float {
        let logMin = log10f(fMin)
        let logMax = log10f(fMax)
        let lf = log10f(max(fMin, min(fMax, freq)))
        return (lf - logMin) / (logMax - logMin)
    }

    fileprivate static func yFor(db: Float, height: CGFloat) -> CGFloat {
        let clamped = max(-dbRange, min(dbRange, db))
        let n = (dbRange - clamped) / (2 * dbRange)
        return CGFloat(n) * height
    }

    fileprivate static func dbFor(y: CGFloat, height: CGFloat) -> Float {
        guard height > 0 else { return 0 }
        let n = Float(y / height)
        return dbRange - n * 2 * dbRange
    }

    /// The on-curve y coordinate for a band's dot. For gain-bearing filters
    /// this is just the band's gain; for pass filters (no gain parameter)
    /// the dot rides on the 0 dB line so it stays a sensible grab target.
    fileprivate static func pointForBand(_ b: EQBand, viewSize: CGSize) -> CGPoint {
        let x = CGFloat(tFor(freq: b.frequency)) * viewSize.width
        let g = b.type.usesGain ? b.gain : 0
        let y = yFor(db: g, height: viewSize.height)
        return CGPoint(x: x, y: y)
    }

    fileprivate static func curvePoints(bands: [EQBand], preamp: Float,
                                        width: CGFloat, height: CGFloat) -> [CGPoint] {
        // 256 samples across a ~450pt chart keeps the curve crisp at 2x
        // Retina. Canvas rendering means the transcendental work isn't the
        // bottleneck — implicit animations during drag were.
        let count = 256
        var pts: [CGPoint] = []
        pts.reserveCapacity(count + 1)
        for i in 0...count {
            let t = Float(i) / Float(count)
            let f = freqAt(t: t)
            let db = totalGainDB(bands: bands, at: f) + preamp
            pts.append(CGPoint(x: CGFloat(t) * width, y: yFor(db: db, height: height)))
        }
        return pts
    }

    fileprivate static func totalGainDB(bands: [EQBand], at f: Float) -> Float {
        var total: Float = 0
        for b in bands where !b.bypass {
            total += bandResponseDB(b, at: f)
        }
        return total
    }

    fileprivate static func bandResponseDB(_ b: EQBand, at f: Float) -> Float {
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

    fileprivate static func freqLabel(_ f: Float) -> String {
        if f >= 1000 { return String(format: "%.2f kHz", Double(f) / 1000) }
        return String(format: "%.0f Hz", Double(f))
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

    private var fillStops: [Gradient.Stop] {
        [
            .init(color: Color.accentColor, location: 0.00),
            .init(color: Color.accentColor, location: 0.70),
            .init(color: .orange,           location: 0.90),
            .init(color: .red,              location: 1.00),
        ]
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
                        stops: fillStops,
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
                // Plain-text labels on both so they're identical height -
                // a `Label` with an SF Symbol made Refresh taller than the
                // text-only Done button and the icon never aligned cleanly
                // with the text baseline either.
                Button("Refresh catalog") {
                    Task { await state.refreshHeadphoneIndex() }
                }
                .disabled(state.headphoneFetchInProgress)
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Sennheiser HD 600, AirPods Max, my custom preset…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            // List virtualizes far better than ScrollView+LazyVStack for
            // ~2000-row catalogs. We also cap the catalog rendering until
            // a query is typed - dumping all 1961 entries into the view
            // hierarchy by default was what made initial scroll glitchy
            // (LazyVStack pre-measures section sizes even when off-screen).
            List {
                let userMatches = matchingUserPresets()
                if !userMatches.isEmpty {
                    Section("Your presets · \(userMatches.count)") {
                        ForEach(userMatches) { p in
                            UserPresetSearchRow(preset: p, state: state, onClose: onClose)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                        }
                    }
                }
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    Section("AutoEQ catalog · \(state.headphoneIndex.count)") {
                        Text("Type a brand or model to search.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12,
                                                      bottom: 8, trailing: 12))
                            .listRowSeparator(.hidden)
                    }
                } else {
                    let catalogMatches = state.searchHeadphones(query)
                    Section("AutoEQ catalog · \(catalogMatches.count)") {
                        if catalogMatches.isEmpty {
                            Text("No matches. Try Refresh, or check spelling.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .listRowInsets(EdgeInsets(top: 8, leading: 12,
                                                          bottom: 8, trailing: 12))
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(catalogMatches) { entry in
                                CatalogSearchRow(entry: entry, state: state, onClose: onClose)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(height: 320)
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

import SwiftUI
import AVFoundation
import AppKit

/// First-run onboarding. Three phases:
///
///   1. No 2-channel loopback driver found → show install instructions
///      + "Re-check" button. Earshot needs a loopback to intercept
///      system audio; BlackHole 2ch is the recommended free option but
///      VB-Cable, Soundflower (2ch), and Loopback Audio also work.
///   2. Microphone permission not granted → ask. macOS classifies a
///      virtual-audio loopback as a microphone, so denial silently
///      breaks capture.
///   3. Permission + driver OK, but no preset loaded → invite the user
///      to pick a headphone preset from the bundled catalog (or skip).
///
/// Shown in a standalone NSWindow rather than as a sheet inside the
/// NSPopover. The popover is `.transient` (closes on focus loss), and a
/// sheet attached to it competes with that behaviour - presenting the
/// sheet steals focus, which closes the popover, which kills the sheet
/// and leaves the user with no UI. A separate window owns its own
/// keyWindow lifetime so there's no race.
struct OnboardingSheet: View {
    @ObservedObject var state: AppState
    var onClose: () -> Void

    @State private var loopbackPresent: Bool = EQEngine.findLoopbackInputUID() != nil
    @State private var micStatus: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(headerText)
                .font(.system(size: 16, weight: .semibold))
            phaseSection
        }
        .padding(24)
        .frame(width: 420)
    }

    private var headerText: String {
        if !loopbackPresent { return "Install a loopback driver." }
        if micStatus != .authorized { return "Grant microphone access." }
        return "Pick an output."
    }

    @ViewBuilder
    private var phaseSection: some View {
        if !loopbackPresent {
            loopbackPane
        } else if micStatus != .authorized {
            micPane
        } else {
            readyPane
        }
    }

    // MARK: Loopback driver

    private var loopbackPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Earshot routes macOS audio through a 2-channel virtual loopback driver. BlackHole 2ch is the free option; VB-Cable, Soundflower (2ch), or Loopback Audio also work.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("brew install blackhole-2ch")
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                Link("Or download from existential.audio/blackhole",
                     destination: URL(string: "https://existential.audio/blackhole")!)
                    .font(.system(size: 12))
            }
            HStack {
                Spacer()
                Button("Re-check") {
                    loopbackPresent = EQEngine.findLoopbackInputUID() != nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Mic permission

    private var micPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS treats virtual loopbacks as microphones, so the system prompt asks for Microphone access. Earshot only reads from the loopback driver; no real microphone is opened.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                if micStatus == .denied || micStatus == .restricted {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("Grant access") {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async {
                            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Ready

    private var readyPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: Binding(
                get: { state.outputDeviceUID ?? "" },
                set: { state.setOutputDevice(uid: $0) })) {
                ForEach(state.availableOutputs) { d in
                    Text(d.name).tag(d.uid)
                }
                if state.availableOutputs.isEmpty {
                    Text("(no outputs)").tag("")
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            HStack {
                Spacer()
                Button("Start using Earshot") {
                    UserDefaults.standard.set(true, forKey: "earshot.onboardingComplete")
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

@MainActor
enum Onboarding {
    private static var window: NSWindow?

    /// Show the onboarding window on first launch, or whenever the user
    /// is missing a loopback driver / mic permission. Driver and
    /// permission status are checked at every invocation so the gate
    /// stays accurate even after a driver was installed mid-session.
    static func shouldShow() -> Bool {
        if UserDefaults.standard.bool(forKey: "earshot.onboardingComplete") {
            if EQEngine.findLoopbackInputUID() == nil { return true }
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { return true }
            return false
        }
        return true
    }

    static func showIfNeeded(state: AppState) {
        guard shouldShow() else { return }
        present(state: state)
    }

    static func present(state: AppState) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: OnboardingSheet(state: state, onClose: {
            Onboarding.dismiss()
        }))
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        w.title = "Earshot setup"
        w.contentViewController = host
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func dismiss() {
        window?.close()
        window = nil
    }
}

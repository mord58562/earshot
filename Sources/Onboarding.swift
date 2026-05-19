import SwiftUI
import AVFoundation
import AppKit

/// First-run onboarding. Three phases:
///
///   1. BlackHole 2ch missing → show install instructions + "Re-check"
///      button. Earshot needs BlackHole as a loopback to intercept
///      system audio; there is no path that skips this.
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

    @State private var blackHolePresent: Bool = EQEngine.findBlackHoleUID() != nil
    @State private var micStatus: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Earshot")
                .font(.system(size: 18, weight: .semibold))
            phaseSection
        }
        .padding(24)
        .frame(width: 420)
    }

    @ViewBuilder
    private var phaseSection: some View {
        if !blackHolePresent {
            blackHolePane
        } else if micStatus != .authorized {
            micPane
        } else {
            readyPane
        }
    }

    // MARK: BlackHole

    private var blackHolePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("BlackHole 2ch isn't installed.")
            Text("Earshot needs a virtual loopback driver to capture system audio. BlackHole 2ch is the standard one; install with Homebrew or directly:")
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
                    blackHolePresent = EQEngine.findBlackHoleUID() != nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Mic permission

    private var micPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("One macOS permission to enable.")
            Text("BlackHole appears to macOS as a microphone, so Earshot has to ask for Microphone access. It only reads from the loopback - no real microphone is ever opened.")
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
            label("Pick an output and you're set.")
            Text("Choose where Earshot should send the EQ'd audio. You can change this any time from the popover.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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
                Button("Done") {
                    UserDefaults.standard.set(true, forKey: "earshot.onboardingComplete")
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
    }
}

@MainActor
enum Onboarding {
    private static var window: NSWindow?

    /// Show the onboarding window on first launch, or whenever the user
    /// is missing BlackHole / mic permission. Driver and permission
    /// status are checked at every invocation so the gate stays
    /// accurate even after BlackHole was installed mid-session.
    static func shouldShow() -> Bool {
        if UserDefaults.standard.bool(forKey: "earshot.onboardingComplete") {
            if EQEngine.findBlackHoleUID() == nil { return true }
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
        w.title = "Welcome to Earshot"
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

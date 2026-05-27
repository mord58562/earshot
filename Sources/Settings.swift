import Cocoa
import SwiftUI
import ServiceManagement

/// Settings window. macOS accessory apps (no Dock icon) don't get a
/// standard application menu, so Cmd-, has to be wired manually from
/// inside the popover keyMonitor. We use a free-standing NSWindow with
/// a SwiftUI hosting content view; sticking close to system register
/// (titlebar visible, content-sized, single-pane) keeps it feeling
/// native rather than bolted-on.
@MainActor
enum SettingsWindow {

    private static var window: NSWindow?

    static func show(state: AppState) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsPane(state: state)
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        w.title = "Earshot Settings"
        w.contentViewController = hosting
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName("EarshotSettings")
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsPane: View {
    @ObservedObject var state: AppState
    @State private var launchAtLogin: Bool = SettingsPane.currentLoginItem()

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        applyLoginItem(newValue)
                    }
                Toggle("Auto-preamp by default", isOn: Binding(
                    get: { state.autoPreampEnabled },
                    set: { state.setAutoPreampEnabled($0) }))
            } header: {
                Text("General")
            } footer: {
                Text("Auto-preamp parks the loudest channel about 3 dB below clipping. It only attenuates - it never adds gain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(Self.versionString())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open Logs Folder") { openLogs() }
                    Button("Source on GitHub") { openGitHub() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 260)
    }

    private static func currentLoginItem() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func applyLoginItem(_ on: Bool) {
        let svc = SMAppService.mainApp
        do {
            if on {
                if svc.status != .enabled { try svc.register() }
            } else {
                if svc.status == .enabled { try svc.unregister() }
            }
        } catch {
            // Surface failure into the state error strip so the user
            // sees why the toggle bounced back.
            state.lastError = "Could not change login-item setting: \(error.localizedDescription)"
            DispatchQueue.main.async {
                self.launchAtLogin = Self.currentLoginItem()
            }
        }
    }

    private func openLogs() {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Earshot", isDirectory: true)
        if let url = url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        }
    }

    private func openGitHub() {
        if let u = URL(string: "https://github.com/mord58562/earshot") {
            NSWorkspace.shared.open(u)
        }
    }

    private static func versionString() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Standard About panel, configured with credits + copyright. macOS draws
/// the icon and version automatically from Info.plist.
@MainActor
enum AboutPanel {
    static func show() {
        let credits = NSMutableAttributedString(string: """
        A menubar parametric EQ for macOS system audio.

        Routes through a 2-channel virtual loopback (BlackHole 2ch, VB-Cable,
        Soundflower, or Loopback Audio), drift-corrected with CAPlayThrough's
        rate-scalar approach. AutoEQ headphone catalog by oratory1990 and
        Crinacle, used under their respective licences.
        """)
        credits.addAttributes([
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ], range: NSRange(location: 0, length: credits.length))

        let copyright = "\u{00A9} 2026 mord58562. Released under the MIT licence."

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .init(rawValue: "Copyright"): copyright,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

import Cocoa
import SwiftUI
import AVFoundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let state = AppState()
    private var hostingController: NSHostingController<PopoverRoot>!
    private var lastClickTime: CFTimeInterval = 0
    private var includeOToole = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = MenubarGlyph.image()
            button.target = self
            button.action = #selector(handleStatusClick(_:))
            // Default action mask = left mouse up. Listen to right mouse
            // too so we can route Ctrl-click / right-click to a profiles
            // menu without breaking standard left-click toggling.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            Log.write("status item created and wired")
        } else {
            Log.write("status item created but button is nil!")
        }

        hostingController = NSHostingController(rootView: PopoverRoot(state: state))
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.delegate = self
        registerAsLoginItem()
        Log.write("Earshot launched. Loopback installed: \(state.preferredLoopbackInstalled)")
    }

    /// Register Earshot to launch at login. Idempotent. Runs off-main so a
    /// stalled service call can never block the UI. The app starts idle (EQ
    /// off) unless the persisted state says otherwise, so registering at
    /// login can't strand BlackHole as the system default.
    private func registerAsLoginItem() {
        DispatchQueue.global(qos: .utility).async {
            let service = SMAppService.mainApp
            guard service.status != .enabled else {
                Log.write("login item already enabled")
                return
            }
            do {
                try service.register()
                Log.write("registered as login item")
            } catch {
                Log.write("login item registration failed: \(error)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.appWillTerminate()
    }

    // NSPopoverDelegate. Gate background work that only matters when the
    // UI is on-screen (meter ticker + level @Published storm) on these
    // callbacks - dropped CPU usage substantially when the popover is
    // closed, which is most of the time.
    func popoverDidShow(_ notification: Notification) {
        state.setPopoverVisible(true)
    }
    func popoverDidClose(_ notification: Notification) {
        state.setPopoverVisible(false)
    }

    @objc private func handleStatusClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        Log.write("status click received, event=\(event?.type.rawValue ?? 0)")
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false) {
            Log.write("routing to profiles menu")
            showProfilesMenu()
        } else {
            Log.write("routing to popover toggle")
            toggleStatusItem()
        }
    }

    private func toggleStatusItem() {
        let now = CACurrentMediaTime()
        guard now - lastClickTime > 0.15 else {
            Log.write("toggle debounced")
            return
        }
        lastClickTime = now

        if popover.isShown {
            // popover.close() is unconditional. performClose() goes
            // through the responder chain and bounces if a sheet (file
            // picker, save dialog, headphone search) is up on top of
            // the popover - which meant the menubar icon stopped
            // closing the popover the moment a sheet was open. close()
            // tears down the popover regardless and the sheet's hosting
            // window closes with it.
            Log.write("popover currently shown - closing")
            popover.close()
            return
        }
        guard let button = statusItem.button else {
            Log.write("toggle: status button missing")
            return
        }
        if Int.random(in: 0..<10) == 0 {
            button.toolTip = "O'Toole"
        } else {
            button.toolTip = "Earshot"
        }
        // Don't call state.refreshDevices() here - it's a synchronous
        // CoreAudio sweep that blocks on coreaudiod, and if coreaudiod is
        // mid-negotiation with a flaky output device the popover open can
        // stall for seconds. The CoreAudio device-change listener already
        // refreshes the device lists asynchronously when the system
        // changes, so the cached lists are good enough to render with.
        // Defer the popover show by one runloop tick so any in-flight click
        // event finishes processing before SwiftUI tries to lay out a new
        // window on top of it. Eliminates a class of "click does nothing"
        // races where AppKit was still inside the click dispatch when we
        // asked the popover to attach.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let button = self.statusItem.button else { return }
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.popover.contentViewController?.view.window?.makeKey()
            Log.write("popover shown")
        }
    }

    private func showProfilesMenu() {
        // Right-click menu: presets + open + quit.
        let menu = NSMenu()
        if state.presets.isEmpty {
            let item = NSMenuItem(title: "No presets yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let title = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for preset in state.presets {
                let item = NSMenuItem(title: "  \(preset.name)", action: #selector(loadPresetFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id
                if state.loadedPresetID == preset.id { item.state = NSControl.StateValue.on }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open Earshot", action: #selector(toggleStatusItemFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Earshot", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func loadPresetFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        state.loadPreset(id)
    }

    @objc private func toggleStatusItemFromMenu() {
        toggleStatusItem()
    }
}

MainActor.assumeIsolated {
    // Single-instance discipline, latest-launch-wins. If another Earshot
    // is already running we ask it to quit, force-kill stragglers, then
    // proceed. The alternative — exiting on collision — traps the user
    // when a stale or crashed instance still owns the menubar icon: it
    // eats clicks, and a new launch from Finder or Launchpad would
    // silently bail.
    let bundleID = Bundle.main.bundleIdentifier ?? "com.mord58562.Earshot"
    let myPID = ProcessInfo.processInfo.processIdentifier

    func priors() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
    }

    var stragglers = priors()
    if !stragglers.isEmpty {
        Log.write("prior Earshot instance(s) found (pids: \(stragglers.map { $0.processIdentifier })) - asking to terminate")
        for other in stragglers { other.terminate() }
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            stragglers = priors()
            if stragglers.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        for other in priors() {
            Log.write("force-terminating pid=\(other.processIdentifier)")
            other.forceTerminate()
        }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

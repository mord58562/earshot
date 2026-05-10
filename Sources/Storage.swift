import Foundation

/// Persists the user's preset library and last-used app settings under
/// ~/Library/Application Support/Earshot/. Atomic writes; defaults bundled
/// with the app are copied in on first run if no user library exists yet.
enum Storage {

    private static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Earshot", isDirectory: true)
    }()

    private static let presetsURL = appSupportDir.appendingPathComponent("presets.json")
    private static let settingsURL = appSupportDir.appendingPathComponent("settings.json")

    // MARK: presets

    static func loadPresets() -> [EQPreset] {
        ensureDir()
        if !FileManager.default.fileExists(atPath: presetsURL.path) {
            seedFromBundle()
        }
        guard let data = try? Data(contentsOf: presetsURL) else { return [] }
        do {
            let file = try JSONDecoder().decode(PresetFile.self, from: data)
            return file.presets
        } catch {
            Log.write("preset load failed: \(error). Returning empty.")
            return []
        }
    }

    static func savePresets(_ presets: [EQPreset]) {
        ensureDir()
        let file = PresetFile(version: 1, presets: presets)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: presetsURL, options: .atomic)
        } catch {
            Log.write("preset save failed: \(error)")
        }
    }

    // MARK: settings

    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return .empty }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? .empty
    }

    static func saveSettings(_ s: AppSettings) {
        ensureDir()
        do {
            let data = try JSONEncoder().encode(s)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            Log.write("settings save failed: \(error)")
        }
    }

    // MARK: helpers

    private static func ensureDir() {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    private static func seedFromBundle() {
        guard let bundled = Bundle.main.url(forResource: "presets", withExtension: "json"),
              let data = try? Data(contentsOf: bundled) else {
            Log.write("no bundled presets to seed")
            return
        }
        try? data.write(to: presetsURL, options: .atomic)
        Log.write("seeded preset library from bundle")
    }
}

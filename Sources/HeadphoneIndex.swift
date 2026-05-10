import Foundation

/// Index of headphones whose oratory1990 measurements live in the AutoEQ
/// repository. Each entry points at a raw `ParametricEQ.txt` URL on GitHub.
/// We bundle a curated index (popular models) and fall back to fetching the
/// full directory listing on demand.
struct HeadphoneEntry: Codable, Identifiable, Hashable {
    var name: String
    var measurer: String  // "oratory1990", "harman", "crinacle", etc.
    var rawTxtURL: String

    var id: String { rawTxtURL }
}

enum HeadphoneIndex {

    static let bundledFile = "headphones"
    static let cacheDir: URL = {
        let lib = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("Earshot", isDirectory: true)
    }()

    /// AutoEq's GitHub repo. The oratory1990 measurements live in subdirs
    /// like `harman_over-ear_2018`, `harman_in-ear_2019v2`, etc. We list
    /// each subdir to find every headphone folder, then build raw-content
    /// URLs to the ParametricEQ.txt files inside.
    private static let oratoryAPI = "https://api.github.com/repos/jaakkopasanen/AutoEq/contents/results/oratory1990"
    private static let oratoryRaw = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990"
    private static let cacheStaleAfter: TimeInterval = 7 * 24 * 60 * 60   // 7 days

    static func load() -> [HeadphoneEntry] {
        if let cached = loadCached() { return cached }
        if let bundled = loadBundled() { return bundled }
        return []
    }

    /// True if the cache is missing or older than 7 days. Used by the
    /// search UI to decide whether to auto-refresh on open.
    static func cacheIsStale() -> Bool {
        let f = cacheDir.appendingPathComponent("headphones.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
              let date = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(date) > cacheStaleAfter
    }

    /// Fetches the live AutoEq oratory1990 catalog from GitHub and writes
    /// it to the cache. Throws on network/rate-limit failure; the bundled
    /// list still works as fallback in that case.
    static func refreshFromNetwork() async throws -> [HeadphoneEntry] {
        let measurementSets = try await fetchListing(urlString: oratoryAPI)
        var entries: [HeadphoneEntry] = []
        for set in measurementSets where set.type == "dir" {
            let setURL = "\(oratoryAPI)/\(percentEncode(set.name))"
            do {
                let headphones = try await fetchListing(urlString: setURL)
                for hp in headphones where hp.type == "dir" {
                    let folderEnc = percentEncode(hp.name)
                    let txtName = "\(percentEncode(hp.name))%20ParametricEQ.txt"
                    let raw = "\(oratoryRaw)/\(percentEncode(set.name))/\(folderEnc)/\(txtName)"
                    entries.append(HeadphoneEntry(name: hp.name, measurer: "oratory1990", rawTxtURL: raw))
                }
            } catch {
                Log.write("AutoEq listing for \(set.name) failed: \(error.localizedDescription)")
            }
        }
        // De-dupe by name keeping the first hit (different measurement
        // sets sometimes contain the same headphone; first hit wins).
        var seen = Set<String>()
        let unique = entries.filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !unique.isEmpty {
            saveCache(unique)
        }
        Log.write("AutoEq refresh: \(unique.count) headphones across \(measurementSets.count) measurement sets")
        return unique
    }

    private struct GitHubItem: Codable {
        let name: String
        let type: String
    }

    private static func fetchListing(urlString: String) async throws -> [GitHubItem] {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Earshot-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // GitHub returns 403 on rate-limit. Surface a useful error.
            if http.statusCode == 403 {
                throw NSError(domain: "Earshot.HeadphoneIndex", code: 403,
                              userInfo: [NSLocalizedDescriptionKey:
                                "GitHub rate limit hit. Try again in an hour."])
            }
            throw NSError(domain: "Earshot.HeadphoneIndex", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub returned \(http.statusCode)"])
        }
        return try JSONDecoder().decode([GitHubItem].self, from: data)
    }

    private static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private static func loadBundled() -> [HeadphoneEntry]? {
        guard let url = Bundle.main.url(forResource: bundledFile, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([HeadphoneEntry].self, from: data)
    }

    private static func loadCached() -> [HeadphoneEntry]? {
        let f = cacheDir.appendingPathComponent("headphones.json")
        guard let data = try? Data(contentsOf: f) else { return nil }
        return try? JSONDecoder().decode([HeadphoneEntry].self, from: data)
    }

    static func saveCache(_ entries: [HeadphoneEntry]) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let f = cacheDir.appendingPathComponent("headphones.json")
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: f, options: .atomic)
        }
    }

    /// Download the ParametricEQ.txt for a given entry and parse it. Caches
    /// the raw text under ~/Library/Caches/Earshot/.
    static func fetchPreset(for entry: HeadphoneEntry) async throws -> EQPreset {
        guard let url = URL(string: entry.rawTxtURL) else {
            throw URLError(.badURL)
        }
        // Stable on-disk key: Swift's hashValue is randomized per process,
        // so a hashValue-keyed filename never hits across launches. Derive
        // the cache name from the URL path instead.
        let stableKey = entry.rawTxtURL
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let cacheFile = cacheDir.appendingPathComponent("txt-\(stableKey).txt")
        let text: String
        if let cached = try? String(contentsOf: cacheFile, encoding: .utf8) {
            text = cached
        } else {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            text = String(data: data, encoding: .utf8) ?? ""
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? text.write(to: cacheFile, atomically: true, encoding: .utf8)
        }
        switch AutoEQFormat.decode(text: text, defaultName: entry.name) {
        case .success(var preset):
            preset.name = entry.name
            return preset
        case .failure(let error):
            throw error
        }
    }
}

import Foundation
import CryptoKit

private enum SHA256 {
    static func hash(_ s: String) -> String {
        let digest = CryptoKit.SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

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

    /// AutoEQ's GitHub repo. Each measurer (oratory1990, crinacle, …) has
    /// its own subtree under `results/<measurer>/<set>/<headphone>/…`.
    /// We enumerate each measurer in `measurers` and build raw-content
    /// URLs to the ParametricEQ.txt files inside. Order matters for
    /// de-dupe: the first measurer for a given headphone name wins.
    private static let apiBase = "https://api.github.com/repos/jaakkopasanen/AutoEq/contents/results"
    private static let rawBase = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results"
    private static let measurers: [String] = ["oratory1990", "crinacle"]
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

    /// Fetches the live AutoEQ catalog from GitHub across all configured
    /// measurers and writes it to the cache. Throws on network/rate-limit
    /// failure; the bundled list still works as fallback in that case.
    static func refreshFromNetwork() async throws -> [HeadphoneEntry] {
        var entries: [HeadphoneEntry] = []
        for measurer in measurers {
            let measurerAPI = "\(apiBase)/\(percentEncode(measurer))"
            let measurerRaw = "\(rawBase)/\(percentEncode(measurer))"
            let sets: [GitHubItem]
            do {
                sets = try await fetchListing(urlString: measurerAPI)
            } catch {
                Log.write("AutoEQ listing for \(measurer) failed: \(error.localizedDescription)")
                continue
            }
            for set in sets where set.type == "dir" {
                let setURL = "\(measurerAPI)/\(percentEncode(set.name))"
                do {
                    let headphones = try await fetchListing(urlString: setURL)
                    for hp in headphones where hp.type == "dir" {
                        let folderEnc = percentEncode(hp.name)
                        let txtName = "\(percentEncode(hp.name))%20ParametricEQ.txt"
                        let raw = "\(measurerRaw)/\(percentEncode(set.name))/\(folderEnc)/\(txtName)"
                        entries.append(HeadphoneEntry(name: hp.name,
                                                      measurer: measurer,
                                                      rawTxtURL: raw))
                    }
                } catch {
                    Log.write("AutoEQ listing for \(measurer)/\(set.name) failed: \(error.localizedDescription)")
                }
            }
        }
        // De-dupe by name keeping the first hit. Because measurers iterate
        // in declared order, the most-trusted source (oratory1990) wins
        // when a headphone is measured by multiple parties.
        var seen = Set<String>()
        let unique = entries.filter { seen.insert($0.name.lowercased()).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !unique.isEmpty {
            saveCache(unique)
        }
        Log.write("AutoEQ refresh: \(unique.count) headphones across \(measurers.count) measurers")
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
        // Defense in depth: refuse any URL that isn't on the AutoEQ raw
        // host. The catalog file lives in the app bundle and is fetched
        // from GitHub at runtime - both paths could in principle deliver
        // a doctored entry pointing somewhere arbitrary. Restricting to
        // raw.githubusercontent.com means a tampered catalog can still
        // only cause Earshot to fetch from the same host it always uses.
        guard url.scheme == "https",
              url.host == "raw.githubusercontent.com" else {
            throw URLError(.badURL)
        }
        // Stable on-disk key derived from the URL path. Hash the URL to
        // a fixed-length filename so a hostile entry can't path-traverse
        // out of the cache dir via crafted separators.
        let hash = SHA256.hash(entry.rawTxtURL)
        let cacheFile = cacheDir.appendingPathComponent("txt-\(hash).txt")
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

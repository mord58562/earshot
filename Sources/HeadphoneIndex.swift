import Foundation
import CryptoKit

private enum SHA256 {
    static func hash(_ s: String) -> String {
        let digest = CryptoKit.SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Index of headphones whose measurements live in either the AutoEQ
/// repository OR a squig.link database. Each entry points at a raw
/// preset/measurement URL; the import path resolves it to a PEQ at
/// runtime. We bundle a curated snapshot and refresh from the network
/// on demand.
struct HeadphoneEntry: Codable, Identifiable, Hashable {
    var name: String
    var measurer: String  // "oratory1990", "crinacle", "super-review", "hangout-5128", "listener", "vsg", ...
    var rawTxtURL: String
    /// AutoEQ `set` directory name when the entry comes from AutoEQ
    /// (e.g. "harman_over-ear_2018", "711 in-ear"). For squig-direct
    /// entries this is the squig site identifier (e.g. "vsg.squig.link").
    var set: String?
    /// Measurement rig in human-readable form: "GRAS 43AG", "IEC 60318-4
    /// (711)", "B&K 5128", "KB006x", etc. Derived from `set` on bundled
    /// data, supplied directly for squig-direct entries.
    var rig: String?
    /// Target curve the preset is tuned against: "Harman 2018 OE",
    /// "Harman 2019 IE", "IEF Neutral", "JM-1", etc. Optional - some
    /// AutoEQ sets don't encode the target in the folder name.
    var target: String?

    var id: String { rawTxtURL }

    /// Decoding tolerates the older bundled schema that had only
    /// {name, measurer, rawTxtURL}. New fields default to nil and the
    /// loader fills them by inspecting the URL.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.measurer = try c.decode(String.self, forKey: .measurer)
        self.rawTxtURL = try c.decode(String.self, forKey: .rawTxtURL)
        self.set = try c.decodeIfPresent(String.self, forKey: .set)
        self.rig = try c.decodeIfPresent(String.self, forKey: .rig)
        self.target = try c.decodeIfPresent(String.self, forKey: .target)
        // Backfill the derived fields from the URL path when the bundled
        // JSON predates the schema. Cheap, deterministic, runs once per
        // entry at load time.
        if (set == nil || rig == nil || target == nil),
           let derived = HeadphoneEntry.deriveMetadata(rawURL: rawTxtURL) {
            if self.set == nil    { self.set    = derived.set }
            if self.rig == nil    { self.rig    = derived.rig }
            if self.target == nil { self.target = derived.target }
        }
    }

    init(name: String, measurer: String, rawTxtURL: String,
         set: String? = nil, rig: String? = nil, target: String? = nil) {
        self.name = name
        self.measurer = measurer
        self.rawTxtURL = rawTxtURL
        self.set = set
        self.rig = rig
        self.target = target
    }

    enum CodingKeys: String, CodingKey {
        case name, measurer, rawTxtURL, set, rig, target
    }

    /// Short label for the search UI: "oratory1990 · GRAS · Harman 2018 OE".
    /// Skips fields that aren't known so old entries still read cleanly.
    var qualifier: String {
        var parts: [String] = [measurer]
        if let rig = rig, !rig.isEmpty { parts.append(rig) }
        if let target = target, !target.isEmpty { parts.append(target) }
        return parts.joined(separator: " · ")
    }

    /// Form factor (over-ear vs in-ear-shaped) of the headphone this entry
    /// measures. Used to split the target picker into two sections so the
    /// user is choosing inside the right ear coupler.
    enum FormFactor: String { case overEar, inEar }

    var formFactor: FormFactor {
        let s = (set ?? "").lowercased()
        let r = (rig ?? "").lowercased()
        // Explicit set names beat rig hints (e.g. a "5128 in-ear" set is
        // an IEM rig with a 5128 coupler).
        if s.contains("in-ear") || s.contains("iem") || s.contains("earbud") {
            return .inEar
        }
        if s.contains("over-ear") { return .overEar }
        // Rig fallback. 711 and KB006x couplers are IEM-side; GRAS / KEMAR
        // / HMS / EARS / B&K 5128 (default) are HP-side.
        if r.contains("711") || r.contains("kb006x") || r.contains("60318-4") {
            return .inEar
        }
        return .overEar
    }

    /// Which target-picker section this target name belongs in.
    static func formFactor(forTarget target: String) -> FormFactor {
        let s = target.lowercased()
        // Over-ear-shaped targets: anything with "OE" or "over-ear" plus
        // the diffuse / free field family (speaker-derived, conventionally
        // applied to over-ear).
        if s.contains("oe") || s.contains("over-ear")
            || s.contains("diffuse") || s.contains("free field") {
            return .overEar
        }
        // Everything Harman in-ear, IEF, JM-1, AutoEQ IE.
        return .inEar
    }

    /// Parse an AutoEQ raw URL of the form
    ///   .../results/<measurer>/<set>/<headphone>/<headphone>%20ParametricEQ.txt
    /// to extract the set name and infer rig + target from common
    /// patterns. Returns nil for non-AutoEQ URLs.
    static func deriveMetadata(rawURL: String) -> (set: String, rig: String?, target: String?)? {
        guard let url = URL(string: rawURL) else { return nil }
        let comps = url.pathComponents
        guard let idx = comps.firstIndex(of: "results"),
              comps.count > idx + 3 else { return nil }
        let setRaw = comps[idx + 2]
            .removingPercentEncoding ?? comps[idx + 2]
        let measurerRaw = (comps[idx + 1].removingPercentEncoding ?? comps[idx + 1])
        return (set: setRaw,
                rig: rigFromSet(setRaw),
                target: targetFromSet(setRaw, measurer: measurerRaw))
    }

    /// Public re-exports for callers (the refresh loop) that have a set
    /// name + measurer in hand but no full URL to parse.
    static func rigFromSetPublic(_ set: String) -> String? { rigFromSet(set) }
    static func targetFromSetPublic(_ set: String, measurer: String) -> String? {
        targetFromSet(set, measurer: measurer)
    }

    /// Heuristic. AutoEQ folder names are not formal, but the conventions
    /// are stable enough to catch the common cases. Unknown sets return
    /// nil so the UI just omits the rig column rather than guessing.
    private static func rigFromSet(_ set: String) -> String? {
        let lower = set.lowercased()
        if lower.contains("5128") { return "B&K 5128" }
        if lower.contains("gras 43ag-7") || lower.contains("gras_43ag-7") { return "GRAS 43AG-7" }
        if lower.contains("gras") { return "GRAS 43AG" }
        if lower.contains("kb006x") { return "KB006x" }
        if lower.contains("ears") { return "EARS" }
        if lower.contains("hms ii") || lower.contains("hms_ii") { return "HMS II.3" }
        if lower.contains("kemar") { return "KEMAR" }
        if lower.contains("711") || lower.contains("in-ear") || lower.contains("in_ear") {
            return "IEC 60318-4 (711)"
        }
        return nil
    }

    /// Infer the target curve AutoEQ tuned this PEQ against. AutoEQ
    /// folder names encode rig, not target; the target is convention
    /// per (measurer, rig). Mirror of `target_from(measurer, set_name)`
    /// in Tools/build_headphones_json.py so the runtime backfill and
    /// the bundled snapshot agree.
    private static func targetFromSet(_ set: String, measurer: String) -> String? {
        let s = set.lowercased()
        let m = measurer.lowercased()
        if s.contains("5128") {
            if s.contains("in-ear") || s.contains("iem") {
                return m.contains("crinacle") ? "JM-1" : "IEF Neutral"
            }
            if s.contains("over-ear") { return "Harman 2018 OE" }
            if s.contains("earbud") { return nil }
        }
        if s.contains("ief") { return "IEF Neutral" }
        if s.contains("jm-1") || s.contains("jm1") { return "JM-1" }
        if s.contains("711") || s.contains("in-ear") { return "Harman 2019 IE" }
        if s.contains("over-ear") || s.contains("gras")
            || s.contains("kemar") || s.contains("hms") || s.contains("ears") {
            return "Harman 2018 OE"
        }
        return nil
    }
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
    /// Every measurer AutoEQ currently mirrors. Order is preference for
    /// de-dupe (first-hit wins) - oratory1990's hand-tuned PEQs come first
    /// because they're the gold standard where they exist; the others fill
    /// out the long tail. Sources that 404 are silently skipped so the
    /// refresh keeps working as AutoEQ adds/removes directories.
    private static let measurers: [String] = [
        "oratory1990",
        "crinacle",
        "Super Review",
        "innerfidelity",
        "rtings",
        "Kuulokenurkka",
        "DHRME",
        "HypetheSonics",
        "jaytiss",
        "RikudouGoku",
        "kr0mka",
        "Bakkwatan",
        "Filk",
        "Harpo",
        "ToneDeafMonk",
        "Headphone.com Legacy",
        "Hi End Portable",
        "Ted's Squig Hoard",
        "Auriculares Argentina",
        "Regan Cipher",
        "freeryder05",
        "Fahryst",
        "Kazi",
    ]
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
    /// De-dupes by `(name, target)` so the same headphone measured by
    /// different reviewers shows up once per target curve rather than
    /// being squashed to a single entry.
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
                        let derived = HeadphoneEntry.deriveMetadata(rawURL: raw)
                        entries.append(HeadphoneEntry(
                            name: hp.name,
                            measurer: measurer,
                            rawTxtURL: raw,
                            set: derived?.set ?? set.name,
                            rig: derived?.rig
                                ?? HeadphoneEntry.rigFromSetPublic(set.name),
                            target: derived?.target
                                ?? HeadphoneEntry.targetFromSetPublic(set.name, measurer: measurer)))
                    }
                } catch {
                    Log.write("AutoEQ listing for \(measurer)/\(set.name) failed: \(error.localizedDescription)")
                }
            }
        }
        // De-dupe by (name, target). Same name + same target across
        // measurers collapses to the first hit (preference: oratory1990
        // first, then long-tail in declared order). Different targets
        // for the same headphone (e.g. "HD 600 (Harman 2018)" and
        // "HD 600 (oratory1990)") survive as separate rows so the user
        // can pick the tuning they prefer instead of being forced into
        // whichever measurement happened to come first.
        var seen = Set<String>()
        let unique = entries.filter {
            let key = "\($0.name.lowercased())|\($0.target?.lowercased() ?? "")"
            return seen.insert(key).inserted
        }
        .sorted {
            let a = $0.name.localizedStandardCompare($1.name)
            if a != .orderedSame { return a == .orderedAscending }
            return ($0.target ?? "") < ($1.target ?? "")
        }
        // Pull live squig sources that AutoEQ does NOT mirror. Each source
        // is fetched in parallel; any single failure (DNS hiccup, ATS, 404)
        // is logged and skipped without poisoning the whole refresh.
        var combined = unique
        await withTaskGroup(of: [HeadphoneEntry].self) { group in
            for source in SquigFetcher.liveSources {
                group.addTask {
                    do {
                        let entries = try await SquigFetcher.fetchCatalog(source)
                        Log.write("squig \(source.id): \(entries.count) entries")
                        return entries
                    } catch {
                        Log.write("squig \(source.id) failed: \(error.localizedDescription)")
                        return []
                    }
                }
            }
            for await batch in group {
                combined.append(contentsOf: batch)
            }
        }
        var seen2 = Set<String>()
        let final = combined.filter {
            let key = "\($0.name.lowercased())|\($0.measurer.lowercased())|\($0.target?.lowercased() ?? "")"
            return seen2.insert(key).inserted
        }
        .sorted {
            let a = $0.name.localizedStandardCompare($1.name)
            if a != .orderedSame { return a == .orderedAscending }
            return ($0.target ?? "") < ($1.target ?? "")
        }
        if !final.isEmpty {
            saveCache(final)
        }
        Log.write("library refresh: \(final.count) entries (\(unique.count) AutoEQ + \(final.count - unique.count) squig-direct)")
        return final
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

    /// Download the ParametricEQ.txt for a given entry and parse it,
    /// OR fit a PEQ on-device when the entry comes from a squig source
    /// that ships raw FR instead of pre-baked PEQ. Caches the raw text
    /// under ~/Library/Caches/Earshot/ (squig fits cache the resolved
    /// preset directly, not the FR data).
    static func fetchPreset(for entry: HeadphoneEntry) async throws -> EQPreset {
        // Squig-direct entries take a different path: no ParametricEQ.txt
        // exists; we fetch FR + target and run the on-device autofit.
        if let source = SquigFetcher.liveSources.first(where: { $0.id == entry.measurer }) {
            return try await SquigFetcher.fetchPreset(entry: entry, source: source)
        }
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
            // The user asked for imports to surface their target curve
            // in the name (e.g. "Sennheiser HD 600 (Harman 2018 OE)").
            // Falls back to a measurer-only suffix when the target isn't
            // known, and to the bare name when neither is known.
            preset.name = nameWithQualifier(entry: entry)
            return preset
        case .failure(let error):
            throw error
        }
    }

    static func nameWithQualifier(entry: HeadphoneEntry) -> String {
        if let target = entry.target, !target.isEmpty {
            return "\(entry.name) (\(target))"
        }
        if !entry.measurer.isEmpty {
            return "\(entry.name) (\(entry.measurer))"
        }
        return entry.name
    }
}

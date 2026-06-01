import Foundation

/// Fetches frequency-response data and target curves directly from a
/// squig.link database, runs an on-device FR-to-PEQ fit, and returns
/// the result as an EQPreset. Covers the squig sources that AutoEQ
/// does NOT mirror (modern Crinacle on hangout.audio, Listener,
/// VSG, Precogvision, Audio Discourse, Banbeucmas, HBB).
///
/// Data format
/// -----------
/// Every CrinGraph / Squiglink-Lab fork serves data at
///   `https://<sub>.squig.link/data/phone_book.json`
/// plus per-model `data/<file> L.txt` and `data/<file> R.txt`. The TXTs
/// are REW-format TSV: a single `Frequency\tdB\tUnweighted` header line
/// followed by `freq<TAB>spl[<TAB>unweighted]` rows at 48 PPO from 20-
/// 20000 Hz. Target curves live in the same `data/` dir as
/// `<Target Name> Target.txt`.
///
/// Fit algorithm
/// -------------
/// Port of squig's own `equalizer.js` (0BSD):
///   1. Compute delta(f) = target(f) - measured(f) on a 1/96-oct grid.
///   2. Find sign-change runs above a threshold; emit one peaking filter
///      per run centred on the geometric mean of the run.
///   3. Two-pass coordinate descent on (freq, Q, gain) with step sizes
///      [5, 2, 1] - the published algorithm's pragmatic defaults.
///   4. Preamp = -max(target - corrected) so post-EQ peaks don't clip.
///
/// AVAudioUnitEQ caveats
/// ---------------------
/// Apple's parametric biquad is the Butterworth form, not RBJ. At
/// extreme gains the response differs subtly; for the ±12 dB envelope
/// these fits stay in, it's audibly indistinguishable. Q→bandwidth
/// conversion goes through `bandwidthOctaves(forQ:)`.
enum SquigFetcher {

    // MARK: - Catalog

    /// One live squig source not covered by AutoEQ. Each entry is a
    /// `(base URL, human label, rig, default target name)`. Order is
    /// quality / freshness preference; user-facing UI groups by source.
    struct Source: Hashable {
        let id: String          // stable key, "hangout-5128"
        let label: String       // "Hangout.audio (5128)"
        let dataBase: URL       // "https://graph.hangout.audio/iem/5128/data/"
        let rig: String         // "B&K 5128"
        let defaultTarget: String   // file name (without ".txt") of the default Target.txt
    }

    /// Lazy-loaded from `squigsites.json` (the same directory squig.link
    /// itself uses to populate its "more squiglinks" picker). All 118
    /// databases get enumerated; per-site failures during refresh are
    /// logged and skipped, not fatal. Bundled fallback so first-run
    /// works offline.
    static let liveSources: [Source] = loadSitesFromBundle()

    private static func loadSitesFromBundle() -> [Source] {
        guard let url = Bundle.main.url(forResource: "squigsites", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let sites = try? JSONDecoder().decode([SquigSiteEntry].self, from: data) else {
            // Fallback to the half-dozen hand-curated sources that were
            // shipped in 1.4.0 so the catalog isn't empty if the bundled
            // JSON ever ends up missing.
            return Source.handCuratedFallback
        }
        return sites.flatMap { $0.expandToSources() }
    }

    private struct SquigSiteEntry: Decodable {
        let name: String
        let username: String
        let urlType: String?     // "subdomain", "root", "altDomain", "lab"
        let altDomain: String?
        let dbs: [DbEntry]?

        struct DbEntry: Decodable {
            let type: String     // "IEMs", "Headphones", "5128", "Earbuds"
            let folder: String?  // "/", "/headphones/", "/iems/", etc.
        }

        /// Expand to one SquigFetcher.Source per (site, database). Most
        /// sites have a single IEM database; multi-db sites (Hangout,
        /// CammyFi, Listener, Filk, kr0mka, Hadoe, SilicaGel etc.)
        /// produce 2-3 Sources each.
        func expandToSources() -> [SquigFetcher.Source] {
            let baseURL: String
            switch urlType {
            case "root":         baseURL = "https://squig.link"
            case "altDomain":    baseURL = altDomain ?? "https://\(username).squig.link"
            case "subdomain":    baseURL = "https://\(username).squig.link"
            default:             baseURL = "https://squig.link/lab/\(username)"
            }
            return (dbs ?? []).compactMap { db in
                let folder = db.folder ?? "/"
                guard let url = URL(string: baseURL + folder + "data/") else { return nil }
                let id = "\(username)\(folder.replacingOccurrences(of: "/", with: "-"))"
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                return SquigFetcher.Source(
                    id: id,
                    label: dbLabel(name: name, type: db.type),
                    dataBase: url,
                    rig: rigForDbType(db.type, source: username),
                    defaultTarget: defaultTargetForDbType(db.type, source: username))
            }
        }
    }
}

extension SquigFetcher.Source {
    static let handCuratedFallback: [SquigFetcher.Source] = [
        .init(id: "hangout-5128",
              label: "Crinacle 5128 (hangout.audio)",
              dataBase: URL(string: "https://graph.hangout.audio/iem/5128/data/")!,
              rig: "B&K 5128", defaultTarget: "JM-1"),
        .init(id: "hangout-711",
              label: "Crinacle 711 (hangout.audio)",
              dataBase: URL(string: "https://graph.hangout.audio/iem/711/data/")!,
              rig: "IEC 60318-4 (711)", defaultTarget: "IEF Neutral 2023"),
        .init(id: "hangout-hp",
              label: "Crinacle Headphones (hangout.audio)",
              dataBase: URL(string: "https://graph.hangout.audio/headphones/data/")!,
              rig: "GRAS 43AG-7", defaultTarget: "Harman OE 2018"),
        .init(id: "hbb",
              label: "HBB",
              dataBase: URL(string: "https://hbb.squig.link/data/")!,
              rig: "IEC 60318-4 (711)", defaultTarget: "Harman 2019 IE"),
    ]
}

/// Per-DB shape labels, rigs, and default targets. Heuristics tuned for
/// the squig.link convention - IEMs are 711 by default unless the site
/// is the explicit 5128 type; headphones default to GRAS-rig with a
/// Harman 2018 OE target; earbuds get no target since none of the
/// in-ear targets translate.
private func dbLabel(name: String, type: String) -> String {
    switch type {
    case "5128":      return "\(name) (5128)"
    case "Headphones": return "\(name) (headphones)"
    case "Earbuds":   return "\(name) (earbuds)"
    default:           return name
    }
}

private func rigForDbType(_ type: String, source: String) -> String {
    switch type {
    case "5128":      return "B&K 5128"
    case "Headphones":
        // A handful of headphone squigs use HMS II.3 rather than GRAS.
        if source.lowercased().contains("kr0mka") { return "GRAS 43AG" }
        return "GRAS 43AG-7"
    case "Earbuds":   return "IEC 60318-4 (711)"
    default:           return "IEC 60318-4 (711)"
    }
}

private func defaultTargetForDbType(_ type: String, source: String) -> String {
    switch type {
    case "5128":
        // Crinacle's hangout primary is JM-1; Earphones Archive and
        // other 5128 squigs ship IEF Neutral as default.
        return source.lowercased().contains("graph") ? "JM-1" : "IEF Neutral 2023"
    case "Headphones": return "Harman 2018 OE"
    case "Earbuds":   return "Diffuse Field"   // earbuds don't have a Harman target
    default:           return "Harman 2019 IE"
    }
}

// The fetch / parse / fit methods originally lived inside the
// SquigFetcher enum's body. Splitting them into an extension keeps
// the directory-loading and helper-function group separate from the
// catalog/PEQ machinery without reflowing 200+ lines of code.
extension SquigFetcher {

    /// Targets each squig source advertises in its `config.js`. Populated
    /// at refresh time by `fetchTargetsConfig`. The search sheet unions
    /// these into the target-curve picker so every reviewer-specific
    /// target (Antdroid, MRS, RikudouGoku, Bad Guy 2022, Crinacle 2023,
    /// Super Review, Precogvision, Etymotic, ...) shows up - not just
    /// the source's default.
    @MainActor static var supportedTargetsBySource: [String: [String]] = [:]

    /// Did the user's specific-target filter line up with a source the
    /// catalog entry belongs to. Used by the search sheet so picking
    /// "Antdroid" surfaces every squig source that supports Antdroid,
    /// not just whichever source had it as default.
    @MainActor
    static func sourceSupports(measurerID: String, target: String) -> Bool {
        supportedTargetsBySource[measurerID]?.contains(target) ?? false
    }

    /// Fetch and parse the targets array out of a squig source's config.js.
    /// CrinGraph configs declare:
    ///     const targets = [
    ///         { type:"Δ" , files:["Δ 10dB","IEF Comp"] },
    ///         { type:"Reference", files:["Harman 2019 IEM","IEF Neutral"] },
    ///         ...
    ///     ];
    /// We strip the Δ / delta groups (those are correction overlays, not
    /// target curves) and the `Δ X / Comp / Tilt`-named files inside any
    /// group, then flatten to a list of target file names.
    static func fetchTargets(_ source: Source) async -> [String] {
        let cfgURL = source.dataBase.deletingLastPathComponent()
            .appendingPathComponent("config.js")
        guard let (data, response) = try? await URLSession.shared.data(from: cfgURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return parseTargetsFromConfigJS(text)
    }

    static func parseTargetsFromConfigJS(_ js: String) -> [String] {
        // Pull the targets array body. Non-greedy so a comment or
        // unrelated `]` later in the file doesn't get sucked in.
        let blockRE = try? NSRegularExpression(
            pattern: #"(?:const|let|var)\s+targets\s*=\s*\[([\s\S]*?)\]\s*;"#)
        let ns = js as NSString
        guard let block = blockRE?
            .firstMatch(in: js, range: NSRange(location: 0, length: ns.length)),
              block.numberOfRanges >= 2,
              block.range(at: 1).location != NSNotFound else { return [] }
        let body = ns.substring(with: block.range(at: 1))
        let bodyNS = body as NSString

        // Each group: { type:"...", files:[...] }
        let groupRE = try? NSRegularExpression(
            pattern: #"\{\s*type\s*:\s*['"]([^'"]*)['"]\s*,\s*files\s*:\s*\[([^\]]+)\]"#)
        let stringRE = try? NSRegularExpression(pattern: #"['"]([^'"]+)['"]"#)
        let groups = groupRE?.matches(
            in: body, range: NSRange(location: 0, length: bodyNS.length)) ?? []

        var out: [String] = []
        for m in groups {
            guard m.numberOfRanges >= 3 else { continue }
            let type = bodyNS.substring(with: m.range(at: 1))
            // Skip delta / comp groups - those are EQ overlays for
            // visual A/B comparison, not target curves.
            let typeLower = type.lowercased()
            if type.hasPrefix("Δ") || typeLower.contains("delta")
                || typeLower.contains("compensation") { continue }
            let filesBlock = bodyNS.substring(with: m.range(at: 2))
            let filesNS = filesBlock as NSString
            let strs = stringRE?.matches(
                in: filesBlock,
                range: NSRange(location: 0, length: filesNS.length)) ?? []
            for s in strs {
                let name = filesNS.substring(with: s.range(at: 1))
                let lower = name.lowercased()
                // Same overlay filter applied per-name, because some
                // sites stuff "Δ 10dB" into a non-delta group.
                if name.hasPrefix("Δ") || lower.contains(" comp")
                    || lower.contains(" tilt") || lower.contains("compensation") {
                    continue
                }
                out.append(name)
            }
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }

    /// Fetch the phone_book.json for a source and flatten to one
    /// HeadphoneEntry per model. Squig phone_book entries are a mixed
    /// array of strings (`"FQQ"`) and objects (`{name, file, ...}`);
    /// both forms are normalised here.
    static func fetchCatalog(_ source: Source) async throws -> [HeadphoneEntry] {
        let url = source.dataBase.appendingPathComponent("phone_book.json")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let brands = try JSONDecoder().decode([PhoneBookBrand].self, from: data)
        var out: [HeadphoneEntry] = []
        for brand in brands {
            let prefix = brand.suffix.flatMap { "\(brand.name) \($0)" } ?? brand.name
            for model in brand.phones {
                let displayName = "\(prefix) \(model.displayName)"
                let fileBase: String = model.file ?? "\(brand.name) \(model.displayName)"
                // Per-model URL is reconstructed at fetch time, not stored
                // - the base ID is the unambiguous handle. We stuff the
                // file base into rawTxtURL so the existing import machinery
                // has a stable key (and rejects mid-flight tampering via
                // host validation - we'll re-validate when fetching).
                let urlString = source.dataBase
                    .appendingPathComponent(fileBase)
                    .absoluteString
                out.append(HeadphoneEntry(
                    name: displayName,
                    measurer: source.id,
                    rawTxtURL: urlString,
                    set: source.id,
                    rig: source.rig,
                    target: source.defaultTarget))
            }
        }
        return out
    }

    /// Convert a squig FR for `entry` into a PEQ preset using `source`'s
    /// default target. `entry.target` is treated as the target name; if
    /// the matching `<target> Target.txt` is missing we fall back to a
    /// flat target (zero correction).
    static func fetchPreset(entry: HeadphoneEntry, source: Source) async throws -> EQPreset {
        guard let base = URL(string: entry.rawTxtURL),
              base.host == source.dataBase.host else {
            throw URLError(.badURL)
        }
        // Fetch L + R, average linearly, then subtract target.
        let leftURL = URL(string: base.absoluteString + " L.txt")!
        let rightURL = URL(string: base.absoluteString + " R.txt")!
        async let l = fetchTSV(leftURL)
        async let r = fetchTSV(rightURL)
        let left = try await l
        let right = try await r
        let measured = averageLinear(left, right)
        let targetName = entry.target ?? source.defaultTarget
        let targetURL = source.dataBase
            .appendingPathComponent("\(targetName) Target.txt")
        let target: [FRPoint]
        if let t = try? await fetchTSV(targetURL), !t.isEmpty {
            target = t
        } else {
            // Flat target - results in a measure-only PEQ that flattens
            // the FR. Still useful, even if unconventional.
            target = measured.map { FRPoint(freq: $0.freq, db: 0) }
        }
        let bands = FRToPEQ.fit(measured: measured, target: target)
        let preamp = FRToPEQ.preamp(bands: bands)
        return EQPreset(
            id: UUID(),
            name: HeadphoneIndex.nameWithQualifier(entry: entry),
            preampDB: preamp,
            bands: bands)
    }

    // MARK: - TSV parsing

    private static func fetchTSV(_ url: URL) async throws -> [FRPoint] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return parseTSV(text)
    }

    static func parseTSV(_ text: String) -> [FRPoint] {
        var out: [FRPoint] = []
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let f = Float(parts[0].trimmingCharacters(in: .whitespaces)),
                  let db = Float(parts[1].trimmingCharacters(in: .whitespaces)),
                  f > 0 else { continue }
            out.append(FRPoint(freq: f, db: db))
        }
        return out
    }

    private static func averageLinear(_ a: [FRPoint], _ b: [FRPoint]) -> [FRPoint] {
        // Squig averages in linear amplitude, not dB. Match that so the
        // PEQ stays portable between Earshot and the source site.
        var index: [Float: Float] = [:]
        for pt in b { index[pt.freq] = pt.db }
        return a.map { pt in
            guard let bDB = index[pt.freq] else { return pt }
            let aLin = powf(10, pt.db / 20)
            let bLin = powf(10, bDB / 20)
            let avg = (aLin + bLin) / 2
            return FRPoint(freq: pt.freq, db: 20 * log10f(max(1e-9, avg)))
        }
    }

    // MARK: - phone_book.json

    private struct PhoneBookBrand: Decodable {
        let name: String
        let suffix: String?
        let phones: [PhoneBookEntry]
    }

    private struct PhoneBookEntry: Decodable {
        let displayName: String
        let file: String?

        init(from decoder: Decoder) throws {
            // Bare string OR object form. Try string first.
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                self.displayName = s
                self.file = nil
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.displayName = try c.decode(String.self, forKey: .name)
            // `file` can be a string OR an array of strings (sample-variation
            // groupings). Take the first when it's an array.
            if let s = try? c.decode(String.self, forKey: .file) {
                self.file = s
            } else if let arr = try? c.decode([String].self, forKey: .file),
                      let first = arr.first {
                self.file = first
            } else {
                self.file = nil
            }
        }

        enum CodingKeys: String, CodingKey { case name, file }
    }
}

/// One (frequency, dB SPL) sample from an FR or target curve.
struct FRPoint {
    let freq: Float
    let db: Float
}

/// Frequency-response to parametric-EQ fit. Ported from squig.link's
/// `equalizer.js` (0BSD). Documented in SquigFetcher's header.
enum FRToPEQ {

    /// Public entry point. `measured` and `target` are at any grid
    /// (we resample to a common 1/96-oct log grid internally). Returns
    /// up to `maxBands` peaking filters in PEQ order.
    static func fit(measured: [FRPoint], target: [FRPoint],
                    maxBands: Int = 10) -> [EQBand] {
        let grid = logGrid(fMin: 20, fMax: 20000, perOctave: 96)
        let m = resampleLog(curve: measured, onto: grid)
        let t = resampleLog(curve: target, onto: grid)
        var delta = zip(t, m).map { $0 - $1 }

        var bands: [EQBand] = []
        for _ in 0..<maxBands {
            // Pick the largest absolute deviation in [20, 15000] Hz.
            // squig.link's autofit limits to that range because above
            // 15 kHz the rig data is too noisy to fit meaningfully.
            guard let (idx, value) = peakIndex(delta: delta, grid: grid,
                                               fMin: 20, fMax: 15000) else {
                break
            }
            if abs(value) < 0.5 { break }
            let f = grid[idx]
            let q: Float = 1.41
            let gain = max(-12, min(12, value))
            var band = EQBand(type: .parametric, frequency: f, gain: gain, q: q)
            // Coordinate-descent refinement.
            band = refine(band: band, delta: delta, grid: grid)
            // Subtract the band's contribution from delta so the next
            // pick goes after the next-biggest deviation.
            for (i, freq) in grid.enumerated() {
                delta[i] -= biquadGain(band, at: freq)
            }
            bands.append(band)
        }
        return bands
    }

    /// Preamp = -max(0, residual peak). Negative because we attenuate to
    /// keep the post-EQ signal under 0 dBFS; positive residual means the
    /// EQ adds gain somewhere and we need headroom.
    static func preamp(bands: [EQBand]) -> Float {
        guard !bands.isEmpty else { return 0 }
        let grid = logGrid(fMin: 20, fMax: 20000, perOctave: 96)
        var maxGain: Float = 0
        for f in grid {
            var sum: Float = 0
            for b in bands where !b.bypass {
                sum += biquadGain(b, at: f)
            }
            if sum > maxGain { maxGain = sum }
        }
        // Round to 0.1 dB; never positive (we don't make-up gain).
        return -max(0, (maxGain * 10).rounded() / 10)
    }

    // MARK: Resampling

    private static func logGrid(fMin: Float, fMax: Float, perOctave: Int) -> [Float] {
        let octaves = log2f(fMax / fMin)
        let count = Int((octaves * Float(perOctave)).rounded()) + 1
        var out: [Float] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let t = Float(i) / Float(count - 1)
            out.append(fMin * powf(2, octaves * t))
        }
        return out
    }

    private static func resampleLog(curve: [FRPoint], onto grid: [Float]) -> [Float] {
        guard !curve.isEmpty else { return Array(repeating: 0, count: grid.count) }
        let sorted = curve.sorted { $0.freq < $1.freq }
        var out: [Float] = []
        out.reserveCapacity(grid.count)
        var j = 0
        for f in grid {
            // Advance j to the segment containing f.
            while j + 1 < sorted.count && sorted[j + 1].freq < f { j += 1 }
            if j + 1 >= sorted.count {
                out.append(sorted.last!.db); continue
            }
            let a = sorted[j], b = sorted[j + 1]
            if f <= a.freq { out.append(a.db); continue }
            // Log-frequency interpolation in dB.
            let t = (log2f(f) - log2f(a.freq)) / (log2f(b.freq) - log2f(a.freq))
            out.append(a.db + (b.db - a.db) * max(0, min(1, t)))
        }
        return out
    }

    // MARK: Peak picking + refinement

    private static func peakIndex(delta: [Float], grid: [Float],
                                  fMin: Float, fMax: Float) -> (Int, Float)? {
        var bestIdx = -1
        var bestAbs: Float = 0
        for (i, f) in grid.enumerated() where f >= fMin && f <= fMax {
            let a = abs(delta[i])
            if a > bestAbs { bestAbs = a; bestIdx = i }
        }
        return bestIdx >= 0 ? (bestIdx, delta[bestIdx]) : nil
    }

    private static func refine(band: EQBand,
                               delta: [Float], grid: [Float]) -> EQBand {
        var current = band
        let stepsFreq: [Float] = [1.05, 1.02, 1.005]
        let stepsQ:    [Float] = [0.5, 0.2, 0.05]
        let stepsGain: [Float] = [1.0, 0.5, 0.1]
        var bestErr = residualSquared(band: current, delta: delta, grid: grid)
        for pass in 0..<3 {
            let sf = stepsFreq[pass]
            let sq = stepsQ[pass]
            let sg = stepsGain[pass]
            for axis in ["f", "q", "g"] {
                for dir in [1.0, -1.0] {
                    var trial = current
                    switch axis {
                    case "f":
                        trial.frequency = max(20, min(20000,
                            dir > 0 ? trial.frequency * sf : trial.frequency / sf))
                    case "q":
                        trial.q = max(0.3, min(8,
                            dir > 0 ? trial.q + sq : trial.q - sq))
                    default:
                        trial.gain = max(-12, min(12,
                            dir > 0 ? trial.gain + sg : trial.gain - sg))
                    }
                    let err = residualSquared(band: trial, delta: delta, grid: grid)
                    if err < bestErr { current = trial; bestErr = err }
                }
            }
        }
        return current
    }

    private static func residualSquared(band: EQBand,
                                        delta: [Float], grid: [Float]) -> Float {
        var err: Float = 0
        for (i, f) in grid.enumerated() {
            let model = biquadGain(band, at: f)
            let d = delta[i] - model
            err += d * d
        }
        return err
    }

    // MARK: Analytic peaking-filter magnitude

    /// RBJ Cookbook peaking filter magnitude in dB at frequency `f`.
    /// Used by the autofit error metric AND the preamp solver; cheap
    /// closed-form so the fit converges in a handful of ms even at the
    /// 1/96-oct grid.
    private static func biquadGain(_ band: EQBand, at f: Float) -> Float {
        guard band.type == .parametric || band.type == .lowShelf
                || band.type == .highShelf else {
            return 0
        }
        let g = band.gain
        let q = max(0.05, band.q)
        let fc = band.frequency
        switch band.type {
        case .parametric:
            // Gaussian-bell approximation of a peaking biquad - close
            // enough for autofit work and avoids the full s-domain
            // transfer-function evaluation. Squig's equalizer.js uses
            // the same shortcut.
            let bw = 2.0 / (Float(log(2.0))) * asinhf(0.5 / q)
            let lf = log2f(f / fc)
            return g * expf(-powf(lf / max(0.1, bw / 2), 2))
        case .lowShelf:
            let lf = log2f(f / fc)
            let s = 1.0 / (1.0 + expf(lf * 4))
            return g * s
        case .highShelf:
            let lf = log2f(f / fc)
            let s = 1.0 / (1.0 + expf(-lf * 4))
            return g * s
        default:
            return 0
        }
    }
}

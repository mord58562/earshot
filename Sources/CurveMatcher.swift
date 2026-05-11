import Foundation

/// Fits a small number of parametric biquad filters to approximate a
/// desired correction curve in dB. Used by:
///
///   - Room-correction flow: measure FR at the listening position with
///     REW + a calibrated mic, pick a target (Harman / B&K / flat),
///     correction = target - measured, fit biquads to the correction.
///   - Headphone-target match: measured FR vs target curve, same math.
///   - Generic curve match: user supplies any target, we fit bands to it
///     starting from a flat EQ.
///
/// Algorithm
/// =========
///
/// Greedy peak-picking. Each iteration:
///   1. Find the frequency where the residual error has the largest
///      |dB| value.
///   2. Estimate the width of the bump/dip in residual at that point by
///      walking outward until residual decays to half (in dB) of the
///      peak. Frequency ratio of the half-points -> Q estimate.
///   3. Add a peaking biquad with gain == residual peak and Q == that
///      estimate.
///   4. Subtract the new band's modeled response from the residual.
///   5. Repeat until the residual is below threshold or we hit the band
///      cap.
///
/// AutoEQ's reference implementation runs scipy.optimize.curve_fit
/// across all bands jointly after the greedy init for ~10-20% lower
/// residual. Doing that in pure Swift without a real optimizer would be
/// disproportionate; greedy alone covers smooth room-response and
/// headphone-correction targets well in practice.
enum CurveMatcher {

    /// Match a target dB curve (sampled on `freqs`) starting from `flat`
    /// EQ (no existing bands). Returns up to `maxBands` peaking filters
    /// whose combined response approximates `target` within
    /// `residualThresholdDB`.
    ///
    /// - Parameters:
    ///   - freqs: frequency points in Hz, monotonically increasing,
    ///     log-spaced is best. Typical: 96 - 256 points from 20 Hz to
    ///     20 kHz.
    ///   - target: desired dB level at each frequency. Same length as
    ///     `freqs`.
    ///   - maxBands: cap on how many bands to add.
    ///   - residualThresholdDB: stop when the largest |residual| drops
    ///     below this.
    static func fitBands(freqs: [Float],
                         target: [Float],
                         maxBands: Int = 10,
                         residualThresholdDB: Float = 0.5) -> [EQBand] {
        precondition(freqs.count == target.count, "freqs and target must align")
        precondition(freqs.count > 4, "need at least a handful of sample points")

        var residual = target
        var bands: [EQBand] = []

        for _ in 0..<maxBands {
            // Find index of the largest absolute residual.
            var bestI = 0
            var bestAbs: Float = 0
            for i in 0..<residual.count {
                let a = abs(residual[i])
                if a > bestAbs { bestAbs = a; bestI = i }
            }
            if bestAbs < residualThresholdDB { break }

            let fc = freqs[bestI]
            let gain = residual[bestI]
            let q = estimateQ(residual: residual, freqs: freqs, peakIndex: bestI)

            // Clamp into Earshot's accepted ranges.
            let clampedFreq = max(20, min(22000, fc))
            let clampedGain = max(-24, min(24, gain))
            let clampedQ = max(0.3, min(6.0, q))

            let band = EQBand(type: .parametric,
                              frequency: clampedFreq,
                              gain: clampedGain,
                              q: clampedQ)
            bands.append(band)

            // Subtract the new band's response from the residual.
            for i in 0..<residual.count {
                residual[i] -= bandResponseDB(band, at: freqs[i])
            }
        }

        return bands
    }

    /// Estimate a peaking-filter Q from the bump width in the residual.
    /// We walk outward from the peak until the residual magnitude falls
    /// to half the peak. The frequency ratio of those two -3 dB-ish
    /// points gives bandwidth in octaves, which we convert to Q.
    private static func estimateQ(residual: [Float], freqs: [Float], peakIndex: Int) -> Float {
        let peak = residual[peakIndex]
        let sign: Float = peak >= 0 ? 1 : -1
        let halfTarget = peak * 0.5
        // sign-aware half-target: for a positive peak, "half" is the y-value
        // that's still positive but at half height; for a negative trough,
        // it's a less-negative value. Below uses sign-flipped compare so
        // the same walk works for both peaks and dips.
        func isBelowHalf(_ y: Float) -> Bool {
            sign > 0 ? (y < halfTarget) : (y > halfTarget)
        }

        var lowI = peakIndex
        while lowI > 0, !isBelowHalf(residual[lowI]) { lowI -= 1 }
        var highI = peakIndex
        while highI < residual.count - 1, !isBelowHalf(residual[highI]) { highI += 1 }

        let fLow = freqs[lowI]
        let fHigh = freqs[highI]
        guard fHigh > fLow, fLow > 0 else { return 1.0 }
        // bandwidth in octaves
        let bwOct = log2f(fHigh / fLow)
        // Standard parametric-EQ bandwidth-to-Q. Inverse of the formula
        // used elsewhere in the app for the EQ visualiser.
        let q = sqrtf(powf(2, bwOct)) / (powf(2, bwOct) - 1)
        return q.isFinite ? q : 1.0
    }

    /// Closed-form approximation of a peaking biquad's dB response at
    /// `f`. Matches the model EQCurveView uses for visualisation - good
    /// enough for the fitter, since the real AVAudioUnitEQ biquad is
    /// already well-approximated by a Gaussian-on-log-frequency.
    private static func bandResponseDB(_ b: EQBand, at f: Float) -> Float {
        let fc = b.frequency
        let bw = bandwidthOctaves(forQ: max(0.1, b.q))
        let lf = log2f(f / fc)
        let env = expf(-powf(lf / max(0.1, bw / 2), 2))
        return b.gain * env
    }

    /// Generate a log-spaced frequency grid from `fMin` to `fMax`.
    /// Default 192 points: dense enough to catch narrow features, cheap
    /// enough that a 10-band greedy fit runs in single-digit ms.
    static func logFreqGrid(fMin: Float = 20, fMax: Float = 20000,
                            points: Int = 192) -> [Float] {
        let logMin = log10f(fMin)
        let logMax = log10f(fMax)
        return (0..<points).map { i in
            let t = Float(i) / Float(points - 1)
            return powf(10, logMin + t * (logMax - logMin))
        }
    }
}

// MARK: - Target curves

/// A target frequency response (dB at each frequency). Used to compute
/// the correction needed: `correction = target - measured`.
struct TargetCurve {
    let name: String
    let dB: (Float) -> Float

    static let flat = TargetCurve(name: "Flat") { _ in 0 }

    /// B&K 1974 "preferred listening response" - a gentle ~1 dB/octave
    /// roll-off above 1 kHz. Closer to what humans want from "flat in a
    /// room" than a literal flat curve.
    static let bk1974 = TargetCurve(name: "B&K 1974") { f in
        if f <= 1000 { return 0 }
        // -1 dB/octave above 1 kHz
        return -log2f(f / 1000)
    }

    /// Harman 2018 over-ear - the canonical target for over-ear
    /// headphone EQ. Sketched here as a piecewise approximation; the
    /// real curve is a published table interpolated, but this captures
    /// the shape (bass shelf, slight presence boost, treble roll-off)
    /// well enough for matching.
    static let harman = TargetCurve(name: "Harman 2018") { f in
        // Bass shelf: +5 dB below 80 Hz, ramping down to 0 at 200 Hz.
        // Slight upper-mid bump around 3 kHz (+3 dB), gradual roll-off
        // above 10 kHz.
        let bass: Float = {
            if f >= 200 { return 0 }
            if f <= 80 { return 5 }
            let t = (200 - f) / (200 - 80)
            return 5 * t
        }()
        let presence: Float = {
            // bell-ish around 3 kHz, width 1.5 oct, +3 dB peak
            let lf = log2f(f / 3000)
            return 3 * expf(-powf(lf / 0.75, 2))
        }()
        let treble: Float = {
            if f <= 10000 { return 0 }
            // -2 dB/octave above 10 kHz, capped
            let drop = -2 * log2f(f / 10000)
            return max(drop, -6)
        }()
        return bass + presence + treble
    }
}

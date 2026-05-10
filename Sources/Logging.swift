import Foundation

/// File log at ~/Library/Logs/Earshot/Earshot.log, mirrored to NSLog. Rotates
/// at ~512 KB by trimming the oldest half.
enum Log {

    static func write(_ msg: String) {
        NSLog("%@", "Earshot: " + msg)
        guard let url = logURL else { return }
        let line = "\(Self.timestamp()) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path),
           let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
            rotateIfNeeded(url)
        } else {
            try? data.write(to: url)
        }
    }

    static let logURL: URL? = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        return lib?.appendingPathComponent("Logs/Earshot/Earshot.log")
    }()

    private static func rotateIfNeeded(_ url: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 512 * 1024 else { return }
        guard let data = try? Data(contentsOf: url), let str = String(data: data, encoding: .utf8) else { return }
        let half = str.suffix(str.count / 2)
        try? Data(half.utf8).write(to: url)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }
}

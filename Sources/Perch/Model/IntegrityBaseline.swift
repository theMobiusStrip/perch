import Foundation
import PerchCore

/// Persisted "I looked at this" record for the integrity page: item id →
/// acknowledged fingerprint. Not an approval and not a mute — the scanner
/// suppresses a flag only while the surface still matches the acknowledged
/// fingerprint, so any real change re-flags on the next scan.
struct IntegrityBaseline: Codable {
    var acks: [String: String] = [:]

    static var file: URL { PerchPaths.appSupportDir.appendingPathComponent("integrity-baseline.json") }

    static func load(from url: URL = file) -> IntegrityBaseline {
        guard let data = try? Data(contentsOf: url),
              let baseline = try? JSONDecoder().decode(IntegrityBaseline.self, from: data) else {
            return IntegrityBaseline()
        }
        return baseline
    }

    func save(to url: URL = file) throws {
        try PerchPaths.ensureAppSupportDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

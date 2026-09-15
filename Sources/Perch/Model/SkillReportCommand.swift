import Darwin
import Foundation

enum SkillReportCommand {
    struct InvalidProject: LocalizedError {
        let path: String
        let reason: String

        var errorDescription: String? {
            let cleanPath = path.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? " " : String($0)
            }.joined()
            return "Cannot audit project \(cleanPath): \(reason)."
        }
    }

    /// A missing optional skills directory is normal; a missing requested
    /// project is not. Validate before scanning or loading review markers.
    static func projects(from paths: [String]) throws -> [URL] {
        try paths.map { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw InvalidProject(path: url.path, reason: String(cString: strerror(errno)))
            }
            defer { close(descriptor) }
            guard access(url.path, X_OK) == 0 else {
                throw InvalidProject(path: url.path, reason: String(cString: strerror(errno)))
            }
            return url
        }
    }
}

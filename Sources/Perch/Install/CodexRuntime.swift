import Foundation
import PerchCore

/// A probe and any subsequent repair use the same executable and config home.
struct CodexRuntime: Equatable, Sendable {
    let executable: URL
    let label: String
    let codexHome: URL

    func configure(_ process: Process, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                     "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/bin", "/usr/bin", "/bin"]
        environment["PATH"] = ([environment["PATH"] ?? ""] + extra).filter { !$0.isEmpty }.joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    }

    static func discover(codexHome: URL = PerchPaths.codexHomeDir) -> [CodexRuntime] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        return discover(home: home, path: ProcessInfo.processInfo.environment["PATH"] ?? "",
                        codexHome: codexHome, isExecutable: fm.isExecutableFile(atPath:),
                        canonicalPath: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    }

    /// Keep desktop and CLI coverage distinct. A stale PATH CLI must not hide
    /// the desktop runtime's newly supported hooks.
    static func discover(home: String, path: String, codexHome: URL,
                         isExecutable: (String) -> Bool,
                         canonicalPath: (String) -> String) -> [CodexRuntime] {
        var candidates: [(String, String)] = []
        for app in ["ChatGPT", "Codex"] {
            for directory in ["/Applications", "\(home)/Applications"] {
                candidates.append(("\(directory)/\(app).app/Contents/Resources/codex", "\(app) desktop"))
            }
        }
        let cliDirectories = path.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/bin"]
        if let cli = cliDirectories.map({ "\($0)/codex" }).first(where: isExecutable) {
            candidates.append((cli, "Codex CLI"))
        }
        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            guard isExecutable(candidate.0) else { return nil }
            let resolved = canonicalPath(candidate.0)
            guard seen.insert(resolved).inserted else { return nil }
            return CodexRuntime(executable: URL(fileURLWithPath: candidate.0), label: candidate.1,
                                codexHome: codexHome)
        }
    }
}

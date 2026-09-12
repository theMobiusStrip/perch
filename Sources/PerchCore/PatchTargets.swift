import Foundation

/// Extracts file-operation metadata, never patch contents or shell commands.
/// Mirrors apply_patch's header boundaries, including its legacy EOF wrapper.
/// This is not a filesystem/applicability check and does not resolve symlinks.
enum PatchTargets {
    struct Target {
        let path: String
        var removesFile: Bool
    }

    private enum Mode { case start, add, delete, update }

    static func parse(_ patch: String) -> [Target] {
        var lines = patch.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.count >= 4, ["<<EOF", "<<'EOF'", "<<\"EOF\""].contains(lines[0]),
           lines.last?.hasSuffix("EOF") == true {
            lines.removeLast()
            lines.removeFirst()
        }
        guard lines.count >= 2,
              lines[0].trimmingCharacters(in: .whitespacesAndNewlines) == "*** Begin Patch",
              lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "*** End Patch"
        else { return [] }

        var targets: [Target] = []
        var mode = Mode.start
        var hasEnvironment = false
        var canMove = false
        var chunkHasLines: Bool?
        var afterEOF = false
        var ended = false
        for line in lines.dropFirst().dropLast() {
            if ended {
                guard line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
                continue
            }
            // In update bodies, a leading space is a context-line marker.
            // Trimming it would turn source text into a fake file operation.
            let marker = mode == .update
                ? String(line.reversed().drop(while: { $0.isWhitespace }).reversed())
                : line.trimmingCharacters(in: .whitespacesAndNewlines)

            if marker == "*** End Patch" {
                guard mode != .update || chunkHasLines == true else { return [] }
                ended = true
                continue
            }

            if mode == .start, marker.hasPrefix("*** Environment ID:") {
                guard !hasEnvironment,
                      !marker.dropFirst("*** Environment ID:".count)
                        .trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
                hasEnvironment = true
                continue
            }

            let headers: [(String, Mode)] = [("*** Add File: ", .add),
                                             ("*** Delete File: ", .delete),
                                             ("*** Update File: ", .update)]
            if let (prefix, next) = headers.first(where: { marker.hasPrefix($0.0) }) {
                guard mode != .update || chunkHasLines == true else { return [] }
                let path = String(marker.dropFirst(prefix.count))
                guard !path.isEmpty else { return [] }
                targets.append(Target(path: path, removesFile: next == .delete))
                mode = next
                canMove = next == .update
                chunkHasLines = nil
                afterEOF = false
                continue
            }

            switch mode {
            case .start, .delete: return []
            case .add:
                guard line.hasPrefix("+") else { return [] }
            case .update:
                if afterEOF {
                    if marker.isEmpty { continue }
                    guard marker == "@@" || marker.hasPrefix("@@ ") else { return [] }
                }
                if canMove, marker.hasPrefix("*** Move to: ") {
                    let path = String(marker.dropFirst("*** Move to: ".count))
                    guard !path.isEmpty else { return [] }
                    targets[targets.count - 1].removesFile = true
                    targets.append(Target(path: path, removesFile: false))
                    canMove = false
                    continue
                }
                if marker == "@@" || marker.hasPrefix("@@ ") {
                    guard chunkHasLines != false else { return [] }
                    canMove = false
                    chunkHasLines = false
                    afterEOF = false
                } else if marker == "*** End of File" {
                    guard chunkHasLines != false else { return [] }
                    // Upstream accepts an early EOF marker before any chunk
                    // as a no-op; it does not end that update hunk.
                    if chunkHasLines == true { afterEOF = true }
                } else {
                    guard line.isEmpty || line.hasPrefix(" ") || line.hasPrefix("+")
                            || line.hasPrefix("-") else { return [] }
                    canMove = false
                    chunkHasLines = true
                }
            }
        }
        guard mode != .update || chunkHasLines == true else { return [] }
        return targets
    }

    /// Lexical resolution only: patch paths do not expand '~', '$', or quotes.
    /// Without cwd, retain a relative prefix so .codex/.ssh rules still match.
    static func resolve(_ path: String, cwd: String?) -> String {
        let joined = path.hasPrefix("/") ? path : (cwd ?? ".") + "/" + path
        let absolute = joined.hasPrefix("/")
        var parts: [Substring] = []
        for part in joined.split(separator: "/") {
            if part == "." { continue }
            if part == "..", let last = parts.last, last != ".." {
                parts.removeLast()
            } else if part != ".." || !absolute {
                parts.append(part)
            }
        }
        return (absolute ? "/" : "./") + parts.joined(separator: "/")
    }
}

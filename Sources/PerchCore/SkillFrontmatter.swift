import Foundation

/// A deliberately small YAML reader. Unsupported YAML is reported separately
/// from known invalid fields; it must never turn a valid skill into INVALID.
public struct SkillFrontmatter: Equatable, Sendable {
    public var name: String?
    public var description: String?
    public var invalid: [String] = []
    public var unsupported: [String] = []

    public static func parse(_ text: String) -> SkillFrontmatter {
        var result = SkillFrontmatter()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            // Claude permits plain Markdown and derives defaults from the
            // directory/body. The scanner applies Codex's required fields.
            return result
        }
        guard let end = lines.indices.dropFirst().first(where: {
            lines[$0] == "---" || lines[$0] == "..."
        }) else {
            result.invalid.append("YAML frontmatter has no closing delimiter.")
            return result
        }
        var seen = Set<String>()
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let (key, value) = mappingEntry(line) else {
                result.unsupported.append("YAML structure could not be fully interpreted.")
                continue
            }
            var continuation: [String] = []
            while index < end {
                let next = lines[index]
                if !next.isEmpty && !next.hasPrefix(" ") && !next.hasPrefix("\t") { break }
                continuation.append(next)
                index += 1
            }
            guard seen.insert(key).inserted else {
                result.invalid.append("Duplicate YAML field: \(key).")
                continue
            }
            guard key == "name" || key == "description" else {
                // Ignored values still need a recognized structure: otherwise
                // malformed metadata could make the entire manifest unreadable.
                if !supportsIgnoredValue(value, continuation: continuation, depth: 0) {
                    result.unsupported.append("YAML structure in \(key) needs a full YAML parser.")
                }
                continue
            }
            let meaningful = continuation.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            var scalar: String?
            if value.hasPrefix("|") || value.hasPrefix(">") {
                let indicator = value.split(separator: "#", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces) ?? value
                guard ["|", "|-", "|+", ">", ">-", ">+"].contains(indicator),
                      supportsIgnoredValue(value, continuation: continuation, depth: 0) else {
                    result.unsupported.append("Unsupported block scalar in \(key).")
                    continue
                }
                let indentation = meaningful.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
                let body = continuation.map { String($0.dropFirst(min(indentation, $0.count))) }
                if value.hasPrefix(">") {
                    var folded = ""
                    for (offset, part) in body.enumerated() {
                        if offset > 0 {
                            let prior = body[offset - 1]
                            folded += part.isEmpty || prior.isEmpty || part.hasPrefix(" ") || prior.hasPrefix(" ") ? "\n" : " "
                        }
                        folded += part
                    }
                    scalar = folded.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    scalar = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if !meaningful.isEmpty {
                result.unsupported.append("Multiline or nested \(key) needs a full YAML parser.")
            } else if value.hasPrefix("\"") {
                // JSON string syntax is a safe subset of YAML double quoting.
                if let data = value.data(using: .utf8),
                   let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
                    scalar = decoded
                } else {
                    result.unsupported.append("Unsupported quoted scalar in \(key).")
                }
            } else if value.hasPrefix("'") {
                if value.count >= 2 && value.hasSuffix("'") {
                    let body = String(value.dropFirst().dropLast())
                    if body.replacingOccurrences(of: "''", with: "").contains("'") {
                        result.unsupported.append("Unsupported quoted scalar in \(key).")
                    } else { scalar = body.replacingOccurrences(of: "''", with: "'") }
                } else { result.unsupported.append("Unsupported quoted scalar in \(key).") }
            } else if value.hasPrefix("[") || value.hasPrefix("{") {
                result.invalid.append("\(key) must be a string, not a collection.")
            } else if value.hasPrefix("&") || value.hasPrefix("*") || value.hasPrefix("!") || value.hasPrefix("#") {
                result.unsupported.append("YAML tags, aliases or scalar syntax in \(key) need a full YAML parser.")
            } else {
                let plain = value.components(separatedBy: " #").first?.trimmingCharacters(in: .whitespaces) ?? ""
                if !supportsPlainScalar(plain) {
                    result.unsupported.append("Unsupported plain scalar in \(key).")
                } else if plain.isEmpty || ["null", "~", "true", "false"].contains(plain.lowercased()) || isYAMLNumber(plain) {
                    result.invalid.append("\(key) must be a nonempty string.")
                } else { scalar = plain }
            }
            if let scalar {
                if scalar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.invalid.append("\(key) must be a nonempty string.")
                } else if key == "name" { result.name = scalar }
                else { result.description = scalar }
            }
        }
        result.unsupported = Array(Set(result.unsupported)).sorted()
        return result
    }

    /// Restrict keys to a simple block-mapping subset. In YAML, `name:demo`
    /// is a plain scalar, not a mapping entry; flow mappings need a full parser.
    private static func mappingEntry(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { return nil }
        let remainder = line[line.index(after: colon)...]
        guard remainder.isEmpty || remainder.first == " " || remainder.first == "\t" else { return nil }
        return (key, remainder.trimmingCharacters(in: .whitespaces))
    }

    /// Validate only the common ignored-metadata subset: scalars, indented
    /// mappings, and scalar sequences. Anything else is explicitly incomplete.
    private static func supportsIgnoredValue(_ value: String, continuation: [String], depth: Int) -> Bool {
        guard depth < 32, !continuation.contains(where: { $0.prefix(while: { $0.isWhitespace }).contains("\t") }) else { return false }
        let significant = continuation.filter {
            let text = $0.trimmingCharacters(in: .whitespaces)
            return !text.isEmpty && !text.hasPrefix("#")
        }
        if value.hasPrefix("|") || value.hasPrefix(">") {
            let indicator = value.components(separatedBy: " #").first ?? value
            guard ["|", "|-", "|+", ">", ">-", ">+"].contains(indicator) else { return false }
            let nonempty = continuation.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let first = nonempty.first else { return true }
            let indent = first.prefix(while: { $0 == " " }).count
            return indent > 0 && nonempty.allSatisfy { $0.prefix(while: { $0 == " " }).count >= indent }
        }
        if value.isEmpty || value.hasPrefix("#") {
            guard let first = significant.first else { return true }
            let indent = first.prefix(while: { $0 == " " }).count
            guard indent > 0 else { return false }
            var index = 0
            var sequence: Bool?
            var keys = Set<String>()
            while index < significant.count {
                let line = significant[index]
                guard line.prefix(while: { $0 == " " }).count == indent else { return false }
                let text = String(line.dropFirst(indent))
                let isSequence = text == "-" || text.hasPrefix("- ")
                if let sequence, sequence != isSequence { return false }
                sequence = isSequence
                let childValue: String
                if isSequence {
                    childValue = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                } else {
                    guard let (key, value) = mappingEntry(text), keys.insert(key).inserted else { return false }
                    childValue = value
                }
                index += 1
                let start = index
                while index < significant.count && significant[index].prefix(while: { $0 == " " }).count > indent { index += 1 }
                let children = significant[start..<index].map { String($0.dropFirst(indent)) }
                guard supportsIgnoredValue(childValue, continuation: children, depth: depth + 1) else { return false }
            }
            return true
        }
        guard significant.isEmpty else { return false }
        if value.hasPrefix("\"") {
            guard let data = value.data(using: .utf8) else { return false }
            return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) is String
        }
        if value.hasPrefix("'") {
            return value.count >= 2 && value.hasSuffix("'") &&
                !value.dropFirst().dropLast().replacingOccurrences(of: "''", with: "").contains("'")
        }
        return supportsPlainScalar(value.components(separatedBy: " #").first ?? value)
    }

    private static func supportsPlainScalar(_ value: String) -> Bool {
        let reserved = ["[", "]", "{", "}", "&", "*", "!", "@", "`", "%", "- ", "? ", ": "]
        return !["-", "?", ":"].contains(value) && !reserved.contains(where: value.hasPrefix) && !value.contains(": ") &&
            !value.hasSuffix(":") && !value.contains("\t")
    }

    private static func isYAMLNumber(_ value: String) -> Bool {
        // Double accepts bare NaN/Infinity, which are ordinary YAML strings.
        // YAML's special numeric values require the leading dot.
        if [".nan", ".inf", "+.inf", "-.inf"].contains(value.lowercased()) { return true }
        return value.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                           options: .regularExpression) != nil
            || value.range(of: #"^0(?:o[0-7]+|x[0-9a-fA-F]+)$"#, options: .regularExpression) != nil
    }
}

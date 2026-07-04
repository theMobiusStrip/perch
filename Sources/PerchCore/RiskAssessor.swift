import Foundation

/// Severity of a tool call, surfaced on the read-only notch risk card,
/// session badges, and OS notifications. Ordered so `max` picks the worst
/// signal.
public enum RiskLevel: Int, Codable, Sendable, Comparable {
    case safe = 0
    case caution = 1
    case danger = 2

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .safe: return "safe"
        case .caution: return "caution"
        case .danger: return "danger"
        }
    }
}

/// One thing the assessor flagged about a tool call.
public struct RiskFinding: Equatable, Sendable {
    public let level: RiskLevel
    public let code: String       // stable id, e.g. "destructive-delete"
    public let message: String    // human one-liner for the card

    public init(level: RiskLevel, code: String, message: String) {
        self.level = level
        self.code = code
        self.message = message
    }
}

public struct RiskAssessment: Equatable, Sendable {
    public let level: RiskLevel
    public let findings: [RiskFinding]

    public var isEmpty: Bool { findings.isEmpty }

    public init(level: RiskLevel, findings: [RiskFinding]) {
        self.level = level
        self.findings = findings
    }

    public static let none = RiskAssessment(level: .safe, findings: [])
}

/// Heuristic, offline detector for risky agent tool calls. Deterministic and
/// dependency-free so it runs identically in the bridge, the app, and the
/// selftest. Conservative by construction: it flags patterns, it does not
/// execute or parse shells, and it has no authority — findings only raise
/// attention (OS notification + notch card); the decision stays with the
/// human in the terminal.
///
/// Matching philosophy: a risky token must appear where it would EXECUTE or
/// name a real TARGET, not merely be mentioned. Quoted string literals,
/// heredoc bodies, commit messages, and regex fixtures are data, so they are
/// stripped before command matching (the payload of `sh -c '…'` is re-scanned,
/// since there the quoted text *is* the command). This deliberately trades a
/// quoting-based evasion (an attention tool drowned in false positives
/// protects nothing) for a usable signal-to-noise ratio.
public enum RiskAssessor {
    /// User-declared regenerable scratch directory BASENAMES, from
    /// PerchConfig.scratchDirs. A recursive delete whose target's basename is
    /// one of these downgrades to caution — the escape hatch for project-local
    /// build-output dirs (`.sweep`, `.preview`, `dist`) Perch can't know are
    /// safe by name. Set once at launch via `sanitizedScratchDirs`; empty in
    /// the bridge/selftest.
    public nonisolated(unsafe) static var userScratchDirs: Set<String> = []

    /// Filters PerchConfig.scratchDirs down to safe directory BASENAMES: no
    /// empties, path separators, globs, or `.`/`..`/`~`. A value like "/" or a
    /// path like "src/app" must never be accepted, and an ancestor name like
    /// "src" is only ever matched as a basename (see isScratchPath), so a
    /// config value cannot silence deletes of unrelated real data.
    public static func sanitizedScratchDirs(_ raw: [String]) -> Set<String> {
        Set(raw.compactMap { value -> String? in
            let v = value.trimmingCharacters(in: .whitespaces).lowercased()
            guard !v.isEmpty, v != ".", v != "..", v != "~",
                  !v.contains("/"), !v.contains("*") else { return nil }
            return v
        })
    }

    public static func assess(agent: AgentKind, toolName: String, input: JSONValue?) -> RiskAssessment {
        var findings: [RiskFinding] = []
        let tool = toolName.lowercased()

        // Shell-style tools: inspect the command string.
        if let command = shellCommand(toolName: tool, input: input) {
            findings.append(contentsOf: assessCommand(command))
        }

        // File writes to sensitive locations (Write/Edit and friends).
        if isWriteTool(tool), let path = input?.first(of: ["file_path", "path", "notebook_path"])?.string {
            findings.append(contentsOf: assessWritePath(path))
        }

        // Network-fetch tools reaching non-obvious hosts.
        if tool == "webfetch" || tool == "fetch",
           let url = input?.first(of: ["url"])?.string {
            findings.append(contentsOf: assessURL(url))
        }

        let level = findings.map(\.level).max() ?? .safe
        return RiskAssessment(level: level, findings: dedupe(findings))
    }

    // MARK: - Command text preparation

    /// Removes the parts of a shell command that are data, not shell syntax:
    /// heredoc bodies and quoted string literals. With `keepDoubleQuoted`,
    /// SINGLE-LINE double-quoted spans survive — shell users pass real
    /// operand paths in double quotes (`cat "$HOME/.ssh/id_rsa"`), while
    /// literal payloads (python -c scripts, PR bodies, regex fixtures) are
    /// multi-line or sit in single quotes / heredocs. A real path never
    /// contains a newline.
    static func strippedForMatching(_ raw: String, keepDoubleQuoted: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        let s = Array(raw.unicodeScalars)
        var i = 0
        var pendingHeredocTags: [String] = []   // opened on this line, body starts after newline
        var heredocTag: String?                 // currently skipping a heredoc body

        func line(from start: Int) -> (text: String, next: Int) {
            var j = start
            while j < s.count && s[j] != "\n" { j += 1 }
            return (String(String.UnicodeScalarView(s[start..<j])), min(j + 1, s.count))
        }

        while i < s.count {
            if let tag = heredocTag {
                let (text, next) = line(from: i)
                i = next
                if text.trimmingCharacters(in: .whitespaces) == tag {
                    heredocTag = pendingHeredocTags.isEmpty ? nil : pendingHeredocTags.removeFirst()
                }
                continue
            }
            let c = s[i]
            switch c {
            case "\\":
                // Escaped char: emit both so \' never opens a quote span.
                out.unicodeScalars.append(c)
                if i + 1 < s.count { out.unicodeScalars.append(s[i + 1]) }
                i += 2
            case "'":
                var j = i + 1
                while j < s.count && s[j] != "'" { j += 1 }
                out.append(" ")
                i = min(j + 1, s.count)
            case "\"":
                var j = i + 1
                var spansLines = false
                while j < s.count && s[j] != "\"" {
                    if s[j] == "\n" { spansLines = true }
                    j += (s[j] == "\\" ? 2 : 1)
                }
                if keepDoubleQuoted && !spansLines {
                    out.unicodeScalars.append(contentsOf: s[i..<min(j + 1, s.count)])
                } else {
                    out.append(" ")
                }
                i = min(j + 1, s.count)
            case "<" where i + 1 < s.count && s[i + 1] == "<":
                if i + 2 < s.count && s[i + 2] == "<" {
                    // <<< here-string: the word follows normal quoting rules.
                    out.append("<<<")
                    i += 3
                    continue
                }
                // Heredoc marker: <<[-][ ]['"]TAG['"] — body starts on the next line.
                var j = i + 2
                if j < s.count && s[j] == "-" { j += 1 }
                while j < s.count && (s[j] == " " || s[j] == "\t") { j += 1 }
                var quote: Unicode.Scalar?
                if j < s.count && (s[j] == "'" || s[j] == "\"") { quote = s[j]; j += 1 }
                var tag = ""
                while j < s.count, CharacterSet.alphanumerics.contains(s[j]) || s[j] == "_" {
                    tag.unicodeScalars.append(s[j]); j += 1
                }
                if let q = quote, j < s.count, s[j] == q { j += 1 }
                if tag.isEmpty {
                    out.append("<<")
                    i += 2
                } else {
                    pendingHeredocTags.append(tag)
                    out.append(" ")
                    i = j
                }
            case "\n":
                out.append("\n")
                i += 1
                if heredocTag == nil && !pendingHeredocTags.isEmpty {
                    heredocTag = pendingHeredocTags.removeFirst()
                }
            default:
                out.unicodeScalars.append(c)
                i += 1
            }
        }
        return out
    }

    /// Quoted payloads of `sh -c '…'` (and bash/zsh/dash/ksh) ARE commands —
    /// extract them so quote-stripping can't hide `bash -c "rm -rf /"`.
    /// Anchored at a real command boundary (not any whitespace) so a `sh -c
    /// "…"` MENTIONED inside a quoted fixture (`echo 'bash -c "rm"'`) is not
    /// harvested — only one actually being invoked. Includes the wrapper
    /// run-up so `timeout 120 bash -c '…'` still harvests its payload.
    private static let shEvalBoundary = #"(?:"# + cmdAnchor + #"|\bxargs\s+(?:-\S+\s+)*|-exec(?:dir)?\s+)"#
    private static let shDashC = try! NSRegularExpression(
        pattern: shEvalBoundary + #"(?:ba|z|da|k)?sh\s+(?:-[a-z]+\s+)*-c\s+(?:'([^']*)'|"((?:[^"\\]|\\.)*)")"#,
        options: [.caseInsensitive])

    static func inlineShellPayloads(_ raw: String) -> [String] {
        let ns = raw as NSString
        return shDashC.matches(in: raw, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            for group in 1...2 where m.range(at: group).location != NSNotFound {
                return ns.substring(with: m.range(at: group))
            }
            return nil
        }
    }

    /// Everything in `raw` that will EXECUTE despite quotes/heredocs: sh -c and
    /// eval arguments, `$(…)` / backtick substitutions, and heredocs fed to a
    /// shell. Re-scanned as commands by assessCommand.
    ///
    /// The sh -c / eval / substitution harvest runs on the text with DATA
    /// heredoc bodies removed — a commit message or a python heredoc that
    /// merely *mentions* `` `dd …` `` or `sh -c "shutdown"` is not executing it.
    /// Heredocs actually fed to a shell are harvested separately from `raw`.
    static func executablePayloads(_ raw: String) -> [String] {
        let visible = withoutHeredocBodies(raw)
        var out = inlineShellPayloads(visible)
        out.append(contentsOf: evalPayloads(visible))
        out.append(contentsOf: commandSubstitutions(visible))
        out.append(contentsOf: heredocIntoShellBodies(raw))
        return out
    }

    /// `raw` with every heredoc body blanked but all quoting and the rest of
    /// the marker line preserved — the harvest surface for command
    /// substitutions and sh -c/eval arguments. The heredoc body starts on the
    /// line AFTER the marker, so `cat <<EOF | bash` keeps its `| bash`.
    static func withoutHeredocBodies(_ raw: String) -> String {
        var out = ""
        let s = Array(raw.unicodeScalars)
        var i = 0
        var pendingTags: [String] = []
        var skippingTag: String?
        func lineEnd(_ from: Int) -> Int {
            var j = from; while j < s.count && s[j] != "\n" { j += 1 }; return j
        }
        while i < s.count {
            if let tag = skippingTag {
                let end = lineEnd(i)
                let line = String(String.UnicodeScalarView(s[i..<end]))
                i = min(end + 1, s.count)
                if line.trimmingCharacters(in: .whitespaces) == tag {
                    skippingTag = pendingTags.isEmpty ? nil : pendingTags.removeFirst()
                }
                continue
            }
            if s[i] == "<" && i + 1 < s.count && s[i + 1] == "<"
                && !(i + 2 < s.count && s[i + 2] == "<") {
                var j = i + 2
                if j < s.count && s[j] == "-" { j += 1 }
                while j < s.count && (s[j] == " " || s[j] == "\t") { j += 1 }
                var quote: Unicode.Scalar?
                if j < s.count && (s[j] == "'" || s[j] == "\"") { quote = s[j]; j += 1 }
                var tag = ""
                while j < s.count, CharacterSet.alphanumerics.contains(s[j]) || s[j] == "_" {
                    tag.unicodeScalars.append(s[j]); j += 1
                }
                if let q = quote, j < s.count, s[j] == q { j += 1 }
                guard !tag.isEmpty else { out.append("<<"); i += 2; continue }
                out.unicodeScalars.append(contentsOf: s[i..<j])   // keep `<<TAG`, drop body later
                pendingTags.append(tag)
                i = j
                continue
            }
            if s[i] == "\n" {
                out.append("\n")
                i += 1
                if skippingTag == nil && !pendingTags.isEmpty { skippingTag = pendingTags.removeFirst() }
                continue
            }
            out.unicodeScalars.append(s[i])
            i += 1
        }
        return out
    }

    /// `eval '<payload>'` runs its argument as a command — same blast radius as
    /// `sh -c`. Capture the (single-, double-, or unquoted) argument so a
    /// destructive command hidden in `eval "rm -rf ~"` is re-scanned.
    private static let evalArg = try! NSRegularExpression(
        pattern: shEvalBoundary + #"eval\s+(?:'([^']*)'|"([^"]*)"|([^;&|\n]+))"#,
        options: [.caseInsensitive])

    static func evalPayloads(_ raw: String) -> [String] {
        let ns = raw as NSString
        return evalArg.matches(in: raw, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            for group in 1...3 where m.range(at: group).location != NSNotFound {
                return ns.substring(with: m.range(at: group))
            }
            return nil
        }
    }

    /// Command substitutions `$(…)` and `` `…` `` execute regardless of any
    /// enclosing double quotes, so their bodies must be re-scanned even though
    /// strippedForMatching removes the surrounding quoted span. Bodies inside
    /// SINGLE quotes are literal (no substitution) and are skipped.
    static func commandSubstitutions(_ raw: String) -> [String] {
        var out: [String] = []
        let s = Array(raw.unicodeScalars)
        var i = 0
        var inSingle = false
        while i < s.count {
            let c = s[i]
            if c == "\\" { i += 2; continue }
            if inSingle { if c == "'" { inSingle = false }; i += 1; continue }
            if c == "'" { inSingle = true; i += 1; continue }
            if c == "$" && i + 1 < s.count && s[i + 1] == "(" {
                var depth = 1, j = i + 2
                let start = j
                while j < s.count && depth > 0 {
                    if s[j] == "(" { depth += 1 } else if s[j] == ")" { depth -= 1 }
                    if depth == 0 { break }
                    j += 1
                }
                out.append(String(String.UnicodeScalarView(s[start..<min(j, s.count)])))
                i = j + 1
                continue
            }
            if c == "`" {
                var j = i + 1
                let start = j
                while j < s.count && s[j] != "`" { j += 1 }
                out.append(String(String.UnicodeScalarView(s[start..<min(j, s.count)])))
                i = j + 1
                continue
            }
            i += 1
        }
        return out
    }

    /// Heredoc bodies are re-scanned only when the heredoc is fed to a shell
    /// (`bash <<EOF …`, `cat <<EOF | sh`) — otherwise a heredoc body is file
    /// content / a fixture, which must stay stripped. The "fed to a shell"
    /// test runs on the command SKELETON (bodies removed) so a `| sh`
    /// *mentioned inside a body* (a red-line fixture, a commit message) can't
    /// make the body harvest itself.
    static func heredocIntoShellBodies(_ raw: String) -> [String] {
        let skeleton = withoutHeredocBodies(raw).lowercased()
        let feedsShell = matches(skeleton, #"\|\s*(?:sudo\s+)?(?:ba|z|da|k)?sh\b"#)
            || matches(skeleton, #"(?:^\s*|[;&|(\n]\s*)(?:ba|z|da|k)?sh\b[^\n]*<<"#)
        guard feedsShell else { return [] }
        return collectHeredocBodies(raw)
    }

    /// Every heredoc body in `raw` (the inverse of strippedForMatching's skip).
    private static func collectHeredocBodies(_ raw: String) -> [String] {
        var bodies: [String] = []
        let s = Array(raw.unicodeScalars)
        var i = 0
        while i < s.count {
            if s[i] == "<" && i + 1 < s.count && s[i + 1] == "<"
                && !(i + 2 < s.count && s[i + 2] == "<") {
                var j = i + 2
                if j < s.count && s[j] == "-" { j += 1 }
                while j < s.count && (s[j] == " " || s[j] == "\t") { j += 1 }
                var quote: Unicode.Scalar?
                if j < s.count && (s[j] == "'" || s[j] == "\"") { quote = s[j]; j += 1 }
                var tag = ""
                while j < s.count, CharacterSet.alphanumerics.contains(s[j]) || s[j] == "_" {
                    tag.unicodeScalars.append(s[j]); j += 1
                }
                if let q = quote, j < s.count, s[j] == q { j += 1 }
                guard !tag.isEmpty else { i += 2; continue }
                // Skip to end of this line, then collect until the closing tag.
                while j < s.count && s[j] != "\n" { j += 1 }
                j += 1
                var body = ""
                while j < s.count {
                    var k = j
                    while k < s.count && s[k] != "\n" { k += 1 }
                    let line = String(String.UnicodeScalarView(s[j..<k]))
                    if line.trimmingCharacters(in: .whitespaces) == tag { j = k + 1; break }
                    body += line + "\n"
                    j = k + 1
                }
                bodies.append(body)
                i = j
                continue
            }
            i += 1
        }
        return bodies
    }

    // MARK: - Command heuristics

    /// A position where a token would execute: start of the command, right
    /// after a separator / subshell opener / backtick / `)` (case branch), or
    /// after a shell keyword that introduces a command (then/do/else/while/
    /// until) or `{`.
    private static let seg = #"(?:^\s*|[;&|(`{)\n]\s*|\$\(\s*|\b(?:then|do|else|while|until)\s+)"#

    /// After a boundary the shell may stack modifiers before the real command.
    /// `runUpAlts` are the individual modifiers; `runUp` repeats them (with an
    /// optional `sudo`) so the command word underneath is still seen at command
    /// position: an alias-defeating backslash (`\rm`); wrapper runners
    /// (time/timeout/nohup/nice/env/command/exec/doas/flock/…); a leading
    /// redirection (`2>/dev/null rm`); and VAR=value assignments.
    /// `time sudo rm -rf ~`, `timeout 5 rm -rf /`, `\rm -rf /`,
    /// `TOKEN=x curl … | sh` all anchor.
    private static let runUpAlts =
        #"(?:\\+|(?:nohup|setsid|ionice|command|exec|builtin|doas)\s+"#
        + #"|time\s+|timeout\s+(?:-[a-z]+\s+)*[0-9]+[smhd]?\s+"#
        + #"|nice\s+(?:-n\s+)?-?[0-9]+\s+|nice\s+"#
        + #"|env\s+(?:-[a-z]+\s+)*|stdbuf\s+(?:-[a-z]+\s+)*"#
        + #"|flock\s+(?:-[a-z]+\s+)*[^\s;&|]+\s+"#
        + #"|[0-9]*(?:>>?|<)(?:&[0-9]+)?[^\s;&|]*\s+|&>>?[^\s;&|]*\s+"#
        + #"|[a-z_][a-z0-9_]*=[^\s;&|]*\s+)"#
    private static let runUp = #"(?:"# + runUpAlts + #"|sudo\s+(?:-[a-z]+\s+)*)*"#
    /// Same run-up but without the `sudo` alternative — so a `sudo` behind
    /// `timeout`/redirects is still detected as privilege escalation.
    private static let sudoRunUp = #"(?:"# + runUpAlts + #")*"#
    private static let cmdAnchor = seg + runUp
    private static let sudoOpt = #"(?:sudo\s+(?:-[a-z]+\s+)*)?"#

    /// Quoted args that are prose / output / search patterns, not file
    /// operands — dropped from the needle text so a commit message, banner, or
    /// grep pattern *mentioning* .env can't fire. Covers message flags
    /// (`git commit -m "…"`, `gh api -f body="…"`), echo/printf, and the
    /// search family (`grep/rg "…"`, `find -name "…"`). A credential file is
    /// read as an OPERAND (a separate token), so `grep -q "^K=" .env` still
    /// fires on the real `.env` operand. Command substitutions inside these
    /// args are harvested separately and still execute.
    private static let messageArg =
        #"(?:(?:-m|--message|--title|--body|--notes|-f|--field)(?:\s+\w+=|\s*=?\s*)"#
        + #"|\b(?:echo|printf)\s+(?:-[a-z]+\s+)*"#
        + #"|\b(?:grep|egrep|fgrep|rg|ag|ack)\s+(?:-[a-z]+\s+)*"#
        + #"|(?:-name|-iname|-path|-ipath|--include|--exclude)\s*=?\s*"#
        + #")"[^"\n]*""#

    static func assessCommand(_ raw: String) -> [RiskFinding] {
        // Execution rules match the stripped text; target-needle rules keep
        // double-quoted operands. Anything that will EXECUTE despite quoting —
        // sh -c / eval arguments, `$(…)` / backtick substitutions, heredocs
        // fed to a shell — is harvested and re-scanned so quoting can't hide a
        // real command. (Recurse one level: a payload may itself contain a
        // substitution.)
        var payloads = executablePayloads(raw)
        payloads += payloads.flatMap(executablePayloads)
        var exec = strippedForMatching(raw)
        var needle = strippedForMatching(raw, keepDoubleQuoted: true)
            .replacingOccurrences(of: messageArg, with: " ", options: .regularExpression)
        for payload in payloads {
            // A harvested payload is code, not prose — no message-arg carve-out.
            exec += "\n" + strippedForMatching(payload)
            needle += "\n" + strippedForMatching(payload, keepDoubleQuoted: true)
        }
        let cmd = exec.lowercased()
        let needleCmd = needle.lowercased()

        var out: [RiskFinding] = []
        func flag(_ level: RiskLevel, _ code: String, _ message: String) {
            out.append(RiskFinding(level: level, code: code, message: message))
        }

        // Destructive filesystem operations, graded by blast radius: a
        // recursive rm of a real path is the notify-worthy event; rm scoped
        // to scratch space, to files the command itself recreates, or a
        // non-recursive `rm -f file` (named files, no tree) only badges.
        // Detection runs on the exec text; target classification reads the
        // needle text, where double-quoted operands (`rm -rf "$DIR"`) are
        // still visible.
        switch destructiveDelete(in: cmd, targets: needleCmd) {
        case .real:
            flag(.danger, "destructive-delete", "Recursive/forced delete (rm -rf)")
        case .scratchOnly:
            flag(.caution, "destructive-delete", "Recursive delete of scratch/regenerated paths")
        case .forceOnly:
            flag(.caution, "destructive-delete", "Forced delete of named files (rm -f)")
        case nil:
            break
        }
        if matches(cmd, cmdAnchor + #"(?:mkfs(?:\.[a-z0-9]+)?\s|diskutil\s+erase|dd\s+[^;&|\n]*\bof=/dev/)"#) {
            flag(.danger, "disk-write", "Raw disk / filesystem write")
        }
        if matches(cmd, #">\s*/dev/(disk|rdisk|sd)"#) {
            flag(.danger, "device-write", "Write to a raw device node")
        }
        if matches(cmd, cmdAnchor + #"(?:shutdown|reboot|halt)\b"#) {
            flag(.danger, "power", "System shutdown/reboot")
        }

        // Privilege escalation: sudo actually running a real command as root.
        // A no-op probe (`sudo -n true`, `sudo :`) or a bare credential
        // refresh (`sudo -v`/`-k`) performs no privileged action.
        if sudoRunsRealCommand(in: cmd) {
            flag(.danger, "privilege-escalation", "Runs a command as root (sudo)")
        }
        if matches(cmd, #"\bchmod\s+(-[a-z]*\s+)*777\b"#) {
            flag(.caution, "loose-permissions", "chmod 777 — world-writable")
        }

        // Pipe-to-shell from the network: curl/wget piped into a shell, or
        // into a bare interpreter that executes its stdin. An interpreter
        // with an inline script (-e/-c) is consuming the pipe as data.
        let pipeSrc = cmdAnchor + #"(?:curl|wget)\b[^|\n]*\|\s*"# + sudoOpt
        if matches(cmd, pipeSrc + #"(?:ba|z|da|k)?sh\b"#)
            || matches(cmd, pipeSrc + #"(?:python[0-9.]*|node|ruby|perl)\s*(?:-\s*)?(?:$|[;&|\n)])"#)
            // `eval "$(curl … )"` executes the download's output — same risk.
            // Requires eval as a real command word (`eval\s`) whose argument is
            // a command substitution containing curl/wget, so a prose mention
            // like `eval/run.ts … Bash(curl:*)` can't fire.
            || matches(needleCmd, cmdAnchor + #"eval\s+["']?[`$]\(?[^;&|\n]*(?:curl|wget)\b"#) {
            flag(.danger, "pipe-to-shell", "Downloads and pipes straight into a shell")
        }

        // Credential / secret material named as a real operand (quoted
        // mentions and heredoc fixtures were stripped above). `\.env\b` must
        // not fire on the process.env / import.meta.env code idiom, escaped
        // regex-pattern forms (`\.env`), the committed-by-design .env.example
        // family, or fixture homes staged under a temp dir.
        if credentialOperandPresent(in: needleCmd) {
            flag(.danger, "credential-access", "Touches credential / secret material")
        }
        if matches(cmd, cmdAnchor + #"security\s+(dump-keychain|find-(generic|internet)-password)"#) {
            flag(.danger, "keychain-dump", "Reads macOS Keychain secrets")
        }

        // History rewrites / force pushes. --force-with-lease is the safe
        // idiom — it refuses to clobber unseen commits, so it stays quiet.
        if matches(cmd, #"git\s+push\b[^;&|\n]*(?:--force\b(?!-with-lease)|\s-f\b)"#) {
            flag(.caution, "force-push", "Force-push can overwrite remote history")
        }
        if matches(cmd, #"git\s+reset\s+--hard\b"#) {
            flag(.caution, "hard-reset", "git reset --hard discards local changes")
        }

        // Kill-all / broad process signals.
        if matches(cmd, #"\b(kill(all)?\s+-9|pkill\s+-9)\b"#) {
            flag(.caution, "force-kill", "Force-kills processes (-9)")
        }

        // Outbound data over the network — netcat invoked, not mentioned.
        if matches(cmd, cmdAnchor + #"(?:nc|ncat|netcat)\s+[^;&|\n]*\s\d"#) {
            flag(.caution, "netcat", "Raw network connection (netcat)")
        }

        // Shell writes into the agent's own config/instruction surface. The
        // needle must be the TARGET of a write (redirect target, tee/cp/mv
        // destination, sed -i file) — co-occurrence of a `>` somewhere and a
        // mention somewhere is how `cat CLAUDE.md 2>/dev/null` used to fire.
        out.append(contentsOf: agentSurfaceFindings(inCommand: needleCmd))

        return out
    }

    /// destructive-delete: nil = no match; true = every rm target lives in
    /// scratch space; false = at least one real target.
    ///
    /// `rm` must be the command actually running — at command position
    /// (behind any wrapper/assignment/`\`/sudo run-up), or fed by xargs /
    /// find -exec. Subcommands that merely SPELL rm (`git rm`, `docker … rm`,
    /// `npm rm`) are namespaced, recoverable operations, not filesystem deletes.
    private static let rmInvocation =
        #"(?:"# + cmdAnchor + #"|\bxargs\s+(?:-\S+\s+)*|-exec(?:dir)?\s+)rm\s+"#
    /// Captures the rm argument list (group 1) so target extraction reads only
    /// what follows `rm`, never an "rm" substring inside a wrapper/assignment
    /// (e.g. `TERM=x`).
    private static let rmSegment = try! NSRegularExpression(pattern: rmInvocation + #"([^;&|\n]*)"#)

    private enum DeleteScope { case real, scratchOnly, forceOnly }

    private static func destructiveDelete(in cmd: String, targets targetText: String) -> DeleteScope? {
        // Require an actual -r/-f style flag: `-?[a-z]*[rf]` used to match ANY
        // next token whose letters contained r or f (`rm foo.txt`, `npm rm react`).
        let recursive = matches(cmd, rmInvocation + #"(?:[^;&|\n]*\s)?-[a-z]*r[a-z]*\b"#)
            || matches(cmd, rmInvocation + #"[^;&|\n]*--recursive\b"#)
        let forced = matches(cmd, rmInvocation + #"(?:[^;&|\n]*\s)?-[a-z]*f[a-z]*\b"#)
            || matches(cmd, rmInvocation + #"[^;&|\n]*--force\b"#)
        guard recursive || forced else { return nil }
        guard recursive else { return .forceOnly }
        let ns = targetText as NSString
        let scratchVars = scratchVariables(in: targetText)
        var sawTarget = false
        for m in rmSegment.matches(in: targetText, range: NSRange(location: 0, length: ns.length)) {
            // `cd /tmp/x && rm -rf y` deletes inside scratch: resolve relative
            // targets against the last cd before this rm.
            let inScratchCwd = lastCd(in: targetText, before: m.range.location)
                .map { isScratchPath($0, vars: scratchVars) } ?? false
            let args = ns.substring(with: m.range(at: 1))
            let tokens = args.split(whereSeparator: { $0 == " " || $0 == "\t" })
            for token in tokens where !token.hasPrefix("-") {
                let t = String(token)
                // A shell redirection (`2>/dev/null`, `>out`, `&>log`) is not
                // an rm target — skip it so it isn't misread as a real path.
                if t.contains(">") || t.contains("<") { continue }
                sawTarget = true
                // A path that climbs out with `..` is never treated as scratch
                // (`/tmp/../real`, `./node_modules/../src`, `../../Users/x`).
                let escapes = t.contains("..")
                let isRelative = !t.hasPrefix("/") && !t.hasPrefix("~") && !t.hasPrefix("$") && !t.hasPrefix("\"")
                if !escapes, isScratchPath(t, vars: scratchVars) || (isRelative && inScratchCwd) { continue }
                // `rm -rf X && mkdir X` regenerates an in-tree build dir. Gated
                // to relative, non-traversing, non-sensitive paths so it can't
                // downgrade a real data delete like `rm -rf ~/Documents && mkdir …`.
                if !escapes, isRecreatedBuildDir(t, in: targetText) { continue }
                return .real
            }
        }
        return sawTarget ? .scratchOnly : .real  // opaque targets stay danger
    }

    /// A relative in-tree path that this same command deletes and immediately
    /// re-creates with mkdir — a build-output reset (`rm -rf .sweep && mkdir
    /// -p .sweep`). Restricted to relative, non-`..` paths whose basename
    /// isn't a known data/config dir, so `rm -rf ~/Documents && mkdir …`
    /// (absolute/home) and `rm -rf .git && mkdir .git` still fire danger.
    private static let recreateSensitive: Set<String> = [
        ".git", ".ssh", ".claude", ".codex", ".aws", ".gnupg", ".config", ".env",
    ]
    private static func isRecreatedBuildDir(_ token: String, in cmd: String) -> Bool {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !t.hasPrefix("/"), !t.hasPrefix("~"), !t.hasPrefix("$"), !t.contains("..") else { return false }
        guard !recreateSensitive.contains((t as NSString).lastPathComponent) else { return false }
        return matches(cmd, #"\bmkdir\s+(?:-[a-z]+\s+)*[^;&|\n]*"# + NSRegularExpression.escapedPattern(for: t))
    }

    /// Paths whose deletion an agent can always regenerate: temp dirs and
    /// throwaway build artifacts (.venv, node_modules, build caches).
    private static let scratchPrefixes = ["/tmp/", "/private/tmp/", "/var/folders/",
                                          "/private/var/folders/", "$tmpdir", "${tmpdir"]

    private static func isScratchPath(_ token: String, vars: Set<String> = []) -> Bool {
        let t = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if t.contains("..") { return false }   // never let a traversal read as scratch
        if scratchPrefixes.contains(where: t.hasPrefix)
            || ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"].contains(t)
            || t.hasSuffix(".venv") || t.hasSuffix(".venv/")
            || t.hasSuffix("/node_modules") || t.hasSuffix("/node_modules/")
            || t == "node_modules" || t.hasPrefix("node_modules/")
            // Regenerable build caches (SwiftPM, Python bytecode).
            || t == ".build" || t.hasPrefix(".build/") || t.hasSuffix("/.build") || t.contains("/.build/")
            || t.contains("__pycache__") { return true }
        // User-declared regenerable dirs (PerchConfig.scratchDirs): match ONLY
        // the deleted path's BASENAME. Matching an ancestor segment would let a
        // broad value like "src" mark everything nested under any `src/` as
        // scratch — downgrading a real delete and suppressing credential reads
        // under it. Unsafe values (empty, "/", ".", "..", "~", anything with a
        // slash) are ignored so a config value can't neuter detection wholesale.
        if !userScratchDirs.isEmpty {
            let base = t.split(separator: "/").last.map(String.init) ?? t
            if !base.isEmpty, base != ".", base != "..", base != "~", userScratchDirs.contains(base) {
                return true
            }
        }
        // $VAR / ${VAR} where VAR was assigned a scratch path in this command.
        if t.hasPrefix("$") {
            let name = t.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
            return vars.contains(String(name))
        }
        return false
    }

    /// Variables assigned a scratch path (or mktemp result) in this command,
    /// with one level of propagation so `VAL=/tmp/x; IW="$VAL/y"; rm -rf $IW`
    /// resolves. Assignments are processed in order of appearance.
    private static let assignment = try! NSRegularExpression(
        pattern: #"(?:^\s*|[;&|\n(]\s*)(?:export\s+)?([a-z_][a-z0-9_]*)=("?)([^\s;&|\n]*)"#)

    static func scratchVariables(in cmd: String) -> Set<String> {
        let ns = cmd as NSString
        var vars = Set<String>()
        for m in assignment.matches(in: cmd, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let value = ns.substring(with: m.range(at: 3))
            if isScratchPath(value, vars: vars) || value.hasPrefix("$(mktemp") {
                vars.insert(name)
            }
        }
        return vars
    }

    /// Argument of the last `cd` before `offset`, if any.
    private static let cdCommand = try! NSRegularExpression(
        pattern: #"(?:^\s*|[;&|\n(]\s*)cd\s+([^\s;&|\n]+)"#)

    private static func lastCd(in cmd: String, before offset: Int) -> String? {
        let ns = cmd as NSString
        var last: String?
        for m in cdCommand.matches(in: cmd, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location >= offset { break }
            last = ns.substring(with: m.range(at: 1))
        }
        return last
    }

    /// A command-position `sudo` whose command word is a real action. The word
    /// `true`/`:`/`false` is a no-op capability probe, and a leftover
    /// `-v`/`-k`/`-n` flag with no command word only touches the credential
    /// cache — neither escalates. A second real sudo on the same line
    /// (`sudo -n true && sudo cat /etc/shadow`) still fires.
    private static let sudoInvocation = try! NSRegularExpression(
        pattern: #"(?:^\s*|[;&|(\n]\s*|\$\(\s*)"# + sudoRunUp
            + #"(?:sudo|doas)\s+((?:-[a-z]+(?:\s+"[^"\n]*"|\s+\S+)?\s+)*)(\S+)?"#)

    private static func sudoRunsRealCommand(in cmd: String) -> Bool {
        let ns = cmd as NSString
        for m in sudoInvocation.matches(in: cmd, range: NSRange(location: 0, length: ns.length)) {
            guard m.range(at: 2).location != NSNotFound else { continue } // sudo -v/-k, no command
            let word = ns.substring(with: m.range(at: 2))
            if word.hasPrefix("-") { continue }
            if ["true", ":", "false"].contains(word) { continue }         // no-op probe
            return true
        }
        return false
    }

    /// Writes to the agent's own instruction/configuration surface. Split by
    /// blast radius: hook/settings/plugin files execute automatically in
    /// future sessions (danger); instruction/memory files poison future
    /// prompts (caution — agents also update memory legitimately, so this
    /// badges without notifying). Perch's own installer trips the danger rule
    /// when it writes settings.json — deliberately not exempted.
    static let agentConfigNeedles: [String] = [
        "/.claude/settings", "/.claude/hooks", "/.claude/plugins", "/.claude/skills",
        "/.codex/hooks.json", "/.codex/config.toml",
    ]
    static let memoryPollutionNeedles: [String] = [
        "claude.md", "agents.md", "memory.md", "/.claude/memory/",
        ".cursorrules", "copilot-instructions.md",
    ]
    static let agentConfigNeedlePattern =
        #"(?:/\.claude/settings|/\.claude/hooks|/\.claude/plugins|/\.claude/skills|/\.codex/hooks\.json|/\.codex/config\.toml)"#
    static let memoryPollutionNeedlePattern =
        #"(?:claude\.md|agents\.md|memory\.md|/\.claude/memory/|\.cursorrules|copilot-instructions\.md)"#

    static func agentSurfaceFindings(inCommand cmd: String) -> [RiskFinding] {
        var out: [RiskFinding] = []
        if isWriteTarget(agentConfigNeedlePattern, in: cmd) {
            out.append(RiskFinding(level: .danger, code: "agent-config",
                                   message: "Writes agent hook/settings config — executes in future sessions"))
        }
        if isWriteTarget(memoryPollutionNeedlePattern, in: cmd) {
            out.append(RiskFinding(level: .caution, code: "memory-pollution",
                                   message: "Writes agent instructions/memory (CLAUDE.md, memory files)"))
        }
        return out
    }

    /// The needle appears as the target of a write: a redirect/tee target
    /// token, the final (destination) argument of cp/mv/install/ln -s, or a
    /// sed -i operand. Token-bound, so `2>/dev/null` next to a mention of
    /// CLAUDE.md can no longer combine into a finding. `git mv` is a
    /// versioned rename inside the repo, not an instruction-file write.
    private static func isWriteTarget(_ needle: String, in cmd: String) -> Bool {
        let patterns = [
            #">{1,2}\s*\S*"# + needle,
            #"\btee\s+(?:-[a-z]+\s+)*\S*"# + needle,
            #"\bsed\s+(?:-[a-z]+\s+)*-i[^;&|\n]*"# + needle,
            #"(?:\bcp|(?<!git\s)\bmv|\binstall|\bln\s+-s[a-z]*)\s+[^;&|\n]*"# + needle + #"[^\s;&|\n]*\s*(?:$|[;&|\n])"#,
        ]
        return patterns.contains { matches(cmd, $0) }
    }

    /// Credential needle present as a real operand: pattern matches are
    /// discarded when the enclosing token sits in scratch space (a fixture
    /// home under /tmp is test scaffolding, not the user's keys) — everything
    /// else counts.
    private static let credentialNeedles = try! NSRegularExpression(pattern:
        #"(?<!\\)\.ssh/|id_rsa|id_ed25519|(?<!\\)\.aws/credentials|(?<!\\)\.netrc\b|keychain\b|/etc/shadow|auth\.json"#
        + #"|(?<!process)(?<!import\.meta)(?<!\\)\.env\b(?!\.(?:example|sample|template))"#)

    private static func credentialOperandPresent(in cmd: String) -> Bool {
        let ns = cmd as NSString
        let ws: Set<String> = [" ", "\t", "\n"]
        let scratchVars = scratchVariables(in: cmd)
        for m in credentialNeedles.matches(in: cmd, range: NSRange(location: 0, length: ns.length)) {
            // Expand the match to its whitespace-bounded token.
            var start = m.range.location
            while start > 0, !ws.contains(ns.substring(with: NSRange(location: start - 1, length: 1))) {
                start -= 1
            }
            var end = m.range.location + m.range.length
            while end < ns.length, !ws.contains(ns.substring(with: NSRange(location: end, length: 1))) {
                end += 1
            }
            let token = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            // Same scratch resolution rm uses: a fixture secret under a temp
            // dir (literal /tmp/, a $VAR=mktemp path, or a relative path under
            // a scratch cwd) is test scaffolding, not the user's real keys. A
            // `..` traversal out of scratch is never exempt.
            if token.contains("..") { return true }
            if isScratchPath(token, vars: scratchVars) { continue }
            let isRelative = !token.hasPrefix("/") && !token.hasPrefix("~") && !token.hasPrefix("$")
            if isRelative,
               let cd = lastCd(in: cmd, before: m.range.location),
               isScratchPath(cd, vars: scratchVars) { continue }
            return true
        }
        return false
    }

    static func assessWritePath(_ path: String) -> [RiskFinding] {
        let p = path.lowercased()
        var out: [RiskFinding] = []
        let sensitive = [
            ("/.ssh/", "credential-access", "Writes into ~/.ssh"),
            ("/.aws/", "credential-access", "Writes into ~/.aws"),
            ("/etc/", "system-path", "Writes under /etc"),
            ("/library/launchagents", "persistence", "Installs a LaunchAgent (persistence)"),
            ("/library/launchdaemons", "persistence", "Installs a LaunchDaemon (persistence)"),
            (".zshrc", "shell-profile", "Modifies a shell profile"),
            (".bashrc", "shell-profile", "Modifies a shell profile"),
            (".bash_profile", "shell-profile", "Modifies a shell profile"),
        ]
        for (needle, code, message) in sensitive where p.contains(needle) {
            let level: RiskLevel = (code == "shell-profile") ? .caution : .danger
            out.append(RiskFinding(level: level, code: code, message: message))
        }
        // .env by filename, not substring — `.env` mid-path used to catch
        // x.environment.ts; the .env.example family is committed by design.
        let name = (p as NSString).lastPathComponent
        if name == ".env" || name == ".envrc"
            || (name.hasPrefix(".env.") && !["example", "sample", "template"].contains(String(name.dropFirst(5)))) {
            out.append(RiskFinding(level: .danger, code: "secret-file", message: "Writes a .env file"))
        }
        // For a Write/Edit path the needle IS the target — plain contains. But
        // a skill's Markdown is prompt material, not executable config: a
        // SKILL.md / references/*.md is injected as instructions, it never
        // runs like a hook or a settings permission. Route it to
        // memory-pollution (caution) so it badges instead of firing a danger
        // OS notification; scripts and the settings/hooks/plugins surface
        // still fire danger.
        if agentConfigNeedles.contains(where: p.contains) {
            if p.contains("/.claude/skills/"), (p as NSString).pathExtension == "md" {
                out.append(RiskFinding(level: .caution, code: "memory-pollution",
                                       message: "Writes agent instructions (skill markdown)"))
            } else {
                out.append(RiskFinding(level: .danger, code: "agent-config",
                                       message: "Writes agent hook/settings config — executes in future sessions"))
            }
        }
        // Claude Code's own auto-memory lives under ~/.claude/projects/…/memory
        // and is written every session by design — flagging it is pure noise.
        // Project CLAUDE.md/AGENTS.md and ~/.claude/CLAUDE.md stay covered.
        if memoryPollutionNeedles.contains(where: p.contains), !p.contains("/.claude/projects/") {
            out.append(RiskFinding(level: .caution, code: "memory-pollution",
                                   message: "Writes agent instructions/memory (CLAUDE.md, memory files)"))
        }
        return out
    }

    static func assessURL(_ url: String) -> [RiskFinding] {
        let u = url.lowercased()
        if u.hasPrefix("http://") {
            return [RiskFinding(level: .caution, code: "insecure-url", message: "Fetches over plaintext HTTP")]
        }
        if matches(u, #"(\d{1,3}\.){3}\d{1,3}"#) {
            return [RiskFinding(level: .caution, code: "raw-ip", message: "Fetches from a raw IP address")]
        }
        return []
    }

    // MARK: - Plumbing

    private static func shellCommand(toolName: String, input: JSONValue?) -> String? {
        // `exec_command` is Codex's real shell tool (input field `cmd`);
        // omitting it silently skipped risk-scoring every Codex command.
        let shellTools: Set<String> = ["bash", "shell", "local_shell", "exec_command",
                                       "run_command", "execute"]
        guard shellTools.contains(toolName) else { return nil }
        return input?.first(of: ["command", "cmd", "script"])?.string
    }

    private static func isWriteTool(_ tool: String) -> Bool {
        ["write", "edit", "multiedit", "notebookedit", "apply_patch", "create_file"].contains(tool)
    }

    private static func dedupe(_ findings: [RiskFinding]) -> [RiskFinding] {
        var seen = Set<String>()
        var out: [RiskFinding] = []
        for f in findings.sorted(by: { $0.level > $1.level }) where !seen.contains(f.code) {
            seen.insert(f.code)
            out.append(f)
        }
        return out
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

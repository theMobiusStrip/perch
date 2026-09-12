import Foundation
import PerchCore

extension Selftest {
    @MainActor
    static func patchCompatibility(_ t: Checker) {
        t.suite("patchCompatibility")
        func assess(_ body: String, cwd: String? = "/workspace") -> RiskAssessment {
            RiskAssessor.assess(agent: .codex, toolName: "apply_patch",
                                input: .object(["command": .string(body)]), cwd: cwd)
        }
        func patch(_ body: String) -> String { "*** Begin Patch\n\(body)\n*** End Patch" }
        let config = "*** Update File: .codex/hooks.json\n@@\n-{}\n+{}"
        t.expectEqual(assess(patch(config)).level, .danger, "relative config update")
        t.expectEqual(assess(patch(config), cwd: nil).level, .danger, "missing cwd retains relative surface")
        t.expectEqual(assess(patch("*** Add File: ../.codex/config.toml\n+x"), cwd: "/workspace/src").level,
                      .danger, "parent-relative config add")
        t.expectEqual(assess(patch("*** Add File: hooks.json\n+x"), cwd: "/workspace/.codex").level,
                      .danger, "cwd supplies sensitive directory")
        t.expectEqual(assess(patch("*** Add File: /workspace/.codex/../src/app.swift\n+x")).level,
                      .safe, "dot segments normalize away non-target config")
        let removal = assess(patch("*** Delete File: /workspace/.ssh/config"))
        t.expectEqual(removal.level, .danger, "sensitive delete")
        t.expectTrue(removal.findings.first?.message.hasPrefix("Deletes") == true, "delete wording")
        t.expectEqual(assess(patch("*** Update File: src.txt\n*** Move to: .codex/hooks.json\n@@\n-a\n+b")).level,
                      .danger, "move destination scored")
        t.expectEqual(assess(patch("*** Update File: .codex/hooks.json\n*** Move to: src.txt\n@@\n-a\n+b")).level,
                      .danger, "move source scored")
        t.expectEqual(assess(patch("*** Add File: docs.txt\n+rm -rf /\n+*** Delete File: /etc/passwd")).level,
                      .safe, "added content never commands or headers")
        t.expectEqual(assess(patch("*** Update File: docs.txt\n@@\n *** Delete File: /etc/passwd\n-*** Add File: .codex/hooks.json\n+ordinary")).level,
                      .safe, "context and removed content never headers")
        let multiple = "*** Add File: normal.txt\n+hello\n\(config)\n*** Delete File: .env"
        let multi = assess(patch(multiple))
        t.expectTrue(multi.findings.contains { $0.code == "agent-config" }, "multi-file config")
        t.expectTrue(multi.findings.contains { $0.code == "secret-file" }, "multi-file secret")
        t.expectEqual(assess(patch(config).replacingOccurrences(of: "\n", with: "\r\n")).level,
                      .danger, "CRLF")
        t.expectEqual(assess(" \n" + patch(config) + "\n \t").level, .danger, "outer whitespace")
        t.expectEqual(assess(patch("  *** Add File: .codex/hooks.json  \n+x")).level,
                      .danger, "lenient add header whitespace")
        t.expectEqual(assess(patch("*** Environment ID: remote\n" + config)).level,
                      .danger, "environment preamble")
        for wrapper in ["<<EOF", "<<'EOF'", "<<\"EOF\""] {
            t.expectEqual(assess("\(wrapper)\n\(patch(config))\nEOF\n").level, .danger, "legacy \(wrapper)")
            t.expectEqual(assess("\(wrapper)\n\(patch(config))\nEOF\n".replacingOccurrences(of: "\n", with: "\r\n")).level,
                          .danger, "legacy wrapper with CRLF")
        }
        t.expectEqual(assess(patch("*** Update File: .codex/hooks.json\n-old\n+new")).level,
                      .danger, "first chunk without context header")
        t.expectEqual(assess(patch(config + "\n*** End of File\n")).level, .danger, "EOF marker")
        t.expectEqual(assess(patch("*** Update File: .codex/hooks.json\n*** End of File\n@@\n-old\n+new")).level,
                      .danger, "early EOF before chunk is a no-op")
        t.expectEqual(assess(patch(config) + "\n \n*** End Patch").level,
                      .danger, "upstream tolerates duplicate final end marker")
        for malformed in ["", "rm -rf /", "*** Begin Patch\n" + config,
                          patch("*** Update File: .codex/hooks.json\n@@"),
                          patch("*** Add File: .codex/hooks.json\nnot-added"),
                          patch("*** Move to: .codex/hooks.json"),
                          patch(config + "\n*** End of File\n*** End of File"),
                          patch("*** Environment ID:\n" + config)] {
            t.expectEqual(assess(malformed).level, .safe, "reject malformed patch")
        }
        let large = patch("*** Add File: docs.txt\n" + String(repeating: "+text\n", count: 20_000) + config)
        t.expectEqual(assess(large).level, .danger, "large content retains trailing target")
    }
}

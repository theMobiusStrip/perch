import Foundation
import PerchCore

extension Selftest {
    @MainActor
    static func skillRisk(_ t: Checker) {
        t.suite("RiskAssessor.skills")
        func file(_ path: String, tool: String = "Write", cwd: String? = nil) -> RiskAssessment {
            RiskAssessor.assess(agent: .codex, toolName: tool,
                                input: .object(["file_path": .string(path)]), cwd: cwd)
        }
        func shell(_ command: String, cwd: String? = nil) -> RiskAssessment {
            RiskAssessor.assess(agent: .codex, toolName: "exec_command",
                                input: .object(["cmd": .string(command)]), cwd: cwd)
        }
        for root in ["/Users/example/.claude/skills", "/Users/example/.agents/skills",
                     "/workspace/.claude/skills", "/workspace/.agents/skills"] {
            for tool in ["Write", "Edit", "create_file"] {
                t.expectEqual(file(root + "/audit/SKILL.md", tool: tool).level, .caution, "\(tool) instructions \(root)")
                t.expectEqual(file(root + "/audit/references/guide.md", tool: tool).level, .caution, "\(tool) references \(root)")
                t.expectEqual(file(root + "/audit/scripts/run.py", tool: tool).level, .danger, "\(tool) script \(root)")
                t.expectEqual(file(root + "/audit/scripts/runner", tool: tool).level, .danger, "\(tool) extensionless script \(root)")
                t.expectEqual(file(root + "/audit/main.js", tool: tool).level, .danger, "\(tool) code outside scripts \(root)")
                t.expectEqual(file(root + "/audit/assets/icon.png", tool: tool).level, .caution, "\(tool) supporting material \(root)")
            }
            let commands: [(String, RiskLevel)] = [
                ("printf text > \(root)/audit/SKILL.md", .caution),
                ("cat <<'EOF' > \(root)/audit/SKILL.md\n# instructions\nEOF", .caution),
                ("cp guide.md \(root)/audit/references/guide.md", .caution),
                ("cp run.py \(root)/audit/scripts/run.py 2>/dev/null", .danger),
                ("cp run.py 2>/dev/null \(root)/audit/scripts/run.py", .danger),
                ("cp > /tmp/log run.py \(root)/audit/scripts/run.py", .danger),
                ("cp run.py < /tmp/input \(root)/audit/scripts/run.py", .danger),
                ("cp run.py 2>&1 \(root)/audit/scripts/run.py", .danger),
                ("cp run.py &>/tmp/log \(root)/audit/scripts/run.py", .danger),
                ("cp -f \"/tmp/run.py\" \(root)/audit/scripts/run.py", .danger),
                ("cp -f \"/tmp/run.py\" \"\(root)/audit/scripts/run.py\"", .danger),
                ("/bin/cp run.py \(root)/audit/main.js", .danger),
                ("mv run.py \(root)/audit/scripts/run.py", .danger),
                ("install run.sh \(root)/audit/scripts/run.sh", .danger),
                ("tee -a \(root)/audit/SKILL.md", .caution),
                ("sed -i 's/old/new/' \(root)/audit/SKILL.md", .caution),
                ("sed -i '' -e 's/old/new/' \(root)/audit/scripts/run.py /workspace/other.py", .danger),
                ("sed -i \(root)/audit/scripts/run.py -e 's/old/new/' /workspace/other.py", .danger),
                ("sed -i 's/old/new/' \(root)/audit/scripts/run.py /workspace/other.py", .danger),
                ("sed -i.bak -e 's/old/new/' /workspace/other.py \(root)/audit/scripts/run.py", .danger),
                ("sed -i .bak -f /tmp/edit.sed \(root)/audit/scripts/run.py /workspace/other.py", .danger),
                ("sed --in-place --expression='s/old/new/' \(root)/audit/scripts/run.py /workspace/other.py", .danger),
                ("mkdir -p \(root)/audit", .caution),
                ("ln -s /workspace/skill-source \(root)/audit", .caution),
                ("ln -sf /tmp/skill-source \(root)/audit", .danger),
                ("ln -s /private/var/tmp/skill-source \(root)/audit", .danger),
                ("chmod +x \(root)/audit/scripts/run.sh", .danger),
                ("chmod +x \(root)/audit/SKILL.md", .danger),
                ("echo cp guide.md \(root)/audit/SKILL.md", .safe),
                ("echo \"cp guide.md \(root)/audit/SKILL.md\"", .safe),
                ("cat \(root)/audit/SKILL.md 2>/dev/null", .safe),
                ("ls -la \(root)", .safe),
                ("cp \(root)/audit/SKILL.md /workspace/copy.md", .safe),
                ("cp -f \"\(root)/audit/scripts/run.py\" 2>/dev/null /workspace/copy.py", .safe),
                ("cp source.py < \(root)/audit/scripts/run.py /workspace/copy.py", .safe),
                ("sed -e 's/old/new/' \(root)/audit/scripts/run.py", .safe),
                ("sed -i -e '/\\.agents\\/skills\\/a\\/run.py/d' /workspace/copy.py", .safe),
                ("git log --grep \(root)/audit/SKILL.md", .safe),
                ("git commit -m 'touch \(root)/audit/SKILL.md'", .safe),
            ]
            for (command, expected) in commands {
                t.expectEqual(shell(command).level, expected, command)
                t.expectEqual(shell(" \t" + command).level, expected, "leading whitespace " + command)
            }
        }
        t.expectEqual(file(".agents/skills/a/SKILL.md").level, .caution, "relative registration without cwd")
        t.expectEqual(file("SKILL.md", cwd: "/workspace/.agents/skills/a").level, .caution, "file cwd instructions")
        t.expectEqual(file("run.py", cwd: "/workspace/.claude/skills/a/scripts").level, .danger, "file cwd script")
        t.expectEqual(file(".agents/skills/../../src/main.js", cwd: "/workspace").level, .safe, "lexical path leaves skills")
        t.expectEqual(file("/workspace/.agents/skills-copy/a/SKILL.md").level, .safe, "similarly named sibling")
        t.expectEqual(file("/workspace/skills/a/SKILL.md").level, .safe, "unregistered source unknown")
        t.expectEqual(shell("cp a SKILL.md", cwd: "/workspace/.agents/skills/a").level, .caution, "shell cwd instructions")
        t.expectEqual(shell("cd /workspace/.agents/skills/a && touch SKILL.md").level, .caution, "shell cd instructions")
        t.expectEqual(shell("cp run.py \"$HOME/.agents/skills/a/scripts/run.py\"").level, .danger, "double quoted operand")
        t.expectEqual(shell("cp guide.md \"/workspace/.agents/skills/a/references/a guide.md\"").level,
                      .caution, "spaces in double quoted operand")
        t.expectEqual(shell("echo \"write > ~/.agents/skills/a/SKILL.md\"").level, .safe, "quoted redirect mention")
        t.expectEqual(shell("cat \"guide > .agents/skills/a/SKILL.md\"").level, .safe, "operator in quoted path")
        t.expectEqual(shell("printf 'touch ~/.agents/skills/a/SKILL.md' > /tmp/help.txt").level, .safe, "single quoted prose")
        t.expectEqual(shell("git commit -m \"cp -f source.py /workspace/.agents/skills/a/run.py\"").level,
                      .safe, "double quoted prose is not a mutation")
        t.expectEqual(shell("gh api /repos/example/project -f body=\"cp -f source.py /workspace/.agents/skills/a/run.py\"").level,
                      .safe, "gh body field is prose")
        t.expectEqual(shell("printf \"cp -f source.py /workspace/.agents/skills/a/run.py\"").level,
                      .safe, "printf format is prose")
        t.expectEqual(shell("sed -i --expression='/workspace/.agents/skills/a/run.py/d' /workspace/other.py").level,
                      .safe, "attached sed expression is not a file operand")
        t.expectEqual(shell("cat 'guide > .agents/skills/a/SKILL.md'").level, .safe, "single quoted redirect mention")
        t.expectEqual(shell("cp source.py '/workspace/.agents/skills/a/run.py'").level, .danger, "single quoted mutation operand")
        for command in ["printf text > ~/outside.py", "printf text > \"$HOME/outside.py\"",
                        "printf text > ${HOME}/outside.py", "printf text > $OUTPUT/outside.py",
                        "cd ~ && printf text > outside.py", "cd \"$HOME\" && printf text > outside.py"] {
            t.expectEqual(shell(command, cwd: "/workspace/.agents/skills/a").level, .safe,
                          "symbolic shell root is not under skill cwd: " + command)
        }
        t.expectEqual(shell("printf text > \"~/outside.py\"", cwd: "/workspace/.agents/skills/a").level,
                      .danger, "quoted tilde is a literal relative directory")
        t.expectEqual(shell("printf text > '$HOME/outside.py'", cwd: "/workspace/.agents/skills/a").level,
                      .danger, "single quoted variable is a literal relative directory")
        t.expectEqual(shell("cd ~/.agents/skills/a && touch run.py").level, .danger, "symbolic cd retains known skill suffix")
        t.expectEqual(shell("ln -s ./source /workspace/.agents/skills/a", cwd: "/tmp").level,
                      .caution, "relative symlink target does not use command cwd")
        t.expectEqual(shell("ln -s ./source /tmp/.agents/skills/a", cwd: "/workspace").level,
                      .danger, "relative symlink target under temporary destination")
        t.expectEqual(shell("ln ./source /workspace/.agents/skills/a", cwd: "/tmp").level,
                      .danger, "hard link source does use command cwd")
        t.expectEqual(shell("ln ./source /tmp/.agents/skills/a", cwd: "/workspace").level,
                      .caution, "hard link target does not relocate source")
        let workdir = RiskAssessor.assess(agent: .codex, toolName: "exec_command",
            input: .object(["cmd": .string("touch scripts/run.py"), "workdir": .string("/workspace/.agents/skills/a")]),
            cwd: "/workspace")
        t.expectEqual(workdir.level, .danger, "explicit shell workdir")
        let patch = "*** Begin Patch\n*** Add File: .agents/skills/a/scripts/run.py\n+print('hello')\n*** End Patch"
        t.expectEqual(RiskAssessor.assess(agent: .codex, toolName: "apply_patch",
            input: .object(["command": .string(patch)]), cwd: "/workspace").level, .danger, "patch script target")
        let markdownPatch = patch.replacingOccurrences(of: "scripts/run.py", with: "SKILL.md")
        t.expectEqual(RiskAssessor.assess(agent: .codex, toolName: "apply_patch",
            input: .object(["command": .string(markdownPatch)]), cwd: "/workspace").level, .caution, "patch instruction target")
        t.expectTrue(file("/workspace/.agents/skills/a/scripts/run.py").findings.allSatisfy {
            !$0.message.contains("executes in future sessions")
        }, "script finding does not claim automatic execution")
    }
}

import Foundation
import PerchCore

extension Selftest {
    @MainActor
    static func skillFrontmatter(_ t: Checker) {
        t.suite("SkillsAudit.frontmatter")
        func parse(_ yaml: String) -> SkillFrontmatter {
            SkillFrontmatter.parse("---\n\(yaml)\n---\n# Instructions\n")
        }
        let missingSeparator = parse("name:demo\ndescription:demo")
        t.expectEqual(missingSeparator.name, nil, "plain scalar is not a name mapping")
        t.expectEqual(missingSeparator.description, nil, "plain scalar is not a description mapping")
        t.expectFalse(missingSeparator.unsupported.isEmpty, "nonmapping document is incomplete")

        let flow = parse("{name: demo, description: Demo skill}")
        t.expectFalse(flow.unsupported.isEmpty, "valid flow mapping explicitly unsupported")
        t.expectTrue(flow.invalid.isEmpty, "valid flow mapping not called invalid")
        for metadata in ["[", "{broken", "\"unterminated", "'unterminated", "*unknown", "!custom value",
                         "\n  tags: [", "\n  note: description: value", "\n  tags:\n    - audit\n   broken: indentation"] {
            let result = parse("name: demo\ndescription: Demo skill\nmetadata: \(metadata)")
            t.expectFalse(result.unsupported.isEmpty, "unhandled metadata cannot be clean: \(metadata)")
        }
        let nested = parse("""
        name: demo
        description: Demo skill
        license: MIT
        metadata:
          tags:
            - audit
            - 'local skills'
          author:
            name: Example
            active: true
          version: 1
          nothing: null
        """)
        t.expectEqual(nested.name, "demo", "common nested metadata retains name")
        t.expectEqual(nested.description, "Demo skill", "common nested metadata retains description")
        t.expectTrue(nested.unsupported.isEmpty, "common nested mappings and scalar lists supported")
        t.expectTrue(nested.invalid.isEmpty, "common metadata is valid")
        let metadataBlock = parse("name: demo\ndescription: Demo skill\nmetadata: |\n  First line.\n  Second line.")
        t.expectTrue(metadataBlock.unsupported.isEmpty, "ignored block scalar supported")
        let reservedScalar = parse("name: demo\ndescription: @reserved")
        t.expectFalse(reservedScalar.unsupported.isEmpty, "reserved plain scalar is incomplete")
        let duplicateUnknown = parse("name: demo\ndescription: Demo skill\nmetadata: one\nmetadata: two")
        t.expectFalse(duplicateUnknown.invalid.isEmpty, "duplicate ignored key cannot be clean")

        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("perch-frontmatter-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fixture) }
        do {
            let home = fixture.appendingPathComponent("home")
            let cases = [
                "separator": "name:demo\ndescription:demo",
                "metadata": "name: demo\ndescription: Demo skill\nmetadata: [",
                "flow": "{name: demo, description: Demo skill}",
            ]
            for (name, yaml) in cases {
                let source = home.appendingPathComponent(".agents/skills/\(name)")
                try fm.createDirectory(at: source, withIntermediateDirectories: true)
                try Data("---\n\(yaml)\n---\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
            }
            let snapshot = SkillScanner.scan(claudeDir: fixture.appendingPathComponent("claude"), home: home,
                                             now: Date().addingTimeInterval(3 * 86_400))
            t.expectEqual(snapshot.records.count, cases.count, "all unsupported fixtures retained")
            for record in snapshot.records {
                t.expectTrue(record.issues.contains(.scanIncomplete), "unsupported manifest is incomplete")
                t.expectFalse(record.isDiscoverable, "unsupported manifest not declared discoverable")
                t.expectFalse(record.canReview, "unsupported manifest cannot be reviewed")
                t.expectFalse(record.issues.contains(.invalidSkill), "uninterpreted manifest not falsely invalid")
            }
        } catch {
            t.expectTrue(false, "frontmatter fixture error: \(error)")
        }
    }
}

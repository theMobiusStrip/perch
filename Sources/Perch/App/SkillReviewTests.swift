import Darwin
import Foundation
import PerchCore

extension Selftest {
    @MainActor
    static func skillReviewMarkers(_ t: Checker) {
        t.suite("SkillsAudit.reviewMarkers")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("perch-skill-review-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("markers.json")
        do {
            t.expectEqual(try SkillAuditBaseline.load(from: file).acks, [:], "missing starts empty")
            let markers = SkillAuditBaseline(acks: ["source-a": "fingerprint-a"])
            try markers.save(to: file)
            t.expectEqual(try SkillAuditBaseline.load(from: file).acks, markers.acks, "markers round trip")
            let permissions = try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            t.expectEqual(permissions?.intValue, 0o600, "markers private")
            t.expectEqual(try fm.contentsOfDirectory(atPath: root.path), ["markers.json"], "staging removed")

            let corrupt = Data("not-json".utf8)
            try corrupt.write(to: file)
            let model = SkillAuditModel(baselineURL: file)
            let record = SkillRecord(id: "source-a", name: "review", sourcePath: "/example/skills/review",
                                     registrations: [], issues: [.changed], fingerprint: "new")
            model.injectSnapshot(SkillAuditSnapshot(records: [record]))
            t.expectFalse(model.acknowledge(record), "save failure reports no review receipt")
            t.expectTrue(model.errorMessage != nil, "corrupt marker error visible")
            t.expectEqual(try Data(contentsOf: file), corrupt, "corrupt file preserved")
            t.expectFalse(model.snapshot.records[0].isReviewed, "failed write never shows reviewed")

            for issue in [SkillIssue.unreadable, .scanIncomplete, .brokenLink, .invalidSkill] {
                var invalid = record
                invalid.issues = [issue]
                t.expectFalse(invalid.canReview, "cannot acknowledge \(issue.rawValue)")
                t.expectFalse(model.acknowledge(invalid), "no receipt for \(issue.rawValue)")
            }
            var reviewed = record
            reviewed.isReviewed = true
            t.expectFalse(model.acknowledge(reviewed), "already reviewed does not save again")
            t.expectEqual(try Data(contentsOf: file), corrupt, "ineligible reviews leave marker storage untouched")
            let selectionRequest = model.selectionRequest
            model.select(record.id)
            t.expectEqual(model.selectedSkillID, record.id, "explicit source open selects its ID")
            t.expectEqual(model.selectionRequest, selectionRequest + 1, "explicit source open requests filter reveal")
            model.select(record.id)
            t.expectEqual(model.selectionRequest, selectionRequest + 2, "reopening same source still requests reveal")
            let target = root.appendingPathComponent("target.json")
            try corrupt.write(to: target)
            try fm.removeItem(at: file)
            try fm.createSymbolicLink(at: file, withDestinationURL: target)
            do {
                _ = try SkillAuditBaseline.load(from: file)
                t.expectTrue(false, "symlink marker rejected")
            } catch { t.expectTrue(true, "symlink marker rejected") }
            try markers.save(to: file)
            t.expectEqual(try Data(contentsOf: target), corrupt, "atomic replacement preserves symlink target")
            t.expectEqual(try SkillAuditBaseline.load(from: file).acks, markers.acks, "replacement readable")

            let fifo = root.appendingPathComponent("fifo.json")
            t.expectEqual(mkfifo(fifo.path, mode_t(0o600)), 0, "FIFO fixture created")
            do {
                _ = try SkillAuditBaseline.load(from: fifo)
                t.expectTrue(false, "FIFO marker rejected without blocking")
            } catch { t.expectTrue(true, "FIFO marker rejected without blocking") }
            let oversized = root.appendingPathComponent("oversized.json")
            try Data(repeating: 0, count: 4 * 1024 * 1024 + 1).write(to: oversized)
            do {
                _ = try SkillAuditBaseline.load(from: oversized)
                t.expectTrue(false, "oversized marker rejected")
            } catch { t.expectTrue(true, "oversized marker rejected") }

            let alias = root.appendingPathComponent("parent-alias")
            try fm.createSymbolicLink(at: alias, withDestinationURL: root)
            do {
                try markers.save(to: alias.appendingPathComponent("redirected.json"))
                t.expectTrue(false, "symlink parent rejected")
            } catch { t.expectTrue(true, "symlink parent rejected") }
            t.expectFalse(fm.fileExists(atPath: root.appendingPathComponent("redirected.json").path),
                          "no marker written through parent symlink")

            var unsafeName = record
            unsafeName.name = "review\u{1B}[31m\nspoof"
            let report = SkillAuditSnapshot(records: [unsafeName]).reportText
            t.expectFalse(report.contains("\u{1B}"), "report strips terminal escapes")
            t.expectFalse(report.contains("\nspoof"), "report strips injected lines")
        } catch {
            t.expectTrue(false, "fixture error: \(error)")
        }
    }
}

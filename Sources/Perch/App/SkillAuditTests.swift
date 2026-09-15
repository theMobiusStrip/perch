import Darwin
import Foundation
import PerchCore

extension Selftest {
    @MainActor
    static func skillAudit(_ t: Checker) {
        t.suite("SkillAudit")
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("perch-skills-test-\(UUID().uuidString)")
        let user = fixture.appendingPathComponent("user")
        let claude = user.appendingPathComponent("custom-claude")
        let claudeSkills = claude.appendingPathComponent("skills")
        let codexSkills = user.appendingPathComponent(".agents/skills")
        let shared = fixture.appendingPathComponent("shared")
        let now = Date()
        let old = now.addingTimeInterval(-172_800)
        defer { try? fm.removeItem(at: fixture) }
        func directory(_ url: URL) throws {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        func write(_ text: String, _ url: URL) throws {
            try directory(url.deletingLastPathComponent())
            try Data(text.utf8).write(to: url)
        }
        func skill(_ url: URL, name: String = "sample", description: String = "A test skill.") throws {
            try write("---\nname: \(name)\ndescription: \(description)\n---\n# Skill\n", url.appendingPathComponent("SKILL.md"))
        }
        func scan(_ projects: [URL] = [], acks: [String: String] = [:], limits: SkillScanLimits = SkillScanLimits()) -> SkillAuditSnapshot {
            SkillScanner.scan(claudeDir: claude, home: user, projectDirs: projects, acks: acks, now: now, limits: limits)
        }
        func record(_ snapshot: SkillAuditSnapshot, _ name: String) -> SkillRecord? {
            snapshot.records.first { $0.name == name }
        }
        func diskInventory() -> [String: String] {
            guard let iterator = fm.enumerator(at: fixture, includingPropertiesForKeys: nil) else { return [:] }
            var inventory: [String: String] = [:]
            for case let url as URL in iterator {
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                let kind = info.st_mode & S_IFMT
                var content = ""
                if kind == S_IFREG { content = (try? Data(contentsOf: url).base64EncodedString()) ?? "unreadable" }
                if kind == S_IFLNK { content = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "unreadable" }
                inventory[url.path] = "\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(content)"
            }
            return inventory
        }
        do {
            try directory(claudeSkills)
            try directory(codexSkills)
            try skill(shared, name: "shared")
            try write("print('first')\n", shared.appendingPathComponent("scripts/task.py"))
            try write("Reference", shared.appendingPathComponent("references/guide.md"))
            try write("Asset", shared.appendingPathComponent("assets/icon.txt"))
            let claudeLink = claudeSkills.appendingPathComponent("shared")
            let codexLink = codexSkills.appendingPathComponent("shared")
            try fm.createSymbolicLink(at: claudeLink, withDestinationURL: shared)
            try fm.createSymbolicLink(at: codexLink, withDestinationURL: shared)
            let first = scan()
            let baseline = record(first, "shared")
            t.expectEqual(first.records.count, 1, "canonical source groups registrations")
            t.expectEqual(baseline?.registrations.count, 2, "two agent registrations")
            t.expectEqual(baseline?.isShared, true, "shared source badge")
            t.expectEqual(baseline?.isDiscoverable, true, "valid local skill discoverable")
            t.expectEqual(baseline?.counts, SkillFileCounts(scripts: 1, references: 1, assets: 1, total: 4), "content counts")
            t.expectEqual(baseline?.issues.contains(.changed), true, "first sight recent change")
            guard let baseline else { t.expectTrue(false, "baseline exists"); return }
            let acks = [baseline.id: baseline.fingerprint]
            let reviewed = record(scan(acks: acks), "shared")
            t.expectEqual(reviewed?.isReviewed, true, "matching fingerprint reviewed")
            t.expectEqual(reviewed?.issues.contains(.changed), false, "review clears changed only")
            let targetFile = shared.appendingPathComponent("scripts/task.py")
            let targetAttributes = try fm.attributesOfItem(atPath: targetFile.path)
            let linkAttributes = try fm.attributesOfItem(atPath: claudeLink.path)
            try write("print('other')\n", targetFile)
            if let date = targetAttributes[.modificationDate] as? Date {
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: targetFile.path)
            }
            let changed = record(scan(acks: acks), "shared")
            t.expectTrue(changed?.fingerprint != baseline.fingerprint, "target bytes change fingerprint with preserved mtime")
            t.expectEqual(changed?.issues.contains(.changed), true, "target bytes invalidate review")
            t.expectEqual((try fm.attributesOfItem(atPath: claudeLink.path))[.modificationDate] as? Date,
                          linkAttributes[.modificationDate] as? Date, "registration mtime stays unchanged")

            let alternate = fixture.appendingPathComponent("alternate")
            try skill(alternate, name: "alternate")
            try fm.removeItem(at: codexLink)
            try fm.createSymbolicLink(at: codexLink, withDestinationURL: alternate)
            let retargeted = scan(acks: acks)
            t.expectEqual(retargeted.records.count, 2, "retarget separates canonical sources")
            t.expectTrue(record(retargeted, "shared")?.fingerprint != changed?.fingerprint, "registration change changes fingerprint")
            t.expectEqual(record(retargeted, "alternate")?.isReviewed, false, "new target not reviewed")
            var registrationAcks = acks
            for registration in baseline.registrations { registrationAcks[registration.reviewKey] = baseline.fingerprint }
            let delayedRetarget = SkillScanner.scan(claudeDir: claude, home: user, acks: registrationAcks,
                                                   now: now.addingTimeInterval(3 * 86_400))
            t.expectEqual(record(delayedRetarget, "alternate")?.issues.contains(.changed), true,
                          "registration baseline flags old retarget outside recency window")

            let identityHome = fixture.appendingPathComponent("identity-home")
            let identityClaude = identityHome.appendingPathComponent(".claude")
            let identitySource = fixture.appendingPathComponent("identity-source")
            let identityAlias = fixture.appendingPathComponent("IDENTITY-SOURCE")
            try skill(identitySource, name: "identity")
            try directory(identityClaude.appendingPathComponent("skills"))
            try directory(identityHome.appendingPathComponent(".agents/skills"))
            try fm.createSymbolicLink(at: identityClaude.appendingPathComponent("skills/one"), withDestinationURL: identitySource)
            var canonicalInfo = stat()
            var aliasInfo = stat()
            let sameCaseAlias = lstat(identitySource.path, &canonicalInfo) == 0 && lstat(identityAlias.path, &aliasInfo) == 0 &&
                canonicalInfo.st_dev == aliasInfo.st_dev && canonicalInfo.st_ino == aliasInfo.st_ino
            if !sameCaseAlias { try skill(identityAlias, name: "identity") }
            let identityLink = identityHome.appendingPathComponent(".agents/skills/two")
            try fm.createSymbolicLink(at: identityLink, withDestinationURL: identityAlias)
            let identityScan = SkillScanner.scan(claudeDir: identityClaude, home: identityHome)
            t.expectEqual(identityScan.records.count, sameCaseAlias ? 1 : 2, "source grouping follows physical identity, not path case")
            t.expectEqual(identityScan.registrationCount, 2, "case aliases retain both registrations")
            t.expectEqual(identityScan.records.allSatisfy(\.isShared), sameCaseAlias, "only same inode is a shared source")
            if sameCaseAlias, let identityRecord = identityScan.records.first {
                try fm.removeItem(at: identityLink)
                try fm.createSymbolicLink(at: identityLink, withDestinationURL: identitySource)
                let spellingChange = SkillScanner.scan(claudeDir: identityClaude, home: identityHome,
                                                       acks: [identityRecord.id: identityRecord.fingerprint])
                t.expectEqual(spellingChange.records.first?.id, identityRecord.id, "case alias keeps source identity")
                t.expectTrue(spellingChange.records.first?.fingerprint != identityRecord.fingerprint,
                             "original link spelling remains fingerprinted after physical-source deduplication")
                t.expectEqual(spellingChange.records.first?.isReviewed, false, "changed link text invalidates review")
            }
            let identityCopy = fixture.appendingPathComponent("identity-copy")
            try skill(identityCopy, name: "identity")
            try fm.removeItem(at: identityLink)
            try fm.createSymbolicLink(at: identityLink, withDestinationURL: identityCopy)
            let distinctIdentity = SkillScanner.scan(claudeDir: identityClaude, home: identityHome)
            t.expectEqual(distinctIdentity.records.count, 2, "identical bytes in distinct directories do not merge")

            let broken = claudeSkills.appendingPathComponent("broken")
            try fm.createSymbolicLink(at: broken, withDestinationURL: fixture.appendingPathComponent("missing"))
            let cycleA = claudeSkills.appendingPathComponent("cycle-a")
            let cycleB = claudeSkills.appendingPathComponent("cycle-b")
            try fm.createSymbolicLink(at: cycleA, withDestinationURL: cycleB)
            try fm.createSymbolicLink(at: cycleB, withDestinationURL: cycleA)
            t.expectEqual(record(scan(), "broken")?.issues.contains(.brokenLink), true, "dangling link visible")
            t.expectEqual(record(scan(), "broken")?.isDiscoverable, false, "dangling link not discoverable")
            t.expectEqual(record(scan(), "cycle-a")?.issues.contains(.scanIncomplete), true, "cycle bounded and visible")
            try write("ordinary file", fixture.appendingPathComponent("ordinary-file"))
            try fm.createSymbolicLink(atPath: claudeSkills.appendingPathComponent("nondirectory-hop").path,
                                      withDestinationPath: fixture.path + "/ordinary-file/../shared")
            let nondirectoryHop = record(scan(), "nondirectory-hop")
            t.expectEqual(nondirectoryHop?.issues.contains(.scanIncomplete), true, "regular file before dot-dot cannot be traversed")
            t.expectEqual(nondirectoryHop?.isDiscoverable, false, "invalid intermediate component not discoverable")

            try directory(claudeSkills.appendingPathComponent("missing-manifest"))
            try directory(claudeSkills.appendingPathComponent("directory-manifest/SKILL.md"))
            try directory(claudeSkills.appendingPathComponent("symlink-manifest"))
            try fm.createSymbolicLink(at: claudeSkills.appendingPathComponent("symlink-manifest/SKILL.md"),
                                      withDestinationURL: shared.appendingPathComponent("SKILL.md"))
            try write("---\nname: []\ndescription: true\n---\n", claudeSkills.appendingPathComponent("bad/SKILL.md"))
            try write("---\nname: &name valid\ndescription: *name\n---\n", codexSkills.appendingPathComponent("yaml-alias/SKILL.md"))
            try write("---\ndescription: Claude directory name fallback\n---\n", claudeSkills.appendingPathComponent("fallback/SKILL.md"))
            try write("# Plain Claude skill\nInstructions from the body.\n", claudeSkills.appendingPathComponent("plain/SKILL.md"))
            try write("---\ndescription: Missing Codex name\n---\n", codexSkills.appendingPathComponent("required/SKILL.md"))
            let formats = scan()
            t.expectEqual(record(formats, "missing-manifest")?.issues.contains(.invalidSkill), true, "missing manifest invalid")
            t.expectEqual(record(formats, "directory-manifest")?.issues.contains(.invalidSkill), true, "directory manifest invalid")
            t.expectEqual(record(formats, "symlink-manifest")?.issues.contains(.scanIncomplete), true, "symlink manifest is uninspected")
            for name in ["missing-manifest", "directory-manifest", "symlink-manifest"] {
                guard let malformed = record(formats, name) else { t.expectTrue(false, "malformed manifest fixture exists"); continue }
                t.expectEqual(malformed.isDiscoverable, false, "\(name) not discoverable")
                t.expectEqual(malformed.canReview, false, "\(name) cannot be reviewed")
                let marked = SkillScanner.scan(claudeDir: claude, home: user,
                                                acks: [malformed.id: malformed.fingerprint],
                                                now: now.addingTimeInterval(3 * 86_400))
                t.expectEqual(record(marked, name)?.isReviewed, false, "\(name) ignores matching review marker")
            }
            t.expectEqual(record(formats, "bad")?.issues.contains(.invalidSkill), true, "nonstring fields invalid")
            t.expectEqual(record(formats, "yaml-alias")?.issues.contains(.scanIncomplete), true, "unsupported YAML visible")
            t.expectEqual(record(formats, "yaml-alias")?.issues.contains(.invalidSkill), false, "unsupported YAML not false invalid")
            t.expectEqual(record(formats, "fallback")?.isDiscoverable, true, "Claude accepts directory fallback")
            t.expectEqual(record(formats, "plain")?.isDiscoverable, true, "Claude accepts plain Markdown")
            t.expectEqual(record(formats, "required")?.issues.contains(.invalidSkill), true, "Codex requires name")

            let nested = claudeSkills.appendingPathComponent("nested")
            try skill(nested, name: "nested")
            try fm.createSymbolicLink(at: nested.appendingPathComponent("external"), withDestinationURL: shared)
            t.expectEqual(record(scan(), "nested")?.issues.contains(.scanIncomplete), true, "nested external link disclosed")
            let fifo = nested.appendingPathComponent("pipe")
            t.expectEqual(mkfifo(fifo.path, mode_t(0o600)), 0, "FIFO fixture")
            t.expectTrue(record(scan(), "nested")?.notes.contains(where: { $0.contains("Special filesystem") }) == true, "FIFO never read")
            let unreadable = claudeSkills.appendingPathComponent("locked")
            try skill(unreadable, name: "locked")
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
            let locked = record(scan(), "locked")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
            if geteuid() != 0 {
                t.expectEqual(locked?.issues.contains(.unreadable), true, "unreadable source visible")
                t.expectEqual(locked?.isDiscoverable, false, "unreadable source not discoverable")
            } else {
                t.expectTrue(locked != nil, "privileged reader retains source")
            }

            let project = fixture.appendingPathComponent("repo")
            let child = project.appendingPathComponent("child")
            let unrelated = fixture.appendingPathComponent("other-repo")
            try directory(project.appendingPathComponent(".git"))
            try directory(unrelated.appendingPathComponent(".git"))
            try directory(child)
            try skill(project.appendingPathComponent(".agents/skills/one"), name: "overlap")
            try skill(child.appendingPathComponent(".agents/skills/two"), name: "overlap")
            try skill(unrelated.appendingPathComponent(".agents/skills/three"), name: "overlap")
            let conflicts = scan([child, unrelated]).records.filter { $0.name == "overlap" }
            t.expectEqual(conflicts.filter { $0.issues.contains(.nameConflict) }.count, 2, "only overlapping project scopes conflict")
            t.expectEqual(SkillScanner.projectRoots(from: [child]).map(\.path).sorted(),
                          [project.path, child.path].sorted(), "known ancestors stop at repository")
            t.expectEqual(SkillScanner.projectRoots(from: [shared]).map(\.path), [shared.path], "nonrepo cwd enrolls no ancestors")

            let boundaryRepo = fixture.appendingPathComponent("boundary-repo")
            let nestedRepo = boundaryRepo.appendingPathComponent("nested-repo")
            let nestedWorktree = boundaryRepo.appendingPathComponent(".claude/worktrees/nested")
            try directory(boundaryRepo.appendingPathComponent(".git"))
            try directory(nestedRepo.appendingPathComponent(".git"))
            try write("gitdir: /example/worktree-metadata\n", nestedWorktree.appendingPathComponent(".git"))
            for root in [boundaryRepo, nestedRepo, nestedWorktree] {
                for agentDir in [".claude", ".agents"] {
                    try skill(root.appendingPathComponent("\(agentDir)/skills/boundaries"), name: "boundaries")
                }
            }
            let independentContexts = scan([boundaryRepo, nestedRepo, nestedWorktree]).records.filter { $0.name == "boundaries" }
            t.expectEqual(independentContexts.count, 6, "both agents' independent repository fixtures discovered")
            t.expectTrue(independentContexts.allSatisfy { !$0.issues.contains(.nameConflict) },
                         "nested repository and worktree boundaries prevent false conflicts")
            t.expectEqual(SkillScanner.projectRoots(from: [nestedWorktree]).map(\.path), [nestedWorktree.path],
                          "worktree gitfile stops ancestor discovery")
            let siblingA = boundaryRepo.appendingPathComponent("sibling-a")
            let siblingB = boundaryRepo.appendingPathComponent("sibling-b")
            for root in [siblingA, siblingB] {
                try skill(root.appendingPathComponent(".agents/skills/siblings"), name: "siblings")
            }
            let siblingContexts = scan([siblingA, siblingB]).records.filter { $0.name == "siblings" }
            t.expectEqual(siblingContexts.count, 2, "sibling project fixtures discovered")
            t.expectTrue(siblingContexts.allSatisfy { !$0.issues.contains(.nameConflict) },
                         "same repository does not make sibling discovery contexts overlap")

            try skill(claudeSkills.appendingPathComponent("deploy"), name: "personal-label")
            try skill(project.appendingPathComponent(".claude/skills/deploy"), name: "project-label")
            try skill(claudeSkills.appendingPathComponent("display-one"), name: "shared-display")
            try skill(project.appendingPathComponent(".claude/skills/display-two"), name: "shared-display")
            let commandNames = scan([project])
            t.expectEqual(record(commandNames, "personal-label")?.issues.contains(.nameConflict), true,
                          "Claude same command conflicts despite different display names")
            t.expectEqual(record(commandNames, "project-label")?.issues.contains(.nameConflict), true,
                          "Claude project command conflict visible")
            let sameDisplay = commandNames.records.filter { $0.name == "shared-display" }
            t.expectEqual(sameDisplay.count, 2, "different Claude command names retained")
            t.expectTrue(sameDisplay.allSatisfy { !$0.issues.contains(.nameConflict) },
                         "Claude matching display names do not create command conflicts")

            let aliasedSource = fixture.appendingPathComponent("alias-source")
            try write("# Claude skill without frontmatter\n", aliasedSource.appendingPathComponent("SKILL.md"))
            try fm.createSymbolicLink(at: claudeSkills.appendingPathComponent("alpha-alias"), withDestinationURL: aliasedSource)
            try fm.createSymbolicLink(at: claudeSkills.appendingPathComponent("second-alias"), withDestinationURL: aliasedSource)
            try write("# Conflicting project alias\n", project.appendingPathComponent(".claude/skills/second-alias/SKILL.md"))
            let aliases = scan([project])
            t.expectEqual(record(aliases, "alpha-alias")?.issues.contains(.nameConflict), true, "shared source's second alias conflicts")
            t.expectEqual(record(aliases, "second-alias")?.issues.contains(.nameConflict), true, "project alias conflict visible")

            let emptyHome = fixture.appendingPathComponent("empty-home")
            let homeAlias = fixture.appendingPathComponent("home-alias")
            try directory(emptyHome)
            try fm.createSymbolicLink(at: homeAlias, withDestinationURL: emptyHome)
            let absentViaAlias = SkillScanner.scan(claudeDir: homeAlias.appendingPathComponent(".claude"), home: homeAlias)
            t.expectTrue(absentViaAlias.issues.isEmpty, "missing optional roots beneath valid ancestor link stay absent")
            try write("not a directory", emptyHome.appendingPathComponent(".agents"))
            let malformedRoot = SkillScanner.scan(claudeDir: emptyHome.appendingPathComponent(".claude"), home: emptyHome)
            t.expectTrue(malformedRoot.issues.contains { $0.issue == .scanIncomplete }, "nondirectory root component visible")
            try fm.removeItem(at: emptyHome.appendingPathComponent(".agents"))
            try directory(emptyHome.appendingPathComponent(".agents"))
            try fm.createSymbolicLink(at: emptyHome.appendingPathComponent(".agents/skills"),
                                      withDestinationURL: emptyHome.appendingPathComponent("missing-target"))
            let danglingRoot = SkillScanner.scan(claudeDir: emptyHome.appendingPathComponent(".claude"), home: emptyHome)
            t.expectTrue(danglingRoot.issues.contains { $0.issue == .brokenLink }, "dangling root still reported")

            try skill(user.appendingPathComponent(".claude/skills/excluded"), name: "excluded-default")
            try skill(claudeSkills.appendingPathComponent("synced/excluded"), name: "excluded-synced")
            try skill(codexSkills.appendingPathComponent(".system/excluded"), name: "excluded-system")
            let excluded = scan().records.map(\.name)
            t.expectTrue(!excluded.contains("excluded-default"), "Claude config override replaces default")
            t.expectTrue(!excluded.contains("excluded-synced"), "Claude synced excluded")
            t.expectTrue(!excluded.contains("excluded-system"), "bundled system excluded")

            var limited = SkillScanLimits()
            limited.maxFilesPerSkill = 1
            t.expectEqual(record(scan(limits: limited), "shared")?.issues.contains(.scanIncomplete), true, "file limit visible")
            limited = SkillScanLimits(); limited.maxFileBytes = 4
            t.expectEqual(record(scan(limits: limited), "shared")?.issues.contains(.scanIncomplete), true, "file byte limit visible")
            limited = SkillScanLimits(); limited.maxDepth = 0
            t.expectEqual(record(scan(limits: limited), "shared")?.issues.contains(.scanIncomplete), true, "depth limit visible")
            limited = SkillScanLimits(); limited.maxTotalBytes = 1
            t.expectTrue(scan(limits: limited).records.contains { $0.issues.contains(.scanIncomplete) }, "total byte limit visible")
            limited = SkillScanLimits(); limited.maxSkills = 1
            t.expectTrue(scan(limits: limited).issues.contains { $0.issue == .scanIncomplete }, "registration limit visible")
            limited = SkillScanLimits(); limited.maxEntriesPerDirectory = 1
            t.expectTrue(scan(limits: limited).issues.contains { $0.issue == .scanIncomplete }, "bounded root enumeration visible")
            limited = SkillScanLimits(); limited.maxProjectDirectories = 0
            t.expectTrue(scan([project], limits: limited).issues.contains { $0.issue == .scanIncomplete }, "project budget visible")
            limited = SkillScanLimits(); limited.maxProjectDirectories = 1
            t.expectTrue(scan([child], limits: limited).issues.contains {
                $0.issue == .scanIncomplete && $0.message.contains("ancestor")
            }, "expanded project ancestor budget visible")
            let partial = record(scan(limits: limited), "nested")!
            let partialReview = record(scan(acks: [partial.id: partial.fingerprint]), "nested")
            t.expectEqual(partialReview?.isReviewed, false, "incomplete source cannot be reviewed")
            t.expectEqual(partialReview?.issues.contains(.scanIncomplete), true, "review cannot hide incomplete")

            try fm.setAttributes([.modificationDate: old], ofItemAtPath: alternate.appendingPathComponent("SKILL.md").path)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: alternate.path)
            let before = diskInventory()
            _ = scan([child, unrelated], acks: acks)
            t.expectEqual(diskInventory(), before, "scan makes no filesystem changes")

            let folded = SkillFrontmatter.parse("---\nname: sample\ndescription: >-\n  First sentence.\n  Second sentence.\nmetadata:\n  tags:\n    - audit\n---\n")
            t.expectEqual(folded.description, "First sentence. Second sentence.", "folded YAML scalar")
            t.expectTrue(folded.invalid.isEmpty && folded.unsupported.isEmpty, "nested unknown metadata accepted")
            let literal = SkillFrontmatter.parse("---\nname: 'sample'\ndescription: |\n  First line.\n  Second line.\n---\n")
            t.expectEqual(literal.description, "First line.\nSecond line.", "literal YAML scalar")
            t.expectTrue(!SkillFrontmatter.parse("---\nname: first\nname: second\n---\n").invalid.isEmpty, "duplicate metadata invalid")
            t.expectTrue(!SkillFrontmatter.parse("---\nname: first\n").invalid.isEmpty, "unterminated metadata invalid")
            for value in ["NaN", "Infinity", "-Infinity"] {
                let plainWord = SkillFrontmatter.parse("---\nname: sample\ndescription: \(value)\n---\n")
                t.expectEqual(plainWord.description, value, "plain YAML word \(value) stays a string")
                t.expectTrue(plainWord.invalid.isEmpty, "plain YAML word \(value) not invalid")
            }
            t.expectTrue(!SkillFrontmatter.parse("---\nname: sample\ndescription: .nan\n---\n").invalid.isEmpty,
                         "YAML special numeric value is not a string")
            let hostile = SkillAuditSnapshot(records: [SkillRecord(id: "x", name: "bad\u{1b}[2J", sourcePath: "/raw\npath", registrations: [])])
            t.expectTrue(!hostile.reportText.contains("\u{1b}"), "report escapes terminal controls")
            t.expectEqual(hostile.records.first?.sourcePath, "/raw\npath", "model preserves exact disk paths")
        } catch {
            t.expectTrue(false, "fixture failed: \(error)")
        }
    }
}

import Foundation
import PerchCore

extension Selftest {
    @MainActor
    static func skillQuery(_ t: Checker) {
        t.suite("SkillsAudit.query")
        let claudeUser = SkillRegistration(agent: .claude, scope: .user,
                                           path: "/example/user/claude/skills/review")
        let codexProject = SkillRegistration(agent: .codex, scope: .project,
                                             path: "/example/app/.agents/skills/review",
                                             projectPath: "/example/project-orbit")
        let claudeProject = SkillRegistration(agent: .claude, scope: .project,
                                              path: "/example/app/.claude/skills/build",
                                              projectPath: "/example/app")
        let shared = SkillRecord(id: "shared", name: "Review 2", description: "Inspect deployment changes",
                                 sourcePath: "/example/shared/review", registrations: [claudeUser, codexProject],
                                 issues: [.nameConflict], isReviewed: true)
        let changed = SkillRecord(id: "changed", name: "Review 10", sourcePath: "/example/changed",
                                  registrations: [claudeProject], issues: [.changed])
        let reviewed = SkillRecord(id: "reviewed", name: "Build", sourcePath: "/example/build",
                                   registrations: [claudeProject], isReviewed: true)
        let ordinary = SkillRecord(id: "ordinary", name: "Deploy", sourcePath: "/example/deploy",
                                   registrations: [claudeUser])
        let unregistered = SkillRecord(id: "unregistered", name: "Detached", sourcePath: "/example/detached",
                                       registrations: [])
        let snapshot = SkillAuditSnapshot(records: [ordinary, changed, unregistered, shared, reviewed], issues: [
            SkillScanIssue(path: "/example/unreadable", issue: .unreadable, message: "Could not read root"),
            SkillScanIssue(path: "/example/incomplete", issue: .scanIncomplete, message: "Bounded scan")
        ])
        var query = SkillAuditQuery()
        func ids(_ query: SkillAuditQuery, in snapshot: SkillAuditSnapshot) -> [String] {
            query.records(in: snapshot).map(\.id)
        }
        func ids(_ query: SkillAuditQuery) -> [String] { ids(query, in: snapshot) }

        t.expectEqual(ids(query), ["shared", "changed", "reviewed", "ordinary", "unregistered"],
                      "default puts findings first then natural names")
        t.expectFalse(query.hasFilters, "default has no filters")
        query.search = " \n\t "
        t.expectFalse(query.hasFilters, "whitespace is not an active search")
        t.expectEqual(ids(query), ids(SkillAuditQuery()), "whitespace search keeps every record")
        query.search = "  REVIEW\tDEPLOYMENT\nORBIT  "
        t.expectEqual(ids(query), ["shared"], "case insensitive terms match across name description and project")
        query.search = "shared claude/skills"
        t.expectEqual(ids(query), ["shared"], "terms match source and registration paths")
        query.search = "review missing"
        t.expectEqual(ids(query), [], "every search term must match")
        query.search = ""
        query.agent = .claude
        query.scope = .project
        t.expectEqual(ids(query), ["changed", "reviewed"], "agent and scope require same registration")
        query.agent = .codex
        t.expectEqual(ids(query), ["shared"], "shared source matches its project agent")
        query.scope = .user
        t.expectEqual(ids(query), [], "shared source does not cross-match another agent scope")
        query.agent = nil
        t.expectEqual(ids(query), ["shared", "ordinary"], "scope-only query matches either agent")
        query.scope = nil
        query.agent = .codex
        t.expectEqual(ids(query), ["shared"], "agent-only query matches either scope")

        query.resetFilters()
        query.status = .reviewed
        t.expectEqual(ids(query), ["shared", "reviewed"], "reviewed includes reviewed record with findings")
        t.expectEqual(query.count(.all, in: snapshot), 5, "all count ignores active status")
        t.expectEqual(query.count(.attention, in: snapshot), 2, "attention excludes root scan issues")
        t.expectEqual(query.count(.reviewed, in: snapshot), 2, "reviewed count honors marker")
        t.expectEqual(snapshot.flaggedCount, 4, "root issues remain in snapshot attention total")
        let rootIssuesOnly = SkillAuditSnapshot(issues: snapshot.issues)
        t.expectEqual(query.count(.attention, in: rootIssuesOnly), 0, "root-only problems do not create source counts")
        t.expectEqual(ids(query, in: rootIssuesOnly), [], "root-only problems do not create source rows")
        query.status = .attention
        t.expectEqual(ids(query), ["shared", "changed"], "attention uses findings not inverse review state")
        t.expectEqual(query.count(.reviewed, in: snapshot), 2, "status counts allow overlap")
        query.agent = .claude
        query.scope = .project
        t.expectEqual(query.count(.all, in: snapshot), 2, "counts honor same-registration filter")
        t.expectEqual(query.count(.attention, in: snapshot), 1, "attention count honors registration filter")
        t.expectEqual(query.count(.reviewed, in: snapshot), 1, "reviewed count honors registration filter")
        query.search = "build"
        t.expectEqual(query.count(.all, in: snapshot), 2, "counts search registration paths too")
        query.search = "/example/build"
        t.expectEqual(query.count(.all, in: snapshot), 1, "counts honor text search")
        t.expectEqual(ids(query), [], "selected attention still filters matching reviewed source")

        query.sort = .recentlyModified
        t.expectTrue(query.hasFilters, "combined query has active filters")
        query.resetFilters()
        t.expectEqual(query, SkillAuditQuery(sort: .recentlyModified), "reset clears filters but preserves sort")
        t.expectFalse(query.hasFilters, "sort alone is not a filter")
        query.status = .reviewed
        t.expectTrue(query.hasFilters, "status alone is a filter")
        query.resetFilters()
        query.agent = .claude
        t.expectTrue(query.hasFilters, "agent alone is a filter")
        query.resetFilters()
        query.scope = .project
        t.expectTrue(query.hasFilters, "scope alone is a filter")
        query.resetFilters()
        query.search = "review"
        t.expectTrue(query.hasFilters, "text alone is a filter")

        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        func sortRecord(_ id: String, _ name: String, _ date: Date?, flagged: Bool = false) -> SkillRecord {
            SkillRecord(id: id, name: name, sourcePath: "/example/\(id)", registrations: [],
                        issues: flagged ? [.changed] : [], lastModified: date)
        }
        let sortSnapshot = SkillAuditSnapshot(records: [
            sortRecord("nil-10", "Skill 10", nil),
            sortRecord("late-b", "Skill 2", later),
            sortRecord("early", "Alpha", earlier, flagged: true),
            sortRecord("nil-2", "Skill 2", nil),
            sortRecord("late-a", "Skill 2", later)
        ])
        query = SkillAuditQuery(sort: .recentlyModified)
        let recentIDs = ["late-a", "late-b", "early", "nil-2", "nil-10"]
        t.expectEqual(ids(query, in: sortSnapshot), recentIDs, "newest first with nil last natural names and ID ties")
        t.expectEqual(ids(query, in: SkillAuditSnapshot(records: Array(sortSnapshot.records.reversed()))), recentIDs,
                      "recent sort independent of input order")
        query.sort = .name
        let nameIDs = ["early", "late-a", "late-b", "nil-2", "nil-10"]
        t.expectEqual(ids(query, in: sortSnapshot), nameIDs, "name sort natural numeric order with ID ties")
        query.sort = .attention
        t.expectEqual(ids(query, in: sortSnapshot), nameIDs, "attention sort resolves name ties by ID")
        let caseSnapshot = SkillAuditSnapshot(records: [
            sortRecord("b", "review", nil), sortRecord("a", "Review", nil)
        ])
        let caseOrder = ids(query, in: caseSnapshot)
        t.expectEqual(ids(query, in: SkillAuditSnapshot(records: Array(caseSnapshot.records.reversed()))), caseOrder,
                      "localized name ties never depend on input order")

        let visible = SkillAuditQuery().records(in: snapshot)
        t.expectEqual(SkillAuditQuery.reconciledSelection(nil, records: visible), "shared",
                      "initial selection uses first visible source")
        t.expectEqual(SkillAuditQuery.reconciledSelection("ordinary", records: visible), "ordinary",
                      "refresh preserves visible selected ID")
        t.expectEqual(SkillAuditQuery.reconciledSelection("ordinary", records: Array(visible.reversed())), "ordinary",
                      "reorder preserves selected ID")
        let filtered = SkillAuditQuery(status: .attention).records(in: snapshot)
        t.expectEqual(SkillAuditQuery.reconciledSelection("ordinary", records: filtered), "shared",
                      "hidden selection moves to first filtered source")
        t.expectEqual(SkillAuditQuery.reconciledSelection("removed", records: visible), "shared",
                      "removed selection moves to first visible source")
        t.expectNil(SkillAuditQuery.reconciledSelection("shared", records: []), "empty results clear selection")
        t.expectNil(SkillAuditQuery.reconciledSelection(nil, records: []), "empty initial selection stays nil")
    }
}

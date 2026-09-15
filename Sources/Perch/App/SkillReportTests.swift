import Darwin
import Foundation

extension Selftest {
    @MainActor
    static func skillReportProjects(_ t: Checker) {
        t.suite("SkillReportProjects")
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("perch-skill-report-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fixture) }
        func rejected(_ path: String, _ name: String) {
            do {
                _ = try SkillReportCommand.projects(from: [path])
                t.expectTrue(false, name)
            } catch let error as SkillReportCommand.InvalidProject {
                t.expectTrue(error.errorDescription?.contains("Cannot audit project") == true, name)
            } catch {
                t.expectTrue(false, "\(name): unexpected error \(error)")
            }
        }
        do {
            try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
            let valid = try SkillReportCommand.projects(from: [fixture.path])
            t.expectEqual(valid.first?.path, fixture.standardizedFileURL.path, "empty project valid without skills directory")
            rejected(fixture.appendingPathComponent("missing").path, "missing explicit project rejected")
            let file = fixture.appendingPathComponent("file")
            try Data("not a directory".utf8).write(to: file)
            rejected(file.path, "regular file project rejected")
            rejected(file.path + "/..", "regular file cannot be traversed before dot-dot")
            let fifo = fixture.appendingPathComponent("pipe")
            t.expectEqual(mkfifo(fifo.path, mode_t(0o600)), 0, "FIFO fixture created")
            rejected(fifo.path, "FIFO project rejected without blocking")
            let link = fixture.appendingPathComponent("linked-project")
            try fm.createSymbolicLink(at: link, withDestinationURL: fixture)
            t.expectEqual(try SkillReportCommand.projects(from: [link.path]).count, 1, "directory symlink accepted")
            let dangling = fixture.appendingPathComponent("dangling")
            try fm.createSymbolicLink(at: dangling, withDestinationURL: fixture.appendingPathComponent("absent"))
            rejected(dangling.path, "dangling project symlink rejected")
            do {
                _ = try SkillReportCommand.projects(from: [fixture.path, dangling.path])
                t.expectTrue(false, "all explicit projects validated")
            } catch is SkillReportCommand.InvalidProject {
                t.expectTrue(true, "all explicit projects validated")
            }
            let locked = fixture.appendingPathComponent("locked")
            try fm.createDirectory(at: locked, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
            if geteuid() != 0 { rejected(locked.path, "inaccessible project rejected") }
            let error = SkillReportCommand.InvalidProject(path: "bad\n\u{001B}path", reason: "missing")
            t.expectFalse(error.errorDescription?.contains("\n") == true, "error path escapes newline")
            t.expectFalse(error.errorDescription?.contains("\u{001B}") == true, "error path escapes terminal control")
        } catch {
            t.expectTrue(false, "fixture: \(error)")
        }
    }
}

import Foundation
import PerchCore

extension Selftest {
    @MainActor
    static func runNotificationPreferencesTests(_ t: Checker) {
        t.suite("NotificationPreferences.persistence")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("perch-notifications-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        var writes = 0
        let load: () -> PerchConfig = {
            guard let data = try? Data(contentsOf: file),
                  let config = try? JSONDecoder().decode(PerchConfig.self, from: data) else {
                return PerchConfig()
            }
            return config
        }
        let save: (PerchConfig) throws -> Void = { config in
            try JSONEncoder().encode(config).write(to: file, options: .atomic)
            writes += 1
        }

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let missing = NotificationPreferences(loadConfig: load, saveConfig: save)
            t.expectFalse(missing.alertsDisabled, "missing file enables alerts by default")
            t.expectFalse(fm.fileExists(atPath: file.path), "initializing does not create config")
            t.expectEqual(writes, 0, "initializing performs no writes")

            let seed = """
            {"notifyDangerousCalls":false,"notifyTaskCompletion":false,
             "playNotificationSounds":false,"checkForUpdates":false,
             "scratchDirs":[".cache"],"futureSetting":{"revision":1}}
            """
            try Data(seed.utf8).write(to: file)
            let preferences = NotificationPreferences(loadConfig: load, saveConfig: save)
            t.expectFalse(preferences.alertsDisabled, "missing global setting enables alerts")
            t.expectEqual(writes, 0, "loading existing choices performs no writes")
            preferences.alertsDisabled = true

            let muted = NotificationPreferences(loadConfig: load, saveConfig: save)
            t.expectTrue(muted.alertsDisabled, "mute survives new preferences instance")
            t.expectEqual([muted.dangerousCalls, muted.attention, muted.taskCompletion,
                           muted.usageThresholds, muted.sounds],
                          [false, true, false, true, false], "mute preserves category and sound choices")
            t.expectEqual(writes, 1, "only mute writes config")

            var interleaved = load()
            interleaved.extra["futureSetting"] = .object(["revision": .number(2)])
            interleaved.scratchDirs = [".cache", ".preview"]
            interleaved.worktreeStaleDays = 12
            interleaved.lastCodexHookEventAt = Date(timeIntervalSince1970: 1234)
            try JSONEncoder().encode(interleaved).write(to: file, options: .atomic)
            muted.sounds = true
            let afterSound = load()
            t.expectTrue(afterSound.alertsDisabled, "editing category choice retains mute")
            t.expectEqual(afterSound.extra["futureSetting"], interleaved.extra["futureSetting"],
                          "preference save preserves latest unknown fields")
            t.expectEqual(afterSound.scratchDirs, interleaved.scratchDirs,
                          "preference save preserves latest scratch directories")
            t.expectEqual(afterSound.worktreeStaleDays, 12, "preference save preserves worktree setting")
            t.expectEqual(afterSound.lastCodexHookEventAt, interleaved.lastCodexHookEventAt,
                          "preference save preserves latest hook verification")
            t.expectFalse(afterSound.checkForUpdates, "preference save preserves update choice")

            muted.alertsDisabled = false
            let unmuted = NotificationPreferences(loadConfig: load, saveConfig: save)
            t.expectFalse(unmuted.alertsDisabled, "unmute survives new preferences instance")
            t.expectEqual([unmuted.dangerousCalls, unmuted.attention, unmuted.taskCompletion,
                           unmuted.usageThresholds, unmuted.sounds],
                          [false, true, false, true, true], "unmute retains edited category and sound choices")
            t.expectEqual(writes, 3, "restarting preferences adds no writes")

            unmuted.alertsDisabled = true
            unmuted.markSetupCompleted()
            t.expectTrue(load().hasCompletedSetup, "setup completion persists")
            t.expectTrue(load().alertsDisabled, "setup completion preserves mute")
            t.expectEqual(load().extra["futureSetting"], interleaved.extra["futureSetting"],
                          "setup completion preserves unknown fields")
            let setupWrites = writes
            unmuted.markSetupCompleted()
            t.expectEqual(writes, setupWrites, "repeated setup completion performs no write")

            let explicit = NotificationPreferences(config: PerchConfig(), loadConfig: load, saveConfig: save)
            t.expectFalse(explicit.alertsDisabled, "explicit initial config takes precedence over storage")
            t.expectTrue(load().alertsDisabled, "explicit initialization leaves stored mute intact")
            t.expectEqual(writes, setupWrites, "explicit initialization performs no write")

            for raw in ["{\"alertsDisabled\":null}", "{\"alertsDisabled\":\"true\"}", "not-json"] {
                try Data(raw.utf8).write(to: file)
                let malformed = NotificationPreferences(loadConfig: load, saveConfig: save)
                t.expectFalse(malformed.alertsDisabled, "malformed global config uses default: \(raw)")
                t.expectEqual(try String(contentsOf: file, encoding: .utf8), raw,
                              "initializing leaves malformed config untouched")
            }
            t.expectEqual(writes, setupWrites, "malformed config initialization performs no writes")
        } catch {
            t.expectTrue(false, "notification preferences fixture error: \(error)")
        }
    }
}

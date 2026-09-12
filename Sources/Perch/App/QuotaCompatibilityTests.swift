import Foundation
import PerchCore

extension Selftest {
    @MainActor
    static func quotaCompatibility(_ t: Checker) {
        codexQuotaIdentity(t)
        codexQuotaUnavailableWindows(t)
        codexQuotaMalformedWindows(t)
        codexQuotaThresholdIsolation(t)
        codexQuotaReplayOrdering(t)
    }

    private static func quotaPayload(id: JSONValue? = .string("codex"),
                                     primary: Double?, secondary: Double?) -> JSONValue {
        var limits: [String: JSONValue] = [
            "primary": primary.map { .object(["used_percent": .number($0),
                                              "window_minutes": .number(300)]) } ?? .null,
            "secondary": secondary.map { .object(["used_percent": .number($0),
                                                  "window_minutes": .number(10080)]) } ?? .null,
        ]
        if let id { limits["limit_id"] = id }
        return .object(["type": .string("token_count"), "rate_limits": .object(limits)])
    }

    @MainActor
    private static func codexQuotaIdentity(_ t: Checker) {
        t.suite("UsageStore.codexQuotaIdentity")
        let acceptedIDs: [JSONValue?] = [nil, .null, .string("codex")]
        for (index, id) in acceptedIDs.enumerated() {
            let usage = UsageStore()
            usage.applyCodexRateLimits(quotaPayload(id: id, primary: 80, secondary: 70))
            t.expectEqual(usage.codexPrimary?.usedPercentage, 80, "legacyOrCodexPrimary\(index)")
            t.expectEqual(usage.codexSecondary?.usedPercentage, 70, "legacyOrCodexSecondary\(index)")
            t.expectEqual(usage.codexPrimary?.windowMinutes, 300, "rawWindowMinutes\(index)")
        }

        let usage = UsageStore()
        let baselineAt = Date(timeIntervalSince1970: 1_800_000_000)
        usage.applyCodexRateLimits(quotaPayload(primary: 80, secondary: 70), observedAt: baselineAt)
        let ignoredIDs: [JSONValue] = [.string("codex_secondary"), .string(""), .number(1), .bool(true), .object([:])]
        for id in ignoredIDs {
            usage.applyCodexRateLimits(quotaPayload(id: id, primary: 3, secondary: nil),
                                      observedAt: baselineAt.addingTimeInterval(10))
            t.expectEqual(usage.codexPrimary?.usedPercentage, 80, "otherOrMalformedIdPreservesPrimary")
            t.expectEqual(usage.codexSecondary?.usedPercentage, 70, "otherOrMalformedIdPreservesSecondary")
        }
        usage.applyCodexRateLimits(quotaPayload(primary: 81, secondary: 71),
                                  observedAt: baselineAt.addingTimeInterval(1))
        t.expectEqual(usage.codexPrimary?.usedPercentage, 81, "ignoredIdsDoNotAdvanceTimestamp")
    }

    @MainActor
    private static func codexQuotaUnavailableWindows(_ t: Checker) {
        t.suite("UsageStore.codexQuotaUnavailableWindows")
        let usage = UsageStore()
        usage.applyCodexRateLimits(quotaPayload(primary: 20, secondary: 30))
        usage.applyCodexRateLimits(quotaPayload(primary: 21, secondary: nil))
        t.expectEqual(usage.codexPrimary?.usedPercentage, 21, "knownPrimaryReplaced")
        t.expectNil(usage.codexSecondary, "nullSecondaryClears")

        let absentSnapshots: [JSONValue] = [.object([:]), .object(["rate_limits": .null]),
                                            .object(["rate_limits": .string("unavailable")])]
        for payload in absentSnapshots {
            usage.applyCodexRateLimits(payload)
            t.expectEqual(usage.codexPrimary?.usedPercentage, 21, "noSnapshotPreservesKnownValue")
        }
        usage.applyCodexRateLimits(.object(["rate_limits": .object([
            "limit_id": .string("codex"),
            "secondary": .object(["used_percent": .number(31)]),
        ])]))
        t.expectNil(usage.codexPrimary, "missingPrimaryClears")
        t.expectEqual(usage.codexSecondary?.usedPercentage, 31, "knownSecondaryReplaced")
        usage.applyCodexRateLimits(quotaPayload(primary: nil, secondary: nil))
        t.expectNil(usage.codexPrimary, "bothUnavailablePrimary")
        t.expectNil(usage.codexSecondary, "bothUnavailableSecondary")
    }

    @MainActor
    private static func codexQuotaMalformedWindows(_ t: Checker) {
        t.suite("UsageStore.codexQuotaMalformedWindows")
        let usage = UsageStore()
        let baselineAt = Date(timeIntervalSince1970: 1_800_000_000)
        usage.applyCodexRateLimits(quotaPayload(primary: 20, secondary: 30), observedAt: baselineAt)
        var notificationCount = 0
        usage.onThreshold = { _, _ in notificationCount += 1 }
        let malformedWindows: [JSONValue] = [.string("bad"), .object([:]), .array([])]
        for key in ["primary", "secondary"] {
            for malformed in malformedWindows {
                var limits: [String: JSONValue] = [
                    "limit_id": .string("codex"),
                    "primary": .object(["used_percent": .number(90)]),
                    "secondary": .object(["used_percent": .number(95)]),
                ]
                limits[key] = malformed
                usage.applyCodexRateLimits(.object(["rate_limits": .object(limits)]),
                                          observedAt: baselineAt.addingTimeInterval(10))
                t.expectEqual(usage.codexPrimary?.usedPercentage, 20, "malformedWindowPreservesPrimary")
                t.expectEqual(usage.codexSecondary?.usedPercentage, 30, "malformedWindowPreservesSecondary")
            }
        }
        t.expectEqual(notificationCount, 0, "malformedSnapshotCannotFireThresholds")
        usage.applyCodexRateLimits(quotaPayload(primary: 21, secondary: 31),
                                  observedAt: baselineAt.addingTimeInterval(1))
        t.expectEqual(usage.codexPrimary?.usedPercentage, 21, "malformedSnapshotDoesNotAdvanceTimestamp")
    }

    @MainActor
    private static func codexQuotaThresholdIsolation(_ t: Checker) {
        t.suite("UsageStore.codexQuotaThresholdIsolation")
        let usage = UsageStore()
        var notifications: [String] = []
        usage.onThreshold = { label, _ in notifications.append(label) }
        usage.applyCodexRateLimits(quotaPayload(id: .string("codex_secondary"), primary: 90, secondary: 90))
        t.expectTrue(notifications.isEmpty, "otherQuotaDoesNotNotify")
        usage.applyCodexRateLimits(quotaPayload(primary: 80, secondary: 70))
        t.expectEqual(notifications, ["Codex 5h"], "otherQuotaDoesNotSuppressCodex")
        usage.applyCodexRateLimits(quotaPayload(id: .string("codex_secondary"), primary: 3, secondary: nil))
        usage.applyCodexRateLimits(quotaPayload(primary: nil, secondary: nil))
        usage.applyCodexRateLimits(quotaPayload(primary: 81, secondary: 71))
        t.expectEqual(notifications.count, 1, "otherQuotaAndUnavailableDoNotRearm")
        usage.applyCodexRateLimits(quotaPayload(primary: 74, secondary: 71))
        usage.applyCodexRateLimits(quotaPayload(primary: 82, secondary: 71))
        t.expectEqual(notifications.count, 2, "knownCodexValueRearms")
    }

    @MainActor
    private static func codexQuotaReplayOrdering(_ t: Checker) {
        t.suite("CodexRolloutTailer.quotaReplayOrdering")
        let usage = UsageStore()
        var notificationCount = 0
        usage.onThreshold = { _, _ in notificationCount += 1 }
        let tailer = CodexRolloutTailer(store: SessionStore(), usage: usage)
        let newestAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 10)
        let formatter = ISO8601DateFormatter()
        func line(_ payload: JSONValue, at: Date, topLevel: Bool = false) -> JSONValue {
            .object(["timestamp": .string(formatter.string(from: at)),
                     "type": .string(topLevel ? "token_count" : "event_msg"), "payload": payload])
        }
        tailer.ingestLineForSelftest(line(quotaPayload(primary: 50, secondary: 60), at: newestAt),
                                    sessionID: "quota-newer")
        tailer.ingestLineForSelftest(line(quotaPayload(primary: 90, secondary: 95),
                                         at: newestAt.addingTimeInterval(-5), topLevel: true),
                                    sessionID: "quota-older", isSeed: true)
        t.expectEqual(usage.codexPrimary?.usedPercentage, 50, "recentOlderSeedCannotOverwritePrimary")
        t.expectEqual(usage.codexSecondary?.usedPercentage, 60, "recentOlderSeedCannotOverwriteSecondary")
        t.expectEqual(usage.codexPrimary?.updatedAt, newestAt, "sourceTimestampPreserved")
        t.expectEqual(notificationCount, 0, "olderSeedCannotFireThresholds")

        tailer.ingestLineForSelftest(line(quotaPayload(primary: nil, secondary: nil),
                                         at: newestAt.addingTimeInterval(1)), sessionID: "quota-newer")
        tailer.ingestLineForSelftest(line(quotaPayload(primary: 51, secondary: 61), at: newestAt),
                                    sessionID: "quota-older")
        t.expectNil(usage.codexPrimary, "olderLiveRecordCannotRestoreClearedPrimary")
        t.expectNil(usage.codexSecondary, "olderLiveRecordCannotRestoreClearedSecondary")

        let relativeReset = UsageStore.parseWindow(.object([
            "used_percent": .number(5), "resets_in_seconds": .number(120),
        ]), observedAt: newestAt)
        t.expectEqual(relativeReset?.resetsAt, newestAt.addingTimeInterval(120), "relativeResetUsesSourceTime")
    }
}

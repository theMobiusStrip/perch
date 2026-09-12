import Foundation
import PerchCore

extension Selftest {
    @MainActor
    static func codexCompatibility(_ t: Checker) {
        t.suite("CodexCompatibility.discovery")
        let home = URL(fileURLWithPath: "/fixture/codex-home")
        let desktop = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let cli = "/fixture/bin/codex"
        let runtimes = CodexRuntime.discover(home: "/fixture/user", path: "/fixture/bin", codexHome: home,
                                            isExecutable: { [desktop, cli].contains($0) }, canonicalPath: { $0 })
        t.expectEqual(runtimes.count, 2, "desktopAndPathCLIKept")
        t.expectEqual(runtimes.first?.executable.path, desktop, "staleCLICannotHideDesktop")
        t.expectTrue(runtimes.allSatisfy { $0.codexHome == home }, "sharedExplicitConfigHome")
        let process = Process()
        runtimes[0].configure(process, arguments: ["app-server"])
        t.expectEqual(process.environment?["CODEX_HOME"], home.path, "processUsesSameConfigHome")
        t.expectEqual(process.executableURL, runtimes[0].executable, "probeUsesSelectedExecutable")
        t.expectTrue(process.environment?["PATH"]?.contains("/opt/homebrew/bin") == true,
                     "GUIProbeCanResolveHomebrewNode")
        let deduped = CodexRuntime.discover(home: "/fixture/user", path: "/fixture/bin", codexHome: home,
                                          isExecutable: { [desktop, cli].contains($0) }, canonicalPath: { _ in desktop })
        t.expectEqual(deduped.count, 1, "symlinkedCLIIsNotSecondRuntime")

        t.suite("CodexCompatibility.identities")
        let source = home.appendingPathComponent("hooks.json").path
        let command = InstallSupport.hookCommand(bridgePath: "/fixture/perch-bridge", agent: .codex)
        func metadata(key: String = "pre_tool_use", command override: String? = nil,
                      source overrideSource: String? = nil, status: String = "trusted",
                      enabled: Bool? = true, matcher: String = ".*", handler: String = "command") -> JSONValue {
            var fields: [String: JSONValue] = [
                "key": .string("\(overrideSource ?? source):\(key):0:0"),
                "currentHash": .string("hash"), "trustStatus": .string(status),
                "command": .string(override ?? command), "matcher": .string(matcher),
                "handlerType": .string(handler),
            ]
            if let enabled { fields["enabled"] = .bool(enabled) }
            return .object(fields)
        }
        let listed: JSONValue = .object(["data": .array([.object([
            "hooks": .array([
                metadata(), metadata(command: "echo perch-bridge"), metadata(source: "/another/hooks.json"),
                metadata(key: "made_up_event"), metadata(key: "permission_request", enabled: false),
                metadata(key: "session_start", status: "managed"), metadata(key: "stop", enabled: nil),
                metadata(matcher: "Read"), metadata(handler: "prompt"),
            ]), "errors": .array([]),
        ])])])
        let summary = CodexHookTrust.summarize(hooksListResult: listed, expectedCommand: command, sourcePath: source)
        t.expectEqual(summary.perchHooks.count, 4, "exactSourceCommandAndKnownEventOnly")
        t.expectEqual(summary.perchHooks.filter(\.canRun).count, 2, "managedAllowedDisabledAndUnknownEnabledRejected")
        let original = summary.perchHooks[0]
        let trusted = CodexHookTrust.ListSummary(perchHooks: [original], asyncSkipped: 0)
        t.expectTrue(CodexHookTrust.verified(expected: [original], actual: trusted), "unchangedIdentityVerified")
        t.expectFalse(CodexHookTrust.verified(expected: [original], actual: .init(perchHooks: [], asyncSkipped: 0)),
                      "emptyRelistCannotVerify")
        t.expectFalse(CodexHookTrust.verified(expected: [], actual: .init(perchHooks: [], asyncSkipped: 0)),
                      "emptyExpectedCannotVerify")
        var changed = original
        changed.currentHash = "changed"
        t.expectFalse(CodexHookTrust.verified(expected: [original], actual: .init(perchHooks: [changed], asyncSkipped: 0)),
                      "changedHashCannotVerify")
        changed = original
        changed.enabled = false
        t.expectFalse(CodexHookTrust.verified(expected: [original], actual: .init(perchHooks: [changed], asyncSkipped: 0)),
                      "disabledTrustedHookCannotVerify")
        changed = original
        changed.trustStatus = "modified"
        t.expectFalse(CodexHookTrust.verified(expected: [original], actual: .init(perchHooks: [changed], asyncSkipped: 0)),
                      "storedStaleHashCannotVerify")
        t.expectFalse(CodexHookTrust.verified(expected: [original, summary.perchHooks[1]], actual: trusted),
                      "partialRelistCannotVerify")
        t.expectFalse(CodexHookTrust.verified(expected: [original, original],
                      actual: .init(perchHooks: [original, original], asyncSkipped: 0)),
                      "duplicateIdentitiesCannotVerify")

        t.suite("CodexCompatibility.coverage")
        let full = CodexHookInstaller.allEvents.map { event in
            CodexHookTrust.HookEntry(key: "\(source):\(event.rawValue):0:0", currentHash: "same", trustStatus: "trusted")
        }
        func coverage(_ entries: [CodexHookTrust.HookEntry], enabled: Bool = true,
                      errors: Bool = false) -> CodexHookTrust.Coverage {
            .init(runtime: runtimes[0], hooks: .init(perchHooks: entries, asyncSkipped: 0, hasErrors: errors),
                  hooksEnabled: enabled)
        }
        t.expectTrue(coverage(full).isReady, "allExpectedEventsReady")
        t.expectFalse(coverage(full, enabled: false).isReady, "featureOffNeverReady")
        t.expectFalse(coverage(full, errors: true).isReady, "runtimeErrorsNeverReady")
        t.expectFalse(coverage(Array(full.prefix(2))).isReady, "oldRuntimeLimitedCoverage")
        t.expectFalse(coverage([]).isReady, "noHooksOrManagedOnlyPolicyNotReady")
        var mixed = full
        mixed[0].trustStatus = "untrusted"
        t.expectFalse(coverage(mixed).isReady, "oneUntrustedHookNotReady")
        t.expectEqual(CodexHookTrust.check(coverages: [coverage(full)], failures: []).state, .ready, "readyCheck")
        t.expectEqual(CodexHookTrust.check(coverages: [coverage(full), coverage(mixed)], failures: []).state,
                      .needsAttention, "oneRuntimeCannotHideAnother")
        t.expectEqual(CodexHookTrust.check(coverages: [], failures: ["timed out"]).state, .unavailable,
                      "probeFailureNeverGreen")
        t.expectFalse(CodexHookTrust.conflictingHashes([coverage(full), coverage(full)]), "sharedHashesCompatible")
        mixed[0].currentHash = "different-normalization"
        t.expectTrue(CodexHookTrust.conflictingHashes([coverage(full), coverage(mixed)]), "crossRuntimeHashConflict")
    }
}

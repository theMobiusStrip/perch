import Foundation
import PerchCore

extension CodexHookTrust {
    struct Coverage {
        let runtime: CodexRuntime
        let hooks: ListSummary
        let hooksEnabled: Bool

        var visibleEvents: Set<String> { Set(hooks.perchHooks.map { eventName(fromKey: $0.key) }) }
        var readyEvents: Set<String> {
            Set(hooks.perchHooks.filter(\.canRun).map { eventName(fromKey: $0.key) })
        }
        var expectedEvents: Set<String> {
            Set(CodexHookInstaller.allEvents.map { normalizeEvent($0.rawValue) })
        }
        var isReady: Bool {
            hooksEnabled && !hooks.hasErrors && !hooks.perchHooks.isEmpty
                && Set(readyEvents.map(normalizeEvent)).isSuperset(of: expectedEvents)
                && hooks.perchHooks.allSatisfy(\.canRun)
        }
        var toolRiskReady: Bool {
            hooksEnabled && !hooks.hasErrors
                && Set(readyEvents.map(normalizeEvent)).isSuperset(of: ["pretooluse", "permissionrequest"])
        }
        var summary: String {
            if !hooksEnabled { return "\(runtime.label): hooks disabled by configuration" }
            if hooks.hasErrors { return "\(runtime.label): hook configuration errors" }
            if hooks.perchHooks.isEmpty {
                return "\(runtime.label): no Perch hooks visible (runtime support or policy)"
            }
            let running = readyEvents.count
            let expected = expectedEvents.count
            if isReady { return "\(runtime.label): \(running)/\(expected) hooks enabled and trusted" }
            let unavailable = expectedEvents.subtracting(Set(visibleEvents.map(normalizeEvent))).count
            let limited = unavailable > 0 ? "; \(unavailable) not exposed by this runtime" : ""
            let core = toolRiskReady ? "; tool-risk hooks ready" : "; tool-risk coverage incomplete"
            return "\(runtime.label): \(running)/\(expected) hooks ready\(limited)\(core)"
        }
    }

    static func normalizeEvent(_ event: String) -> String {
        event.replacingOccurrences(of: "_", with: "").lowercased()
    }

    /// Require every original identity to survive the write unchanged. Empty
    /// or partial re-list responses must not become vacuous success.
    static func verified(expected: [HookEntry], actual: ListSummary) -> Bool {
        guard !expected.isEmpty, !actual.hasErrors,
              expected.count == actual.perchHooks.count,
              Set(expected.map(\.key)).count == expected.count,
              Set(actual.perchHooks.map(\.key)).count == actual.perchHooks.count else { return false }
        return expected.allSatisfy { original in
            actual.perchHooks.contains { current in
                current.key == original.key && current.currentHash == original.currentHash && current.canRun
            }
        }
    }

    static func conflictingHashes(_ coverages: [Coverage]) -> Bool {
        var hashes: [String: String] = [:]
        for coverage in coverages {
            for entry in coverage.hooks.perchHooks {
                if let previous = hashes[entry.key], previous != entry.currentHash { return true }
                hashes[entry.key] = entry.currentHash
            }
        }
        return false
    }

    static func check(coverages: [Coverage], failures: [String]) -> MonitoringCheck {
        let ready = !coverages.isEmpty && failures.isEmpty && coverages.allSatisfy(\.isReady)
        return MonitoringCheck(
            title: "Codex", state: ready ? .ready : (coverages.isEmpty ? .unavailable : .needsAttention),
            summary: ready ? "Hooks enabled and trusted in detected runtimes" : "Codex hook coverage needs attention",
            detail: (coverages.map(\.summary) + failures).joined(separator: "\n"))
    }
}

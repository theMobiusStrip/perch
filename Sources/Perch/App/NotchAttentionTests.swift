import PerchCore

extension Selftest {
    @MainActor
    static func runNotchAttentionTests(_ t: Checker) {
        t.suite("NotchAttention.automaticExpansion")
        let automatic = NotchViewState()
        automatic.expandForAttention()
        automatic.expandForAttention()
        t.expectTrue(automatic.isExpanded, "repeated attention keeps panel expanded")
        t.expectTrue(automatic.hasAttention, "attention remains visible")
        t.expectTrue(automatic.clearAttention(), "repeated attention retains automatic ownership")
        t.expectFalse(automatic.hasAttention, "clear removes attention indicator")
        t.expectTrue(automatic.isExpanded, "normal clear leaves expansion until scheduled collapse")
        t.expectTrue(automatic.clearAttention(), "mute can still close pending automatic collapse")
        automatic.collapse()
        t.expectFalse(automatic.isExpanded, "automatic collapse closes panel")
        t.expectFalse(automatic.clearAttention(), "collapse resets automatic ownership")

        t.suite("NotchAttention.manualTakeover")
        let takeover = NotchViewState()
        takeover.expandForAttention()
        takeover.page = .skills
        let key = SessionKey(agent: .codex, id: "manual-session")
        takeover.expand(focusing: key)
        t.expectEqual(takeover.page, .sessions, "explicit session open selects sessions page")
        t.expectEqual(takeover.focusedSessionKey, key, "explicit session open focuses selected session")
        t.expectEqual(takeover.sessionFocusRequest, 1, "explicit session open requests focus")
        takeover.expandForAttention()
        t.expectFalse(takeover.clearAttention(), "mute preserves panel after explicit manual takeover")
        t.expectTrue(takeover.isExpanded, "manually opened panel remains expanded after mute")
        t.expectFalse(takeover.hasAttention, "mute still clears attention on manual panel")
        t.expectEqual(takeover.focusedSessionKey, key, "attention leaves manual session selection intact")
        t.expectEqual(takeover.sessionFocusRequest, 1, "attention does not repeat manual focus request")

        t.suite("NotchAttention.manualExpansion")
        let manual = NotchViewState()
        manual.page = .integrity
        manual.expand()
        manual.expandForAttention()
        t.expectFalse(manual.clearAttention(), "attention on an already manual panel does not own it")
        t.expectTrue(manual.isExpanded, "mute preserves manual expansion")
        t.expectEqual(manual.page, .integrity, "attention preserves manually selected page")
        manual.collapse()
        manual.expandForAttention()
        t.expectTrue(manual.clearAttention(), "new automatic expansion acquires fresh ownership")
        manual.collapse()
        manual.expand()
        t.expectFalse(manual.clearAttention(), "manual reopen never inherits old automatic ownership")

        t.suite("NotchAttention.manualTakeoverAfterClear")
        let pending = NotchViewState()
        pending.expandForAttention()
        t.expectTrue(pending.clearAttention(), "normal clear requests automatic collapse")
        pending.expand()
        t.expectFalse(pending.clearAttention(), "manual takeover after clear prevents mute collapse")
        t.expectTrue(pending.isExpanded, "manual takeover after clear remains open")
    }
}

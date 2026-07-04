import Foundation

/// Owns the integrity snapshot shown on the notch's Integrity page. Scans the
/// persistence surface off the main thread; refreshed on launch, on a timer,
/// and whenever the panel opens. `projectDirs` are the cwds of the sessions
/// Perch currently knows about, so per-project CLAUDE.md/AGENTS.md are covered.
@MainActor
final class IntegrityModel: ObservableObject {
    @Published private(set) var snapshot = IntegritySnapshot()
    @Published private(set) var scanning = false

    var projectDirsProvider: () -> [URL] = { [] }

    /// Showcase/selftest support: set a snapshot without scanning.
    func injectSnapshot(_ snap: IntegritySnapshot) {
        snapshot = snap
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let dirs = projectDirsProvider()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snap = IntegrityScanner.scan(projectDirs: dirs, acks: IntegrityBaseline.load().acks)
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = snap
                self.scanning = false
            }
        }
    }

    /// Records "reviewed at this state" for a flagged item. The flag stays
    /// suppressed while the surface matches the acknowledged fingerprint and
    /// returns on any real change.
    func acknowledge(_ item: IntegrityItem) {
        guard !item.fingerprint.isEmpty else { return }
        var baseline = IntegrityBaseline.load()
        baseline.acks[item.id] = item.fingerprint
        try? baseline.save()
        refresh()
    }
}

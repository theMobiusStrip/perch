import AppKit
import Combine
import PerchCore

/// Perch's only network activity: a periodic unauthenticated GET to the GitHub
/// releases API to notice a newer build. Compares the release tag against the
/// running version (pure `SemVer`), publishes the result for the menu, and —
/// on the user's click — opens the release page in the browser. It never
/// downloads or installs anything; that is a deliberate Phase-1 boundary for a
/// security tool. Fully gated by `PerchConfig.checkForUpdates`: when off, this
/// makes zero network calls.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: SemVer
        let tag: String
        let url: URL
    }

    enum State: Equatable {
        case unknown                 // never checked this launch
        case checking
        case upToDate(SemVer)
        case available(Release)
        case failed(String)
        case devBuild                // running an unstamped/local build
    }

    @Published private(set) var state: State = .unknown
    private(set) var autoCheckEnabled: Bool

    /// GitHub's "latest release" endpoint already excludes drafts/prereleases.
    private static let endpoint = URL(string:
        "https://api.github.com/repos/theMobiusStrip/perch/releases/latest")!
    private static let staleInterval: TimeInterval = 6 * 3600

    private var lastCheck: Date?
    private var inFlight = false

    init(autoCheckEnabled: Bool = PerchConfig.load().checkForUpdates) {
        self.autoCheckEnabled = autoCheckEnabled
    }

    // MARK: - Triggers

    /// Launch / timer / menu-open. Silent, throttled, and skipped when
    /// auto-check is off or this is a dev build. Never blocks the caller.
    func checkIfStale() {
        guard autoCheckEnabled else { return }
        guard AppVersion.currentReleaseVersion != nil else {
            state = .devBuild
            return
        }
        if let last = lastCheck, Date().timeIntervalSince(last) < Self.staleInterval { return }
        perform(manual: false, completion: nil)
    }

    /// Explicit "Check for Updates…" click. Always runs (subject to a dev-build
    /// guard) and reports the outcome back so the menu can show an alert.
    func checkManually(completion: @escaping (State) -> Void) {
        guard AppVersion.currentReleaseVersion != nil else {
            state = .devBuild
            completion(.devBuild)
            return
        }
        perform(manual: true, completion: completion)
    }

    /// Opens the release page for the pending update (user-initiated click).
    func openLatest() {
        guard case .available(let release) = state else { return }
        NSWorkspace.shared.open(release.url)
    }

    func setAutoCheck(_ on: Bool) {
        autoCheckEnabled = on
        var config = PerchConfig.load()
        config.checkForUpdates = on
        do {
            try config.save()
        } catch {
            PerchLog.warn("Could not persist update-check preference: \(error)", category: "update")
        }
        if on {
            state = .unknown
            checkIfStale()
        } else {
            state = .unknown
        }
    }

    // MARK: - Fetch

    private func perform(manual: Bool, completion: ((State) -> Void)?) {
        guard !inFlight else { return }
        inFlight = true
        state = .checking

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects API requests without a User-Agent.
        request.setValue("Perch/\(AppVersion.string)", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                self?.finish(data: data, response: response, error: error,
                             manual: manual, completion: completion)
            }
        }.resume()
    }

    private func finish(data: Data?, response: URLResponse?, error: Error?,
                        manual: Bool, completion: ((State) -> Void)?) {
        inFlight = false
        lastCheck = Date()

        func settle(_ newState: State) {
            state = newState
            completion?(newState)
        }

        if let error {
            PerchLog.warn("Update check failed: \(error.localizedDescription)", category: "update")
            settle(.failed(error.localizedDescription))
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data,
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let tag = json["tag_name"]?.string,
              let latest = SemVer.parse(tag) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            PerchLog.warn("Update check: unexpected response (HTTP \(code))", category: "update")
            settle(.failed("Unexpected response from GitHub"))
            return
        }
        guard let running = AppVersion.currentReleaseVersion else {
            settle(.devBuild)
            return
        }

        if latest > running,
           let urlString = json["html_url"]?.string, let url = URL(string: urlString) {
            PerchLog.info("Update available: \(tag) (running \(running.description))", category: "update")
            settle(.available(Release(version: latest, tag: tag, url: url)))
        } else {
            settle(.upToDate(running))
        }
    }
}

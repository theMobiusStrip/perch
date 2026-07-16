import Foundation
import PerchCore

/// Single source for the version shown in the menu bar, Doctor, and
/// `--version`. Reads the bundle: releases are stamped with the tag by
/// scripts/build-dmg.sh, local `make app` stamps `git describe` (e.g.
/// 0.5.0-4-g3566c79-dirty). A bare `swift build` binary has no bundle
/// version and a tarball build keeps the 0.0.0 marker — both report dev.
enum AppVersion {
    /// Raw bundle value ("1.1.0", "1.1.0-4-gabc-dirty", "0.0.0", or nil).
    static var rawBundleVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var string: String {
        guard let v = rawBundleVersion, !v.isEmpty, v != "0.0.0" else { return "dev build" }
        // "v" prefix for version-shaped values; a bare commit hash (tagless
        // repo's `git describe --always`) reads better unprefixed.
        return v.first?.isNumber == true && v.contains(".") ? "v\(v)" : v
    }

    /// The running version as a clean release SemVer, or nil for any dev build
    /// (0.0.0 baseline, empty, or a suffixed `git describe`). The update
    /// checker only compares against a clean release — dev builds never nag.
    static var currentReleaseVersion: SemVer? {
        guard let raw = rawBundleVersion, raw != "0.0.0",
              let v = SemVer.parse(raw), v.exact,
              !(v.major == 0 && v.minor == 0 && v.patch == 0) else { return nil }
        return v
    }
}

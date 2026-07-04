import Foundation

/// Single source for the version shown in the menu bar, Doctor, and
/// `--version`. Reads the bundle: releases are stamped with the tag by
/// scripts/build-dmg.sh, local `make app` stamps `git describe` (e.g.
/// 0.5.0-4-g3566c79-dirty). A bare `swift build` binary has no bundle
/// version and a tarball build keeps the 0.0.0 marker — both report dev.
enum AppVersion {
    static var string: String {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !v.isEmpty, v != "0.0.0" else { return "dev build" }
        // "v" prefix for version-shaped values; a bare commit hash (tagless
        // repo's `git describe --always`) reads better unprefixed.
        return v.first?.isNumber == true && v.contains(".") ? "v\(v)" : v
    }
}

import Foundation

/// Minimal semantic version — enough to decide "is the release newer than the
/// running build". Pure and dependency-free so the selftest exercises the
/// update-check decision without any network. Comparison is numeric only
/// (major, minor, patch); `exact` records whether the source string was a
/// clean `X.Y.Z` tag versus a local `git describe` build with a trailing
/// `-N-gHASH[-dirty]` suffix, which callers treat as a dev build.
public struct SemVer: Comparable, Sendable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let exact: Bool

    public init(major: Int, minor: Int, patch: Int, exact: Bool = true) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.exact = exact
    }

    /// Numeric ordering; `exact` is deliberately ignored so `1.2.0` and a
    /// dev `1.2.0-3-gabc` compare equal.
    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public static func == (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }

    /// Parses `v1.2.3`, `1.2.3`, or a suffixed `1.2.3-4-gabc-dirty`.
    /// Returns nil unless a three-integer `X.Y.Z` core is present.
    public static func parse(_ raw: String) -> SemVer? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.first == "v" || s.first == "V" { s.removeFirst() }

        // Split the numeric core from any pre-release/build suffix.
        let coreEnd = s.firstIndex(where: { $0 == "-" || $0 == "+" })
        let core = coreEnd.map { String(s[s.startIndex..<$0]) } ?? s
        let hasSuffix = coreEnd != nil

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else { return nil }

        return SemVer(major: major, minor: minor, patch: patch, exact: !hasSuffix)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

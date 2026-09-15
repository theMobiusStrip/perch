import Darwin
import Foundation
import PerchCore

/// Owns the audit and Perch's review markers. Scanning never changes skill
/// files; the only persisted state is an explicit review fingerprint.
@MainActor
final class SkillAuditModel: ObservableObject {
    @Published private(set) var snapshot = SkillAuditSnapshot()
    @Published private(set) var scanning = false
    @Published private(set) var errorMessage: String?
    @Published var selectedSkillID: String?
    /// Explicit opens from the notch must reveal the requested source even
    /// when the browser still has filters from an earlier visit.
    @Published private(set) var selectionRequest = 0
    var projectDirsProvider: () -> [URL] = { [] }

    private let baselineURL: URL
    private var refreshPending = false
    private var scanningProjects: [URL] = []
    private var generation = 0

    init(baselineURL: URL = SkillAuditBaseline.file) {
        self.baselineURL = baselineURL
    }

    func injectSnapshot(_ snapshot: SkillAuditSnapshot) {
        generation += 1
        refreshPending = false
        scanning = false
        self.snapshot = snapshot
    }

    func select(_ id: String?) {
        selectedSkillID = id
        selectionRequest &+= 1
    }

    func refresh() { refresh(invalidateCurrent: false) }

    private func refresh(invalidateCurrent: Bool) {
        let dirs = projectDirsProvider()
        guard !scanning else {
            refreshPending = refreshPending || invalidateCurrent || dirs != scanningProjects
            return
        }
        scanning = true
        scanningProjects = dirs
        let baselineURL = baselineURL
        let token = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var acks: [String: String] = [:]
            var baselineError: String?
            do { acks = try SkillAuditBaseline.load(from: baselineURL).acks }
            catch { baselineError = "Could not read Skills Audit review markers. Existing markers were preserved." }
            let result = SkillScanner.scan(projectDirs: dirs, acks: acks)
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.scanning = false
                // A review or new project set arrived while this scan was in
                // flight. Discard the stale result and collect current state.
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                    return
                }
                self.snapshot = result
                self.errorMessage = baselineError
            }
        }
    }

    @discardableResult
    func acknowledge(_ record: SkillRecord) -> Bool {
        guard record.canReview, !record.isReviewed, !scanning else { return false }
        do {
            var baseline = try SkillAuditBaseline.load(from: baselineURL)
            // Save the exact state the person saw, never a newer fingerprint
            // read behind the UI. A concurrent edit will remain flagged.
            baseline.acks[record.id] = record.fingerprint
            for registration in record.registrations {
                baseline.acks[registration.reviewKey] = record.fingerprint
            }
            try baseline.save(to: baselineURL)
            errorMessage = nil
            refresh(invalidateCurrent: true)
            return true
        } catch {
            errorMessage = "Could not save the review marker. This skill has not been marked reviewed."
            return false
        }
    }
}

struct SkillAuditBaseline: Codable {
    var acks: [String: String] = [:]
    static var file: URL { PerchPaths.appSupportDir.appendingPathComponent("skills-baseline.json") }

    static func load(from url: URL = file) throws -> SkillAuditBaseline {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return SkillAuditBaseline() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        let limit = 4 * 1024 * 1024
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= limit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count <= limit - data.count else { throw CocoaError(.fileReadTooLarge) }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, data.count == before.st_size,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save(to url: URL = file) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(parent) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        let staging = ".skills-review-\(UUID().uuidString)"
        let descriptor = openat(parent, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor); unlinkat(parent, staging, 0) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
        // POSIX rename atomically replaces the marker, including a final
        // symlink, without opening or changing that symlink's target.
        guard renameat(parent, staging, parent, url.lastPathComponent) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

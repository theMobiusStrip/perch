import Foundation
import PerchCore
import SQLite3

struct DetectionPostureEvent: Equatable, Sendable {
    let level: RiskLevel
    let observedAt: Date
}

struct DetectionFindingRecord: Equatable, Sendable {
    let code: String
    let level: RiskLevel
}

struct DetectionRecord: Equatable, Sendable {
    let recordSchemaVersion: Int
    let eventID: String
    let observedAtMs: Int64
    let endpointUser: String
    let endpointHost: String
    let producerVersion: String
    let agent: AgentKind
    let sessionID: String
    let toolUseID: String?
    let toolName: String
    let riskLevel: RiskLevel
    let findings: [DetectionFindingRecord]
}

struct DetectionIdentity: Equatable, Sendable {
    let endpointUser: String
    let endpointHost: String
    let producerVersion: String

    static var current: DetectionIdentity {
        DetectionIdentity(
            endpointUser: NSUserName(),
            endpointHost: ProcessInfo.processInfo.hostName,
            producerVersion: AppVersion.string)
    }
}

enum DetectionStoreInspection: Equatable {
    case notCreated
    case ready
    case unavailable
}

private enum DetectionStoreError: Error, CustomStringConvertible, Sendable {
    case disabled
    case filesystem(String)
    case invalidRecord
    case sqlite(operation: String, code: Int32)

    var description: String {
        switch self {
        case .disabled:
            return "disabled for this run"
        case .filesystem(let operation):
            return "\(operation) failed"
        case .invalidRecord:
            return "record validation failed"
        case .sqlite(let operation, let code):
            return "\(operation) failed (SQLite \(code))"
        }
    }

    var disablesStore: Bool {
        guard case .sqlite(_, let code) = self else { return false }
        switch code & 0xff {
        case SQLITE_CORRUPT, SQLITE_IOERR, SQLITE_NOTADB:
            return true
        default:
            return false
        }
    }
}

/// App-only durable store for the minimum facts behind accepted risk-feed
/// entries. The serial queue owns the connection and every prepared statement;
/// the bridge never links or opens this database.
final class DetectionStore {
    static let applicationID: Int32 = 0x50455243 // "PERC"
    static let schemaVersion = 1
    static let recordSchemaVersion = 1
    static let retentionDays = 30
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    static let exportColumns = [
        "record_schema_version",
        "event_id",
        "observed_at_ms",
        "endpoint_user",
        "endpoint_host",
        "producer",
        "producer_version",
        "agent",
        "session_id",
        "tool_use_id",
        "tool_name",
        "risk_level",
        "finding_code",
        "finding_level",
    ]

    let databaseURL: URL

    private let identity: DetectionIdentity
    private let queue = DispatchQueue(label: "app.perch.detection-store")
    private var database: OpaquePointer?
    private var insertEventStatement: OpaquePointer?
    private var insertFindingStatement: OpaquePointer?
    private var recentPostureStatement: OpaquePointer?
    private var pruneStatement: OpaquePointer?
    private var isDisabled = false
    private var lastPruneAt: Date?

    init(databaseURL: URL = PerchPaths.detectionDatabaseFile,
         identity: DetectionIdentity = .current) {
        self.databaseURL = databaseURL
        self.identity = identity
    }

    /// Opens, migrates, prunes, and returns only the posture events from the
    /// previous hour. Work runs off the main actor; completion returns on main.
    func start(completion: @escaping (Result<[DetectionPostureEvent], Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try openAndRestoreOnQueue(now: Date()) }
            if case .failure(let error) = result {
                PerchLog.error("Detection store open failed: \(error)", category: "detection-store")
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Copies only the approved metadata before crossing onto the store queue.
    /// In particular, the queued closure never captures tool input, cwd, paths,
    /// finding prose, or any other live RiskFeed content.
    func enqueue(_ entry: RiskFeed.Entry) {
        let record = DetectionRecord(
            recordSchemaVersion: Self.recordSchemaVersion,
            eventID: entry.id.uuidString.lowercased(),
            observedAtMs: Self.milliseconds(entry.receivedAt),
            endpointUser: identity.endpointUser,
            endpointHost: identity.endpointHost,
            producerVersion: identity.producerVersion,
            agent: entry.key.agent,
            sessionID: entry.key.id,
            toolUseID: entry.toolUseId,
            toolName: entry.toolName,
            riskLevel: entry.risk.level,
            findings: entry.risk.findings.map {
                DetectionFindingRecord(code: $0.code, level: $0.level)
            })
        enqueue(record)
    }

    func close() {
        queue.sync {
            closeOnQueue()
        }
    }

    // MARK: - Selftest seams

    @discardableResult
    func startSynchronously(now: Date = Date()) throws -> [DetectionPostureEvent] {
        try queue.sync {
            try openAndRestoreOnQueue(now: now)
        }
    }

    func insertSynchronously(_ record: DetectionRecord) throws -> Bool {
        try queue.sync {
            guard database != nil, !isDisabled else { throw DetectionStoreError.disabled }
            return try insertOnQueue(record)
        }
    }

    @discardableResult
    func pruneSynchronously(now: Date) throws -> Int {
        try queue.sync {
            guard database != nil, !isDisabled else { throw DetectionStoreError.disabled }
            return try pruneOnQueue(now: now)
        }
    }

    func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: - Diagnostics

    static func inspect(databaseURL: URL = PerchPaths.detectionDatabaseFile)
        -> DetectionStoreInspection {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .notCreated
        }

        var db: OpaquePointer?
        let openCode = databaseURL.path.withCString {
            sqlite3_open_v2($0, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard openCode == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            return .unavailable
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 250)

        guard scalarInt("PRAGMA application_id", database: db) == Int64(applicationID),
              scalarInt("PRAGMA user_version", database: db) == Int64(schemaVersion),
              viewColumns(database: db) == exportColumns else {
            return .unavailable
        }
        return .ready
    }

    static func diagnosticLine(databaseURL: URL = PerchPaths.detectionDatabaseFile) -> String {
        let suffix = "schema \(schemaVersion), contract v\(recordSchemaVersion), "
            + "\(retentionDays)-day retention — \(databaseURL.path)"
        switch inspect(databaseURL: databaseURL) {
        case .notCreated:
            return "Detection store: NOT CREATED — \(suffix)"
        case .ready:
            return "Detection store: OK — \(suffix)"
        case .unavailable:
            return "Detection store: UNAVAILABLE — \(suffix)"
        }
    }

    // MARK: - Queue-owned lifecycle

    private func openAndRestoreOnQueue(now: Date) throws -> [DetectionPostureEvent] {
        if database != nil {
            return try recentPostureOnQueue(now: now)
        }
        guard !isDisabled else { throw DetectionStoreError.disabled }

        do {
            try prepareDirectory()
            try openDatabase()
            try secureDatabaseFiles()
            try configureDatabase()
            try migrateIfNeeded()
            try prepareStatements()
            try secureDatabaseFiles()

            do {
                _ = try pruneOnQueue(now: now)
            } catch {
                handleOperationError(error, operation: "prune")
            }

            let recent: [DetectionPostureEvent]
            do {
                recent = try recentPostureOnQueue(now: now)
            } catch {
                handleOperationError(error, operation: "posture restore")
                recent = []
            }
            lastPruneAt = now
            return recent
        } catch {
            closeOnQueue()
            isDisabled = true
            throw error
        }
    }

    private func prepareDirectory() throws {
        let directory = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path)
        } catch {
            throw DetectionStoreError.filesystem("directory preparation")
        }
    }

    private func openDatabase() throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = databaseURL.path.withCString {
            sqlite3_open_v2($0, &opened, flags, nil)
        }
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw DetectionStoreError.sqlite(operation: "database open", code: code)
        }
        database = opened
        sqlite3_extended_result_codes(opened, 1)
        guard sqlite3_busy_timeout(opened, 250) == SQLITE_OK else {
            throw sqliteError("busy timeout")
        }
    }

    private func configureDatabase() throws {
        guard let database else { throw DetectionStoreError.disabled }
        let mode = try scalarText("PRAGMA journal_mode=WAL", database: database)
        guard mode.lowercased() == "wal" else {
            throw DetectionStoreError.sqlite(
                operation: "WAL configuration",
                code: sqlite3_errcode(database))
        }
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA foreign_keys=ON")
    }

    private func migrateIfNeeded() throws {
        guard let database else { throw DetectionStoreError.disabled }
        let currentApplicationID = try scalarInt("PRAGMA application_id")
        let currentVersion = try scalarInt("PRAGMA user_version")

        guard currentApplicationID == 0
                || currentApplicationID == Int64(Self.applicationID) else {
            throw DetectionStoreError.sqlite(
                operation: "application identity validation",
                code: SQLITE_MISMATCH)
        }

        switch currentVersion {
        case 0:
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("PRAGMA application_id=\(Self.applicationID)")
                try execute(Self.schemaV1)
                try execute("PRAGMA user_version=\(Self.schemaVersion)")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        case Int64(Self.schemaVersion):
            guard currentApplicationID == Int64(Self.applicationID) else {
                throw DetectionStoreError.sqlite(
                    operation: "application identity validation",
                    code: SQLITE_MISMATCH)
            }
        default:
            throw DetectionStoreError.sqlite(
                operation: "schema version validation",
                code: SQLITE_MISMATCH)
        }

        guard try scalarInt("PRAGMA application_id") == Int64(Self.applicationID),
              try scalarInt("PRAGMA user_version") == Int64(Self.schemaVersion) else {
            throw DetectionStoreError.sqlite(
                operation: "migration validation",
                code: sqlite3_errcode(database))
        }
    }

    private func prepareStatements() throws {
        insertEventStatement = try prepare("""
            INSERT INTO detection_events (
                record_schema_version, event_id, observed_at_ms,
                endpoint_user, endpoint_host, producer_version,
                agent, session_id, tool_use_id, tool_name, risk_level
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        insertFindingStatement = try prepare("""
            INSERT INTO detection_findings (
                event_id, finding_code, finding_level
            ) VALUES (?, ?, ?)
            """)
        recentPostureStatement = try prepare("""
            SELECT risk_level, observed_at_ms
            FROM detection_events
            WHERE observed_at_ms >= ?
            ORDER BY observed_at_ms, event_id
            """)
        pruneStatement = try prepare("""
            DELETE FROM detection_events
            WHERE observed_at_ms < ?
            """)
    }

    private func closeOnQueue() {
        for statement in [
            insertEventStatement,
            insertFindingStatement,
            recentPostureStatement,
            pruneStatement,
        ] {
            if let statement { sqlite3_finalize(statement) }
        }
        insertEventStatement = nil
        insertFindingStatement = nil
        recentPostureStatement = nil
        pruneStatement = nil
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
    }

    // MARK: - Queue-owned operations

    private func enqueue(_ record: DetectionRecord) {
        queue.async { [self] in
            guard database != nil, !isDisabled else { return }
            do {
                _ = try insertOnQueue(record)
                let now = Date()
                if lastPruneAt.map({ now.timeIntervalSince($0) >= 24 * 60 * 60 }) ?? true {
                    _ = try pruneOnQueue(now: now)
                    lastPruneAt = now
                }
            } catch {
                handleOperationError(error, operation: "insert")
            }
        }
    }

    private func insertOnQueue(_ record: DetectionRecord) throws -> Bool {
        guard record.recordSchemaVersion == Self.recordSchemaVersion,
              record.riskLevel != .safe,
              !record.findings.isEmpty,
              record.findings.allSatisfy({ $0.level != .safe }),
              record.findings.map(\.level).max() == record.riskLevel else {
            throw DetectionStoreError.invalidRecord
        }
        guard let eventStatement = insertEventStatement,
              let findingStatement = insertFindingStatement else {
            throw DetectionStoreError.disabled
        }

        try execute("BEGIN IMMEDIATE")
        do {
            reset(eventStatement)
            try bind(Int64(record.recordSchemaVersion), at: 1, in: eventStatement)
            try bind(record.eventID, at: 2, in: eventStatement)
            try bind(record.observedAtMs, at: 3, in: eventStatement)
            try bind(record.endpointUser, at: 4, in: eventStatement)
            try bind(record.endpointHost, at: 5, in: eventStatement)
            try bind(record.producerVersion, at: 6, in: eventStatement)
            try bind(record.agent.rawValue, at: 7, in: eventStatement)
            try bind(record.sessionID, at: 8, in: eventStatement)
            try bind(record.toolUseID, at: 9, in: eventStatement)
            try bind(record.toolName, at: 10, in: eventStatement)
            try bind(record.riskLevel.label, at: 11, in: eventStatement)

            let eventCode = sqlite3_step(eventStatement)
            if Self.isUniquenessConflict(eventCode) {
                reset(eventStatement)
                try execute("ROLLBACK")
                return false
            }
            guard eventCode == SQLITE_DONE else {
                throw sqliteError("event insert", code: eventCode)
            }
            reset(eventStatement)

            for finding in record.findings {
                reset(findingStatement)
                try bind(record.eventID, at: 1, in: findingStatement)
                try bind(finding.code, at: 2, in: findingStatement)
                try bind(finding.level.label, at: 3, in: findingStatement)
                let findingCode = sqlite3_step(findingStatement)
                guard findingCode == SQLITE_DONE else {
                    throw sqliteError("finding insert", code: findingCode)
                }
                reset(findingStatement)
            }
            try secureDatabaseFiles()
            try execute("COMMIT")
            return true
        } catch {
            reset(eventStatement)
            reset(findingStatement)
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func recentPostureOnQueue(now: Date) throws -> [DetectionPostureEvent] {
        guard let statement = recentPostureStatement else {
            throw DetectionStoreError.disabled
        }
        reset(statement)
        defer { reset(statement) }
        let cutoff = Self.milliseconds(now.addingTimeInterval(-SecurityPosture.window))
        try bind(cutoff, at: 1, in: statement)

        var result: [DetectionPostureEvent] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else {
                throw sqliteError("posture query", code: code)
            }
            let label = Self.textColumn(statement, at: 0)
            let level: RiskLevel
            switch label {
            case "caution": level = .caution
            case "danger": level = .danger
            default:
                throw DetectionStoreError.sqlite(
                    operation: "posture decoding",
                    code: SQLITE_MISMATCH)
            }
            let observedAtMs = sqlite3_column_int64(statement, 1)
            result.append(DetectionPostureEvent(
                level: level,
                observedAt: Date(timeIntervalSince1970: Double(observedAtMs) / 1000)))
        }
    }

    private func pruneOnQueue(now: Date) throws -> Int {
        guard let database, let statement = pruneStatement else {
            throw DetectionStoreError.disabled
        }
        reset(statement)
        defer { reset(statement) }
        let cutoff = Self.milliseconds(now.addingTimeInterval(-Self.retentionInterval))
        try bind(cutoff, at: 1, in: statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            throw sqliteError("retention prune", code: code)
        }
        try secureDatabaseFiles()
        return Int(sqlite3_changes(database))
    }

    private func handleOperationError(_ error: Error, operation: String) {
        PerchLog.error("Detection store \(operation) failed: \(error)",
                       category: "detection-store")
        if let storeError = error as? DetectionStoreError, storeError.disablesStore {
            closeOnQueue()
            isDisabled = true
        }
    }

    // MARK: - SQLite helpers

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw DetectionStoreError.disabled }
        var statement: OpaquePointer?
        let code = sql.withCString {
            sqlite3_prepare_v2(database, $0, -1, &statement, nil)
        }
        guard code == SQLITE_OK, let statement else {
            throw sqliteError("statement preparation", code: code)
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw DetectionStoreError.disabled }
        let code = sql.withCString {
            sqlite3_exec(database, $0, nil, nil, nil)
        }
        guard code == SQLITE_OK else {
            throw sqliteError("statement execution", code: code)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else {
            throw sqliteError("metadata query", code: code)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarText(_ sql: String, database: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        let prepareCode = sql.withCString {
            sqlite3_prepare_v2(database, $0, -1, &statement, nil)
        }
        guard prepareCode == SQLITE_OK, let statement else {
            throw sqliteError("metadata query", code: prepareCode)
        }
        defer { sqlite3_finalize(statement) }
        let stepCode = sqlite3_step(statement)
        guard stepCode == SQLITE_ROW else {
            throw sqliteError("metadata query", code: stepCode)
        }
        return Self.textColumn(statement, at: 0)
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer)
        throws {
        let code: Int32
        if let value {
            code = value.withCString {
                sqlite3_bind_text(statement, index, $0, -1, Self.sqliteTransient)
            }
        } else {
            code = sqlite3_bind_null(statement, index)
        }
        guard code == SQLITE_OK else {
            throw sqliteError("value binding", code: code)
        }
    }

    private func bind(_ value: Int64, at index: Int32, in statement: OpaquePointer)
        throws {
        let code = sqlite3_bind_int64(statement, index, value)
        guard code == SQLITE_OK else {
            throw sqliteError("value binding", code: code)
        }
    }

    private func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func secureDatabaseFiles() throws {
        let manager = FileManager.default
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where manager.fileExists(atPath: url.path) {
            do {
                try manager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path)
            } catch {
                throw DetectionStoreError.filesystem("file permission update")
            }
        }
    }

    private func sqliteError(_ operation: String, code: Int32? = nil)
        -> DetectionStoreError {
        DetectionStoreError.sqlite(
            operation: operation,
            code: code ?? database.map { sqlite3_extended_errcode($0) } ?? SQLITE_ERROR)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func isUniquenessConflict(_ code: Int32) -> Bool {
        let primaryKey = SQLITE_CONSTRAINT | Int32(6 << 8)
        let unique = SQLITE_CONSTRAINT | Int32(8 << 8)
        return code == primaryKey || code == unique
    }

    private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self)

    private static func textColumn(_ statement: OpaquePointer, at index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: UnsafeRawPointer(bytes).assumingMemoryBound(to: CChar.self))
    }

    private static func scalarInt(_ sql: String, database: OpaquePointer) -> Int64? {
        var statement: OpaquePointer?
        let prepareCode = sql.withCString {
            sqlite3_prepare_v2(database, $0, -1, &statement, nil)
        }
        guard prepareCode == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private static func viewColumns(database: OpaquePointer) -> [String]? {
        var statement: OpaquePointer?
        let sql = "SELECT * FROM detection_export_v1 LIMIT 0"
        let prepareCode = sql.withCString {
            sqlite3_prepare_v2(database, $0, -1, &statement, nil)
        }
        guard prepareCode == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        return (0..<sqlite3_column_count(statement)).compactMap { index in
            sqlite3_column_name(statement, index).map(String.init(cString:))
        }
    }

    private static let schemaV1 = """
        CREATE TABLE detection_events (
            record_schema_version  INTEGER NOT NULL CHECK (record_schema_version = 1),
            event_id               TEXT PRIMARY KEY,
            observed_at_ms         INTEGER NOT NULL,
            endpoint_user          TEXT NOT NULL,
            endpoint_host          TEXT NOT NULL,
            producer_version       TEXT NOT NULL,
            agent                  TEXT NOT NULL CHECK (agent IN ('claude', 'codex')),
            session_id             TEXT NOT NULL,
            tool_use_id            TEXT,
            tool_name              TEXT NOT NULL,
            risk_level             TEXT NOT NULL
                                        CHECK (risk_level IN ('caution', 'danger'))
        );

        CREATE TABLE detection_findings (
            event_id       TEXT NOT NULL
                                REFERENCES detection_events(event_id) ON DELETE CASCADE,
            finding_code   TEXT NOT NULL,
            finding_level  TEXT NOT NULL
                                CHECK (finding_level IN ('caution', 'danger')),
            PRIMARY KEY (event_id, finding_code)
        );

        CREATE INDEX detection_events_observed_at
            ON detection_events(observed_at_ms DESC, event_id DESC);

        CREATE UNIQUE INDEX detection_events_tool_use
            ON detection_events(agent, session_id, tool_use_id)
            WHERE tool_use_id IS NOT NULL;

        CREATE VIEW detection_export_v1 AS
        SELECT
            e.record_schema_version,
            e.event_id,
            e.observed_at_ms,
            e.endpoint_user,
            e.endpoint_host,
            'perch' AS producer,
            e.producer_version,
            e.agent,
            e.session_id,
            e.tool_use_id,
            e.tool_name,
            e.risk_level,
            f.finding_code,
            f.finding_level
        FROM detection_events AS e
        JOIN detection_findings AS f USING (event_id);
        """
}

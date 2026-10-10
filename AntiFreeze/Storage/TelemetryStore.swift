import Foundation
import SQLite3

// MARK: - TelemetryStore (Phase 1)
//
// Local-only SQLite store. One table for raw events, one for hourly
// aggregates. Retention: raw samples are downsampled into hourly aggregates
// after 7 days and deleted after 30 days, so the database cannot grow
// unbounded on a machine that is never restarted.
//
// Chosen over CoreData deliberately: the schema is two flat tables and the
// access pattern is append + time-range scan, which raw SQLite expresses
// with zero model-layer magic. (Spec allowed either; exactly one is used.)

final class TelemetryStore {
    static let shared = TelemetryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.luckyclover.antifreeze.store", qos: .utility)

    /// Raw samples older than this are aggregated into hourly rows.
    private let downsampleAfter: TimeInterval = 7 * 24 * 3600
    /// Raw samples older than this are deleted outright.
    private let rawRetention: TimeInterval = 30 * 24 * 3600

    private init() {}

    // MARK: - Lifecycle

    /// Opens (creating if needed) the database. Returns false on failure —
    /// the engine treats a false here as "run without persistence" rather
    /// than crashing.
    @discardableResult
    func open() -> Bool {
        var ok = false
        queue.sync {
            do {
                let dir = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appendingPathComponent("AntiFreeze", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let path = dir.appendingPathComponent("telemetry.db").path
                if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
                    ok = self.exec("""
                        CREATE TABLE IF NOT EXISTS telemetry_events (
                            id TEXT PRIMARY KEY,
                            timestamp REAL NOT NULL,
                            category TEXT NOT NULL,
                            metric TEXT NOT NULL,
                            value REAL NOT NULL,
                            severity TEXT NOT NULL,
                            source TEXT NOT NULL,
                            metadata TEXT
                        );
                        CREATE INDEX IF NOT EXISTS idx_telemetry_time
                            ON telemetry_events(timestamp);
                        CREATE INDEX IF NOT EXISTS idx_telemetry_cat_metric_time
                            ON telemetry_events(category, metric, timestamp);
                        CREATE TABLE IF NOT EXISTS telemetry_hourly (
                            hour REAL NOT NULL,
                            category TEXT NOT NULL,
                            metric TEXT NOT NULL,
                            avg_value REAL NOT NULL,
                            min_value REAL NOT NULL,
                            max_value REAL NOT NULL,
                            sample_count INTEGER NOT NULL,
                            PRIMARY KEY (hour, category, metric)
                        );
                        """)
                } else {
                    db = nil
                }
            } catch {
                db = nil
            }
        }
        return ok
    }

    func close() {
        queue.sync {
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
        }
    }

    // MARK: - Writes

    func insert(_ event: TelemetryEvent) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = """
                INSERT OR IGNORE INTO telemetry_events
                (id, timestamp, category, metric, value, severity, source, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let metaJSON: String? = event.metadata.flatMap {
                String(data: (try? JSONEncoder().encode($0)) ?? Data(), encoding: .utf8)
            }
            sqlite3_bind_text(stmt, 1, event.id.uuidString, -1, SQLITE_TRANSIENT_PTR)
            sqlite3_bind_double(stmt, 2, event.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, event.category.rawValue, -1, SQLITE_TRANSIENT_PTR)
            sqlite3_bind_text(stmt, 4, event.metric, -1, SQLITE_TRANSIENT_PTR)
            sqlite3_bind_double(stmt, 5, event.value)
            sqlite3_bind_text(stmt, 6, event.severity.rawValue, -1, SQLITE_TRANSIENT_PTR)
            sqlite3_bind_text(stmt, 7, event.source, -1, SQLITE_TRANSIENT_PTR)
            if let metaJSON {
                sqlite3_bind_text(stmt, 8, metaJSON, -1, SQLITE_TRANSIENT_PTR)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_step(stmt)
        }
    }

    func insert(_ events: [TelemetryEvent]) {
        for e in events { insert(e) }
    }

    // MARK: - Reads

    /// Most recent raw samples for one metric, newest first.
    func recentSamples(category: TelemetryCategory, metric: String, limit: Int = 120) -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            let sql = """
                SELECT timestamp, value FROM telemetry_events
                WHERE category = ? AND metric = ?
                ORDER BY timestamp DESC LIMIT ?;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, category.rawValue, -1, SQLITE_TRANSIENT_PTR)
            sqlite3_bind_text(stmt, 2, metric, -1, SQLITE_TRANSIENT_PTR)
            sqlite3_bind_int(stmt, 3, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let t = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                out.append((t, sqlite3_column_double(stmt, 1)))
            }
        }
        return out
    }

    // MARK: - Retention + downsampling

    /// Aggregate raw samples older than `downsampleAfter` into hourly rows,
    /// then delete raw samples older than `rawRetention`. Safe to call on a
    /// daily timer; runs inside a transaction.
    func enforceRetention() {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let now = Date().timeIntervalSince1970
            let downsampleCutoff = now - self.downsampleAfter
            let deleteCutoff = now - self.rawRetention
            self.exec("BEGIN IMMEDIATE;")
            // Hourly aggregates for anything old enough to downsample.
            self.exec("""
                INSERT OR REPLACE INTO telemetry_hourly
                (hour, category, metric, avg_value, min_value, max_value, sample_count)
                SELECT
                    CAST(timestamp / 3600 AS INTEGER) * 3600.0,
                    category, metric,
                    AVG(value), MIN(value), MAX(value), COUNT(*)
                FROM telemetry_events
                WHERE timestamp < \(downsampleCutoff)
                GROUP BY 1, 2, 3;
                """)
            // Drop the raw rows we just aggregated (keep the most recent
            // `downsampleAfter` window of raw samples).
            self.exec("DELETE FROM telemetry_events WHERE timestamp < \(downsampleCutoff);")
            // Belt-and-braces: nothing raw survives past rawRetention even if
            // aggregation somehow missed it.
            self.exec("DELETE FROM telemetry_events WHERE timestamp < \(deleteCutoff);")
            self.exec("COMMIT;")
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}

// sqlite3_bind_text needs a destructor; SQLITE_TRANSIENT as a Swift value.
private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

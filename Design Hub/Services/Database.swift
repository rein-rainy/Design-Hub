import Foundation
import SQLite3

// Minimal SQLite3 wrapper. All methods are synchronous and must be called
// from a single thread (VersionStore runs everything on @MainActor).

final class Database {

    private let handle: OpaquePointer

    // SQLite value types used for binding and reading
    enum Value {
        case text(String)
        case integer(Int64)
        case null

        var string: String? { if case .text(let s) = self { return s } else { return nil } }
        var int64: Int64?   { if case .integer(let i) = self { return i } else { return nil } }
        var int: Int?       { int64.map(Int.init) }
        var bool: Bool      { int64 == 1 }
    }

    enum DBError: Error { case open(String), prepare(String), step(String) }

    // -1 cast to function pointer tells SQLite to copy the string immediately.
    private let transient = unsafeBitCast(Int(bitPattern: UInt(bitPattern: -1)),
                                          to: sqlite3_destructor_type.self)

    // MARK: - Init

    init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let handle = h else {
            throw DBError.open("Cannot open database at \(path)")
        }
        self.handle = handle
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    // MARK: - Public API

    /// Execute a SQL string that produces no rows.
    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DBError.step(errorMessage)
        }
    }

    /// Execute a parameterised write statement.
    func run(_ sql: String, _ params: [Value] = []) throws {
        let stmt = try makeStatement(sql)
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw DBError.step(errorMessage) }
    }

    /// Execute a parameterised query and return rows.
    func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Value]] {
        let stmt = try makeStatement(sql)
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)

        var rows: [[String: Value]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Value] = [:]
            let count = sqlite3_column_count(stmt)
            for i in 0..<count {
                let name = String(cString: sqlite3_column_name(stmt, i))
                row[name] = readColumn(stmt, at: i)
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - Private

    private func makeStatement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DBError.prepare(errorMessage)
        }
        return s
    }

    private func bind(_ params: [Value], to stmt: OpaquePointer) {
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .text(let s):    sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .integer(let n): sqlite3_bind_int64(stmt, idx, n)
            case .null:           sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func readColumn(_ stmt: OpaquePointer, at index: Int32) -> Value {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:    return .text(String(cString: sqlite3_column_text(stmt, index)))
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, index))
        default:             return .null
        }
    }

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }
}

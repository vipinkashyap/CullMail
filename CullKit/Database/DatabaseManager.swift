//
//  DatabaseManager.swift
//  CullKit
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
import GRDB
import os

/// DatabaseManager provides thread-safe database access using GRDB's DatabasePool
/// Note: This is a class (not actor) because GRDB's DatabasePool is already thread-safe
/// and using an actor causes deadlocks when called from @MainActor context
public final class DatabaseManager: @unchecked Sendable {
    public static let shared = DatabaseManager()

    private var dbPool: DatabasePool?
    private let logger = Logger(subsystem: "com.cull.mail", category: "database")
    private let lock = NSLock()

    private init() {}

    // MARK: - Database Access

    public var reader: some DatabaseReader {
        get throws {
            lock.lock()
            defer { lock.unlock() }
            guard let dbPool else {
                throw DatabaseError.notInitialized
            }
            return dbPool
        }
    }

    public var writer: some DatabaseWriter {
        get throws {
            lock.lock()
            defer { lock.unlock() }
            guard let dbPool else {
                throw DatabaseError.notInitialized
            }
            return dbPool
        }
    }

    /// Returns the DatabasePool for ValueObservation subscriptions
    /// Use this for reactive UI updates via GRDB's observation system
    public var databasePool: DatabasePool {
        get throws {
            lock.lock()
            defer { lock.unlock() }
            guard let dbPool else {
                throw DatabaseError.notInitialized
            }
            return dbPool
        }
    }

    // MARK: - Initialization

    public func initialize() throws {
        lock.lock()
        defer { lock.unlock() }
        guard dbPool == nil else { return }

        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let dbDirectoryURL = appSupportURL.appendingPathComponent("CullMail", isDirectory: true)
        try fileManager.createDirectory(at: dbDirectoryURL, withIntermediateDirectories: true)

        let dbURL = dbDirectoryURL.appendingPathComponent("cull.sqlite")
        logger.info("Database path: \(dbURL.path)")

        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { self.logger.debug("\($0)") }
        }

        dbPool = try DatabasePool(path: dbURL.path, configuration: config)

        try migrate()
        logger.info("Database initialized successfully")
    }

    // MARK: - Migration

    private func migrate() throws {
        guard let dbPool else { return }

        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            // Emails table
            try db.create(table: "emails") { t in
                t.primaryKey("id", .text)
                t.column("threadId", .text).notNull()
                t.column("subject", .text)
                t.column("snippet", .text)
                t.column("from", .text).notNull()
                t.column("fromDomain", .text).notNull()
                t.column("to", .text)  // JSON array
                t.column("date", .datetime).notNull()
                t.column("labelIds", .text)  // JSON array
                t.column("isRead", .boolean).defaults(to: false)
                t.column("hasAttachments", .boolean).defaults(to: false)
                t.column("category", .text)
                t.column("rawPayload", .blob)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(index: "idx_emails_domain", on: "emails", columns: ["fromDomain"])
            try db.create(index: "idx_emails_date", on: "emails", columns: ["date"])
            try db.create(index: "idx_emails_category", on: "emails", columns: ["category"])
            try db.create(index: "idx_emails_thread", on: "emails", columns: ["threadId"])

            // Senders table
            try db.create(table: "senders") { t in
                t.primaryKey("domain", .text)
                t.column("totalEmails", .integer).defaults(to: 0)
                t.column("openedCount", .integer).defaults(to: 0)
                t.column("repliedCount", .integer).defaults(to: 0)
                t.column("archivedWithoutReadingCount", .integer).defaults(to: 0)
                t.column("avgTimeToArchiveSeconds", .double)
                t.column("lastEmailAt", .datetime)
                t.column("category", .text)
                t.column("userAction", .text)
                t.column("confidenceScore", .double).defaults(to: 0.5)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Sync state table
            try db.create(table: "sync_state") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Daily stats table
            try db.create(table: "daily_stats") { t in
                t.primaryKey("date", .text)  // YYYY-MM-DD
                t.column("emailsProcessed", .integer).defaults(to: 0)
                t.column("emailsAutoArchived", .integer).defaults(to: 0)
                t.column("attachmentsSaved", .integer).defaults(to: 0)
                t.column("timeSavedSeconds", .integer).defaults(to: 0)
            }
        }

        // Migration v2: Add attachments table
        migrator.registerMigration("v2_attachments") { db in
            try db.create(table: "attachments") { t in
                t.primaryKey("id", .text)
                t.column("emailId", .text).notNull()
                    .references("emails", onDelete: .cascade)
                t.column("filename", .text).notNull()
                t.column("mimeType", .text)
                t.column("sizeBytes", .integer).notNull()
                t.column("category", .text)
                t.column("extractedText", .text)
                t.column("driveFileId", .text)
                t.column("uploadedAt", .datetime)
                t.column("localPath", .text)
                t.column("isTextExtracted", .boolean).defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Index for finding attachments by email
            try db.create(index: "idx_attachments_email", on: "attachments", columns: ["emailId"])

            // Index for finding attachments by category (for smart filing features)
            try db.create(index: "idx_attachments_category", on: "attachments", columns: ["category"])

            // Index for Drive sync status
            try db.create(index: "idx_attachments_drive", on: "attachments", columns: ["driveFileId"])

            // Full-text search index for extracted text (using SQLite FTS5)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS attachments_fts USING fts5(
                    filename,
                    extractedText,
                    content='attachments',
                    content_rowid='rowid'
                )
            """)

            // Triggers to keep FTS index in sync
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS attachments_ai AFTER INSERT ON attachments BEGIN
                    INSERT INTO attachments_fts(rowid, filename, extractedText)
                    VALUES (NEW.rowid, NEW.filename, NEW.extractedText);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS attachments_ad AFTER DELETE ON attachments BEGIN
                    INSERT INTO attachments_fts(attachments_fts, rowid, filename, extractedText)
                    VALUES ('delete', OLD.rowid, OLD.filename, OLD.extractedText);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS attachments_au AFTER UPDATE ON attachments BEGIN
                    INSERT INTO attachments_fts(attachments_fts, rowid, filename, extractedText)
                    VALUES ('delete', OLD.rowid, OLD.filename, OLD.extractedText);
                    INSERT INTO attachments_fts(rowid, filename, extractedText)
                    VALUES (NEW.rowid, NEW.filename, NEW.extractedText);
                END
            """)
        }

        // Migration v3: Add domain_patterns table for learned classification
        migrator.registerMigration("v3_domain_patterns") { db in
            try db.create(table: "domain_patterns") { t in
                t.primaryKey("domain", .text)
                t.column("category", .text).notNull()
                t.column("confidence", .double).defaults(to: 0.5)
                t.column("sampleCount", .integer).defaults(to: 0)
                t.column("lastUpdated", .datetime).notNull()
            }

            // Index for finding patterns by category
            try db.create(index: "idx_patterns_category", on: "domain_patterns", columns: ["category"])
        }

        try migrator.migrate(dbPool)
    }
}

// MARK: - Errors

public enum DatabaseError: Error, LocalizedError {
    case notInitialized

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Database has not been initialized. Call DatabaseManager.shared.initialize() first."
        }
    }
}

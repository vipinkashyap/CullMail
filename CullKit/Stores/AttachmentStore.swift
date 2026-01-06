//
//  AttachmentStore.swift
//  CullKit
//
//  Unified reactive store for attachments
//  Uses GRDB ValueObservation for automatic UI updates
//

import Foundation
import GRDB
import Combine
import os

@MainActor
public final class AttachmentStore: ObservableObject {
    public static let shared = AttachmentStore()

    private let logger = Logger(subsystem: "com.cull.mail", category: "attachmentStore")
    private var attachmentsObserver: AnyDatabaseCancellable?
    private var statsObserver: AnyDatabaseCancellable?

    // MARK: - Observed State

    /// Recent attachments - auto-updated when DB changes
    @Published public private(set) var attachments: [Attachment] = []

    /// Total attachment count
    @Published public private(set) var totalCount: Int = 0

    /// Attachment stats by category
    @Published public private(set) var categoryStats: [AttachmentCategory: Int] = [:]

    /// Total size of all attachments
    @Published public private(set) var totalSizeBytes: Int64 = 0

    /// Error state for observer failures
    @Published public private(set) var observerError: String?

    private var retryCount = 0
    private let maxRetries = 3

    private init() {}

    // MARK: - Lifecycle

    public func start() throws {
        guard attachmentsObserver == nil else { return }

        observerError = nil
        retryCount = 0

        let pool = try DatabaseManager.shared.databasePool

        // Observe recent attachments
        let attachmentsObservation = ValueObservation.tracking { db in
            try Attachment
                .order(Attachment.Columns.createdAt.desc)
                .limit(500)
                .fetchAll(db)
        }

        attachmentsObserver = attachmentsObservation.start(
            in: pool,
            onError: { [weak self] error in
                self?.handleObserverError(error)
            },
            onChange: { [weak self] attachments in
                Task { @MainActor in
                    self?.attachments = attachments
                    self?.totalCount = attachments.count
                    self?.observerError = nil
                    self?.retryCount = 0
                }
            }
        )

        // Observe category stats
        let statsObservation = ValueObservation.tracking { db -> [AttachmentCategory: Int] in
            var stats: [AttachmentCategory: Int] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT category, COUNT(*) as count
                FROM attachments
                GROUP BY category
            """)
            for row in rows {
                if let categoryRaw: String = row["category"],
                   let category = AttachmentCategory(rawValue: categoryRaw) {
                    stats[category] = row["count"]
                }
            }
            return stats
        }

        statsObserver = statsObservation.start(
            in: pool,
            onError: { [weak self] error in
                self?.logger.error("Stats observation error: \(error.localizedDescription)")
            },
            onChange: { [weak self] stats in
                Task { @MainActor in
                    self?.categoryStats = stats
                }
            }
        )

        logger.info("AttachmentStore started")
    }

    private func handleObserverError(_ error: Error) {
        logger.error("Attachment observation error: \(error.localizedDescription)")

        Task { @MainActor in
            self.observerError = "Database error: \(error.localizedDescription)"

            if self.retryCount < self.maxRetries {
                self.retryCount += 1
                let delay = pow(2.0, Double(self.retryCount))
                self.logger.info("Attempting observer recovery (attempt \(self.retryCount)/\(self.maxRetries)) in \(delay)s")

                try? await Task.sleep(for: .seconds(delay))
                self.restart()
            } else {
                self.logger.error("Observer recovery failed after \(self.maxRetries) attempts")
            }
        }
    }

    public func restart() {
        stop()
        do {
            try start()
            logger.info("AttachmentStore restarted successfully")
        } catch {
            logger.error("Failed to restart AttachmentStore: \(error.localizedDescription)")
            observerError = "Failed to restart: \(error.localizedDescription)"
        }
    }

    public func stop() {
        attachmentsObserver?.cancel()
        statsObserver?.cancel()
        attachmentsObserver = nil
        statsObserver = nil
    }

    // MARK: - Write Operations

    public func save(_ attachment: Attachment) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try attachment.save(db)
        }
    }

    public func saveAll(_ attachments: [Attachment]) async throws {
        try await DatabaseManager.shared.writer.write { db in
            for attachment in attachments {
                try attachment.save(db)
            }
        }
    }

    public func delete(id: String) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try Attachment.deleteOne(db, key: id)
        }
    }

    public func deleteForEmail(emailId: String) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try Attachment
                .filter(Attachment.Columns.emailId == emailId)
                .deleteAll(db)
        }
    }

    public func updateExtractedText(id: String, text: String) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try db.execute(
                sql: "UPDATE attachments SET extractedText = ?, isTextExtracted = 1, updatedAt = ? WHERE id = ?",
                arguments: [text, Date(), id]
            )
        }
    }

    public func updateDriveFileId(id: String, driveFileId: String) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try db.execute(
                sql: "UPDATE attachments SET driveFileId = ?, uploadedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [driveFileId, Date(), Date(), id]
            )
        }
    }

    public func updateLocalPath(id: String, localPath: String) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try db.execute(
                sql: "UPDATE attachments SET localPath = ?, updatedAt = ? WHERE id = ?",
                arguments: [localPath, Date(), id]
            )
        }
    }

    // MARK: - Queries

    public func fetch(id: String) async throws -> Attachment? {
        try await DatabaseManager.shared.reader.read { db in
            try Attachment.fetchOne(db, key: id)
        }
    }

    public func fetchForEmail(emailId: String) async throws -> [Attachment] {
        try await DatabaseManager.shared.reader.read { db in
            try Attachment
                .filter(Attachment.Columns.emailId == emailId)
                .order(Attachment.Columns.filename)
                .fetchAll(db)
        }
    }

    public func fetchByCategory(_ category: AttachmentCategory, limit: Int = 100) async throws -> [Attachment] {
        try await DatabaseManager.shared.reader.read { db in
            try Attachment
                .filter(Attachment.Columns.category == category.rawValue)
                .order(Attachment.Columns.createdAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func fetchPendingTextExtraction(limit: Int = 50) async throws -> [Attachment] {
        try await DatabaseManager.shared.reader.read { db in
            try Attachment
                .filter(Attachment.Columns.isTextExtracted == false)
                .filter(sql: "mimeType LIKE '%pdf%' OR filename LIKE '%.pdf'")
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func fetchPendingDriveUpload(limit: Int = 50) async throws -> [Attachment] {
        try await DatabaseManager.shared.reader.read { db in
            try Attachment
                .filter(Attachment.Columns.driveFileId == nil)
                .order(Attachment.Columns.createdAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Full-Text Search

    /// Search attachments by filename or extracted text content
    public func search(query: String, limit: Int = 50) async throws -> [Attachment] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }

        return try await DatabaseManager.shared.reader.read { db in
            // Use FTS5 for full-text search
            let rows = try Row.fetchAll(db, sql: """
                SELECT attachments.*
                FROM attachments
                JOIN attachments_fts ON attachments.rowid = attachments_fts.rowid
                WHERE attachments_fts MATCH ?
                ORDER BY rank
                LIMIT ?
            """, arguments: [query, limit])

            return rows.compactMap { row -> Attachment? in
                try? Attachment(row: row)
            }
        }
    }

    /// Search attachments within a specific category
    public func search(query: String, category: AttachmentCategory, limit: Int = 50) async throws -> [Attachment] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return try await fetchByCategory(category, limit: limit)
        }

        return try await DatabaseManager.shared.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT attachments.*
                FROM attachments
                JOIN attachments_fts ON attachments.rowid = attachments_fts.rowid
                WHERE attachments_fts MATCH ?
                AND attachments.category = ?
                ORDER BY rank
                LIMIT ?
            """, arguments: [query, category.rawValue, limit])

            return rows.compactMap { row -> Attachment? in
                try? Attachment(row: row)
            }
        }
    }

    // MARK: - Stats

    public func getTotalSizeBytes() async throws -> Int64 {
        try await DatabaseManager.shared.reader.read { db in
            let sum = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM attachments")
            return sum ?? 0
        }
    }

    public func getCountByCategory() async throws -> [AttachmentCategory: Int] {
        try await DatabaseManager.shared.reader.read { db in
            var stats: [AttachmentCategory: Int] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT category, COUNT(*) as count
                FROM attachments
                GROUP BY category
            """)
            for row in rows {
                if let categoryRaw: String = row["category"],
                   let category = AttachmentCategory(rawValue: categoryRaw) {
                    stats[category] = row["count"]
                }
            }
            return stats
        }
    }
}

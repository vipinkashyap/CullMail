//
//  EmailRepository.swift
//  CullKit
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
import GRDB

public struct EmailRepository: Sendable {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    // MARK: - Create/Update

    public func save(_ email: Email) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try email.save(db)
        }
    }

    public func saveAll(_ emails: [Email]) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            for email in emails {
                try email.save(db)
            }
        }
    }

    // MARK: - Read

    public func fetch(id: String) async throws -> Email? {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Email.fetchOne(db, key: id)
        }
    }

    public func fetchAll(limit: Int = 100, offset: Int = 0) async throws -> [Email] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Email
                .order(Email.Columns.date.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    public func fetchByDomain(_ domain: String, limit: Int = 1000) async throws -> [Email] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Email
                .filter(Email.Columns.fromDomain == domain)
                .order(Email.Columns.date.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Fetches emails from a root domain and all its subdomains
    /// e.g., "facebookmail.com" matches "facebookmail.com", "pages.facebookmail.com", etc.
    public func fetchByRootDomain(_ rootDomain: String, limit: Int = 5000) async throws -> [Email] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Email
                .filter(Email.Columns.fromDomain == rootDomain || Email.Columns.fromDomain.like("%.\(rootDomain)"))
                .order(Email.Columns.date.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func fetchByCategory(_ category: EmailCategory, limit: Int = 100) async throws -> [Email] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Email
                .filter(Email.Columns.category == category)
                .order(Email.Columns.date.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func fetchUnread(limit: Int = 100) async throws -> [Email] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Email
                .filter(Email.Columns.isRead == false)
                .order(Email.Columns.date.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func fetchByThread(_ threadId: String) async throws -> [Email] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Email
                .filter(Email.Columns.threadId == threadId)
                .order(Email.Columns.date.asc)
                .fetchAll(db)
        }
    }

    // MARK: - Delete

    public func delete(id: String) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try Email.deleteOne(db, key: id)
        }
    }

    public func deleteAll(ids: [String]) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try Email.deleteAll(db, keys: ids)
        }
    }

    public func deleteByDomain(_ domain: String) async throws -> Int {
        let writer = try await dbManager.writer
        return try await writer.write { db in
            try Email
                .filter(Email.Columns.fromDomain == domain)
                .deleteAll(db)
        }
    }

    // MARK: - Counts

    public func count() async throws -> Int {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Email.fetchCount(db)
        }
    }

    public func countByDomain(_ domain: String) async throws -> Int {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Email
                .filter(Email.Columns.fromDomain == domain)
                .fetchCount(db)
        }
    }

    public func countUnread() async throws -> Int {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Email
                .filter(Email.Columns.isRead == false)
                .fetchCount(db)
        }
    }

    // MARK: - Updates

    public func markAsRead(id: String) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE emails SET isRead = 1, updatedAt = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    public func updateCategory(id: String, category: EmailCategory) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE emails SET category = ?, updatedAt = ? WHERE id = ?",
                arguments: [category.rawValue, Date(), id]
            )
        }
    }

    // MARK: - Domain Stats

    public func uniqueDomains() async throws -> [String] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT fromDomain FROM emails ORDER BY fromDomain")
        }
    }

    public func domainCounts() async throws -> [(domain: String, count: Int)] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT fromDomain, COUNT(*) as count
                FROM emails
                GROUP BY fromDomain
                ORDER BY count DESC
            """)
            return rows.map { (domain: $0["fromDomain"], count: $0["count"]) }
        }
    }

    // MARK: - Attachment Backfill

    /// Fetches emails that have hasAttachments=true but no corresponding attachment records
    public func fetchEmailsWithAttachmentsNeedingBackfill() async throws -> [Email] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Email.fetchAll(db, sql: """
                SELECT emails.*
                FROM emails
                LEFT JOIN attachments ON attachments.emailId = emails.id
                WHERE emails.hasAttachments = 1
                AND attachments.id IS NULL
                ORDER BY emails.date DESC
            """)
        }
    }
}

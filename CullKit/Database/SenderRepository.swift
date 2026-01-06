//
//  SenderRepository.swift
//  CullKit
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
import GRDB

public struct SenderRepository: Sendable {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    // MARK: - Create/Update

    public func save(_ sender: Sender) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try sender.save(db)
        }
    }

    public func upsert(_ sender: Sender) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try sender.upsert(db)
        }
    }

    // MARK: - Read

    public func fetch(domain: String) async throws -> Sender? {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Sender.fetchOne(db, key: domain)
        }
    }

    public func fetchAll(limit: Int = 100, offset: Int = 0) async throws -> [Sender] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Sender
                .order(Sender.Columns.totalEmails.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    public func fetchTopSenders(limit: Int = 20) async throws -> [Sender] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Sender
                .order(Sender.Columns.totalEmails.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func fetchByCategory(_ category: EmailCategory) async throws -> [Sender] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Sender
                .filter(Sender.Columns.category == category)
                .order(Sender.Columns.totalEmails.desc)
                .fetchAll(db)
        }
    }

    public func fetchNeverOpened(minEmails: Int = 5) async throws -> [Sender] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Sender
                .filter(Sender.Columns.openedCount == 0)
                .filter(Sender.Columns.totalEmails >= minEmails)
                .order(Sender.Columns.totalEmails.desc)
                .fetchAll(db)
        }
    }

    public func fetchLowEngagement(maxOpenRate: Double = 0.1, minEmails: Int = 10) async throws -> [Sender] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM senders
                WHERE totalEmails >= ?
                AND CAST(openedCount AS REAL) / CAST(totalEmails AS REAL) < ?
                ORDER BY totalEmails DESC
            """, arguments: [minEmails, maxOpenRate])

            return rows.compactMap { row -> Sender? in
                try? Sender(row: row)
            }
        }
    }

    // MARK: - Delete

    public func delete(domain: String) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try Sender.deleteOne(db, key: domain)
        }
    }

    // MARK: - Stats Updates

    public func incrementEmailCount(domain: String) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            let now = Date()
            if var sender = try Sender.fetchOne(db, key: domain) {
                sender.totalEmails += 1
                sender.lastEmailAt = now
                sender.updatedAt = now
                try sender.update(db)
            } else {
                let newSender = Sender(
                    domain: domain,
                    totalEmails: 1,
                    lastEmailAt: now
                )
                try newSender.insert(db)
            }
        }
    }

    public func recordOpen(domain: String) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE senders SET openedCount = openedCount + 1, updatedAt = ? WHERE domain = ?",
                arguments: [Date(), domain]
            )
        }
    }

    public func recordReply(domain: String) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE senders SET repliedCount = repliedCount + 1, updatedAt = ? WHERE domain = ?",
                arguments: [Date(), domain]
            )
        }
    }

    public func recordArchiveWithoutReading(domain: String) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE senders SET archivedWithoutReadingCount = archivedWithoutReadingCount + 1, updatedAt = ? WHERE domain = ?",
                arguments: [Date(), domain]
            )
        }
    }

    public func setUserAction(domain: String, action: UserAction) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE senders SET userAction = ?, updatedAt = ? WHERE domain = ?",
                arguments: [action.rawValue, Date(), domain]
            )
        }
    }

    public func setCategory(domain: String, category: EmailCategory) async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE senders SET category = ?, updatedAt = ? WHERE domain = ?",
                arguments: [category.rawValue, Date(), domain]
            )
        }
    }

    // MARK: - Counts

    public func count() async throws -> Int {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            try Sender.fetchCount(db)
        }
    }

    // MARK: - Bulk Stats Building

    /// Rebuilds sender stats from actual email counts in the database
    /// This is the correct way - count from the source of truth (emails table)
    public func rebuildAllStats() async throws {
        let writer = try await dbManager.writer
        try await writer.write { db in
            // Get actual counts from emails table grouped by domain
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    fromDomain as domain,
                    COUNT(*) as totalEmails,
                    MAX(date) as lastEmailAt
                FROM emails
                WHERE fromDomain != ''
                GROUP BY fromDomain
            """)

            for row in rows {
                let domain: String = row["domain"]
                let totalEmails: Int = row["totalEmails"]
                let lastEmailAt: Date? = row["lastEmailAt"]

                if var sender = try Sender.fetchOne(db, key: domain) {
                    // Update existing - only update counts, preserve user stats (opened, replied, etc)
                    sender.totalEmails = totalEmails
                    if let lastDate = lastEmailAt {
                        sender.lastEmailAt = lastDate
                    }
                    sender.updatedAt = Date()
                    try sender.update(db)
                } else {
                    // Create new sender
                    let newSender = Sender(
                        domain: domain,
                        totalEmails: totalEmails,
                        lastEmailAt: lastEmailAt
                    )
                    try newSender.insert(db)
                }
            }
        }
    }

    /// Updates sender stats for specific domains that were just synced
    /// More efficient than rebuilding all stats
    public func buildStatsFromEmails(_ emails: [Email]) async throws {
        // Get unique domains from this batch
        let domains = Set(emails.compactMap { $0.fromDomain.isEmpty ? nil : $0.fromDomain })
        guard !domains.isEmpty else { return }

        let writer = try await dbManager.writer
        try await writer.write { db in
            for domain in domains {
                // Count actual emails in database for this domain
                let row = try Row.fetchOne(db, sql: """
                    SELECT
                        COUNT(*) as totalEmails,
                        MAX(date) as lastEmailAt
                    FROM emails
                    WHERE fromDomain = ?
                """, arguments: [domain])

                guard let row else { continue }

                let totalEmails: Int = row["totalEmails"]
                let lastEmailAt: Date? = row["lastEmailAt"]

                if var sender = try Sender.fetchOne(db, key: domain) {
                    // Update existing - only update counts, preserve user stats
                    sender.totalEmails = totalEmails
                    if let lastDate = lastEmailAt {
                        sender.lastEmailAt = lastDate
                    }
                    sender.updatedAt = Date()
                    try sender.update(db)
                } else {
                    // Create new sender
                    let newSender = Sender(
                        domain: domain,
                        totalEmails: totalEmails,
                        lastEmailAt: lastEmailAt
                    )
                    try newSender.insert(db)
                }
            }
        }
    }

    /// Fetches senders that the user might want to bulk archive
    public func fetchBulkArchiveSuggestions(limit: Int = 10) async throws -> [Sender] {
        let reader = try await dbManager.reader
        return try await reader.read { db in
            // Senders with many emails but very low open rate
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM senders
                WHERE totalEmails >= 5
                AND openedCount <= totalEmails * 0.1
                AND (userAction IS NULL OR userAction != 'keep')
                ORDER BY totalEmails DESC
                LIMIT ?
            """, arguments: [limit])

            return rows.compactMap { row -> Sender? in
                try? Sender(row: row)
            }
        }
    }
}

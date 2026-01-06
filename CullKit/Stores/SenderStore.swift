//
//  SenderStore.swift
//  CullKit
//
//  Unified reactive store for senders - replaces SenderRepository
//  Uses GRDB ValueObservation for automatic UI updates
//

import Foundation
import GRDB
import Combine
import os

@MainActor
public final class SenderStore: ObservableObject {
    public static let shared = SenderStore()

    private let logger = Logger(subsystem: "com.cull.mail", category: "senderStore")
    private var sendersObserver: AnyDatabaseCancellable?

    // MARK: - Observed State

    /// All senders sorted by email count - auto-updated when DB changes
    @Published public private(set) var senders: [Sender] = []

    /// Total sender count
    @Published public private(set) var totalCount: Int = 0

    /// Error state for observer failures (nil = no error)
    @Published public private(set) var observerError: String?

    /// Track retry attempts for exponential backoff
    private var retryCount = 0
    private let maxRetries = 3

    private init() {}

    // MARK: - Lifecycle

    public func start() throws {
        guard sendersObserver == nil else { return }

        observerError = nil
        retryCount = 0

        let pool = try DatabaseManager.shared.databasePool

        // Observe senders ordered by total emails
        let observation = ValueObservation.tracking { db in
            try Sender
                .order(Sender.Columns.totalEmails.desc)
                .limit(500)
                .fetchAll(db)
        }

        sendersObserver = observation.start(
            in: pool,
            onError: { [weak self] error in
                self?.handleObserverError(error)
            },
            onChange: { [weak self] senders in
                Task { @MainActor in
                    self?.senders = senders
                    self?.totalCount = senders.count
                    self?.observerError = nil  // Clear error on successful update
                    self?.retryCount = 0
                }
            }
        )

        logger.info("SenderStore started")
    }

    /// Handle observer errors with logging and retry logic
    private func handleObserverError(_ error: Error) {
        logger.error("Sender observation error: \(error.localizedDescription)")

        Task { @MainActor in
            self.observerError = "Database error: \(error.localizedDescription)"

            // Attempt automatic recovery if under max retries
            if self.retryCount < self.maxRetries {
                self.retryCount += 1
                let delay = pow(2.0, Double(self.retryCount)) // Exponential backoff: 2, 4, 8 seconds
                self.logger.info("Attempting sender observer recovery (attempt \(self.retryCount)/\(self.maxRetries)) in \(delay)s")

                try? await Task.sleep(for: .seconds(delay))
                self.restart()
            } else {
                self.logger.error("Sender observer recovery failed after \(self.maxRetries) attempts")
            }
        }
    }

    /// Restart observers - useful for error recovery
    public func restart() {
        stop()
        do {
            try start()
            logger.info("SenderStore restarted successfully")
        } catch {
            logger.error("Failed to restart SenderStore: \(error.localizedDescription)")
            observerError = "Failed to restart: \(error.localizedDescription)"
        }
    }

    public func stop() {
        sendersObserver?.cancel()
        sendersObserver = nil
    }

    // MARK: - Write Operations

    public func save(_ sender: Sender) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try sender.save(db)
        }
    }

    public func setUserAction(domain: String, action: UserAction) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try db.execute(
                sql: "UPDATE senders SET userAction = ?, updatedAt = ? WHERE domain = ?",
                arguments: [action.rawValue, Date(), domain]
            )
        }
    }

    public func setCategory(domain: String, category: EmailCategory) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try db.execute(
                sql: "UPDATE senders SET category = ?, updatedAt = ? WHERE domain = ?",
                arguments: [category.rawValue, Date(), domain]
            )
        }
    }

    public func delete(domain: String) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try Sender.deleteOne(db, key: domain)
        }
    }

    // MARK: - Stats Rebuilding

    /// Rebuilds sender stats from actual INBOX email counts in database
    /// Only counts emails that are in INBOX (not archived)
    public func rebuildStats() async throws {
        try await DatabaseManager.shared.writer.write { db in
            // Count only INBOX emails per domain
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    fromDomain as domain,
                    COUNT(*) as totalEmails,
                    MAX(date) as lastEmailAt
                FROM emails
                WHERE fromDomain != ''
                AND labelIds LIKE '%INBOX%'
                GROUP BY fromDomain
            """)

            // First, update/insert senders with INBOX emails
            var domainsWithInbox = Set<String>()
            for row in rows {
                let domain: String = row["domain"]
                let totalEmails: Int = row["totalEmails"]
                let lastEmailAt: Date? = row["lastEmailAt"]
                domainsWithInbox.insert(domain)

                if var sender = try Sender.fetchOne(db, key: domain) {
                    sender.totalEmails = totalEmails
                    if let lastDate = lastEmailAt {
                        sender.lastEmailAt = lastDate
                    }
                    sender.updatedAt = Date()
                    try sender.update(db)
                } else {
                    let newSender = Sender(
                        domain: domain,
                        totalEmails: totalEmails,
                        lastEmailAt: lastEmailAt
                    )
                    try newSender.insert(db)
                }
            }

            // Set totalEmails to 0 for senders with no INBOX emails
            // (or delete them - for now we'll set to 0 so they disappear from sorted lists)
            let existingSenders = try Sender.fetchAll(db)
            for sender in existingSenders {
                if !domainsWithInbox.contains(sender.domain) {
                    var updated = sender
                    updated.totalEmails = 0
                    updated.updatedAt = Date()
                    try updated.update(db)
                }
            }
        }
        logger.info("Sender stats rebuilt (INBOX only)")
    }

    /// Updates stats for specific domains (more efficient than full rebuild)
    /// Only counts INBOX emails
    public func updateStats(for emails: [Email]) async throws {
        let domains = Set(emails.compactMap { $0.fromDomain.isEmpty ? nil : $0.fromDomain })
        guard !domains.isEmpty else { return }

        try await DatabaseManager.shared.writer.write { db in
            for domain in domains {
                // Count only INBOX emails for this domain
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) as totalEmails, MAX(date) as lastEmailAt
                    FROM emails
                    WHERE fromDomain = ?
                    AND labelIds LIKE '%INBOX%'
                """, arguments: [domain])

                guard let row else { continue }

                let totalEmails: Int = row["totalEmails"]
                let lastEmailAt: Date? = row["lastEmailAt"]

                if var sender = try Sender.fetchOne(db, key: domain) {
                    sender.totalEmails = totalEmails
                    if let lastDate = lastEmailAt {
                        sender.lastEmailAt = lastDate
                    }
                    sender.updatedAt = Date()
                    try sender.update(db)
                } else if totalEmails > 0 {
                    // Only create new sender if there are INBOX emails
                    let newSender = Sender(
                        domain: domain,
                        totalEmails: totalEmails,
                        lastEmailAt: lastEmailAt
                    )
                    try newSender.insert(db)
                }
            }
        }
        logger.info("Updated stats for \(domains.count) domains (INBOX only)")
    }

    // MARK: - One-off Fetches

    public func fetch(domain: String) async throws -> Sender? {
        try await DatabaseManager.shared.reader.read { db in
            try Sender.fetchOne(db, key: domain)
        }
    }

    public func fetchLowEngagement(maxOpenRate: Double = 0.1, minEmails: Int = 10) async throws -> [Sender] {
        try await DatabaseManager.shared.reader.read { db in
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
}

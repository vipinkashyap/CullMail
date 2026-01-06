//
//  EmailStore.swift
//  CullKit
//
//  Unified reactive store for emails - replaces EmailRepository
//  Uses GRDB ValueObservation for automatic UI updates
//

import Foundation
import GRDB
import Combine
import os

@MainActor
public final class EmailStore: ObservableObject {
    public static let shared = EmailStore()

    private let logger = Logger(subsystem: "com.cull.mail", category: "emailStore")
    private var emailsObserver: AnyDatabaseCancellable?
    private var countObserver: AnyDatabaseCancellable?
    private var unreadObserver: AnyDatabaseCancellable?
    private var domainObserver: AnyDatabaseCancellable?

    // MARK: - Observed State

    /// Recent emails (latest 10000) - auto-updated when DB changes
    @Published public private(set) var emails: [Email] = []

    /// Total email count in database
    @Published public private(set) var totalCount: Int = 0

    /// Unread email count
    @Published public private(set) var unreadCount: Int = 0

    /// Emails for currently selected domain/filter
    @Published public private(set) var domainEmails: [Email] = []

    /// Currently active domain filter
    @Published public private(set) var activeDomain: String?

    /// Error state for observer failures (nil = no error)
    @Published public private(set) var observerError: String?

    /// Track retry attempts for exponential backoff
    private var retryCount = 0
    private let maxRetries = 3

    // MARK: - Computed

    public var unreadEmails: [Email] { emails.filter { !$0.isRead } }
    public var readEmails: [Email] { emails.filter { $0.isRead } }

    /// Group emails into threads (conversations)
    public var threads: [EmailThread] {
        let grouped = Dictionary(grouping: emails) { $0.threadId }
        return grouped.compactMap { threadId, messages -> EmailThread? in
            let sorted = messages.sorted { $0.date > $1.date }
            guard let latestMessage = sorted.first else { return nil }
            return EmailThread(
                threadId: threadId,
                messages: sorted,
                latestMessage: latestMessage,
                hasUnread: sorted.contains { !$0.isRead }
            )
        }
        .sorted { $0.latestMessage.date > $1.latestMessage.date }
    }

    /// Unread threads (threads with at least one unread message)
    public var unreadThreads: [EmailThread] {
        threads.filter { $0.hasUnread }
    }

    /// Read threads (all messages in thread are read)
    public var readThreads: [EmailThread] {
        threads.filter { !$0.hasUnread }
    }

    /// Threads for currently selected domain
    public var domainThreads: [EmailThread] {
        let grouped = Dictionary(grouping: domainEmails) { $0.threadId }
        return grouped.compactMap { threadId, messages -> EmailThread? in
            let sorted = messages.sorted { $0.date > $1.date }
            guard let latestMessage = sorted.first else { return nil }
            return EmailThread(
                threadId: threadId,
                messages: sorted,
                latestMessage: latestMessage,
                hasUnread: sorted.contains { !$0.isRead }
            )
        }
        .sorted { $0.latestMessage.date > $1.latestMessage.date }
    }

    private init() {}

    // MARK: - Lifecycle

    public func start() throws {
        guard emailsObserver == nil else { return }

        observerError = nil
        retryCount = 0

        let pool = try DatabaseManager.shared.databasePool

        // Observe recent emails (increased limit for AI features)
        let emailsObservation = ValueObservation.tracking { db in
            try Email.order(Email.Columns.date.desc).limit(10000).fetchAll(db)
        }
        emailsObserver = emailsObservation.start(
            in: pool,
            onError: { [weak self] error in
                self?.handleObserverError(error, observerName: "emails")
            },
            onChange: { [weak self] emails in
                Task { @MainActor in
                    self?.emails = emails
                    self?.observerError = nil  // Clear error on successful update
                    self?.retryCount = 0
                }
            }
        )

        // Observe total count
        let countObservation = ValueObservation.tracking { db in
            try Email.fetchCount(db)
        }
        countObserver = countObservation.start(
            in: pool,
            onError: { [weak self] error in
                self?.handleObserverError(error, observerName: "count")
            },
            onChange: { [weak self] count in
                Task { @MainActor in
                    self?.totalCount = count
                }
            }
        )

        // Observe unread count
        let unreadObservation = ValueObservation.tracking { db in
            try Email.filter(Email.Columns.isRead == false).fetchCount(db)
        }
        unreadObserver = unreadObservation.start(
            in: pool,
            onError: { [weak self] error in
                self?.handleObserverError(error, observerName: "unread")
            },
            onChange: { [weak self] count in
                Task { @MainActor in
                    self?.unreadCount = count
                }
            }
        )

        logger.info("EmailStore started")
    }

    /// Handle observer errors with logging and retry logic
    private func handleObserverError(_ error: Error, observerName: String) {
        logger.error("\(observerName) observation error: \(error.localizedDescription)")

        Task { @MainActor in
            self.observerError = "Database error: \(error.localizedDescription)"

            // Attempt automatic recovery if under max retries
            if self.retryCount < self.maxRetries {
                self.retryCount += 1
                let delay = pow(2.0, Double(self.retryCount)) // Exponential backoff: 2, 4, 8 seconds
                self.logger.info("Attempting observer recovery (attempt \(self.retryCount)/\(self.maxRetries)) in \(delay)s")

                try? await Task.sleep(for: .seconds(delay))
                self.restart()
            } else {
                self.logger.error("Observer recovery failed after \(self.maxRetries) attempts")
            }
        }
    }

    /// Restart all observers - useful for error recovery
    public func restart() {
        stop()
        do {
            try start()
            logger.info("EmailStore restarted successfully")
        } catch {
            logger.error("Failed to restart EmailStore: \(error.localizedDescription)")
            observerError = "Failed to restart: \(error.localizedDescription)"
        }
    }

    public func stop() {
        emailsObserver?.cancel()
        countObserver?.cancel()
        unreadObserver?.cancel()
        domainObserver?.cancel()
        emailsObserver = nil
        countObserver = nil
        unreadObserver = nil
        domainObserver = nil
    }

    // MARK: - Domain Filtering

    public func selectDomain(_ domain: String, includeSubdomains: Bool = false) throws {
        activeDomain = domain
        domainObserver?.cancel()

        let pool = try DatabaseManager.shared.databasePool

        if includeSubdomains {
            let observation = ValueObservation.tracking { db in
                try Email
                    .filter(Email.Columns.fromDomain == domain ||
                           Email.Columns.fromDomain.like("%.\(domain)"))
                    .order(Email.Columns.date.desc)
                    .limit(10000)
                    .fetchAll(db)
            }
            domainObserver = observation.start(
                in: pool,
                onError: { [weak self] (error: Error) in
                    self?.logger.error("Domain observation error: \(error.localizedDescription)")
                },
                onChange: { [weak self] (emails: [Email]) in
                    Task { @MainActor in
                        self?.domainEmails = emails
                    }
                }
            )
        } else {
            let observation = ValueObservation.tracking { db in
                try Email
                    .filter(Email.Columns.fromDomain == domain)
                    .order(Email.Columns.date.desc)
                    .limit(5000)
                    .fetchAll(db)
            }
            domainObserver = observation.start(
                in: pool,
                onError: { [weak self] (error: Error) in
                    self?.logger.error("Domain observation error: \(error.localizedDescription)")
                },
                onChange: { [weak self] (emails: [Email]) in
                    Task { @MainActor in
                        self?.domainEmails = emails
                    }
                }
            )
        }
    }

    public func clearDomain() {
        activeDomain = nil
        domainObserver?.cancel()
        domainObserver = nil
        domainEmails = []
    }

    // MARK: - Write Operations (DB updates → UI auto-refreshes)

    public func save(_ email: Email) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try email.save(db)
        }
    }

    public func saveAll(_ emails: [Email]) async throws {
        try await DatabaseManager.shared.writer.write { db in
            for email in emails {
                try email.save(db)
            }
        }
    }

    public func delete(id: String) async throws {
        try await DatabaseManager.shared.writer.write { db in
            try Email.deleteOne(db, key: id)
        }
    }

    public func archive(ids: [String]) async throws {
        try await DatabaseManager.shared.writer.write { db in
            for id in ids {
                if var email = try Email.fetchOne(db, key: id) {
                    email.labelIds = email.labelIds.filter { $0 != "INBOX" }
                    email.updatedAt = Date()
                    try email.update(db)
                }
            }
        }
    }

    public func markRead(ids: [String], isRead: Bool) async throws {
        try await DatabaseManager.shared.writer.write { db in
            for id in ids {
                if var email = try Email.fetchOne(db, key: id) {
                    email.isRead = isRead
                    if isRead {
                        email.labelIds = email.labelIds.filter { $0 != "UNREAD" }
                    } else if !email.labelIds.contains("UNREAD") {
                        email.labelIds.append("UNREAD")
                    }
                    email.updatedAt = Date()
                    try email.update(db)
                }
            }
        }
    }

    // MARK: - One-off Fetches (when observation isn't needed)

    public func fetch(id: String) async throws -> Email? {
        try await DatabaseManager.shared.reader.read { db in
            try Email.fetchOne(db, key: id)
        }
    }

    public func fetchByDomain(_ domain: String, limit: Int = 5000) async throws -> [Email] {
        try await DatabaseManager.shared.reader.read { db in
            try Email
                .filter(Email.Columns.fromDomain == domain)
                .order(Email.Columns.date.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Fetch emails by root domain, including all subdomains
    /// e.g., "github.com" matches "github.com", "mail.github.com", "notifications.github.com"
    public func fetchByRootDomain(_ rootDomain: String, limit: Int = 10000) async throws -> [Email] {
        try await DatabaseManager.shared.reader.read { db in
            try Email
                .filter(Email.Columns.fromDomain == rootDomain ||
                       Email.Columns.fromDomain.like("%.\(rootDomain)"))
                .order(Email.Columns.date.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func count() async throws -> Int {
        try await DatabaseManager.shared.reader.read { db in
            try Email.fetchCount(db)
        }
    }
}

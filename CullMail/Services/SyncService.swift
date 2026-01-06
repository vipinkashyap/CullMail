//
//  SyncService.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
import os
import CullKit

/// Orchestrates email synchronization with Gmail
/// Uses incremental sync via historyId when possible, falls back to full sync when needed
public actor SyncService {
    public static let shared = SyncService()

    private let logger = Logger(subsystem: "com.cull.mail", category: "sync")
    private let gmail = GmailService.shared
    private let emailRepo = EmailRepository()
    private let senderRepo = SenderRepository()

    @MainActor
    private var attachmentSync: AttachmentSyncService { AttachmentSyncService.shared }

    public enum SyncResult {
        case success(added: Int, updated: Int, deleted: Int)
        case fullSync(count: Int)
        case noChanges
        case error(Error)
    }

    public enum SyncProgress: Sendable {
        case starting
        case resuming(fetched: Int)
        case fetchingHistory
        case fetchingMessages(current: Int, total: Int)
        case processingChanges(count: Int)
        case saving
        case complete(added: Int, updated: Int, deleted: Int)
        case fullSyncComplete(count: Int)
        case noChanges
        case error(String)
    }

    private init() {}

    // MARK: - Public API

    /// Performs an intelligent sync - incremental if possible, full if needed
    public func sync(progressHandler: ((SyncProgress) -> Void)? = nil) async throws -> SyncResult {
        progressHandler?(.starting)

        // Check if we have a saved historyId
        let savedHistoryId = try await getSavedHistoryId()

        if let historyId = savedHistoryId {
            // Try incremental sync
            do {
                return try await incrementalSync(from: historyId, progressHandler: progressHandler)
            } catch {
                // History ID might be too old or invalid
                logger.warning("Incremental sync failed, falling back to full sync: \(error.localizedDescription)")
                return try await fullSync(progressHandler: progressHandler)
            }
        } else {
            // First time sync
            return try await fullSync(progressHandler: progressHandler)
        }
    }

    /// Forces a full sync, ignoring any saved historyId
    public func forceFullSync(progressHandler: ((SyncProgress) -> Void)? = nil) async throws -> SyncResult {
        try await fullSync(progressHandler: progressHandler)
    }

    // MARK: - Incremental Sync

    private func incrementalSync(
        from historyId: String,
        progressHandler: ((SyncProgress) -> Void)?
    ) async throws -> SyncResult {
        progressHandler?(.fetchingHistory)
        logger.info("Starting incremental sync from historyId: \(historyId)")

        // Fetch history changes
        let history = try await gmail.listHistory(startHistoryId: historyId)

        // If no history records, no changes
        guard let records = history.history, !records.isEmpty else {
            // Update historyId even if no changes
            try await saveHistoryId(history.historyId)
            progressHandler?(.noChanges)
            return .noChanges
        }

        progressHandler?(.processingChanges(count: records.count))

        var addedIds: Set<String> = []
        var deletedIds: Set<String> = []
        var modifiedIds: Set<String> = []

        // Process all history records
        for record in records {
            // Messages added
            if let added = record.messagesAdded {
                for msg in added {
                    addedIds.insert(msg.message.id)
                }
            }

            // Messages deleted
            if let deleted = record.messagesDeleted {
                for msg in deleted {
                    deletedIds.insert(msg.message.id)
                }
            }

            // Labels changed (marks as modified)
            if let labelsAdded = record.labelsAdded {
                for change in labelsAdded {
                    modifiedIds.insert(change.message.id)
                }
            }
            if let labelsRemoved = record.labelsRemoved {
                for change in labelsRemoved {
                    modifiedIds.insert(change.message.id)
                }
            }
        }

        // Remove deleted from added (if added then deleted)
        addedIds.subtract(deletedIds)
        modifiedIds.subtract(deletedIds)
        modifiedIds.subtract(addedIds) // Will be fetched as new

        // Fetch new and modified messages
        let idsToFetch = Array(addedIds.union(modifiedIds))
        var fetchedEmails: [Email] = []

        if !idsToFetch.isEmpty {
            // Fetch in batches - use .full format to get attachment info
            let batchSize = 25
            for batchStart in stride(from: 0, to: idsToFetch.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, idsToFetch.count)
                let batchIds = Array(idsToFetch[batchStart..<batchEnd])

                progressHandler?(.fetchingMessages(current: batchStart + batchIds.count, total: idsToFetch.count))

                let messages = try await gmail.batchGetMessages(ids: batchIds, format: .full)
                for message in messages {
                    let email = await message.toEmail()
                    if let email {
                        fetchedEmails.append(email)

                        // Extract and save attachment metadata for emails with attachments
                        if email.hasAttachments {
                            let attachmentInfos = message.extractAttachments()
                            if !attachmentInfos.isEmpty {
                                try await attachmentSync.processMessageAttachments(
                                    messageId: message.id,
                                    attachmentInfos: attachmentInfos
                                )
                            }
                        }
                    }
                }
            }
        }

        // Save to database
        progressHandler?(.saving)

        // Delete removed emails
        for id in deletedIds {
            try await emailRepo.delete(id: id)
        }

        // Save new/updated emails and update sender stats
        if !fetchedEmails.isEmpty {
            try await emailRepo.saveAll(fetchedEmails)
            try await senderRepo.buildStatsFromEmails(fetchedEmails)
        }

        // If emails were deleted, rebuild all sender stats to ensure consistency
        if !deletedIds.isEmpty {
            try await senderRepo.rebuildAllStats()
        }

        // Update historyId
        try await saveHistoryId(history.historyId)

        let result = SyncResult.success(
            added: addedIds.count,
            updated: modifiedIds.count,
            deleted: deletedIds.count
        )

        logger.info("Incremental sync complete: +\(addedIds.count) ~\(modifiedIds.count) -\(deletedIds.count)")
        progressHandler?(.complete(added: addedIds.count, updated: modifiedIds.count, deleted: deletedIds.count))

        return result
    }

    // MARK: - Full Sync (Resumable)

    private func fullSync(progressHandler: ((SyncProgress) -> Void)?) async throws -> SyncResult {
        // Check if there's an in-progress sync to resume
        let resumeState = try await getResumableState()

        var pageToken: String? = resumeState?.pageToken
        var emailsFetched = resumeState?.emailsFetched ?? 0
        let maxEmails = 10000  // Increased limit for background sync

        if resumeState != nil {
            logger.info("Resuming sync from \(emailsFetched) emails fetched")
            progressHandler?(.resuming(fetched: emailsFetched))
        } else {
            logger.info("Starting fresh full sync")
            try await markSyncInProgress(true)
        }

        var emailsThisSession: [Email] = []
        var pagesThisSession = 0
        let maxPagesPerSession = 50  // Process 50 pages per session to avoid timeout

        repeat {
            pagesThisSession += 1

            // Fetch ALL messages, not just INBOX - this enables proper categorization and domain grouping
            let response = try await gmail.listMessages(
                maxResults: 50,
                pageToken: pageToken,
                labelIds: nil  // nil = all mail
            )

            guard let messageRefs = response.messages, !messageRefs.isEmpty else {
                break
            }

            // Fetch in batches of 25 - use .full format to get attachment info
            let batchSize = 25
            for batchStart in stride(from: 0, to: messageRefs.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, messageRefs.count)
                let batchIds = messageRefs[batchStart..<batchEnd].map(\.id)

                progressHandler?(.fetchingMessages(current: emailsFetched + emailsThisSession.count + batchIds.count, total: maxEmails))

                let messages = try await gmail.batchGetMessages(ids: Array(batchIds), format: .full)
                for message in messages {
                    let email = await message.toEmail()
                    if let email {
                        emailsThisSession.append(email)

                        // Extract and save attachment metadata for emails with attachments
                        if email.hasAttachments {
                            let attachmentInfos = message.extractAttachments()
                            if !attachmentInfos.isEmpty {
                                try await attachmentSync.processMessageAttachments(
                                    messageId: message.id,
                                    attachmentInfos: attachmentInfos
                                )
                            }
                        }
                    }
                }
            }

            pageToken = response.nextPageToken
            emailsFetched += messageRefs.count

            // Save progress after each page so we can resume
            try await saveResumableState(pageToken: pageToken, emailsFetched: emailsFetched)

            // Save emails incrementally (every 5 pages) to avoid losing progress
            if pagesThisSession % 5 == 0 && !emailsThisSession.isEmpty {
                progressHandler?(.saving)
                try await emailRepo.saveAll(emailsThisSession)
                try await senderRepo.buildStatsFromEmails(emailsThisSession)
                emailsThisSession = []
            }

        } while pageToken != nil && pagesThisSession < maxPagesPerSession && emailsFetched < maxEmails

        // Save remaining emails
        if !emailsThisSession.isEmpty {
            progressHandler?(.saving)
            try await emailRepo.saveAll(emailsThisSession)
            try await senderRepo.buildStatsFromEmails(emailsThisSession)
        }

        // Check if sync is complete (no more pages)
        if pageToken == nil {
            // Sync complete!
            try await clearResumableState()

            // Get and save the current historyId
            let profile = try await gmail.getProfile()
            try await saveHistoryId(profile.historyId)
            try await saveLastSync()

            let result = SyncResult.fullSync(count: emailsFetched)
            logger.info("Full sync complete: \(emailsFetched) emails total")
            progressHandler?(.fullSyncComplete(count: emailsFetched))
            return result
        } else {
            // Sync paused - will continue next session
            logger.info("Sync paused at \(emailsFetched) emails, will continue next session")
            let result = SyncResult.fullSync(count: emailsFetched)
            progressHandler?(.fullSyncComplete(count: emailsFetched))
            return result
        }
    }

    // MARK: - Resumable State Management

    private struct ResumableState {
        let pageToken: String?
        let emailsFetched: Int
    }

    private func getResumableState() async throws -> ResumableState? {
        let reader = try await DatabaseManager.shared.reader
        let inProgress = try await reader.read { db in
            try SyncState
                .filter(SyncState.Columns.key == SyncState.syncInProgressKey)
                .fetchOne(db)?
                .value
        }

        guard inProgress == "true" else { return nil }

        let pageToken = try await reader.read { db in
            try SyncState
                .filter(SyncState.Columns.key == SyncState.syncPageTokenKey)
                .fetchOne(db)?
                .value
        }

        let emailsFetchedStr = try await reader.read { db in
            try SyncState
                .filter(SyncState.Columns.key == SyncState.syncEmailsFetchedKey)
                .fetchOne(db)?
                .value
        }

        let emailsFetched = emailsFetchedStr.flatMap { Int($0) } ?? 0

        return ResumableState(pageToken: pageToken, emailsFetched: emailsFetched)
    }

    private func saveResumableState(pageToken: String?, emailsFetched: Int) async throws {
        let writer = try await DatabaseManager.shared.writer
        try await writer.write { db in
            if let token = pageToken {
                try SyncState(key: SyncState.syncPageTokenKey, value: token).save(db)
            }
            try SyncState(key: SyncState.syncEmailsFetchedKey, value: String(emailsFetched)).save(db)
        }
    }

    private func markSyncInProgress(_ inProgress: Bool) async throws {
        let writer = try await DatabaseManager.shared.writer
        try await writer.write { db in
            try SyncState(key: SyncState.syncInProgressKey, value: inProgress ? "true" : "false").save(db)
        }
    }

    private func clearResumableState() async throws {
        let writer = try await DatabaseManager.shared.writer
        try await writer.write { db in
            try SyncState.filter(SyncState.Columns.key == SyncState.syncInProgressKey).deleteAll(db)
            try SyncState.filter(SyncState.Columns.key == SyncState.syncPageTokenKey).deleteAll(db)
            try SyncState.filter(SyncState.Columns.key == SyncState.syncEmailsFetchedKey).deleteAll(db)
        }
    }

    /// Check if there's an incomplete sync that should be resumed
    public func hasIncompleteSyncToResume() async throws -> Bool {
        let state = try await getResumableState()
        return state != nil
    }

    // MARK: - State Management

    private func getSavedHistoryId() async throws -> String? {
        let reader = try await DatabaseManager.shared.reader
        return try await reader.read { db in
            try SyncState
                .filter(SyncState.Columns.key == SyncState.historyIdKey)
                .fetchOne(db)?
                .value
        }
    }

    private func saveHistoryId(_ historyId: String) async throws {
        let state = SyncState(key: SyncState.historyIdKey, value: historyId)
        let writer = try await DatabaseManager.shared.writer
        try await writer.write { db in
            try state.save(db)
        }
    }

    private func saveLastSync() async throws {
        let state = SyncState(
            key: SyncState.lastSyncKey,
            value: ISO8601DateFormatter().string(from: Date())
        )
        let writer = try await DatabaseManager.shared.writer
        try await writer.write { db in
            try state.save(db)
        }
    }

    public func getLastSyncTime() async throws -> Date? {
        let reader = try await DatabaseManager.shared.reader
        guard let value = try await reader.read({ db in
            try SyncState
                .filter(SyncState.Columns.key == SyncState.lastSyncKey)
                .fetchOne(db)?
                .value
        }) else {
            return nil
        }
        return ISO8601DateFormatter().date(from: value)
    }

    /// Clears sync state, forcing next sync to be a full sync
    public func clearSyncState() async throws {
        let writer = try await DatabaseManager.shared.writer
        try await writer.write { db in
            try SyncState.deleteAll(db)
        }
        logger.info("Sync state cleared")
    }
}

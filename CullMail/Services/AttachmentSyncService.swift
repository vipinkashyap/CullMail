//
//  AttachmentSyncService.swift
//  CullMail
//
//  Coordinates attachment syncing: extracts metadata from emails,
//  downloads attachment data, extracts text for searchability.
//

import Foundation
import CullKit
import os

/// Service that syncs attachments from Gmail to local database
/// Works in conjunction with SyncService for email sync
/// Note: This is MainActor isolated because it works closely with AttachmentStore
@MainActor
public final class AttachmentSyncService {
    public static let shared = AttachmentSyncService()

    private let logger = Logger(subsystem: "com.cull.mail", category: "attachmentSync")
    private let gmail = GmailService.shared
    private var attachmentStore: AttachmentStore { AttachmentStore.shared }

    // Configuration
    private let maxConcurrentDownloads = 5
    private let downloadTimeoutSeconds: TimeInterval = 60

    private init() {}

    // MARK: - Public API

    /// Extract and save attachment metadata from Gmail messages
    /// Call this during email sync for messages that have attachments
    public func processMessageAttachments(
        messageId: String,
        attachmentInfos: [AttachmentInfo]
    ) async throws {
        guard !attachmentInfos.isEmpty else { return }

        logger.debug("Processing \(attachmentInfos.count) attachments for message \(messageId)")

        var attachments: [Attachment] = []

        for info in attachmentInfos {
            // Create unique ID combining message ID and attachment ID
            let attachmentId = "\(messageId)_\(info.attachmentId)"

            let category = AttachmentCategory.detect(
                filename: info.filename,
                mimeType: info.mimeType
            )

            let attachment = Attachment(
                id: attachmentId,
                emailId: messageId,
                filename: info.filename,
                mimeType: info.mimeType,
                sizeBytes: info.size,
                category: category
            )

            attachments.append(attachment)
        }

        try await attachmentStore.saveAll(attachments)
        logger.info("Saved \(attachments.count) attachment records for message \(messageId)")
    }

    /// Download attachment data and optionally extract text
    /// Call this for attachments that need content (e.g., for search indexing)
    public func downloadAndProcessAttachment(
        attachment: Attachment,
        extractText: Bool = true
    ) async throws -> Data {
        // Extract the original Gmail attachment ID from our composite ID
        let parts = attachment.id.split(separator: "_")
        guard parts.count >= 2 else {
            throw AttachmentSyncError.invalidAttachmentId
        }

        let messageId = String(parts[0])
        let attachmentId = parts.dropFirst().joined(separator: "_")

        logger.debug("Downloading attachment: \(attachment.filename)")

        // Fetch attachment data from Gmail
        let data = try await gmail.getAttachment(
            messageId: messageId,
            attachmentId: attachmentId
        )

        // Extract text if this is a text-extractable document
        if extractText && attachment.isTextExtractable {
            await extractAndSaveText(attachment: attachment, data: data)
        }

        return data
    }

    /// Batch download multiple attachments
    public func batchDownload(
        attachments: [Attachment],
        extractText: Bool = true
    ) async throws -> [String: Data] {
        guard !attachments.isEmpty else { return [:] }

        var results: [String: Data] = [:]
        var errorCount = 0

        // Process in controlled batches
        for chunk in attachments.chunked(into: maxConcurrentDownloads) {
            for attachment in chunk {
                do {
                    let data = try await downloadAndProcessAttachment(
                        attachment: attachment,
                        extractText: extractText
                    )
                    results[attachment.id] = data
                } catch {
                    errorCount += 1
                    logger.error("Failed to download attachment \(attachment.id): \(error.localizedDescription)")
                }
            }
        }

        if errorCount > 0 {
            logger.warning("Batch download completed with \(errorCount) errors out of \(attachments.count)")
        }

        return results
    }

    /// Process pending text extractions
    /// Call this periodically to extract text from downloaded attachments
    public func processPendingTextExtractions(limit: Int = 20) async {
        do {
            let pending = try await attachmentStore.fetchPendingTextExtraction(limit: limit)

            guard !pending.isEmpty else {
                logger.debug("No pending text extractions")
                return
            }

            logger.info("Processing \(pending.count) pending text extractions")

            for attachment in pending {
                do {
                    // We need to download the attachment first
                    let data = try await downloadAndProcessAttachment(
                        attachment: attachment,
                        extractText: true
                    )
                    logger.debug("Processed text extraction for: \(attachment.filename) (\(data.count) bytes)")
                } catch {
                    logger.error("Failed text extraction for \(attachment.filename): \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("Failed to fetch pending text extractions: \(error.localizedDescription)")
        }
    }

    /// Save attachment data to local storage
    public func saveToLocalStorage(
        attachment: Attachment,
        data: Data
    ) async throws -> URL {
        let fileManager = FileManager.default

        // Get app support directory
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        // Create attachments directory structure
        let attachmentsDir = appSupport
            .appendingPathComponent("CullMail", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(attachment.emailId, isDirectory: true)

        try fileManager.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

        // Save file with sanitized filename
        let sanitizedFilename = sanitizeFilename(attachment.filename)
        let fileURL = attachmentsDir.appendingPathComponent(sanitizedFilename)

        try data.write(to: fileURL)

        // Update database with local path
        try await attachmentStore.updateLocalPath(id: attachment.id, localPath: fileURL.path)

        logger.info("Saved attachment to: \(fileURL.path)")
        return fileURL
    }

    // MARK: - Backfill Existing Emails

    /// Backfills attachment records from existing emails that have hasAttachments = true
    /// but no corresponding attachment records in the database.
    /// Call this once to populate attachments for emails synced before attachment extraction was added.
    public func backfillAttachmentsFromExistingEmails(
        progressHandler: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        let emailRepo = EmailRepository()

        // Find emails with attachments that don't have attachment records
        let emailsWithAttachments = try await emailRepo.fetchEmailsWithAttachmentsNeedingBackfill()

        guard !emailsWithAttachments.isEmpty else {
            logger.info("No emails need attachment backfill")
            return 0
        }

        logger.info("Backfilling attachments for \(emailsWithAttachments.count) emails")

        var totalAttachments = 0
        var processed = 0

        // Process in batches to avoid overwhelming Gmail API
        let batchSize = 10
        for batchStart in stride(from: 0, to: emailsWithAttachments.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, emailsWithAttachments.count)
            let batch = Array(emailsWithAttachments[batchStart..<batchEnd])
            let batchIds = batch.map(\.id)

            do {
                // Fetch full messages from Gmail to get attachment info
                let messages = try await gmail.batchGetMessages(ids: batchIds, format: .full)

                for message in messages {
                    let attachmentInfos = message.extractAttachments()
                    if !attachmentInfos.isEmpty {
                        try await processMessageAttachments(
                            messageId: message.id,
                            attachmentInfos: attachmentInfos
                        )
                        totalAttachments += attachmentInfos.count
                    }
                }
            } catch {
                logger.error("Failed to backfill batch: \(error.localizedDescription)")
            }

            processed += batch.count
            progressHandler?(processed, emailsWithAttachments.count)
        }

        logger.info("Backfill complete: \(totalAttachments) attachments from \(processed) emails")
        return totalAttachments
    }

    // MARK: - Private Helpers

    private func extractAndSaveText(attachment: Attachment, data: Data) async {
        guard let text = await attachment.extractText(from: data), !text.isEmpty else {
            logger.debug("No text extracted from: \(attachment.filename)")
            return
        }

        do {
            try await attachmentStore.updateExtractedText(id: attachment.id, text: text)
            logger.debug("Extracted \(text.count) characters from: \(attachment.filename)")
        } catch {
            logger.error("Failed to save extracted text for \(attachment.filename): \(error.localizedDescription)")
        }
    }

    private func sanitizeFilename(_ filename: String) -> String {
        // Remove or replace characters that are problematic for filesystems
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = filename.components(separatedBy: invalidChars).joined(separator: "_")

        // Ensure filename isn't too long (macOS limit is 255 bytes)
        if sanitized.utf8.count > 200 {
            let ext = (sanitized as NSString).pathExtension
            let name = (sanitized as NSString).deletingPathExtension
            let truncatedName = String(name.prefix(150))
            return truncatedName + (ext.isEmpty ? "" : ".\(ext)")
        }

        return sanitized.isEmpty ? "unnamed_attachment" : sanitized
    }
}

// MARK: - Errors

public enum AttachmentSyncError: Error, LocalizedError {
    case invalidAttachmentId
    case downloadFailed(String)
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAttachmentId:
            return "Invalid attachment ID format"
        case .downloadFailed(let reason):
            return "Failed to download attachment: \(reason)"
        case .saveFailed(let reason):
            return "Failed to save attachment: \(reason)"
        }
    }
}

// MARK: - Array Extension (if not already defined)

extension Array where Element == Attachment {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

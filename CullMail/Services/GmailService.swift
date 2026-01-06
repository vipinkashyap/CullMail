//
//  GmailService.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
import os
import CullKit

public actor GmailService {
    public static let shared = GmailService()

    private let logger = Logger(subsystem: "com.cull.mail", category: "gmail")
    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"
    private let authService: AuthService

    // Gmail API Rate Limiting
    // - Per-user: 250 quota units/second (moving average, allows short bursts)
    // - Quota costs: list=5, get=5, modify=5, batchModify=50, labels.get=1, history=2
    //
    // We use a token bucket algorithm to track quota consumption
    private var quotaTokens: Double = 250.0  // Start with full bucket
    private var lastQuotaRefill: Date = Date()
    private let maxQuotaTokens: Double = 250.0  // Max tokens (per second limit)
    private let quotaRefillRate: Double = 250.0  // Tokens refilled per second

    /// Quota costs per operation type (units per call)
    private struct QuotaCost {
        static let list: Double = 5
        static let get: Double = 5
        static let modify: Double = 5
        static let batchModify: Double = 50
        static let label: Double = 1
        static let history: Double = 2
        static let profile: Double = 1
        static let trash: Double = 5
    }

    private init() {
        self.authService = AuthService.shared
    }

    /// Consumes quota tokens, waiting if necessary to stay within rate limits
    private func consumeQuota(_ cost: Double) async {
        // Refill tokens based on elapsed time
        let now = Date()
        let elapsed = now.timeIntervalSince(lastQuotaRefill)
        quotaTokens = min(maxQuotaTokens, quotaTokens + (elapsed * quotaRefillRate))
        lastQuotaRefill = now

        // If we don't have enough tokens, wait
        if quotaTokens < cost {
            let waitTime = (cost - quotaTokens) / quotaRefillRate
            logger.debug("Rate limiting: waiting \(String(format: "%.2f", waitTime))s for \(cost) quota units")
            try? await Task.sleep(for: .seconds(waitTime))
            // After waiting, we should have enough tokens
            quotaTokens = cost
        }

        // Consume the tokens
        quotaTokens -= cost
    }

    // MARK: - Profile

    public func getProfile() async throws -> GmailProfile {
        await consumeQuota(QuotaCost.profile)
        let data = try await request(endpoint: "/profile")
        return try JSONDecoder().decode(GmailProfile.self, from: data)
    }

    /// Get quick mailbox stats: total messages, inbox count, unread count
    /// This is lightweight - just 3 API calls (1 unit each = 3 total)
    public func getMailboxStats() async throws -> MailboxStats {
        // Run sequentially to respect quota (3 units total, safe)
        let profile = try await getProfile()
        let inbox = try await getLabel(id: "INBOX")
        let unread = try await getLabel(id: "UNREAD")

        return MailboxStats(
            emailAddress: profile.emailAddress,
            totalMessages: profile.messagesTotal ?? 0,
            totalThreads: profile.threadsTotal ?? 0,
            inboxMessages: inbox.messagesTotal ?? 0,
            inboxUnread: inbox.messagesUnread ?? 0,
            totalUnread: unread.messagesTotal ?? 0,  // UNREAD label counts all unread
            historyId: profile.historyId
        )
    }

    // MARK: - Messages

    /// List messages with optional filters
    /// - Parameters:
    ///   - maxResults: Max messages to return (1-500, default 100)
    ///   - pageToken: Token for pagination
    ///   - labelIds: Only return messages with ALL these labels
    ///   - query: Gmail search query (same syntax as Gmail search box)
    ///   - includeSpamTrash: Include SPAM and TRASH messages (default false)
    /// - Returns: Response with message refs, nextPageToken, and resultSizeEstimate
    public func listMessages(
        maxResults: Int = 100,
        pageToken: String? = nil,
        labelIds: [String]? = nil,
        query: String? = nil,
        includeSpamTrash: Bool = false
    ) async throws -> MessageListResponse {
        await consumeQuota(QuotaCost.list)

        var queryItems = [URLQueryItem(name: "maxResults", value: String(min(maxResults, 500)))]

        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        if let labelIds, !labelIds.isEmpty {
            for labelId in labelIds {
                queryItems.append(URLQueryItem(name: "labelIds", value: labelId))
            }
        }

        if let query {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }

        if includeSpamTrash {
            queryItems.append(URLQueryItem(name: "includeSpamTrash", value: "true"))
        }

        let data = try await request(endpoint: "/messages", queryItems: queryItems)
        return try JSONDecoder().decode(MessageListResponse.self, from: data)
    }

    public func getMessage(id: String, format: MessageFormat = .metadata) async throws -> GmailMessage {
        await consumeQuota(QuotaCost.get)

        let queryItems = [
            URLQueryItem(name: "format", value: format.rawValue)
        ]

        let data = try await request(endpoint: "/messages/\(id)", queryItems: queryItems)
        return try JSONDecoder().decode(GmailMessage.self, from: data)
    }

    /// Batch get messages with rate limiting
    /// Fetches messages in controlled batches to stay within quota limits
    /// Max 50 parallel requests = 250 quota units (exactly at limit)
    public func batchGetMessages(ids: [String], format: MessageFormat = .metadata) async throws -> [GmailMessage] {
        guard !ids.isEmpty else { return [] }

        var allMessages: [GmailMessage] = []
        let maxConcurrent = 40  // 40 * 5 units = 200 units/batch, leaves headroom

        // Process in chunks to avoid exceeding rate limits
        for chunkStart in stride(from: 0, to: ids.count, by: maxConcurrent) {
            let chunkEnd = min(chunkStart + maxConcurrent, ids.count)
            let chunkIds = Array(ids[chunkStart..<chunkEnd])

            // Fetch this chunk in parallel
            let chunkMessages = try await withThrowingTaskGroup(of: GmailMessage.self) { group in
                for id in chunkIds {
                    group.addTask {
                        try await self.getMessage(id: id, format: format)
                    }
                }

                var messages: [GmailMessage] = []
                for try await message in group {
                    messages.append(message)
                }
                return messages
            }

            allMessages.append(contentsOf: chunkMessages)

            // Small delay between chunks to let tokens refill
            if chunkEnd < ids.count {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        return allMessages
    }

    // MARK: - Search

    /// Search emails using Gmail's search syntax
    /// Examples: "from:github.com", "subject:invoice", "older_than:1y", "has:attachment"
    public func searchMessages(
        query: String,
        maxResults: Int = 50,
        pageToken: String? = nil
    ) async throws -> (emails: [Email], nextPageToken: String?) {
        let response = try await listMessages(
            maxResults: maxResults,
            pageToken: pageToken,
            query: query
        )

        guard let messageRefs = response.messages, !messageRefs.isEmpty else {
            return ([], nil)
        }

        // Fetch full messages in parallel - use .full format to get attachment info
        let messages = try await batchGetMessages(ids: messageRefs.map(\.id), format: .full)
        var emails: [Email] = []
        for message in messages {
            if let email = message.toEmail() {
                emails.append(email)
            }
        }

        return (emails, response.nextPageToken)
    }

    // MARK: - Labels

    /// List all labels (basic info only - no counts)
    public func listLabels() async throws -> [GmailLabel] {
        await consumeQuota(QuotaCost.label)
        let data = try await request(endpoint: "/labels")
        let response = try JSONDecoder().decode(LabelListResponse.self, from: data)
        return response.labels
    }

    /// Get a specific label with message counts
    /// Quota: 1 unit
    public func getLabel(id: String) async throws -> GmailLabel {
        await consumeQuota(QuotaCost.label)
        let data = try await request(endpoint: "/labels/\(id)")
        return try JSONDecoder().decode(GmailLabel.self, from: data)
    }

    /// Get all labels with their full details including counts
    /// Useful for exploring what labels exist and their message counts
    /// Note: Fetches sequentially to respect rate limits (1 unit per label)
    public func getAllLabelsWithCounts() async throws -> [GmailLabel] {
        let basicLabels = try await listLabels()

        // Fetch in batches of 50 to stay within rate limits (50 units/batch)
        var results: [GmailLabel] = []
        let batchSize = 50

        for batchStart in stride(from: 0, to: basicLabels.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, basicLabels.count)
            let batch = Array(basicLabels[batchStart..<batchEnd])

            // Fetch this batch in parallel
            let batchResults = await withTaskGroup(of: GmailLabel?.self, returning: [GmailLabel].self) { group in
                for label in batch {
                    group.addTask {
                        try? await self.getLabel(id: label.id)
                    }
                }

                var labels: [GmailLabel] = []
                for await label in group {
                    if let label = label {
                        labels.append(label)
                    }
                }
                return labels
            }

            results.append(contentsOf: batchResults)

            // Small delay between batches
            if batchEnd < basicLabels.count {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        // Sort by total messages descending
        return results.sorted { ($0.messagesTotal ?? 0) > ($1.messagesTotal ?? 0) }
    }

    // MARK: - Modify Messages

    public func modifyMessage(id: String, addLabelIds: [String] = [], removeLabelIds: [String] = []) async throws {
        await consumeQuota(QuotaCost.modify)

        let body = ModifyRequest(addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        let bodyData = try JSONEncoder().encode(body)

        _ = try await request(
            endpoint: "/messages/\(id)/modify",
            method: "POST",
            body: bodyData
        )
    }

    /// Gmail API allows max 1000 IDs per batchModify call (50 quota units each)
    /// We chunk requests and add delays between chunks to stay within rate limits
    private let batchModifyChunkSize = 1000

    public func batchModify(ids: [String], addLabelIds: [String] = [], removeLabelIds: [String] = []) async throws {
        guard !ids.isEmpty else { return }

        // Chunk IDs into groups of 1000 (Gmail API limit)
        let chunks = ids.chunked(into: batchModifyChunkSize)

        for (index, chunk) in chunks.enumerated() {
            await consumeQuota(QuotaCost.batchModify)  // 50 units per call

            let body = BatchModifyRequest(ids: chunk, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
            let bodyData = try JSONEncoder().encode(body)

            _ = try await request(
                endpoint: "/messages/batchModify",
                method: "POST",
                body: bodyData
            )

            logger.info("Batch modified chunk \(index + 1)/\(chunks.count) (\(chunk.count) messages)")

            // Quota token bucket handles timing, but add small delay between chunks
            if index < chunks.count - 1 {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        logger.info("Batch modified total \(ids.count) messages in \(chunks.count) chunks")
    }

    public func trashMessage(id: String) async throws {
        await consumeQuota(QuotaCost.trash)
        _ = try await request(endpoint: "/messages/\(id)/trash", method: "POST")
    }

    public func archiveMessages(ids: [String]) async throws {
        try await batchModify(ids: ids, removeLabelIds: ["INBOX"])
    }

    public func markAsRead(ids: [String]) async throws {
        try await batchModify(ids: ids, removeLabelIds: ["UNREAD"])
    }

    public func markAsUnread(ids: [String]) async throws {
        try await batchModify(ids: ids, addLabelIds: ["UNREAD"])
    }

    // MARK: - Attachments

    /// Fetch attachment data by message ID and attachment ID
    /// Returns the raw attachment data decoded from base64
    /// Quota: 5 units (same as getMessage)
    public func getAttachment(messageId: String, attachmentId: String) async throws -> Data {
        await consumeQuota(QuotaCost.get)

        let data = try await request(endpoint: "/messages/\(messageId)/attachments/\(attachmentId)")

        struct AttachmentResponse: Codable {
            let size: Int
            let data: String  // base64url encoded
        }

        let response = try JSONDecoder().decode(AttachmentResponse.self, from: data)

        // Decode base64url to Data
        guard let attachmentData = decodeBase64URL(response.data) else {
            throw GmailError.invalidResponse
        }

        return attachmentData
    }

    /// Batch fetch multiple attachments with rate limiting
    /// Returns dictionary mapping attachmentId to Data
    public func batchGetAttachments(
        messageId: String,
        attachmentIds: [String]
    ) async throws -> [String: Data] {
        guard !attachmentIds.isEmpty else { return [:] }

        var results: [String: Data] = [:]
        let maxConcurrent = 20  // Conservative to avoid rate limits

        for chunkStart in stride(from: 0, to: attachmentIds.count, by: maxConcurrent) {
            let chunkEnd = min(chunkStart + maxConcurrent, attachmentIds.count)
            let chunkIds = Array(attachmentIds[chunkStart..<chunkEnd])

            let chunkResults = try await withThrowingTaskGroup(of: (String, Data).self) { group in
                for attachmentId in chunkIds {
                    group.addTask {
                        let data = try await self.getAttachment(messageId: messageId, attachmentId: attachmentId)
                        return (attachmentId, data)
                    }
                }

                var resultDict: [String: Data] = [:]
                for try await (id, data) in group {
                    resultDict[id] = data
                }
                return resultDict
            }

            results.merge(chunkResults) { _, new in new }

            if chunkEnd < attachmentIds.count {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        return results
    }

    /// Decode base64url encoded string to Data
    private func decodeBase64URL(_ encoded: String) -> Data? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        return Data(base64Encoded: base64)
    }

    // MARK: - History

    public func listHistory(startHistoryId: String, historyTypes: [String] = ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"]) async throws -> HistoryResponse {
        await consumeQuota(QuotaCost.history)

        var queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId)
        ]

        for type in historyTypes {
            queryItems.append(URLQueryItem(name: "historyTypes", value: type))
        }

        let data = try await request(endpoint: "/history", queryItems: queryItems)
        return try JSONDecoder().decode(HistoryResponse.self, from: data)
    }

    // MARK: - Private

    @MainActor
    private func getAccessToken() async throws -> String {
        try await authService.getValidAccessToken()
    }

    /// Maximum number of retries for rate-limited requests
    private let maxRetries = 5
    /// Base delay for exponential backoff (seconds)
    private let baseRetryDelay: TimeInterval = 2.0

    private func request(
        endpoint: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        retryCount: Int = 0
    ) async throws -> Data {
        // Note: Quota consumption is handled by individual API methods via consumeQuota()
        // This allows operation-specific rate limiting

        let token = try await getAccessToken()

        guard var components = URLComponents(string: baseURL + endpoint) else {
            logger.error("Invalid URL: \(self.baseURL + endpoint)")
            throw GmailError.invalidResponse
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            logger.error("Failed to construct URL from components: \(components)")
            throw GmailError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401:
            throw GmailError.unauthorized
        case 403:
            throw GmailError.forbidden
        case 404:
            throw GmailError.notFound
        case 429, 500, 503:
            // Rate limited or server error - retry with exponential backoff
            if retryCount < maxRetries {
                let delay = baseRetryDelay * pow(2.0, Double(retryCount))
                let jitter = Double.random(in: 0...1) // Add jitter to prevent thundering herd
                let totalDelay = delay + jitter

                logger.warning("Rate limited (429/5xx) on \(endpoint). Retry \(retryCount + 1)/\(self.maxRetries) after \(String(format: "%.1f", totalDelay))s")

                try await Task.sleep(for: .seconds(totalDelay))

                return try await self.request(
                    endpoint: endpoint,
                    method: method,
                    queryItems: queryItems,
                    body: body,
                    retryCount: retryCount + 1
                )
            } else {
                logger.error("Rate limit retries exhausted for \(endpoint)")
                throw GmailError.rateLimited
            }
        default:
            logger.error("Gmail API error \(httpResponse.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
            throw GmailError.apiError(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }
    }
}

// MARK: - Request/Response Types

public enum MessageFormat: String {
    case minimal
    case metadata
    case full
    case raw
}

public struct GmailProfile: Codable, Sendable {
    public let emailAddress: String
    public let messagesTotal: Int?
    public let threadsTotal: Int?
    public let historyId: String
}

/// Quick summary of mailbox stats from Gmail API
public struct MailboxStats: Sendable {
    public let emailAddress: String
    public let totalMessages: Int      // All messages in mailbox
    public let totalThreads: Int       // All threads in mailbox
    public let inboxMessages: Int      // Messages in INBOX
    public let inboxUnread: Int        // Unread in INBOX
    public let totalUnread: Int        // All unread messages (any label)
    public let historyId: String       // For incremental sync
}

public struct MessageListResponse: Codable, Sendable {
    public let messages: [MessageRef]?
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?

    public struct MessageRef: Codable, Sendable {
        public let id: String
        public let threadId: String
    }
}

public struct GmailMessage: Codable, Sendable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String?
    public let historyId: String?
    public let internalDate: String?
    public let payload: Payload?
    public let sizeEstimate: Int?

    public struct Payload: Codable, Sendable {
        public let headers: [Header]?
        public let mimeType: String?
        public let body: Body?
        public let parts: [Part]?
    }

    public struct Header: Codable, Sendable {
        public let name: String
        public let value: String
    }

    public struct Body: Codable, Sendable {
        public let size: Int
        public let data: String?
        public let attachmentId: String?
    }

    public struct Part: Codable, Sendable {
        public let partId: String?
        public let mimeType: String?
        public let filename: String?
        public let headers: [Header]?
        public let body: Body?
        public let parts: [Part]?
    }
}

public struct GmailLabel: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let type: String?                    // "system" or "user"
    public let messageListVisibility: String?   // "show" or "hide"
    public let labelListVisibility: String?     // "labelShow", "labelShowIfUnread", "labelHide"
    public let messagesTotal: Int?              // Total messages with this label
    public let messagesUnread: Int?             // Unread messages with this label
    public let threadsTotal: Int?               // Total threads with this label
    public let threadsUnread: Int?              // Unread threads with this label
    public let color: LabelColor?               // Only for user labels

    public struct LabelColor: Codable, Sendable {
        public let textColor: String?
        public let backgroundColor: String?
    }
}

public struct LabelListResponse: Codable, Sendable {
    public let labels: [GmailLabel]
}

public struct ModifyRequest: Codable, Sendable {
    public let addLabelIds: [String]
    public let removeLabelIds: [String]
}

public struct BatchModifyRequest: Codable, Sendable {
    public let ids: [String]
    public let addLabelIds: [String]
    public let removeLabelIds: [String]
}

public struct HistoryResponse: Codable, Sendable {
    public let history: [HistoryRecord]?
    public let historyId: String
    public let nextPageToken: String?

    public struct HistoryRecord: Codable, Sendable {
        public let id: String
        public let messagesAdded: [MessageAdded]?
        public let messagesDeleted: [MessageDeleted]?
        public let labelsAdded: [LabelChange]?
        public let labelsRemoved: [LabelChange]?
    }

    public struct MessageAdded: Codable, Sendable {
        public let message: MessageListResponse.MessageRef
    }

    public struct MessageDeleted: Codable, Sendable {
        public let message: MessageListResponse.MessageRef
    }

    public struct LabelChange: Codable, Sendable {
        public let message: MessageListResponse.MessageRef
        public let labelIds: [String]
    }
}

// MARK: - Errors

public enum GmailError: Error, LocalizedError {
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case apiError(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Gmail API"
        case .unauthorized:
            return "Unauthorized - please sign in again"
        case .forbidden:
            return "Access forbidden"
        case .notFound:
            return "Resource not found"
        case .rateLimited:
            return "Rate limited - please try again later"
        case .apiError(let code, let message):
            return "Gmail API error \(code): \(message ?? "Unknown error")"
        }
    }
}

// MARK: - Email Conversion

extension GmailMessage {
    public func toEmail() -> Email? {
        guard let payload else { return nil }

        let headers = payload.headers ?? []
        let subject = headers.first { $0.name.lowercased() == "subject" }?.value ?? "(No Subject)"
        let from = headers.first { $0.name.lowercased() == "from" }?.value ?? ""
        let to = headers.first { $0.name.lowercased() == "to" }?.value ?? ""
        let dateString = headers.first { $0.name.lowercased() == "date" }?.value

        // Use DomainUtils for proper domain extraction
        let fromDomain = DomainUtils.extractDomainFromHeader(from)

        var date = Date()
        if let internalDate, let timestamp = Double(internalDate) {
            date = Date(timeIntervalSince1970: timestamp / 1000)
        } else if let dateString {
            let formatter = DateFormatter()
            formatter.dateFormat = "E, d MMM yyyy HH:mm:ss Z"
            if let parsed = formatter.date(from: dateString) {
                date = parsed
            }
        }

        let hasAttachments = checkForAttachments(payload: payload)
        // If labelIds is nil or doesn't contain "UNREAD", the message is read
        let isRead = !(labelIds?.contains("UNREAD") ?? false)

        return Email(
            id: id,
            threadId: threadId,
            subject: subject,
            snippet: snippet ?? "",
            from: from,
            fromDomain: fromDomain,
            to: [to],
            date: date,
            labelIds: labelIds ?? [],
            isRead: isRead,
            hasAttachments: hasAttachments,
            category: nil
        )
    }

    private func checkForAttachments(payload: Payload) -> Bool {
        // Recursively check all parts for attachments
        func hasAttachmentInPart(_ part: Part) -> Bool {
            // Check if this part is an attachment
            if let filename = part.filename, !filename.isEmpty {
                return true
            }
            if let body = part.body, body.attachmentId != nil {
                return true
            }
            // Check Content-Disposition header for attachment indicator
            if let headers = part.headers {
                for header in headers {
                    if header.name.lowercased() == "content-disposition",
                       header.value.lowercased().contains("attachment") {
                        return true
                    }
                }
            }
            // Recursively check nested parts
            if let nestedParts = part.parts {
                for nested in nestedParts {
                    if hasAttachmentInPart(nested) {
                        return true
                    }
                }
            }
            return false
        }

        // Check main payload parts
        if let parts = payload.parts {
            for part in parts {
                if hasAttachmentInPart(part) {
                    return true
                }
            }
        }
        return false
    }

    /// Extracts the email body content (prefers HTML, falls back to plain text)
    public func extractBody() -> (html: String?, plainText: String?) {
        guard let payload else { return (nil, nil) }

        var htmlBody: String?
        var textBody: String?

        // Helper to decode base64url encoded data
        func decodeBase64URL(_ encoded: String) -> String? {
            var base64 = encoded
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")

            // Add padding if needed
            let remainder = base64.count % 4
            if remainder > 0 {
                base64 += String(repeating: "=", count: 4 - remainder)
            }

            guard let data = Data(base64Encoded: base64) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        // Recursively search for body parts
        func findBody(in part: Part) {
            if let mimeType = part.mimeType {
                if mimeType == "text/html", let data = part.body?.data {
                    if let decoded = decodeBase64URL(data) {
                        htmlBody = decoded
                    }
                } else if mimeType == "text/plain", let data = part.body?.data {
                    if let decoded = decodeBase64URL(data) {
                        textBody = decoded
                    }
                }
            }

            // Recurse into nested parts
            if let nestedParts = part.parts {
                for nested in nestedParts {
                    findBody(in: nested)
                }
            }
        }

        // Check if body is directly in payload
        if let mimeType = payload.mimeType {
            if mimeType == "text/html", let data = payload.body?.data {
                htmlBody = decodeBase64URL(data)
            } else if mimeType == "text/plain", let data = payload.body?.data {
                textBody = decodeBase64URL(data)
            }
        }

        // Search in parts
        if let parts = payload.parts {
            for part in parts {
                findBody(in: Part(
                    partId: part.partId,
                    mimeType: part.mimeType,
                    filename: part.filename,
                    headers: part.headers,
                    body: part.body,
                    parts: part.parts
                ))
            }
        }

        return (htmlBody, textBody)
    }
}

// MARK: - Attachment Extraction

/// Metadata about an attachment extracted from a Gmail message
public struct AttachmentInfo: Sendable {
    public let attachmentId: String
    public let filename: String
    public let mimeType: String?
    public let size: Int
}

extension GmailMessage {
    /// Extracts attachment metadata from message parts
    /// Returns array of AttachmentInfo for each attachment found
    public func extractAttachments() -> [AttachmentInfo] {
        guard let payload else { return [] }

        var attachments: [AttachmentInfo] = []

        func extractFromPart(_ part: Part) {
            // Check if this part is an attachment (has filename and attachmentId)
            if let filename = part.filename, !filename.isEmpty,
               let body = part.body,
               let attachmentId = body.attachmentId {
                let info = AttachmentInfo(
                    attachmentId: attachmentId,
                    filename: filename,
                    mimeType: part.mimeType,
                    size: body.size
                )
                attachments.append(info)
            }

            // Recurse into nested parts (for multipart messages)
            if let nestedParts = part.parts {
                for nested in nestedParts {
                    extractFromPart(nested)
                }
            }
        }

        // Check top-level body for single-part attachments
        if let body = payload.body, let attachmentId = body.attachmentId {
            // This is rare - usually attachments are in parts
            let info = AttachmentInfo(
                attachmentId: attachmentId,
                filename: "attachment",  // Fallback name
                mimeType: payload.mimeType,
                size: body.size
            )
            attachments.append(info)
        }

        // Search through all parts
        if let parts = payload.parts {
            for part in parts {
                extractFromPart(part)
            }
        }

        return attachments
    }
}

// MARK: - Array Chunking Extension

extension Array {
    /// Splits an array into chunks of specified size
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

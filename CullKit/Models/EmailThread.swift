//
//  EmailThread.swift
//  CullKit
//
//  Created by Vipin Kumar Kashyap on 1/5/26.
//

import Foundation

/// Represents a conversation thread containing one or more emails
public struct EmailThread: Identifiable, Hashable {
    public var id: String { threadId }
    public let threadId: String
    public let messages: [Email]
    public let latestMessage: Email
    public let hasUnread: Bool

    public init(threadId: String, messages: [Email], latestMessage: Email, hasUnread: Bool) {
        self.threadId = threadId
        self.messages = messages
        self.latestMessage = latestMessage
        self.hasUnread = hasUnread
    }

    // MARK: - Computed Properties

    /// Number of messages in the thread
    public var messageCount: Int { messages.count }

    /// Whether this is a conversation (more than one message)
    public var isConversation: Bool { messages.count > 1 }

    /// Number of unread messages in the thread
    public var unreadCount: Int { messages.filter { !$0.isRead }.count }

    /// Subject from the latest message
    public var subject: String { latestMessage.subject }

    /// Snippet from the latest message
    public var snippet: String { latestMessage.snippet }

    /// Date of the latest message
    public var date: Date { latestMessage.date }

    /// Domain from the latest message
    public var fromDomain: String { latestMessage.fromDomain }

    /// Whether any message in the thread has attachments
    public var hasAttachments: Bool { messages.contains { $0.hasAttachments } }

    /// All unique senders in the thread
    public var participants: [String] {
        let senders = Set(messages.map { extractDisplayName(from: $0.from) })
        return Array(senders).sorted()
    }

    /// Oldest message in the thread
    public var oldestMessage: Email? {
        messages.min { $0.date < $1.date }
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(threadId)
    }

    public static func == (lhs: EmailThread, rhs: EmailThread) -> Bool {
        lhs.threadId == rhs.threadId
    }

    // MARK: - Private

    private func extractDisplayName(from: String) -> String {
        if let angleBracket = from.firstIndex(of: "<") {
            let name = from[..<angleBracket].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return from
    }
}

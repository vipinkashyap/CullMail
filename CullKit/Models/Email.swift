//
//  Email.swift
//  CullKit
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
import GRDB

public enum EmailCategory: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case people
    case shopping
    case finance
    case newsletter
    case travel
    case social
    case promotions
    case other

    public var displayName: String {
        switch self {
        case .people: return "People"
        case .shopping: return "Shopping"
        case .finance: return "Finance"
        case .newsletter: return "Newsletters"
        case .travel: return "Travel"
        case .social: return "Social"
        case .promotions: return "Promotions"
        case .other: return "Other"
        }
    }

    public var icon: String {
        switch self {
        case .people: return "person.2"
        case .shopping: return "cart"
        case .finance: return "dollarsign.circle"
        case .newsletter: return "newspaper"
        case .travel: return "airplane"
        case .social: return "bubble.left.and.bubble.right"
        case .promotions: return "tag"
        case .other: return "tray"
        }
    }
}

public struct Email: Identifiable, Codable, Sendable, Hashable {
    public let id: String              // Gmail message ID
    public let threadId: String
    public var subject: String
    public var snippet: String
    public var from: String
    public var fromDomain: String
    public var to: [String]
    public var date: Date
    public var labelIds: [String]
    public var isRead: Bool
    public var hasAttachments: Bool
    public var category: EmailCategory?
    public var rawPayload: Data?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        threadId: String,
        subject: String,
        snippet: String,
        from: String,
        fromDomain: String,
        to: [String],
        date: Date,
        labelIds: [String],
        isRead: Bool,
        hasAttachments: Bool,
        category: EmailCategory? = nil,
        rawPayload: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.threadId = threadId
        self.subject = subject
        self.snippet = snippet
        self.from = from
        self.fromDomain = fromDomain
        self.to = to
        self.date = date
        self.labelIds = labelIds
        self.isRead = isRead
        self.hasAttachments = hasAttachments
        self.category = category
        self.rawPayload = rawPayload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - GRDB Support

extension Email: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "emails" }

    public enum Columns {
        static let id = Column(CodingKeys.id)
        static let threadId = Column(CodingKeys.threadId)
        static let subject = Column(CodingKeys.subject)
        static let snippet = Column(CodingKeys.snippet)
        static let from = Column(CodingKeys.from)
        static let fromDomain = Column(CodingKeys.fromDomain)
        static let to = Column(CodingKeys.to)
        static let date = Column(CodingKeys.date)
        static let labelIds = Column(CodingKeys.labelIds)
        static let isRead = Column(CodingKeys.isRead)
        static let hasAttachments = Column(CodingKeys.hasAttachments)
        static let category = Column(CodingKeys.category)
        static let rawPayload = Column(CodingKeys.rawPayload)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}

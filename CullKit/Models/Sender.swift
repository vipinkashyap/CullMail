//
//  Sender.swift
//  CullKit
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
import GRDB

public enum UserAction: String, Codable, Sendable, DatabaseValueConvertible {
    case keep
    case bulkArchive
    case unsubscribe
}

public struct Sender: Identifiable, Codable, Sendable, Hashable {
    public var id: String { domain }

    public let domain: String
    public var totalEmails: Int
    public var openedCount: Int
    public var repliedCount: Int
    public var archivedWithoutReadingCount: Int
    public var avgTimeToArchiveSeconds: Double?
    public var lastEmailAt: Date?
    public var category: EmailCategory?
    public var userAction: UserAction?
    public var confidenceScore: Double
    public var createdAt: Date
    public var updatedAt: Date

    public var openRate: Double {
        guard totalEmails > 0 else { return 0 }
        return Double(openedCount) / Double(totalEmails)
    }

    public var replyRate: Double {
        guard totalEmails > 0 else { return 0 }
        return Double(repliedCount) / Double(totalEmails)
    }

    public init(
        domain: String,
        totalEmails: Int = 0,
        openedCount: Int = 0,
        repliedCount: Int = 0,
        archivedWithoutReadingCount: Int = 0,
        avgTimeToArchiveSeconds: Double? = nil,
        lastEmailAt: Date? = nil,
        category: EmailCategory? = nil,
        userAction: UserAction? = nil,
        confidenceScore: Double = 0.5,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.domain = domain
        self.totalEmails = totalEmails
        self.openedCount = openedCount
        self.repliedCount = repliedCount
        self.archivedWithoutReadingCount = archivedWithoutReadingCount
        self.avgTimeToArchiveSeconds = avgTimeToArchiveSeconds
        self.lastEmailAt = lastEmailAt
        self.category = category
        self.userAction = userAction
        self.confidenceScore = confidenceScore
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - GRDB Support

extension Sender: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "senders" }

    public enum Columns {
        static let domain = Column(CodingKeys.domain)
        static let totalEmails = Column(CodingKeys.totalEmails)
        static let openedCount = Column(CodingKeys.openedCount)
        static let repliedCount = Column(CodingKeys.repliedCount)
        static let archivedWithoutReadingCount = Column(CodingKeys.archivedWithoutReadingCount)
        static let avgTimeToArchiveSeconds = Column(CodingKeys.avgTimeToArchiveSeconds)
        static let lastEmailAt = Column(CodingKeys.lastEmailAt)
        static let category = Column(CodingKeys.category)
        static let userAction = Column(CodingKeys.userAction)
        static let confidenceScore = Column(CodingKeys.confidenceScore)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}

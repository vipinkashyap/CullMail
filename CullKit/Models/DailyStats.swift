//
//  DailyStats.swift
//  CullKit
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
import GRDB

public struct DailyStats: Identifiable, Codable, Sendable, Hashable {
    public var id: String { date }

    public let date: String  // YYYY-MM-DD format
    public var emailsProcessed: Int
    public var emailsAutoArchived: Int
    public var attachmentsSaved: Int
    public var timeSavedSeconds: Int

    public var timeSavedMinutes: Double {
        Double(timeSavedSeconds) / 60.0
    }

    public init(
        date: String,
        emailsProcessed: Int = 0,
        emailsAutoArchived: Int = 0,
        attachmentsSaved: Int = 0,
        timeSavedSeconds: Int = 0
    ) {
        self.date = date
        self.emailsProcessed = emailsProcessed
        self.emailsAutoArchived = emailsAutoArchived
        self.attachmentsSaved = attachmentsSaved
        self.timeSavedSeconds = timeSavedSeconds
    }

    public static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

// MARK: - GRDB Support

extension DailyStats: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "daily_stats" }

    public enum Columns {
        static let date = Column(CodingKeys.date)
        static let emailsProcessed = Column(CodingKeys.emailsProcessed)
        static let emailsAutoArchived = Column(CodingKeys.emailsAutoArchived)
        static let attachmentsSaved = Column(CodingKeys.attachmentsSaved)
        static let timeSavedSeconds = Column(CodingKeys.timeSavedSeconds)
    }
}

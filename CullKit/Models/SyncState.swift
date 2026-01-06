//
//  SyncState.swift
//  CullKit
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
import GRDB

public struct SyncState: Codable, Sendable, Hashable {
    public let key: String
    public var value: String
    public var updatedAt: Date

    public init(key: String, value: String, updatedAt: Date = Date()) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }
}

// MARK: - Known Keys

extension SyncState {
    public static let historyIdKey = "gmail_history_id"
    public static let lastSyncKey = "last_sync_timestamp"

    // Resumable sync keys
    public static let syncInProgressKey = "sync_in_progress"
    public static let syncPageTokenKey = "sync_page_token"
    public static let syncEmailsFetchedKey = "sync_emails_fetched"
    public static let syncTotalEstimateKey = "sync_total_estimate"
}

// MARK: - GRDB Support

extension SyncState: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "sync_state" }

    public enum Columns {
        public static let key = Column(CodingKeys.key)
        public static let value = Column(CodingKeys.value)
        public static let updatedAt = Column(CodingKeys.updatedAt)
    }
}

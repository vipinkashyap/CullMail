//
//  CullKit.swift
//  CullKit
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation

// Re-export GRDB for consumers
@_exported import GRDB

// CullKit is the shared framework for CullMail containing:
// - Models: Email, EmailThread, Sender, Attachment, SyncState, DailyStats, GmailLabel
// - Stores: EmailStore, SenderStore, AttachmentStore (reactive, single source of truth)
// - Database: DatabaseManager
// - Utils: DomainUtils, TextExtractor

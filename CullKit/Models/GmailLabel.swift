//
//  GmailLabel.swift
//  CullKit
//
//  Type-safe Gmail label system distinguishing between:
//  - Mailboxes (where emails live): INBOX, SENT, DRAFT, SPAM, TRASH
//  - State labels (properties of emails): UNREAD, STARRED, IMPORTANT
//  - Category labels (Gmail's automatic categorization): CATEGORY_*
//  - User labels (custom folders)
//

import SwiftUI

// MARK: - System Mailboxes (Folders where emails live)

/// System mailboxes represent physical locations in Gmail
/// An email can be in multiple mailboxes (e.g., INBOX + SENT for a reply)
public enum SystemMailbox: String, CaseIterable, Identifiable, Sendable {
    case inbox = "INBOX"
    case sent = "SENT"
    case draft = "DRAFT"
    case spam = "SPAM"
    case trash = "TRASH"
    case allMail = "ALL_MAIL"  // Virtual - all non-deleted emails

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .inbox: return "Inbox"
        case .sent: return "Sent"
        case .draft: return "Drafts"
        case .spam: return "Spam"
        case .trash: return "Trash"
        case .allMail: return "All Mail"
        }
    }

    public var systemImage: String {
        switch self {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .draft: return "doc.text"
        case .spam: return "exclamationmark.shield"
        case .trash: return "trash"
        case .allMail: return "archivebox"
        }
    }

    public var color: Color {
        switch self {
        case .inbox: return .blue
        case .sent: return .green
        case .draft: return .orange
        case .spam: return .red
        case .trash: return .gray
        case .allMail: return .purple
        }
    }

    /// Whether emails in this mailbox are auto-deleted after retention period
    public var hasRetentionPolicy: Bool {
        switch self {
        case .spam, .trash: return true
        default: return false
        }
    }

    /// Approximate retention period in days (Gmail default)
    public var retentionDays: Int? {
        switch self {
        case .spam: return 30
        case .trash: return 30
        default: return nil
        }
    }
}

// MARK: - State Labels (Properties/Overlays on emails)

/// State labels represent properties of an email, not where it lives
/// These are orthogonal to mailboxes - an email can have multiple states
public enum StateLabel: String, CaseIterable, Identifiable, Sendable {
    case unread = "UNREAD"
    case starred = "STARRED"
    case important = "IMPORTANT"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unread: return "Unread"
        case .starred: return "Starred"
        case .important: return "Important"
        }
    }

    /// State labels should be displayed as badges/indicators, not folder colors
    public var badgeColor: Color {
        switch self {
        case .unread: return .blue
        case .starred: return .yellow
        case .important: return .orange
        }
    }

    public var systemImage: String {
        switch self {
        case .unread: return "envelope.badge"
        case .starred: return "star.fill"
        case .important: return "exclamationmark.circle.fill"
        }
    }

    /// Whether this state is typically shown as a visual indicator
    public var showsAsBadge: Bool {
        switch self {
        case .unread: return true  // Bold text, dot indicator
        case .starred: return true  // Star icon
        case .important: return true  // Priority marker
        }
    }
}

// MARK: - Category Labels (Gmail's automatic categorization)

/// Gmail's automatic category tabs (if enabled in Gmail settings)
public enum CategoryLabel: String, CaseIterable, Identifiable, Sendable {
    case primary = "CATEGORY_PERSONAL"
    case social = "CATEGORY_SOCIAL"
    case promotions = "CATEGORY_PROMOTIONS"
    case updates = "CATEGORY_UPDATES"
    case forums = "CATEGORY_FORUMS"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .primary: return "Primary"
        case .social: return "Social"
        case .promotions: return "Promotions"
        case .updates: return "Updates"
        case .forums: return "Forums"
        }
    }

    public var systemImage: String {
        switch self {
        case .primary: return "person"
        case .social: return "person.2"
        case .promotions: return "tag"
        case .updates: return "bell"
        case .forums: return "bubble.left.and.bubble.right"
        }
    }

    public var color: Color {
        switch self {
        case .primary: return .blue
        case .social: return .purple
        case .promotions: return .green
        case .updates: return .cyan
        case .forums: return .orange
        }
    }
}

// MARK: - Unified Label Type

/// Represents any Gmail label with proper type discrimination
public enum GmailLabelType: Identifiable, Sendable {
    case mailbox(SystemMailbox)
    case state(StateLabel)
    case category(CategoryLabel)
    case user(id: String, name: String)

    public var id: String {
        switch self {
        case .mailbox(let m): return m.rawValue
        case .state(let s): return s.rawValue
        case .category(let c): return c.rawValue
        case .user(let id, _): return id
        }
    }

    public var displayName: String {
        switch self {
        case .mailbox(let m): return m.displayName
        case .state(let s): return s.displayName
        case .category(let c): return c.displayName
        case .user(_, let name): return name
        }
    }

    public var color: Color {
        switch self {
        case .mailbox(let m): return m.color
        case .state(let s): return s.badgeColor
        case .category(let c): return c.color
        case .user: return .secondary
        }
    }

    public var systemImage: String {
        switch self {
        case .mailbox(let m): return m.systemImage
        case .state(let s): return s.systemImage
        case .category(let c): return c.systemImage
        case .user: return "tag"
        }
    }

    /// Parse a Gmail label ID string into the appropriate type
    public static func parse(_ labelId: String) -> GmailLabelType {
        // Check system mailboxes
        if let mailbox = SystemMailbox(rawValue: labelId) {
            return .mailbox(mailbox)
        }

        // Check state labels
        if let state = StateLabel(rawValue: labelId) {
            return .state(state)
        }

        // Check category labels
        if let category = CategoryLabel(rawValue: labelId) {
            return .category(category)
        }

        // Otherwise it's a user label
        return .user(id: labelId, name: labelId)
    }

    /// Whether this label represents a location (mailbox) vs a property (state)
    public var isMailbox: Bool {
        if case .mailbox = self { return true }
        return false
    }

    public var isState: Bool {
        if case .state = self { return true }
        return false
    }

    public var isCategory: Bool {
        if case .category = self { return true }
        return false
    }

    public var isUserLabel: Bool {
        if case .user = self { return true }
        return false
    }
}

// MARK: - Email Label Analysis

/// Analyzes an email's labels to extract meaningful information
public struct EmailLabelInfo: Sendable {
    public let mailboxes: [SystemMailbox]
    public let states: [StateLabel]
    public let categories: [CategoryLabel]
    public let userLabels: [(id: String, name: String)]

    public init(labelIds: [String]) {
        var mailboxes: [SystemMailbox] = []
        var states: [StateLabel] = []
        var categories: [CategoryLabel] = []
        var userLabels: [(id: String, name: String)] = []

        for id in labelIds {
            let parsed = GmailLabelType.parse(id)
            switch parsed {
            case .mailbox(let m): mailboxes.append(m)
            case .state(let s): states.append(s)
            case .category(let c): categories.append(c)
            case .user(let id, let name): userLabels.append((id, name))
            }
        }

        self.mailboxes = mailboxes
        self.states = states
        self.categories = categories
        self.userLabels = userLabels
    }

    /// Is this email in the inbox?
    public var isInInbox: Bool {
        mailboxes.contains(.inbox)
    }

    /// Is this email unread?
    public var isUnread: Bool {
        states.contains(.unread)
    }

    /// Is this email starred?
    public var isStarred: Bool {
        states.contains(.starred)
    }

    /// Is this email marked important?
    public var isImportant: Bool {
        states.contains(.important)
    }

    /// Is this email in trash (pending deletion)?
    public var isInTrash: Bool {
        mailboxes.contains(.trash)
    }

    /// Is this email in spam?
    public var isSpam: Bool {
        mailboxes.contains(.spam)
    }

    /// Is this email archived (not in inbox, not in trash)?
    public var isArchived: Bool {
        !isInInbox && !isInTrash && !isSpam
    }

    /// Primary category if Gmail tabs are enabled
    public var primaryCategory: CategoryLabel? {
        categories.first
    }
}

// MARK: - Action Types

/// Represents the semantic difference between Archive and Trash
public enum EmailDisposalAction: Sendable {
    /// Archive: Remove from INBOX, email still exists in All Mail
    /// - Reversible: Yes, instantly
    /// - Searchable: Yes
    /// - Auto-deleted: No
    case archive

    /// Trash: Move to TRASH, scheduled for permanent deletion
    /// - Reversible: Yes, within retention period (~30 days)
    /// - Searchable: Usually excluded from search
    /// - Auto-deleted: Yes, after retention period
    case trash

    /// Spam: Move to SPAM, scheduled for permanent deletion
    /// - Reversible: Yes, within retention period (~30 days)
    /// - Searchable: Excluded from search
    /// - Auto-deleted: Yes, after retention period
    case spam

    /// Permanent delete: Immediately and permanently remove
    /// - Reversible: No
    /// - Searchable: No
    /// - Auto-deleted: N/A - already deleted
    case permanentDelete

    public var displayName: String {
        switch self {
        case .archive: return "Archive"
        case .trash: return "Move to Trash"
        case .spam: return "Mark as Spam"
        case .permanentDelete: return "Delete Permanently"
        }
    }

    public var systemImage: String {
        switch self {
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .spam: return "exclamationmark.shield"
        case .permanentDelete: return "trash.slash"
        }
    }

    /// Labels to add for this action
    public var labelsToAdd: [String] {
        switch self {
        case .archive: return []
        case .trash: return ["TRASH"]
        case .spam: return ["SPAM"]
        case .permanentDelete: return []
        }
    }

    /// Labels to remove for this action
    public var labelsToRemove: [String] {
        switch self {
        case .archive: return ["INBOX"]
        case .trash: return ["INBOX", "SPAM"]
        case .spam: return ["INBOX", "TRASH"]
        case .permanentDelete: return []
        }
    }

    /// Whether this action is reversible
    public var isReversible: Bool {
        switch self {
        case .archive, .trash, .spam: return true
        case .permanentDelete: return false
        }
    }

    /// Risk level for confirmation dialogs
    public var riskLevel: RiskLevel {
        switch self {
        case .archive: return .low
        case .trash, .spam: return .medium
        case .permanentDelete: return .high
        }
    }

    public enum RiskLevel: Sendable {
        case low      // No confirmation needed
        case medium   // Optional confirmation
        case high     // Always confirm
    }
}

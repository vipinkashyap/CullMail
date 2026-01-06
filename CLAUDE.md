# CLAUDE.md - Cull Mail

## Project Overview

**Cull Mail** is a native macOS email client for Gmail that works in the background to kill spam, organize attachments, and save users hours — all without reading their emails.

### One-Liner
> "Your email runs itself. You just show up for what matters."

### Core Philosophy
- **Background-first**: The app works while you don't
- **Privacy-first**: All processing on-device, only anonymous hashed patterns shared
- **Time saved, not time spent**: We measure disengagement, not engagement
- **Stable and simple**: Ship something great, not everything

---

## Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Swift 5.9+ |
| UI Framework | SwiftUI |
| Platform | macOS 13+ (Ventura and later) |
| Database | SQLite (via SQLite.swift or GRDB) |
| Email API | Gmail API (REST) |
| Auth | OAuth 2.0 via ASWebAuthenticationSession |
| Storage API | Google Drive API |
| Background | launchd daemon |
| On-device ML | MLX (Apple Silicon) — future |
| Backend | Cloudflare Workers + D1 — future |

---

## Project Structure

```
CullMail/
├── CullMail/                     # Main macOS App
│   ├── App/
│   │   ├── CullMailApp.swift     # @main entry point
│   │   └── AppDelegate.swift     # Menu bar, lifecycle
│   ├── Views/
│   │   ├── MainWindowView.swift  # Primary window
│   │   ├── EmailListView.swift   # Email list with grouping
│   │   ├── EmailDetailView.swift # Email content display
│   │   ├── SidebarView.swift     # Labels, domains, categories
│   │   ├── StatsView.swift       # Time saved dashboard
│   │   ├── BulkActionSheet.swift # Bulk archive/delete UI
│   │   └── SettingsView.swift    # Preferences
│   ├── ViewModels/
│   │   ├── EmailListViewModel.swift
│   │   ├── EmailDetailViewModel.swift
│   │   ├── SidebarViewModel.swift
│   │   └── StatsViewModel.swift
│   ├── Services/
│   │   ├── AuthService.swift     # OAuth flow + token management
│   │   ├── GmailService.swift    # Gmail API wrapper
│   │   ├── DriveService.swift    # Google Drive API wrapper
│   │   ├── SyncService.swift     # Orchestrates sync logic
│   │   └── KeychainService.swift # Secure token storage
│   └── Resources/
│       └── Assets.xcassets
│
├── CullDaemon/                   # Background Daemon (launchd)
│   ├── main.swift                # Daemon entry point
│   ├── DaemonSyncEngine.swift    # Background sync logic
│   ├── PatternMatcher.swift      # Spam pattern detection
│   └── AttachmentProcessor.swift # Attachment extraction
│
├── CullKit/                      # Shared Framework
│   ├── Database/
│   │   ├── DatabaseManager.swift # SQLite connection
│   │   ├── Schema.swift          # Table definitions
│   │   ├── EmailRepository.swift # Email CRUD
│   │   ├── SenderRepository.swift# Sender stats CRUD
│   │   └── PatternRepository.swift# Spam patterns CRUD
│   ├── Models/
│   │   ├── Email.swift
│   │   ├── Sender.swift
│   │   ├── Label.swift
│   │   ├── Attachment.swift
│   │   ├── SpamPattern.swift
│   │   └── SyncState.swift
│   ├── Intelligence/
│   │   ├── DomainClassifier.swift    # Known domain database
│   │   ├── CategoryDetector.swift    # Shopping, finance, etc.
│   │   ├── NewsletterDetector.swift  # List-Unsubscribe detection
│   │   └── BehaviorTracker.swift     # Open/reply rate tracking
│   └── Utils/
│       ├── HashingUtils.swift        # Privacy-preserving hashes
│       ├── DateUtils.swift
│       └── StringUtils.swift
│
├── CullMailTests/                # Unit Tests
│   ├── Services/
│   ├── Repositories/
│   └── Intelligence/
│
├── CullMailUITests/              # UI Tests
│
├── Resources/
│   ├── com.cull.daemon.plist     # launchd configuration
│   └── domains.json              # Known domain database
│
└── README.md
```

---

## Core Features (MVP Scope)

### 1. Gmail Integration
- OAuth 2.0 authentication
- Incremental sync using historyId
- Batch operations for bulk actions
- Label management
- Thread support

### 2. Domain-wise Grouping
- Group emails by sender domain
- Show stats: email count, open rate, reply rate
- Bulk actions: archive all, delete all, unsubscribe

### 3. Smart Categorization
- Categories: People, Shopping, Finance, Newsletters, Travel, Social, Promotions
- Detection via: known domains, headers (List-Unsubscribe), keywords
- No LLM required for V1

### 4. Background Processing
- launchd daemon runs on schedule (every 15-60 min)
- Incremental sync
- Auto-archive based on learned patterns
- Attachment detection

### 5. Attachment → Drive Sync
- Detect important attachments (invoices, receipts, tickets)
- Auto-upload to Google Drive
- Folder structure mirrors Gmail labels

### 6. Time Saved Tracking
- Track all automated actions
- Calculate estimated time saved
- Display in dashboard: "This week: 47 emails handled, 2.5 hours saved"

### 7. Menu Bar Presence
- Status icon in menu bar
- Quick stats dropdown
- "Last sync: 5 min ago"

---

## Data Models

### Email
```swift
struct Email: Identifiable, Codable {
    let id: String              // Gmail message ID
    let threadId: String
    let subject: String
    let snippet: String
    let from: String
    let fromDomain: String
    let to: [String]
    let date: Date
    let labelIds: [String]
    let isRead: Bool
    let hasAttachments: Bool
    let category: EmailCategory?
    let rawPayload: Data?       // Cached full message
}

enum EmailCategory: String, Codable {
    case people, shopping, finance, newsletter, travel, social, promotions, other
}
```

### Sender
```swift
struct Sender: Identifiable, Codable {
    let domain: String          // Primary key
    var totalEmails: Int
    var openedCount: Int
    var repliedCount: Int
    var archivedWithoutReadingCount: Int
    var avgTimeToArchiveSeconds: Double?
    var lastEmailAt: Date
    var category: EmailCategory?
    var userAction: UserAction? // keep, bulk_archive, unsubscribe
    var confidenceScore: Double
    
    var openRate: Double { Double(openedCount) / Double(totalEmails) }
    var replyRate: Double { Double(repliedCount) / Double(totalEmails) }
}

enum UserAction: String, Codable {
    case keep, bulkArchive, unsubscribe
}
```

### SpamPattern
```swift
struct SpamPattern: Identifiable, Codable {
    let id: UUID
    let domainHash: String      // SHA256 of domain
    let subjectPatternHash: String?
    let reportCount: Int
    let spamConfidence: Double
    let createdAt: Date
    let source: PatternSource
}

enum PatternSource: String, Codable {
    case local      // User marked as spam
    case community  // Downloaded from pattern server
}
```

---

## Database Schema

```sql
-- Emails (cached from Gmail)
CREATE TABLE emails (
    id TEXT PRIMARY KEY,
    thread_id TEXT NOT NULL,
    subject TEXT,
    snippet TEXT,
    from_address TEXT NOT NULL,
    from_domain TEXT NOT NULL,
    to_addresses TEXT,  -- JSON array
    date INTEGER NOT NULL,
    label_ids TEXT,     -- JSON array
    is_read INTEGER DEFAULT 0,
    has_attachments INTEGER DEFAULT 0,
    category TEXT,
    raw_payload BLOB,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX idx_emails_domain ON emails(from_domain);
CREATE INDEX idx_emails_date ON emails(date DESC);
CREATE INDEX idx_emails_category ON emails(category);

-- Senders (aggregated stats)
CREATE TABLE senders (
    domain TEXT PRIMARY KEY,
    total_emails INTEGER DEFAULT 0,
    opened_count INTEGER DEFAULT 0,
    replied_count INTEGER DEFAULT 0,
    archived_without_reading INTEGER DEFAULT 0,
    avg_time_to_archive_seconds REAL,
    last_email_at INTEGER,
    category TEXT,
    user_action TEXT,
    confidence_score REAL DEFAULT 0.5,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

-- Spam Patterns
CREATE TABLE spam_patterns (
    id TEXT PRIMARY KEY,
    domain_hash TEXT NOT NULL,
    subject_pattern_hash TEXT,
    report_count INTEGER DEFAULT 1,
    spam_confidence REAL DEFAULT 0.5,
    source TEXT DEFAULT 'local',
    created_at INTEGER DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX idx_patterns_domain ON spam_patterns(domain_hash);

-- Attachments
CREATE TABLE attachments (
    id TEXT PRIMARY KEY,
    email_id TEXT NOT NULL,
    filename TEXT NOT NULL,
    mime_type TEXT,
    size_bytes INTEGER,
    category TEXT,
    drive_file_id TEXT,
    uploaded_at INTEGER,
    FOREIGN KEY (email_id) REFERENCES emails(id)
);

-- Sync State
CREATE TABLE sync_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

-- Stats (for time saved tracking)
CREATE TABLE daily_stats (
    date TEXT PRIMARY KEY,  -- YYYY-MM-DD
    emails_processed INTEGER DEFAULT 0,
    emails_auto_archived INTEGER DEFAULT 0,
    attachments_saved INTEGER DEFAULT 0,
    time_saved_seconds INTEGER DEFAULT 0
);
```

---

## Gmail API Reference

### Base URL
```
https://gmail.googleapis.com/gmail/v1/users/me
```

### Key Endpoints

| Action | Method | Endpoint | Quota |
|--------|--------|----------|-------|
| List messages | GET | /messages | 5 units |
| Get message | GET | /messages/{id} | 5 units |
| Modify message | POST | /messages/{id}/modify | 5 units |
| Batch modify | POST | /messages/batchModify | 50 units |
| Trash message | POST | /messages/{id}/trash | 5 units |
| List labels | GET | /labels | 1 unit |
| Get history | GET | /history | 2 units |

### Incremental Sync Flow
```swift
// 1. Get current history ID on first sync
let profile = await gmail.getProfile()
let startHistoryId = profile.historyId

// 2. On subsequent syncs, get changes since last historyId
let history = await gmail.listHistory(startHistoryId: savedHistoryId)

// 3. Process only changed messages
for record in history.records {
    if let added = record.messagesAdded {
        // New emails
    }
    if let deleted = record.messagesDeleted {
        // Removed emails
    }
    if let labelsChanged = record.labelsAdded + record.labelsRemoved {
        // Label updates
    }
}

// 4. Save new historyId
save(historyId: history.historyId)
```

### Batch Modify Example
```swift
// Archive 100 emails in one API call
let request = BatchModifyRequest(
    ids: emailIds,
    addLabelIds: [],
    removeLabelIds: ["INBOX"]
)
await gmail.batchModify(request)
```

---

## Intelligence Logic

### Category Detection (No LLM)

```swift
struct CategoryDetector {
    // 1. Check known domains first
    func detectByDomain(_ domain: String) -> EmailCategory? {
        return KnownDomains.shared.category(for: domain)
    }
    
    // 2. Check headers for newsletters
    func detectNewsletter(_ headers: [Header]) -> Bool {
        return headers.contains { $0.name == "List-Unsubscribe" }
            || headers.contains { $0.name == "Precedence" && $0.value == "bulk" }
    }
    
    // 3. Check subject keywords
    func detectBySubject(_ subject: String) -> EmailCategory? {
        let lower = subject.lowercased()
        
        if lower.contains("order") || lower.contains("shipped") || lower.contains("delivered") {
            return .shopping
        }
        if lower.contains("invoice") || lower.contains("receipt") || lower.contains("statement") {
            return .finance
        }
        if lower.contains("booking") || lower.contains("flight") || lower.contains("reservation") {
            return .travel
        }
        return nil
    }
    
    // 4. Check sender patterns
    func detectByFrom(_ from: String) -> EmailCategory? {
        if from.contains("noreply") || from.contains("no-reply") {
            return .promotions  // Likely automated
        }
        return nil
    }
}
```

### Bulk Action Suggestions

```swift
struct BulkActionSuggester {
    func suggest(for sender: Sender) -> SuggestedAction? {
        // Never opened, many emails → suggest archive all
        if sender.openRate < 0.05 && sender.totalEmails > 10 {
            return .archiveAll(reason: "You've never opened emails from this sender")
        }
        
        // Newsletter never read → suggest unsubscribe
        if sender.category == .newsletter && sender.openRate < 0.1 && sender.totalEmails > 5 {
            return .unsubscribe(reason: "You haven't read this newsletter in months")
        }
        
        return nil
    }
}
```

---

## Testing Strategy

### Unit Tests
- [ ] `GmailService` — mock API responses
- [ ] `EmailRepository` — CRUD operations
- [ ] `SenderRepository` — stats calculations
- [ ] `CategoryDetector` — all detection rules
- [ ] `BulkActionSuggester` — suggestion logic
- [ ] `HashingUtils` — privacy-preserving hashes

### Integration Tests
- [ ] OAuth flow (manual/UI test)
- [ ] Full sync cycle
- [ ] Daemon ↔ App communication via shared SQLite

### UI Tests
- [ ] Email list displays correctly
- [ ] Bulk action sheet works
- [ ] Settings save properly

---

## Build Commands

```bash
# Build main app
xcodebuild -scheme CullMail -configuration Debug build

# Build daemon
xcodebuild -scheme CullDaemon -configuration Debug build

# Run tests
xcodebuild -scheme CullMail -configuration Debug test

# Build for release
xcodebuild -scheme CullMail -configuration Release archive
```

---

## Development Guidelines

### Code Style
- Use Swift standard naming conventions
- Prefer `async/await` over callbacks
- Use `@Observable` (iOS 17+) or `@ObservableObject` for view models
- Keep views small, extract components
- Write unit tests for all business logic

### Error Handling
```swift
// Use Result type or throw errors, never force unwrap
func fetchEmails() async throws -> [Email]

// Handle errors gracefully in UI
do {
    emails = try await gmail.fetchEmails()
} catch {
    errorMessage = error.localizedDescription
    showError = true
}
```

### Logging
```swift
import os

let logger = Logger(subsystem: "com.cull.mail", category: "sync")

logger.debug("Starting sync...")
logger.info("Synced \(count) emails")
logger.error("Sync failed: \(error)")
```

### Security
- Store OAuth tokens in Keychain only
- Never log email content
- Hash domains before sharing patterns
- Use App Groups for daemon ↔ app data sharing

---

## Configuration

### App Group (for shared data)
```
group.com.cull.mail
```

### OAuth Scopes
```
https://www.googleapis.com/auth/gmail.modify
https://www.googleapis.com/auth/gmail.labels  
https://www.googleapis.com/auth/drive.file
```

### launchd Schedule
```xml
<key>StartInterval</key>
<integer>900</integer>  <!-- 15 minutes -->
```

---

## Milestones

### Week 1-2: Foundation
- [ ] Xcode project setup (App + Daemon + CullKit)
- [ ] Menu bar app shell
- [ ] Gmail OAuth working
- [ ] Fetch and display emails

### Week 3-4: Core Features
- [ ] Local SQLite caching
- [ ] Domain grouping in sidebar
- [ ] Category detection
- [ ] Bulk action UI

### Week 5-6: Background & Intelligence
- [ ] launchd daemon working
- [ ] Incremental sync
- [ ] Sender stats tracking
- [ ] Auto-archive suggestions

### Week 7-8: Polish
- [ ] Attachment → Drive sync
- [ ] Time saved dashboard
- [ ] Settings UI
- [ ] Comprehensive tests
- [ ] TestFlight build

---

## Future Features (Post-MVP)

- [ ] Crowdsourced spam patterns (pattern sync server)
- [ ] On-device LLM for ambiguous classification (MLX)
- [ ] Gamification (achievements, leaderboards)
- [ ] Multiple Gmail accounts
- [ ] iOS companion app

---

## Key Files to Generate

When starting development, create these files first:

1. `CullMailApp.swift` — App entry point
2. `AppDelegate.swift` — Menu bar setup
3. `AuthService.swift` — OAuth flow
4. `GmailService.swift` — API wrapper
5. `DatabaseManager.swift` — SQLite setup
6. `Email.swift` — Core model
7. `EmailRepository.swift` — Database CRUD
8. `EmailListView.swift` — Main UI

---

## Contact

Project owner: Vipin
Focus: Stable, simple, well-tested Gmail client for macOS with background intelligence.

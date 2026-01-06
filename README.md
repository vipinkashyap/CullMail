# Cull Mail

> Your email runs itself. You show up for what matters.

A native macOS Gmail client that groups emails by sender domain, lets you archive in bulk, and saves you hours — all without reading your emails.

![macOS](https://img.shields.io/badge/macOS-14+-blue?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)

## Features

- **Group by Domain** — See all emails from a sender at once. Newsletters, promotions, notifications — instantly organized.
- **Bulk Archive** — Archive all emails from a domain with one click. Clear years of newsletters in seconds.
- **Gmail Search** — Full Gmail search syntax. Find old emails, filter by date, attachments, or any query.
- **Conversation View** — See threads as conversations. Expand and collapse naturally.
- **Privacy First** — All processing on your Mac. Your emails never touch external servers.
- **Native Performance** — Built with SwiftUI. Fast, lightweight, native macOS experience.

## Screenshots

*Coming soon*

## Installation

### Download

Download the latest release from the [Releases](https://github.com/vipink1/CullMail/releases) page.

### Build from Source

Requirements:
- Xcode 15+
- macOS 14+

```bash
# Clone the repository
git clone https://github.com/vipink1/CullMail.git
cd CullMail

# Create Secrets.swift with your Google OAuth credentials
cat > CullMail/Services/Secrets.swift << 'EOF'
import Foundation

enum Secrets {
    static let googleClientId = "YOUR_CLIENT_ID.apps.googleusercontent.com"
    static let googleClientSecret = "YOUR_CLIENT_SECRET"
}
EOF

# Open in Xcode
open CullMail.xcodeproj

# Build and run (Cmd+R)
```

#### Getting Google OAuth Credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
2. Create a new project or select an existing one
3. Enable the Gmail API and Google Drive API
4. Create OAuth 2.0 credentials (Desktop app type)
5. Copy the Client ID and Client Secret to `Secrets.swift`

## Usage

1. **Sign In** — Authenticate with your Gmail account using OAuth2
2. **Sync** — The app automatically syncs your emails in the background
3. **Browse Senders** — View all your email senders grouped by domain
4. **Take Action** — Archive all, mark read/unread, or view emails from any sender
5. **Search Gmail** — Use Gmail's powerful search syntax to find specific emails

### Gmail Search Examples

| Query | Description |
|-------|-------------|
| `older_than:1y` | Emails older than 1 year |
| `has:attachment` | Emails with attachments |
| `from:newsletter` | Emails from newsletter addresses |
| `subject:invoice` | Emails with "invoice" in subject |
| `from:amazon.com older_than:6m` | Amazon emails older than 6 months |

## Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Swift 5.9+ |
| UI | SwiftUI |
| Platform | macOS 14+ |
| Database | SQLite (GRDB) |
| Email API | Gmail REST API |
| Auth | OAuth 2.0 |

## Privacy

- **Local Processing** — All email processing happens on your Mac
- **No External Servers** — Your email content is never sent anywhere except Gmail
- **Secure Auth** — OAuth 2.0 for Gmail access, tokens stored in Keychain
- **No Tracking** — No analytics, no telemetry, no data collection

## Project Structure

```
CullMail/
├── CullMail/           # Main macOS app
│   ├── Views/          # SwiftUI views
│   ├── Services/       # Gmail, Auth, Sync services
│   └── Resources/      # Assets, Info.plist
├── CullKit/            # Shared framework
│   ├── Models/         # Email, Sender, etc.
│   ├── Stores/         # Reactive data stores
│   ├── Database/       # GRDB repositories
│   └── Utils/          # Utilities
└── docs/               # GitHub Pages site
```

## Contributing

Contributions welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [GRDB](https://github.com/groue/GRDB.swift) — SQLite toolkit for Swift
- Gmail API — Google's email API

---

Made by [Vipin](https://github.com/vipink1)

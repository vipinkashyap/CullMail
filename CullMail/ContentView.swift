//
//  ContentView.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import SwiftUI
import CullKit
import os

private let logger = Logger(subsystem: "com.cull.mail", category: "contentView")

struct ContentView: View {
    @State private var authState = AuthState.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @Binding var showOnboardingFromMenu: Bool
    private let authService = AuthService.shared

    init(showOnboardingFromMenu: Binding<Bool> = .constant(false)) {
        _showOnboardingFromMenu = showOnboardingFromMenu
    }

    var body: some View {
        Group {
            if authState.isCheckingAuth {
                CheckingAuthView()
            } else if authState.isAuthenticated {
                AuthenticatedView(authService: authService)
            } else {
                SignInView(authService: authService)
            }
        }
        .task {
            await authService.checkAuthStatus()
        }
        .onAppear {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .onChange(of: showOnboardingFromMenu) { _, newValue in
            if newValue {
                showOnboarding = true
                showOnboardingFromMenu = false
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                hasCompletedOnboarding = true
                showOnboarding = false
            }
        }
    }
}

// MARK: - Navigation

enum MainView: Hashable {
    case senders
    case unread
    case read
    case sender(String)
    case rootDomain(String)
    case search
    case labels
    case attachments
}

// MARK: - Authenticated View

struct AuthenticatedView: View {
    @Environment(AppState.self) private var appState
    let authService: AuthService

    @ObservedObject private var emailStore = EmailStore.shared
    @ObservedObject private var senderStore = SenderStore.shared

    // UI State
    @State private var currentView: MainView = .senders
    @State private var isSyncing = false
    @State private var syncProgress: String = ""
    @State private var selectedEmail: Email?
    @State private var searchText: String = ""
    @State private var autoSyncTask: Task<Void, Never>?
    @State private var showSyncBanner = true
    @AppStorage("showAsThreads") private var showAsThreads = true

    private var filteredSenders: [Sender] {
        if searchText.isEmpty {
            return senderStore.senders
        }
        return senderStore.senders.filter { $0.domain.localizedCaseInsensitiveContains(searchText) }
    }

    private var unreadCount: Int { emailStore.unreadCount }
    private var readCount: Int { emailStore.totalCount - emailStore.unreadCount }
    private var isLoading: Bool { senderStore.senders.isEmpty && !appState.syncComplete }
    private var unreadEmails: [Email] { emailStore.unreadEmails }
    private var readEmails: [Email] { emailStore.readEmails }

    private var currentThread: EmailThread? {
        guard showAsThreads, let email = selectedEmail else { return nil }
        return emailStore.threads.first { $0.threadId == email.threadId }
    }

    // Views that need a third detail pane for email viewing
    private var viewSupportsDetailPane: Bool {
        switch currentView {
        case .senders, .labels, .attachments:
            return false
        case .unread, .read, .sender, .rootDomain, .search:
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showSyncBanner && !appState.syncComplete {
                SyncStatusBanner(
                    isSyncing: appState.isSyncing,
                    syncedEmails: appState.syncedEmails,
                    totalEmails: appState.totalEmailsEstimate,
                    percentage: appState.syncPercentage,
                    estimatedTime: appState.estimatedTimeRemaining,
                    progress: syncProgress,
                    gmailTotal: appState.gmailTotalMessages,
                    onDismiss: { showSyncBanner = false }
                )
            }

            // Two-column for non-email views, three-column for email views
            if viewSupportsDetailPane {
                threeColumnLayout
            } else {
                twoColumnLayout
            }
        }
        .task {
            await loadData()
            await startAutoSync()
        }
        .onChange(of: emailStore.emails) { _, newEmails in
            appState.updateStats(emails: newEmails)
        }
        .onChange(of: currentView) { _, newView in
            switch newView {
            case .sender(let domain):
                try? emailStore.selectDomain(domain, includeSubdomains: false)
            case .rootDomain(let rootDomain):
                try? emailStore.selectDomain(rootDomain, includeSubdomains: true)
            default:
                emailStore.clearDomain()
            }
            selectedEmail = nil
        }
        .onDisappear {
            autoSyncTask?.cancel()
        }
    }

    // MARK: - Two Column Layout (Senders, Labels, Attachments)

    private var twoColumnLayout: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            mainContent
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(navigationTitle)
        .toolbar { mainToolbar }
    }

    // MARK: - Three Column Layout (Unread, Read, Search, Sender detail)

    private var threeColumnLayout: some View {
        NavigationSplitView {
            sidebarContent
        } content: {
            mainContent
        } detail: {
            if let email = selectedEmail {
                EmailDetailView(
                    email: email,
                    thread: currentThread,
                    onArchive: { email in
                        Task { try? await emailStore.archive(ids: [email.id]) }
                        selectedEmail = nil
                    },
                    onArchiveAllFromSender: { domain in
                        Task { await archiveAllFromDomain(domain) }
                    },
                    onTrash: { email in
                        Task { try? await emailStore.delete(id: email.id) }
                        selectedEmail = nil
                    },
                    onMarkRead: { updatedEmail in
                        Task { try? await emailStore.markRead(ids: [updatedEmail.id], isRead: updatedEmail.isRead) }
                        selectedEmail = updatedEmail
                    }
                )
            } else {
                Text("Select an email to view")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(navigationTitle)
        .toolbar { mainToolbar }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        List(selection: Binding(
            get: { currentView },
            set: { if let v = $0 { currentView = v } }
        )) {
            Section {
                Label("All Senders", systemImage: "person.2.circle")
                    .tag(MainView.senders)

                Label {
                    HStack {
                        Text("Unread")
                        Spacer()
                        if unreadCount > 0 {
                            Text("\(unreadCount)")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.blue)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "envelope.badge")
                }
                .tag(MainView.unread)

                Label {
                    HStack {
                        Text("Read")
                        Spacer()
                        if readCount > 0 {
                            Text("\(readCount)")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AccessibleColors.badgeBackground)
                                .foregroundStyle(.primary)
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "envelope.open")
                }
                .tag(MainView.read)

                Label("Search Gmail", systemImage: "magnifyingglass")
                    .tag(MainView.search)

                Label("Gmail Labels", systemImage: "tag")
                    .tag(MainView.labels)

                Label("Attachments", systemImage: "paperclip")
                    .tag(MainView.attachments)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await syncEmails() }
                } label: {
                    Label("Sync", systemImage: "arrow.clockwise")
                }
                .disabled(isSyncing)
                .keyboardShortcut(AppKeyboardShortcuts.sync)
                .help("Sync emails (⌘R)")
            }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        Group {
            switch currentView {
            case .senders:
                SendersGridView(
                    senders: filteredSenders,
                    searchText: $searchText,
                    isLoading: isLoading,
                    onSelectSender: { domain in currentView = .sender(domain) },
                    onSelectRootDomain: { rootDomain in currentView = .rootDomain(rootDomain) },
                    onArchiveAll: { domain in Task { await archiveAllFromDomain(domain) } },
                    onArchiveAllFromRootDomain: { rootDomain in Task { await archiveAllFromRootDomain(rootDomain) } }
                )

            case .unread:
                EmailListView(
                    emails: unreadEmails,
                    selectedEmail: $selectedEmail,
                    emptyTitle: "No Unread Emails",
                    emptyMessage: "You're all caught up!",
                    emptyIcon: "checkmark.circle"
                )

            case .read:
                EmailListView(
                    emails: readEmails,
                    selectedEmail: $selectedEmail,
                    emptyTitle: "No Read Emails",
                    emptyMessage: "Emails you've read will appear here",
                    emptyIcon: "envelope.open"
                )

            case .sender(let domain):
                SenderDetailView(
                    domain: domain,
                    emails: emailStore.domainEmails,
                    sender: senderStore.senders.first { $0.domain == domain },
                    selectedEmail: $selectedEmail,
                    onBack: { currentView = .senders },
                    onArchiveAll: { Task { await archiveAllFromDomain(domain) } },
                    onMarkAllRead: { Task { await markAllAsRead(domain: domain) } },
                    onMarkAllUnread: { Task { await markAllAsUnread(domain: domain) } }
                )

            case .rootDomain(let rootDomain):
                SenderDetailView(
                    domain: rootDomain,
                    emails: emailStore.domainEmails,
                    sender: nil,
                    selectedEmail: $selectedEmail,
                    onBack: { currentView = .senders },
                    onArchiveAll: { Task { await archiveAllFromRootDomain(rootDomain) } },
                    onMarkAllRead: { Task { await markAllAsReadForRootDomain(rootDomain: rootDomain) } },
                    onMarkAllUnread: { Task { await markAllAsUnreadForRootDomain(rootDomain: rootDomain) } }
                )

            case .search:
                GmailSearchView(selectedEmail: $selectedEmail)

            case .labels:
                LabelExplorerView()

            case .attachments:
                AttachmentBrowserView()
            }
        }
        .frame(minWidth: 400)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if isSyncing {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(syncProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        ToolbarItem(placement: .destructiveAction) {
            Button("Sign Out") {
                Task { try? await authService.signOut() }
            }
        }
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        switch currentView {
        case .senders: return "Senders"
        case .unread: return "Unread"
        case .read: return "Read"
        case .sender(let domain): return domain
        case .rootDomain(let rootDomain): return "\(rootDomain) (all)"
        case .search: return "Search Gmail"
        case .labels: return "Gmail Labels"
        case .attachments: return "Attachments"
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        do {
            try DatabaseManager.shared.initialize()
            try emailStore.start()
            try senderStore.start()
            try? await senderStore.rebuildStats()

            let count = try await emailStore.count()
            if count > 0 {
                appState.setSyncStats(synced: count, total: max(count, appState.totalEmailsEstimate))
            }

            await fetchGmailStats()
        } catch {
            logger.error("Failed to load data: \(error.localizedDescription)")
        }
    }

    private func fetchGmailStats() async {
        do {
            let gmail = GmailService.shared
            let stats = try await gmail.getMailboxStats()
            appState.setGmailStats(
                total: stats.totalMessages,
                threads: stats.totalThreads,
                inbox: stats.inboxMessages,
                unread: stats.totalUnread
            )
        } catch {
            logger.error("Failed to fetch Gmail stats: \(error.localizedDescription)")
        }
    }

    // MARK: - Sync

    private func startAutoSync() async {
        let hasIncomplete = try? await SyncService.shared.hasIncompleteSyncToResume()

        if hasIncomplete == true || appState.syncedEmails == 0 {
            autoSyncTask = Task { await continuousSync() }
        } else {
            appState.setSyncComplete(true)
        }
    }

    private func continuousSync() async {
        let syncService = SyncService.shared
        var sessionCount = 0
        let maxSessions = 100
        var consecutiveErrors = 0
        let maxConsecutiveErrors = 5

        appState.syncStartTime = Date()

        while !Task.isCancelled && sessionCount < maxSessions {
            sessionCount += 1
            isSyncing = true
            appState.isSyncing = true

            do {
                let hasMore = try await syncService.hasIncompleteSyncToResume()

                if !hasMore && appState.syncedEmails > 0 {
                    appState.setSyncComplete(true)
                    syncProgress = "Sync complete"
                    break
                }

                syncProgress = "Syncing..."

                var lastProgressUpdate = Date.distantPast
                let result = try await syncService.sync { progress in
                    Task { @MainActor in
                        let now = Date()
                        let shouldThrottle = now.timeIntervalSince(lastProgressUpdate) < 0.5

                        switch progress {
                        case .starting:
                            self.syncProgress = "Starting..."
                        case .resuming(let fetched):
                            self.syncProgress = "Resuming..."
                            self.appState.setSyncStats(synced: fetched, total: 10000)
                        case .fetchingHistory:
                            self.syncProgress = "Checking for changes..."
                        case .fetchingMessages(let current, let total):
                            if !shouldThrottle || current == total {
                                self.syncProgress = "Fetching \(current)/\(total)..."
                                self.appState.setSyncStats(synced: current, total: max(total, current))
                                lastProgressUpdate = now
                            }
                        case .processingChanges(let count):
                            self.syncProgress = "Processing \(count) changes..."
                        case .saving:
                            self.syncProgress = "Saving..."
                        case .complete(let added, let updated, let deleted):
                            if added + updated + deleted == 0 {
                                self.syncProgress = "Up to date"
                                self.appState.setSyncComplete(true)
                            } else {
                                self.syncProgress = "+\(added) ~\(updated) -\(deleted)"
                            }
                        case .fullSyncComplete(let count):
                            self.syncProgress = "\(count) emails synced"
                            self.appState.setSyncStats(synced: count, total: count)
                        case .noChanges:
                            self.syncProgress = "Up to date"
                            self.appState.setSyncComplete(true)
                        case .error(let message):
                            self.syncProgress = "Error: \(message)"
                        }
                    }
                }

                consecutiveErrors = 0
                appState.setLastSync(Date())

                switch result {
                case .noChanges:
                    appState.setSyncComplete(true)
                    syncProgress = "Sync complete"
                    break
                case .success(let added, let updated, let deleted):
                    if added + updated + deleted > 0 {
                        try? await senderStore.rebuildStats()
                    }
                    appState.setSyncComplete(true)
                    syncProgress = "Sync complete"
                    break
                case .fullSync(let count):
                    appState.setSyncStats(synced: count, total: max(count, 10000))
                    let stillHasMore = try await syncService.hasIncompleteSyncToResume()
                    if !stillHasMore {
                        try? await senderStore.rebuildStats()
                        appState.setSyncComplete(true)
                        syncProgress = "Sync complete - \(count) emails"
                        break
                    } else if sessionCount % 5 == 0 {
                        try? await senderStore.rebuildStats()
                    }
                    syncProgress = "Continuing sync..."
                case .error:
                    consecutiveErrors += 1
                    syncProgress = "Error, retrying..."
                    try? await Task.sleep(for: .seconds(30))
                }

                try? await Task.sleep(for: .seconds(2))

            } catch {
                consecutiveErrors += 1
                logger.error("Sync error: \(error.localizedDescription)")

                let errorString = error.localizedDescription.lowercased()
                let isRateLimitError = errorString.contains("forbidden") ||
                                       errorString.contains("rate") ||
                                       errorString.contains("quota")

                if isRateLimitError {
                    let backoffMinutes = min(pow(2.0, Double(consecutiveErrors - 1)), 16)
                    let backoffSeconds = Int(backoffMinutes * 60)
                    syncProgress = "Rate limited - waiting \(Int(backoffMinutes)) min..."
                    try? await Task.sleep(for: .seconds(backoffSeconds))
                } else {
                    syncProgress = "Error: \(error.localizedDescription)"
                    try? await Task.sleep(for: .seconds(30))
                }

                if consecutiveErrors >= maxConsecutiveErrors {
                    syncProgress = "Sync paused - too many errors"
                    break
                }
            }
        }

        isSyncing = false
        appState.isSyncing = false
    }

    private func syncEmails() async {
        isSyncing = true
        appState.isSyncing = true
        syncProgress = "Starting..."

        do {
            let result = try await SyncService.shared.sync { progress in
                Task { @MainActor in
                    switch progress {
                    case .starting: self.syncProgress = "Starting..."
                    case .resuming(let fetched):
                        self.syncProgress = "Resuming (\(fetched))..."
                        self.appState.setSyncStats(synced: fetched, total: 10000)
                    case .fetchingHistory: self.syncProgress = "Checking..."
                    case .fetchingMessages(let current, let total):
                        self.syncProgress = "\(current)/\(total)"
                        self.appState.setSyncStats(synced: current, total: max(total, current))
                    case .processingChanges(let count): self.syncProgress = "Processing \(count)..."
                    case .saving: self.syncProgress = "Saving..."
                    case .complete(let added, let updated, let deleted):
                        self.syncProgress = added + updated + deleted == 0 ? "Up to date" : "+\(added) ~\(updated) -\(deleted)"
                    case .fullSyncComplete(let count):
                        self.syncProgress = "\(count) emails"
                        self.appState.setSyncStats(synced: count, total: count)
                    case .noChanges: self.syncProgress = "Up to date"
                    case .error(let message): self.syncProgress = "Error: \(message)"
                    }
                }
            }

            try? await senderStore.rebuildStats()
            logger.info("Sync result: \(String(describing: result))")
            appState.setLastSync(Date())
            await fetchGmailStats()

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            syncProgress = ""
        } catch {
            syncProgress = "Error"
            logger.error("Sync error: \(error.localizedDescription)")
        }

        isSyncing = false
        appState.isSyncing = false
    }

    // MARK: - Archive Actions

    private func archiveAllFromDomain(_ domain: String) async {
        isSyncing = true
        syncProgress = "Archiving \(domain)..."

        do {
            let allDomainEmails = try await emailStore.fetchByDomain(domain)
            let emailsToArchive = allDomainEmails.filter { $0.labelIds.contains("INBOX") }

            if !emailsToArchive.isEmpty {
                let ids = emailsToArchive.map(\.id)
                try await GmailService.shared.batchModify(ids: ids, removeLabelIds: ["INBOX"])
                try await emailStore.archive(ids: ids)
                try await senderStore.updateStats(for: emailsToArchive)
                selectedEmail = nil
                syncProgress = "Archived \(ids.count) emails from \(domain)"
            } else {
                syncProgress = "No inbox emails from \(domain)"
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            syncProgress = ""
        } catch {
            syncProgress = "Failed to archive: \(error.localizedDescription)"
            logger.error("Archive error: \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            syncProgress = ""
        }

        isSyncing = false
    }

    private func archiveAllFromRootDomain(_ rootDomain: String) async {
        isSyncing = true
        syncProgress = "Archiving all from \(rootDomain)..."

        do {
            let allEmails = try await emailStore.fetchByRootDomain(rootDomain)
            let emailsToArchive = allEmails.filter { $0.labelIds.contains("INBOX") }

            if !emailsToArchive.isEmpty {
                let ids = emailsToArchive.map(\.id)
                try await GmailService.shared.batchModify(ids: ids, removeLabelIds: ["INBOX"])
                try await emailStore.archive(ids: ids)
                try await senderStore.updateStats(for: emailsToArchive)
                selectedEmail = nil
                syncProgress = "Archived \(ids.count) emails from \(rootDomain)"
            } else {
                syncProgress = "No inbox emails from \(rootDomain)"
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            syncProgress = ""
        } catch {
            syncProgress = "Failed to archive: \(error.localizedDescription)"
            logger.error("Archive error: \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            syncProgress = ""
        }

        isSyncing = false
    }

    // MARK: - Mark Read/Unread Actions

    private func markAllAsRead(domain: String) async {
        isSyncing = true
        syncProgress = "Marking all as read..."

        do {
            let allEmails = try await emailStore.fetchByDomain(domain)
            let unreadEmails = allEmails.filter { !$0.isRead }

            if !unreadEmails.isEmpty {
                let ids = unreadEmails.map(\.id)
                try await GmailService.shared.markAsRead(ids: ids)
                try await emailStore.markRead(ids: ids, isRead: true)
                syncProgress = "Marked \(ids.count) emails as read"
            } else {
                syncProgress = "No unread emails"
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            syncProgress = ""
        } catch {
            syncProgress = "Failed to mark as read"
            logger.error("Mark read error: \(error.localizedDescription)")
        }

        isSyncing = false
    }

    private func markAllAsUnread(domain: String) async {
        isSyncing = true
        syncProgress = "Marking all as unread..."

        do {
            let allEmails = try await emailStore.fetchByDomain(domain)
            let readEmails = allEmails.filter { $0.isRead }

            if !readEmails.isEmpty {
                let ids = readEmails.map(\.id)
                try await GmailService.shared.markAsUnread(ids: ids)
                try await emailStore.markRead(ids: ids, isRead: false)
                syncProgress = "Marked \(ids.count) emails as unread"
            } else {
                syncProgress = "No read emails"
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            syncProgress = ""
        } catch {
            syncProgress = "Failed to mark as unread"
            logger.error("Mark unread error: \(error.localizedDescription)")
        }

        isSyncing = false
    }

    private func markAllAsReadForRootDomain(rootDomain: String) async {
        isSyncing = true
        syncProgress = "Marking all as read..."

        do {
            let allEmails = try await emailStore.fetchByRootDomain(rootDomain)
            let unreadEmails = allEmails.filter { !$0.isRead }

            if !unreadEmails.isEmpty {
                let ids = unreadEmails.map(\.id)
                try await GmailService.shared.markAsRead(ids: ids)
                try await emailStore.markRead(ids: ids, isRead: true)
                syncProgress = "Marked \(ids.count) emails as read"
            } else {
                syncProgress = "No unread emails"
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            syncProgress = ""
        } catch {
            syncProgress = "Failed to mark as read"
            logger.error("Mark read error: \(error.localizedDescription)")
        }

        isSyncing = false
    }

    private func markAllAsUnreadForRootDomain(rootDomain: String) async {
        isSyncing = true
        syncProgress = "Marking all as unread..."

        do {
            let allEmails = try await emailStore.fetchByRootDomain(rootDomain)
            let readEmails = allEmails.filter { $0.isRead }

            if !readEmails.isEmpty {
                let ids = readEmails.map(\.id)
                try await GmailService.shared.markAsUnread(ids: ids)
                try await emailStore.markRead(ids: ids, isRead: false)
                syncProgress = "Marked \(ids.count) emails as unread"
            } else {
                syncProgress = "No read emails"
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            syncProgress = ""
        } catch {
            syncProgress = "Failed to mark as unread"
            logger.error("Mark unread error: \(error.localizedDescription)")
        }

        isSyncing = false
    }
}

#Preview {
    ContentView()
        .environment(AppState.shared)
}

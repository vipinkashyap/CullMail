//
//  CullMailApp.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import SwiftUI
import CullKit
import Observation
import os

private let logger = Logger(subsystem: "com.cull.mail", category: "app")

// MARK: - App State

/// Central app state using @Observable for automatic UI updates
@Observable
@MainActor
public final class AppState {
    public static let shared = AppState()

    // Sync state
    var isSyncing = false
    var lastSyncTime: Date?
    var syncProgress: String = ""
    var syncedEmails: Int = 0
    var totalEmailsEstimate: Int = 0
    var syncComplete: Bool = false
    var syncStartTime: Date?

    // Email stats
    var emailCount: Int = 0
    var unreadCount: Int = 0

    // Gmail API stats (actual counts from API)
    var gmailTotalMessages: Int = 0
    var gmailTotalThreads: Int = 0
    var gmailInboxCount: Int = 0
    var gmailUnreadCount: Int = 0

    private init() {}

    func updateStats(emails: [Email]) {
        emailCount = emails.count
        unreadCount = emails.filter { !$0.isRead }.count
    }

    func setLastSync(_ date: Date) {
        lastSyncTime = date
    }

    func setSyncProgress(_ progress: String) {
        syncProgress = progress
    }

    func setSyncStats(synced: Int, total: Int) {
        syncedEmails = synced
        totalEmailsEstimate = total
    }

    func setSyncComplete(_ complete: Bool) {
        syncComplete = complete
    }

    func setGmailStats(total: Int, threads: Int, inbox: Int, unread: Int) {
        gmailTotalMessages = total
        gmailTotalThreads = threads
        gmailInboxCount = inbox
        gmailUnreadCount = unread
    }

    var syncPercentage: Double {
        guard totalEmailsEstimate > 0 else { return 0 }
        return Double(syncedEmails) / Double(totalEmailsEstimate) * 100
    }

    var estimatedTimeRemaining: String? {
        guard let startTime = syncStartTime,
              syncedEmails > 0,
              totalEmailsEstimate > syncedEmails else { return nil }

        let elapsed = Date().timeIntervalSince(startTime)
        let rate = Double(syncedEmails) / elapsed // emails per second
        let remaining = Double(totalEmailsEstimate - syncedEmails)
        let secondsRemaining = remaining / rate

        if secondsRemaining < 60 {
            return "< 1 minute"
        } else if secondsRemaining < 3600 {
            let minutes = Int(secondsRemaining / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        } else if secondsRemaining < 86400 {
            let hours = Int(secondsRemaining / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        } else {
            let days = Int(secondsRemaining / 86400)
            return "\(days) day\(days == 1 ? "" : "s")"
        }
    }
}

// MARK: - App Entry Point

@main
struct CullMailApp: App {
    @State private var appState = AppState.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showOnboardingFromMenu = false

    var body: some Scene {
        WindowGroup {
            ContentView(showOnboardingFromMenu: $showOnboardingFromMenu)
                .environment(appState)
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("Cull Mail Tutorial") {
                    showOnboardingFromMenu = true
                }
                .keyboardShortcut("?", modifiers: [.command])

                Divider()

                Link("Report an Issue...", destination: URL(string: "https://github.com/mrowl/cullmail/issues")!)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.isSyncing ? "envelope.badge.shield.half.filled" : "envelope")
        }
    }
}

// MARK: - App Delegate for Background Sync

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start background sync scheduler
        BackgroundSyncScheduler.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop background sync
        BackgroundSyncScheduler.shared.stop()
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @State private var authState = AuthState.shared
    private let authService = AuthService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Status indicator with shape differentiation
            HStack(spacing: 10) {
                if authState.isAuthenticated {
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .strokeBorder(.red, lineWidth: 2)
                        .frame(width: 10, height: 10)
                }
                Text(authState.isAuthenticated ? "Connected" : "Not signed in")
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(authState.isAuthenticated ? "Status: Connected to Gmail" : "Status: Not signed in")

            Divider()

            // Stats with improved accessibility
            if authState.isAuthenticated {
                VStack(alignment: .leading, spacing: 6) {
                    if appState.gmailTotalMessages > 0 {
                        Label("\(appState.gmailTotalMessages.formatted()) emails", systemImage: "envelope")
                            .accessibilityLabel("\(appState.gmailTotalMessages) total emails")
                        Label("\(appState.gmailUnreadCount.formatted()) unread", systemImage: "envelope.badge")
                            .foregroundStyle(appState.gmailUnreadCount > 0 ? .blue : .primary.opacity(0.65))
                            .accessibilityLabel("\(appState.gmailUnreadCount) unread emails")
                    } else {
                        Label("\(appState.emailCount.formatted()) emails", systemImage: "envelope")
                            .accessibilityLabel("\(appState.emailCount) emails synced locally")
                        Label("\(appState.unreadCount.formatted()) unread", systemImage: "envelope.badge")
                            .accessibilityLabel("\(appState.unreadCount) unread emails")
                    }

                    if let lastSync = appState.lastSyncTime {
                        Label("Synced \(lastSync, style: .relative)", systemImage: "clock")
                            .foregroundStyle(.primary.opacity(0.65))
                            .accessibilityLabel("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 16)

                Divider()

                // Sync button with proper touch target
                Button {
                    Task {
                        appState.isSyncing = true
                        do {
                            _ = try await SyncService.shared.sync()
                            appState.setLastSync(Date())
                        } catch {
                            logger.error("Menu bar sync error: \(error.localizedDescription)")
                        }
                        appState.isSyncing = false
                    }
                } label: {
                    HStack {
                        Label(appState.isSyncing ? "Syncing..." : "Sync Now", systemImage: "arrow.clockwise")
                            .font(.system(size: 14))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                .disabled(appState.isSyncing)
                .accessibilityLabel(appState.isSyncing ? "Syncing in progress" : "Sync emails now")
                .accessibilityHint(appState.isSyncing ? "" : "Double tap to sync emails with Gmail")
            }

            Divider()

            // Menu buttons with proper sizing
            Button {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
            } label: {
                HStack {
                    Text("Open Cull Mail")
                        .font(.system(size: 14))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Cull Mail application")

            if authState.isAuthenticated {
                Button {
                    Task {
                        try? await authService.signOut()
                    }
                } label: {
                    HStack {
                        Text("Sign Out")
                            .font(.system(size: 14))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sign out of Gmail account")
            }

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quit")
                        .font(.system(size: 14))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
            .accessibilityLabel("Quit Cull Mail")
        }
        .frame(width: 240)
    }
}

//
//  EmailViews.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import SwiftUI
import CullKit
import os

private let logger = Logger(subsystem: "com.cull.mail", category: "emailViews")

struct EmailRowView: View {
    let email: Email

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Accessible unread indicator with shape differentiation
                UnreadIndicator(isUnread: !email.isRead)

                Text(displayName)
                    .font(.system(size: 15, weight: email.isRead ? .regular : .semibold))
                    .lineLimit(1)

                Spacer()

                if email.hasAttachments {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13))
                        .foregroundStyle(AccessibleColors.secondaryText)
                        .accessibilityLabel("Has attachments")
                }

                Text(email.date, style: .relative)
                    .font(.system(size: 13))
                    .foregroundStyle(AccessibleColors.secondaryText)
                    .accessibilityLabel("Received \(email.date.formatted(date: .abbreviated, time: .shortened))")
            }

            Text(DomainUtils.decodeHTMLEntities(email.subject))
                .font(.system(size: 15, weight: email.isRead ? .medium : .semibold))
                .lineLimit(1)

            Text(DomainUtils.decodeHTMLEntities(email.snippet))
                .font(.system(size: 14))
                .foregroundStyle(AccessibleColors.secondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double tap to open email")
    }

    private var displayName: String {
        let from = email.from
        if let angleBracket = from.firstIndex(of: "<") {
            let name = from[..<angleBracket].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return email.fromDomain.isEmpty ? from : email.fromDomain
    }

    private var accessibilityDescription: String {
        let readStatus = email.isRead ? "Read" : "Unread"
        let attachments = email.hasAttachments ? ", has attachments" : ""
        return "\(readStatus) email from \(displayName). Subject: \(email.subject)\(attachments)"
    }
}

/// Row view for displaying a thread (conversation)
struct ThreadRowView: View {
    let thread: EmailThread

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Accessible unread indicator with shape differentiation
                UnreadIndicator(isUnread: thread.hasUnread)

                Text(participantsText)
                    .font(.system(size: 15, weight: thread.hasUnread ? .semibold : .regular))
                    .lineLimit(1)

                Spacer()

                // Show message count if conversation has multiple messages
                if thread.isConversation {
                    AccessibleBadge(count: thread.messageCount, isHighlighted: thread.hasUnread)
                        .accessibilityLabel("\(thread.messageCount) messages in conversation")
                }

                if thread.hasAttachments {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13))
                        .foregroundStyle(AccessibleColors.secondaryText)
                        .accessibilityLabel("Has attachments")
                }

                Text(thread.date, style: .relative)
                    .font(.system(size: 13))
                    .foregroundStyle(AccessibleColors.secondaryText)
            }

            Text(DomainUtils.decodeHTMLEntities(thread.subject))
                .font(.system(size: 15, weight: thread.hasUnread ? .semibold : .medium))
                .lineLimit(1)

            Text(DomainUtils.decodeHTMLEntities(thread.snippet))
                .font(.system(size: 14))
                .foregroundStyle(AccessibleColors.secondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double tap to open conversation")
    }

    private var participantsText: String {
        let participants = thread.participants
        if participants.count == 1 {
            return participants[0]
        } else if participants.count == 2 {
            return participants.joined(separator: ", ")
        } else {
            return "\(participants[0]) + \(participants.count - 1) others"
        }
    }

    private var accessibilityDescription: String {
        let readStatus = thread.hasUnread ? "Unread" : "Read"
        let messageCount = thread.isConversation ? "\(thread.messageCount) messages" : "1 message"
        let attachments = thread.hasAttachments ? ", has attachments" : ""
        return "\(readStatus) conversation with \(participantsText). \(messageCount). Subject: \(thread.subject)\(attachments)"
    }
}

struct EmailBodyContent {
    let html: String?
    let plainText: String?
}

struct EmailDetailView: View {
    let email: Email?
    var thread: EmailThread?
    var onArchive: ((Email) -> Void)?
    var onArchiveAllFromSender: ((String) -> Void)?
    var onTrash: ((Email) -> Void)?
    var onMarkRead: ((Email) -> Void)?

    @State private var emailBody: EmailBodyContent?
    @State private var threadBodies: [String: EmailBodyContent] = [:]
    @State private var isLoading = false
    @State private var isPerformingAction = false
    @State private var actionMessage: String?
    @State private var expandedMessages: Set<String> = []
    @AppStorage("showAsThreads") private var showAsThreads = true

    // Determine if we should show thread view
    private var shouldShowThread: Bool {
        showAsThreads && thread != nil && thread!.isConversation
    }

    // Messages to display (oldest first for conversation view)
    private var threadMessages: [Email] {
        thread?.messages.sorted { $0.date < $1.date } ?? []
    }

    var body: some View {
        Group {
            if let email {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Anchor for scrolling to top
                            Color.clear.frame(height: 0).id("top")

                            EmailActionBar(
                                email: email,
                                isPerformingAction: isPerformingAction,
                                onArchive: { await archiveEmail(email) },
                                onArchiveAll: { await archiveAllFromSender(email.fromDomain) },
                                onTrash: { await trashEmail(email) },
                                onToggleRead: { await toggleReadStatus(email) }
                            )

                            if let message = actionMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .padding(.horizontal)
                            }

                            Divider()

                            if shouldShowThread {
                                // Thread/Conversation view
                                ThreadConversationView(
                                    thread: thread!,
                                    messages: threadMessages,
                                    threadBodies: threadBodies,
                                    expandedMessages: $expandedMessages,
                                    isLoading: isLoading
                                )
                            } else {
                                // Single email view
                                EmailDetailHeader(email: email)

                                Divider()

                                if isLoading {
                                    HStack {
                                        Spacer()
                                        ProgressView("Loading email...")
                                        Spacer()
                                    }
                                    .padding(.top, 40)
                                } else if let body = emailBody {
                                    EmailBodyView(content: body)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else {
                                    Text(email.snippet)
                                        .foregroundStyle(.secondary)
                                }

                                // Show attachments if email has them
                                if email.hasAttachments {
                                    Divider()
                                        .padding(.vertical, 8)
                                    EmailAttachmentsSection(emailId: email.id)
                                }
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .onChange(of: email.id) { _, _ in
                        // Scroll to top when email changes
                        withAnimation {
                            proxy.scrollTo("top", anchor: .top)
                        }
                    }
                }
                .frame(minWidth: 400, maxHeight: .infinity)
                .id(shouldShowThread ? thread?.threadId : email.id)
                .task(id: shouldShowThread ? thread?.threadId : email.id) {
                    actionMessage = nil
                    if shouldShowThread {
                        await loadThreadBodies()
                    } else {
                        await loadEmailBody(for: email)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select an email")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadThreadBodies() async {
        guard let thread = thread else { return }
        isLoading = true
        threadBodies = [:]

        // Initialize expanded state - latest message expanded by default
        if let latest = thread.messages.first {
            expandedMessages = [latest.id]
        }

        let gmail = GmailService.shared

        // Load all message bodies in parallel
        await withTaskGroup(of: (String, EmailBodyContent?).self) { group in
            for message in thread.messages {
                group.addTask {
                    do {
                        let fullMessage = try await gmail.getMessage(id: message.id, format: .full)
                        let (html, plainText) = fullMessage.extractBody()
                        return (message.id, EmailBodyContent(html: html, plainText: plainText))
                    } catch {
                        logger.error("Failed to load message \(message.id): \(error.localizedDescription)")
                        return (message.id, nil)
                    }
                }
            }

            for await (id, body) in group {
                if let body = body {
                    threadBodies[id] = body
                }
            }
        }

        // Mark unread messages as read
        let unreadMessages = thread.messages.filter { !$0.isRead }
        if !unreadMessages.isEmpty {
            let ids = unreadMessages.map(\.id)
            try? await gmail.markAsRead(ids: ids)
            try? await EmailStore.shared.markRead(ids: ids, isRead: true)

            // Notify parent about read status changes
            for message in unreadMessages {
                var updatedMessage = message
                updatedMessage.isRead = true
                updatedMessage.labelIds = message.labelIds.filter { $0 != "UNREAD" }
                onMarkRead?(updatedMessage)
            }
        }

        isLoading = false
    }

    private func loadEmailBody(for email: Email) async {
        isLoading = true
        emailBody = nil

        do {
            let gmail = GmailService.shared
            let message = try await gmail.getMessage(id: email.id, format: .full)
            let (html, plainText) = message.extractBody()
            emailBody = EmailBodyContent(html: html, plainText: plainText)

            // Mark as read if unread
            if !email.isRead {
                // Mark as read on Gmail
                try? await gmail.markAsRead(ids: [email.id])

                // Update DB via store - UI auto-updates via ValueObservation
                try? await EmailStore.shared.markRead(ids: [email.id], isRead: true)

                // Notify parent to update selectedEmail immediately
                var updatedEmail = email
                updatedEmail.isRead = true
                updatedEmail.labelIds = email.labelIds.filter { $0 != "UNREAD" }
                onMarkRead?(updatedEmail)
            }
        } catch {
            logger.error("Failed to load email body: \(error.localizedDescription)")
        }

        isLoading = false
    }

    private func archiveEmail(_ email: Email) async {
        isPerformingAction = true
        do {
            let gmail = GmailService.shared
            try await gmail.archiveMessages(ids: [email.id])

            // Update DB via store - UI auto-updates via ValueObservation
            try? await EmailStore.shared.archive(ids: [email.id])

            actionMessage = "Archived"
            onArchive?(email)
        } catch {
            actionMessage = "Failed to archive"
            logger.error("Archive error: \(error.localizedDescription)")
        }
        isPerformingAction = false
    }

    private func archiveAllFromSender(_ domain: String) async {
        isPerformingAction = true
        actionMessage = "Archiving all from \(domain)..."
        onArchiveAllFromSender?(domain)
        isPerformingAction = false
    }

    private func trashEmail(_ email: Email) async {
        isPerformingAction = true
        do {
            let gmail = GmailService.shared
            try await gmail.trashMessage(id: email.id)

            // Delete from DB via store - UI auto-updates via ValueObservation
            try? await EmailStore.shared.delete(id: email.id)

            actionMessage = "Moved to Trash"
            onTrash?(email)
        } catch {
            actionMessage = "Failed to trash"
            logger.error("Trash error: \(error.localizedDescription)")
        }
        isPerformingAction = false
    }

    private func toggleReadStatus(_ email: Email) async {
        isPerformingAction = true
        do {
            let gmail = GmailService.shared
            var updatedEmail = email

            if email.isRead {
                // Mark as unread
                try await gmail.markAsUnread(ids: [email.id])
                updatedEmail.isRead = false
                if !updatedEmail.labelIds.contains("UNREAD") {
                    updatedEmail.labelIds.append("UNREAD")
                }
                actionMessage = "Marked as unread"
            } else {
                // Mark as read
                try await gmail.markAsRead(ids: [email.id])
                updatedEmail.isRead = true
                updatedEmail.labelIds = email.labelIds.filter { $0 != "UNREAD" }
                actionMessage = "Marked as read"
            }

            // Update DB via store - UI auto-updates via ValueObservation
            try? await EmailStore.shared.markRead(ids: [email.id], isRead: updatedEmail.isRead)
            onMarkRead?(updatedEmail)
        } catch {
            actionMessage = "Failed to update"
            logger.error("Toggle read error: \(error.localizedDescription)")
        }
        isPerformingAction = false
    }
}

struct EmailActionBar: View {
    let email: Email
    let isPerformingAction: Bool
    let onArchive: () async -> Void
    let onArchiveAll: () async -> Void
    let onTrash: () async -> Void
    let onToggleRead: () async -> Void

    @State private var showArchiveAllConfirmation = false
    @State private var showTrashConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            // Archive button with keyboard shortcut
            AccessibleActionButton(
                label: "Archive",
                systemImage: "archivebox",
                isLoading: isPerformingAction
            ) {
                Task { await onArchive() }
            }
            .keyboardShortcut(AppKeyboardShortcuts.archive)
            .help("Archive this email (E)")

            // Archive all - requires confirmation
            AccessibleActionButton(
                label: "Archive All",
                systemImage: "archivebox.fill",
                isLoading: isPerformingAction
            ) {
                showArchiveAllConfirmation = true
            }
            .keyboardShortcut(AppKeyboardShortcuts.archiveAll)
            .help("Archive all from \(email.fromDomain) (Shift+E)")

            // Toggle read/unread
            AccessibleActionButton(
                label: email.isRead ? "Mark Unread" : "Mark Read",
                systemImage: email.isRead ? "envelope.badge" : "envelope.open",
                isLoading: isPerformingAction
            ) {
                Task { await onToggleRead() }
            }
            .keyboardShortcut(email.isRead ? AppKeyboardShortcuts.markUnread : AppKeyboardShortcuts.markRead)
            .help(email.isRead ? "Mark as unread (Shift+U)" : "Mark as read (Shift+R)")

            Spacer()

            // Trash - requires confirmation
            AccessibleActionButton(
                label: "Trash",
                systemImage: "trash",
                isDestructive: true,
                isLoading: isPerformingAction
            ) {
                showTrashConfirmation = true
            }
            .keyboardShortcut(AppKeyboardShortcuts.trash)
            .help("Move to trash (Delete)")

            if isPerformingAction {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 24, height: 24)
            }
        }
        .confirmationDialog(
            "Archive All from \(email.fromDomain)?",
            isPresented: $showArchiveAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Archive All", role: .destructive) {
                Task { await onArchiveAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will archive all emails from \(email.fromDomain). This action can be undone in Gmail.")
        }
        .confirmationDialog(
            "Move to Trash?",
            isPresented: $showTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await onTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This email will be moved to trash. You can recover it from Gmail's trash within 30 days.")
        }
    }
}

struct EmailDetailHeader: View {
    let email: Email

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(email.subject)
                .font(.title2)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(avatarInitial)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(emailAddress)
                        .font(.system(size: 13))
                        .foregroundStyle(AccessibleColors.secondaryText)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(email.date, style: .date)
                        .font(.system(size: 13))
                    Text(email.date, style: .time)
                        .font(.system(size: 13))
                        .foregroundStyle(AccessibleColors.secondaryText)
                }
            }

            if email.hasAttachments {
                Label("Has attachments", systemImage: "paperclip")
                    .font(.system(size: 13))
                    .foregroundStyle(AccessibleColors.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Email from \(displayName), \(emailAddress). Sent \(email.date.formatted(date: .long, time: .shortened))")
    }

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .indigo, .mint, .teal]
        let hash = abs(email.fromDomain.hashValue)
        return colors[hash % colors.count]
    }

    private var displayName: String {
        let from = email.from
        if let angleBracket = from.firstIndex(of: "<") {
            let name = from[..<angleBracket].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return email.fromDomain
    }

    private var emailAddress: String {
        let from = email.from
        if let start = from.firstIndex(of: "<"),
           let end = from.firstIndex(of: ">") {
            let emailStart = from.index(after: start)
            return String(from[emailStart..<end])
        }
        return from
    }

    private var avatarInitial: String {
        String(displayName.prefix(1).uppercased())
    }
}

struct EmailBodyView: View {
    let content: EmailBodyContent

    var body: some View {
        if let html = content.html {
            HTMLTextView(html: html)
        } else if let plainText = content.plainText {
            Text(plainText)
                .font(.body)
                .textSelection(.enabled)
        } else {
            Text("No content available")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Thread Conversation View

struct ThreadConversationView: View {
    let thread: EmailThread
    let messages: [Email]
    let threadBodies: [String: EmailBodyContent]
    @Binding var expandedMessages: Set<String>
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thread subject
            Text(thread.subject)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.bottom, 12)

            // Thread info
            HStack {
                Text("\(messages.count) messages in this conversation")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    if expandedMessages.count == messages.count {
                        // Collapse all except latest
                        if let latest = thread.messages.first {
                            expandedMessages = [latest.id]
                        }
                    } else {
                        // Expand all
                        expandedMessages = Set(messages.map(\.id))
                    }
                } label: {
                    Text(expandedMessages.count == messages.count ? "Collapse All" : "Expand All")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            .padding(.bottom, 16)

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading conversation...")
                    Spacer()
                }
                .padding(.top, 40)
            } else {
                // Messages list
                ForEach(messages) { message in
                    ThreadMessageRow(
                        message: message,
                        messageBody: threadBodies[message.id],
                        isExpanded: expandedMessages.contains(message.id),
                        isLatest: message.id == thread.messages.first?.id,
                        onToggle: {
                            if expandedMessages.contains(message.id) {
                                expandedMessages.remove(message.id)
                            } else {
                                expandedMessages.insert(message.id)
                            }
                        }
                    )

                    if message.id != messages.last?.id {
                        Divider()
                            .padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

struct ThreadMessageRow: View {
    let message: Email
    let messageBody: EmailBodyContent?
    let isExpanded: Bool
    let isLatest: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Collapsed header (always visible)
            Button(action: onToggle) {
                HStack(alignment: .top) {
                    Circle()
                        .fill(avatarColor)
                        .frame(width: 32, height: 32)
                        .overlay {
                            Text(avatarInitial)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(displayName)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)

                            if isLatest {
                                Text("Latest")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.blue.opacity(0.2))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                            }
                        }

                        if !isExpanded {
                            Text(message.snippet)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(message.date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(message.date, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Message body
                    if let content = messageBody {
                        EmailBodyView(content: content)
                    } else {
                        Text(message.snippet)
                            .foregroundStyle(.secondary)
                    }

                    // Show attachments if present
                    if message.hasAttachments {
                        Divider()
                        EmailAttachmentsSection(emailId: message.id)
                    }
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
    }

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .indigo, .mint, .teal]
        let hash = abs(message.fromDomain.hashValue)
        return colors[hash % colors.count]
    }

    private var displayName: String {
        let from = message.from
        if let angleBracket = from.firstIndex(of: "<") {
            let name = from[..<angleBracket].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return message.fromDomain
    }

    private var avatarInitial: String {
        String(displayName.prefix(1).uppercased())
    }
}

// MARK: - Self-sizing WKWebView for proper HTML email rendering

import WebKit

/// A self-sizing HTML view that calculates its own height after content loads
struct HTMLTextView: View {
    let html: String
    @State private var contentHeight: CGFloat = 400
    @State private var isLoaded = false

    var body: some View {
        SelfSizingWebView(html: html, contentHeight: $contentHeight, isLoaded: $isLoaded)
            .frame(height: contentHeight)
            .opacity(isLoaded ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.2), value: isLoaded)
    }
}

struct SelfSizingWebView: NSViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat
    @Binding var isLoaded: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let styledHTML = wrapHTMLWithStyles(html)
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SelfSizingWebView

        init(parent: SelfSizingWebView) {
            self.parent = parent
        }

        // Open links in default browser instead of in the webview
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Calculate content height after page loads
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, error in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            self?.parent.contentHeight = max(height + 20, 100) // Add padding, min 100
                        }
                        self?.parent.isLoaded = true
                    }
                }
            }
        }
    }

    private func wrapHTMLWithStyles(_ html: String) -> String {
        // Check if HTML already has proper structure
        let hasHTMLTag = html.lowercased().contains("<html")
        let hasBodyTag = html.lowercased().contains("<body")

        let css = """
        <style>
            * {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
                line-height: 1.5;
            }
            body {
                font-size: 14px;
                color: #1a1a1a;
                background-color: transparent;
                margin: 0;
                padding: 0;
                word-wrap: break-word;
                overflow-wrap: break-word;
            }
            img {
                max-width: 100%;
                height: auto;
            }
            a {
                color: #0066cc;
            }
            blockquote {
                border-left: 3px solid #ccc;
                margin: 10px 0;
                padding-left: 15px;
                color: #666;
            }
            pre, code {
                background-color: #f5f5f5;
                padding: 2px 5px;
                border-radius: 3px;
                font-family: 'SF Mono', Monaco, monospace;
                font-size: 13px;
            }
            table {
                border-collapse: collapse;
                max-width: 100%;
            }
            @media (prefers-color-scheme: dark) {
                body {
                    color: #e5e5e5;
                    background-color: transparent;
                }
                a {
                    color: #4da6ff;
                }
                blockquote {
                    border-left-color: #555;
                    color: #aaa;
                }
                pre, code {
                    background-color: #2a2a2a;
                }
            }
        </style>
        """

        if hasHTMLTag && hasBodyTag {
            // Inject CSS into existing head or after <html>
            if html.lowercased().contains("<head") {
                return html.replacingOccurrences(
                    of: "</head>",
                    with: "\(css)</head>",
                    options: .caseInsensitive
                )
            } else {
                return html.replacingOccurrences(
                    of: "<body",
                    with: "\(css)<body",
                    options: .caseInsensitive
                )
            }
        } else {
            // Wrap in full HTML structure
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                \(css)
            </head>
            <body>
                \(html)
            </body>
            </html>
            """
        }
    }
}

// MARK: - Email Attachments Section

/// Displays attachments for an email with download capability
struct EmailAttachmentsSection: View {
    let emailId: String
    @State private var attachments: [Attachment] = []
    @State private var isLoading = true
    @State private var downloadingIds: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading attachments...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !attachments.isEmpty {
                // Header
                HStack {
                    Image(systemName: "paperclip")
                    Text("\(attachments.count) Attachment\(attachments.count == 1 ? "" : "s")")
                        .fontWeight(.medium)
                    Spacer()
                    Text(totalSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)

                // Attachment list
                VStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        AttachmentRow(
                            attachment: attachment,
                            isDownloading: downloadingIds.contains(attachment.id),
                            onDownload: { downloadAttachment(attachment) }
                        )
                    }
                }
            }
        }
        .task {
            await loadAttachments()
        }
    }

    private var totalSize: String {
        let bytes = attachments.reduce(0) { $0 + Int64($1.sizeBytes) }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func loadAttachments() async {
        isLoading = true
        defer { isLoading = false }

        do {
            attachments = try await AttachmentStore.shared.fetchForEmail(emailId: emailId)
        } catch {
            logger.error("Failed to load attachments: \(error.localizedDescription)")
        }
    }

    private func downloadAttachment(_ attachment: Attachment) {
        guard !downloadingIds.contains(attachment.id) else { return }

        downloadingIds.insert(attachment.id)

        Task {
            defer {
                Task { @MainActor in
                    downloadingIds.remove(attachment.id)
                }
            }

            do {
                let gmail = GmailService.shared
                let data = try await gmail.getAttachment(
                    messageId: attachment.emailId,
                    attachmentId: extractGmailAttachmentId(from: attachment.id)
                )

                // Save to Downloads folder
                let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                var fileURL = downloadsURL.appendingPathComponent(attachment.filename)

                // Handle duplicate filenames
                var counter = 1
                while FileManager.default.fileExists(atPath: fileURL.path) {
                    let name = (attachment.filename as NSString).deletingPathExtension
                    let ext = (attachment.filename as NSString).pathExtension
                    fileURL = downloadsURL.appendingPathComponent("\(name) (\(counter)).\(ext)")
                    counter += 1
                }

                try data.write(to: fileURL)

                // Open in Finder
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])

                logger.info("Downloaded attachment: \(attachment.filename)")
            } catch {
                logger.error("Failed to download attachment: \(error.localizedDescription)")
            }
        }
    }

    private func extractGmailAttachmentId(from compositeId: String) -> String {
        // Our IDs are formatted as "messageId_attachmentId"
        let parts = compositeId.split(separator: "_")
        return parts.count >= 2 ? parts.dropFirst().joined(separator: "_") : compositeId
    }
}

/// Row view for a single attachment
struct AttachmentRow: View {
    let attachment: Attachment
    let isDownloading: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(categoryColor.opacity(0.1))
                    .frame(width: 36, height: 36)

                Image(systemName: attachment.category.systemImage)
                    .font(.system(size: 16))
                    .foregroundStyle(categoryColor)
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(attachment.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(attachment.category.displayName)
                        .font(.caption)
                        .foregroundStyle(categoryColor)
                }
            }

            Spacer()

            // Download button
            Button {
                onDownload()
            } label: {
                if isDownloading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18))
                }
            }
            .buttonStyle(.borderless)
            .disabled(isDownloading)
            .help("Download to Downloads folder")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var categoryColor: Color {
        switch attachment.category {
        case .invoice, .receipt: return .green
        case .ticket: return .orange
        case .contract, .statement: return .blue
        case .report, .document: return .purple
        case .image: return .pink
        case .spreadsheet: return .teal
        case .archive: return .brown
        case .other: return .gray
        @unknown default: return .gray
        }
    }
}

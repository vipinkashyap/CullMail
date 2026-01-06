//
//  LabelExplorerView.swift
//  CullMail
//
//  Explore Gmail labels and their real counts
//  Uses type-safe label system distinguishing mailboxes from state labels
//

import SwiftUI
import CullKit

/// Shows all Gmail labels with their actual message counts from the API
/// Labels are properly categorized:
/// - Mailboxes (INBOX, SENT, etc.) - where emails physically live
/// - State labels (UNREAD, STARRED, etc.) - properties/overlays on emails
/// - Categories (CATEGORY_*) - Gmail's automatic categorization
/// - User labels - custom folders
struct LabelExplorerView: View {
    @State private var labels: [GmailLabel] = []
    @State private var profile: GmailProfile?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredLabels: [GmailLabel] {
        if searchText.isEmpty {
            return labels
        }
        return labels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    // Group labels by semantic type using the new type-safe system
    private var mailboxLabels: [GmailLabel] {
        filteredLabels.filter { label in
            let parsed = GmailLabelType.parse(label.id)
            return parsed.isMailbox
        }
    }

    private var stateLabels: [GmailLabel] {
        filteredLabels.filter { label in
            let parsed = GmailLabelType.parse(label.id)
            return parsed.isState
        }
    }

    private var categoryLabels: [GmailLabel] {
        filteredLabels.filter { label in
            let parsed = GmailLabelType.parse(label.id)
            return parsed.isCategory
        }
    }

    private var userLabels: [GmailLabel] {
        filteredLabels.filter { label in
            let parsed = GmailLabelType.parse(label.id)
            // User labels are those with type "user" OR unknown system labels
            return parsed.isUserLabel || (label.type == "user")
        }
    }

    // Other system labels that don't fit the above categories
    private var otherSystemLabels: [GmailLabel] {
        filteredLabels.filter { label in
            let parsed = GmailLabelType.parse(label.id)
            return label.type == "system" && !parsed.isMailbox && !parsed.isState && !parsed.isCategory
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with totals
            if let profile = profile {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Gmail Account Overview")
                            .font(.headline)
                        Text(profile.emailAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing) {
                        HStack {
                            Text("Total Messages:")
                            Text("\(profile.messagesTotal ?? 0)")
                                .fontWeight(.bold)
                                .foregroundStyle(.blue)
                        }
                        HStack {
                            Text("Total Threads:")
                            Text("\(profile.threadsTotal ?? 0)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
                .padding()
                .background(.bar)
            }

            // Search
            TextField("Search labels...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 8)

            if isLoading {
                ProgressView("Loading labels...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { await loadLabels() }
                    }
                }
            } else {
                List {
                    // Mailboxes section - where emails physically live
                    Section {
                        ForEach(mailboxLabels) { label in
                            LabelRowView(label: label)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "tray.2")
                            Text("Mailboxes")
                        }
                    } footer: {
                        Text("Physical locations where emails are stored")
                            .font(.caption2)
                    }

                    // State labels section - properties/overlays on emails
                    if !stateLabels.isEmpty {
                        Section {
                            ForEach(stateLabels) { label in
                                StateLabelRowView(label: label)
                            }
                        } header: {
                            HStack {
                                Image(systemName: "tag")
                                Text("Email States")
                            }
                        } footer: {
                            Text("Properties that overlay on emails (an email can have multiple states)")
                                .font(.caption2)
                        }
                    }

                    // Category labels section - Gmail's automatic categorization
                    if !categoryLabels.isEmpty {
                        Section {
                            ForEach(categoryLabels) { label in
                                LabelRowView(label: label)
                            }
                        } header: {
                            HStack {
                                Image(systemName: "square.stack.3d.up")
                                Text("Gmail Categories")
                            }
                        } footer: {
                            Text("Automatic categorization by Gmail (if tabs are enabled)")
                                .font(.caption2)
                        }
                    }

                    // Other system labels
                    if !otherSystemLabels.isEmpty {
                        Section("Other System Labels") {
                            ForEach(otherSystemLabels) { label in
                                LabelRowView(label: label)
                            }
                        }
                    }

                    // User labels section
                    if !userLabels.isEmpty {
                        Section {
                            ForEach(userLabels) { label in
                                LabelRowView(label: label)
                            }
                        } header: {
                            HStack {
                                Image(systemName: "folder")
                                Text("Your Labels (\(userLabels.count))")
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await loadLabels() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task {
            if labels.isEmpty {
                await loadLabels()
            }
        }
    }

    private func loadLabels() async {
        isLoading = true
        errorMessage = nil

        do {
            let gmail = GmailService.shared

            // Fetch profile and labels in parallel
            async let profileTask = gmail.getProfile()
            async let labelsTask = gmail.getAllLabelsWithCounts()

            profile = try await profileTask
            labels = try await labelsTask

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

/// Row view for mailbox and category labels (folder-style display)
struct LabelRowView: View {
    let label: GmailLabel

    private var labelType: GmailLabelType {
        GmailLabelType.parse(label.id)
    }

    var body: some View {
        HStack {
            // Label name with icon from type-safe system
            HStack(spacing: 8) {
                Image(systemName: labelType.systemImage)
                    .foregroundStyle(labelType.color)
                    .frame(width: 20)

                VStack(alignment: .leading) {
                    Text(label.name)
                        .fontWeight(label.type == "system" ? .medium : .regular)

                    // Show semantic type for educational purposes
                    Text(semanticTypeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Counts - Messages and Threads
            LabelCountsView(label: label)
        }
        .padding(.vertical, 2)
    }

    private var semanticTypeLabel: String {
        switch labelType {
        case .mailbox: return "📁 Mailbox"
        case .category: return "📊 Category"
        case .user: return "🏷️ User Label"
        case .state: return "🔘 State"  // Shouldn't happen in this view
        }
    }
}

/// Row view for state labels (badge/indicator-style display)
/// State labels are displayed differently because they're properties, not locations
struct StateLabelRowView: View {
    let label: GmailLabel

    private var stateLabel: StateLabel? {
        StateLabel(rawValue: label.id)
    }

    var body: some View {
        HStack {
            // State indicator with badge-style display
            HStack(spacing: 10) {
                // Badge-style indicator instead of folder icon
                ZStack {
                    Circle()
                        .fill(stateLabel?.badgeColor.opacity(0.2) ?? Color.secondary.opacity(0.2))
                        .frame(width: 28, height: 28)

                    Image(systemName: stateLabel?.systemImage ?? "tag")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(stateLabel?.badgeColor ?? .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(label.name)
                        .fontWeight(.medium)

                    Text("🔘 State (overlay)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // For state labels, show what this means
            VStack(alignment: .trailing, spacing: 2) {
                if let total = label.messagesTotal {
                    Text("\(total.formatted()) emails")
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Text(stateExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var stateExplanation: String {
        switch stateLabel {
        case .unread:
            return "Not yet opened"
        case .starred:
            return "Bookmarked by you"
        case .important:
            return "Priority by Gmail/you"
        case nil:
            return "Property of emails"
        }
    }
}

/// Reusable counts display for labels
struct LabelCountsView: View {
    let label: GmailLabel

    var body: some View {
        HStack(spacing: 16) {
            // Messages
            VStack(alignment: .trailing, spacing: 2) {
                if let total = label.messagesTotal {
                    HStack(spacing: 4) {
                        Text("\(total)")
                            .fontWeight(.medium)
                        Text("msgs")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                if let unread = label.messagesUnread, unread > 0 {
                    HStack(spacing: 4) {
                        Text("\(unread)")
                            .foregroundStyle(.blue)
                        Text("unread")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
            }

            // Threads
            VStack(alignment: .trailing, spacing: 2) {
                if let total = label.threadsTotal {
                    HStack(spacing: 4) {
                        Text("\(total)")
                            .fontWeight(.medium)
                        Text("threads")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                if let unread = label.threadsUnread, unread > 0 {
                    HStack(spacing: 4) {
                        Text("\(unread)")
                            .foregroundStyle(.orange)
                        Text("unread")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
            }
        }
    }
}

#Preview {
    LabelExplorerView()
}

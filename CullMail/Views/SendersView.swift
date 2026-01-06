//
//  SendersView.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import SwiftUI
import CullKit

struct DomainGroup: Identifiable {
    let rootDomain: String
    let senders: [Sender]

    var id: String { rootDomain }

    var totalEmails: Int {
        senders.reduce(0) { $0 + $1.totalEmails }
    }

    var hasSubdomains: Bool {
        senders.count > 1 || (senders.first?.domain != rootDomain)
    }
}

struct SendersGridView: View {
    let senders: [Sender]
    @Binding var searchText: String
    let isLoading: Bool
    let onSelectSender: (String) -> Void
    let onSelectRootDomain: (String) -> Void
    let onArchiveAll: (String) -> Void  // For single domain
    let onArchiveAllFromRootDomain: (String) -> Void  // For root domain + subdomains

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 16)
    ]

    private var domainGroups: [DomainGroup] {
        var grouped: [String: [Sender]] = [:]

        for sender in senders {
            let rootDomain = DomainUtils.normalizeToRootDomain(sender.domain)
            grouped[rootDomain, default: []].append(sender)
        }

        return grouped.map { DomainGroup(rootDomain: $0.key, senders: $0.value) }
            .sorted { $0.totalEmails > $1.totalEmails }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Accessible search bar with proper touch targets
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(AccessibleColors.secondaryText)
                    .accessibilityHidden(true)
                TextField("Search senders...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .accessibilityLabel("Search senders")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(AccessibleColors.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .frame(width: AccessibilityConstants.minTouchTarget,
                           height: AccessibilityConstants.minTouchTarget)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: AccessibilityConstants.minTouchTarget)
            .background(AccessibleColors.mutedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding()

            if isLoading {
                Spacer()
                ProgressView("Loading senders...")
                Spacer()
            } else if senders.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(AccessibleColors.secondaryText)
                        .accessibilityHidden(true)
                    Text("No Senders")
                        .font(.title2)
                        .fontWeight(.medium)
                    Text("Sync your emails to see senders")
                        .font(.system(size: 15))
                        .foregroundStyle(AccessibleColors.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("No senders. Sync your emails to see senders.")
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(domainGroups) { group in
                            DomainGroupCard(
                                group: group,
                                onSelectSender: onSelectSender,
                                onSelectRootDomain: onSelectRootDomain,
                                onArchiveAll: onArchiveAll,
                                onArchiveAllFromRootDomain: onArchiveAllFromRootDomain
                            )
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

struct DomainGroupCard: View {
    let group: DomainGroup
    let onSelectSender: (String) -> Void
    let onSelectRootDomain: (String) -> Void
    let onArchiveAll: (String) -> Void  // For single domain
    let onArchiveAllFromRootDomain: (String) -> Void  // For root domain + subdomains

    @State private var isExpanded = false
    @State private var showArchiveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(String(group.rootDomain.prefix(1)).uppercased())
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.rootDomain)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("\(group.totalEmails) emails")
                            .font(.system(size: 13))
                            .foregroundStyle(AccessibleColors.secondaryText)

                        if group.hasSubdomains {
                            Text("•")
                                .foregroundStyle(AccessibleColors.secondaryText)
                            Text("\(group.senders.count) addresses")
                                .font(.system(size: 13))
                                .foregroundStyle(AccessibleColors.secondaryText)
                        }
                    }
                }

                Spacer()

                Text("\(group.totalEmails)")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(AccessibleColors.secondaryText)
                    .accessibilityLabel("\(group.totalEmails) total emails")
            }

            if group.hasSubdomains && isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.senders.sorted { $0.totalEmails > $1.totalEmails }) { sender in
                        SubdomainRow(
                            sender: sender,
                            onTap: { onSelectSender(sender.domain) }
                        )
                    }
                }
                .padding(.leading, 52)
            }

            HStack(spacing: 10) {
                if group.senders.count == 1 {
                    AccessibleActionButton(
                        label: "View",
                        systemImage: "envelope"
                    ) {
                        onSelectSender(group.senders[0].domain)
                    }
                } else {
                    AccessibleActionButton(
                        label: isExpanded ? "Collapse" : "Expand",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    }
                    .accessibilityHint(isExpanded ? "Hide email addresses" : "Show \(group.senders.count) email addresses")

                    AccessibleActionButton(
                        label: "View All",
                        systemImage: "envelope.open"
                    ) {
                        onSelectRootDomain(group.rootDomain)
                    }
                }

                AccessibleActionButton(
                    label: "Archive All",
                    systemImage: "archivebox"
                ) {
                    showArchiveConfirmation = true
                }
                .accessibilityHint("Archive all \(group.totalEmails) emails from \(group.rootDomain)")

                Spacer()
            }
        }
        .padding(16)
        .background(AccessibleColors.mutedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.rootDomain), \(group.totalEmails) emails\(group.hasSubdomains ? ", \(group.senders.count) addresses" : "")")
        .confirmationDialog(
            "Archive all from \(group.rootDomain)?",
            isPresented: $showArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Archive \(group.totalEmails) emails", role: .destructive) {
                // Use root domain archive if there are subdomains, otherwise single domain
                if group.hasSubdomains {
                    onArchiveAllFromRootDomain(group.rootDomain)
                } else {
                    onArchiveAll(group.senders[0].domain)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will archive all \(group.totalEmails) emails from \(group.rootDomain). You can undo this in Gmail.")
        }
    }

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .indigo, .mint, .teal]
        let hash = abs(group.rootDomain.hashValue)
        return colors[hash % colors.count]
    }
}

struct SubdomainRow: View {
    let sender: Sender
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 8) {
                Text(sender.domain)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(sender.totalEmails)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AccessibleColors.secondaryText)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(AccessibleColors.secondaryText)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(minHeight: AccessibilityConstants.minTouchTarget)
            .background(AccessibleColors.mutedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(sender.domain), \(sender.totalEmails) emails")
        .accessibilityHint("View emails from this address")
    }
}

struct StatBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(color)
        }
    }
}

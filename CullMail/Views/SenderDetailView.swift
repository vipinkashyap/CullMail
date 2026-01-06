//
//  SenderDetailView.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import SwiftUI
import CullKit

struct SenderDetailView: View {
    let domain: String
    let emails: [Email]
    let sender: Sender?
    @Binding var selectedEmail: Email?
    let onBack: () -> Void
    let onArchiveAll: () -> Void
    var onMarkAllRead: (() -> Void)?
    var onMarkAllUnread: (() -> Void)?

    private var unreadCount: Int {
        emails.filter { !$0.isRead }.count
    }

    private var readCount: Int {
        emails.filter { $0.isRead }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)

                Spacer()

                // Show actual count from loaded emails
                Text("\(emails.count) emails")
                    .foregroundStyle(.secondary)

                if let sender, sender.openedCount > 0 {
                    Text("•")
                        .foregroundStyle(.secondary)

                    Text("\(Int(sender.openRate * 100))% opened")
                        .foregroundStyle(sender.openRate > 0.5 ? .green : .orange)
                }

                Spacer()

                // Bulk actions menu
                Menu {
                    Button {
                        onArchiveAll()
                    } label: {
                        Label("Archive All", systemImage: "archivebox")
                    }

                    Divider()

                    Button {
                        onMarkAllRead?()
                    } label: {
                        Label("Mark All as Read (\(unreadCount))", systemImage: "envelope.open")
                    }
                    .disabled(unreadCount == 0)

                    Button {
                        onMarkAllUnread?()
                    } label: {
                        Label("Mark All as Unread (\(readCount))", systemImage: "envelope.badge")
                    }
                    .disabled(readCount == 0)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    onArchiveAll()
                } label: {
                    Label("Archive All", systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color.secondary.opacity(0.05))

            List(emails, selection: $selectedEmail) { email in
                EmailRowView(email: email)
                    .tag(email)
            }
        }
    }
}

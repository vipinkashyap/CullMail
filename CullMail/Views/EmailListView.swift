//
//  EmailListView.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/5/26.
//

import SwiftUI
import CullKit

struct EmailListView: View {
    let emails: [Email]
    @Binding var selectedEmail: Email?
    let emptyTitle: String
    let emptyMessage: String
    let emptyIcon: String
    var showThreadToggle: Bool = true

    @AppStorage("showAsThreads") private var showAsThreads = true
    @State private var selectedThread: EmailThread?

    private var threads: [EmailThread] {
        let grouped = Dictionary(grouping: emails) { $0.threadId }
        return grouped.map { threadId, messages in
            let sorted = messages.sorted { $0.date > $1.date }
            return EmailThread(
                threadId: threadId,
                messages: sorted,
                latestMessage: sorted.first!,
                hasUnread: sorted.contains { !$0.isRead }
            )
        }
        .sorted { $0.latestMessage.date > $1.latestMessage.date }
    }

    var body: some View {
        Group {
            if emails.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyIcon)
                } description: {
                    Text(emptyMessage)
                }
            } else if showAsThreads && showThreadToggle {
                // Thread view
                List(threads, selection: $selectedThread) { thread in
                    ThreadRowView(thread: thread)
                        .tag(thread)
                }
                .listStyle(.inset)
                .onChange(of: selectedThread) { _, newThread in
                    // When a thread is selected, select the latest message
                    selectedEmail = newThread?.latestMessage
                }
            } else {
                // Individual email view
                List(emails, selection: $selectedEmail) { email in
                    EmailRowView(email: email)
                        .tag(email)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if showThreadToggle && !emails.isEmpty {
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: $showAsThreads) {
                        Label(
                            showAsThreads ? "Threads" : "Messages",
                            systemImage: showAsThreads ? "bubble.left.and.bubble.right" : "envelope"
                        )
                    }
                    .toggleStyle(.button)
                    .help(showAsThreads ? "Showing conversations" : "Showing individual messages")
                }
            }
        }
    }
}

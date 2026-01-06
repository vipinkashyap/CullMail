//
//  GmailSearchView.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import SwiftUI
import CullKit
import os

private let logger = Logger(subsystem: "com.cull.mail", category: "search")

struct GmailSearchView: View {
    @Binding var selectedEmail: Email?

    @State private var searchQuery: String = ""
    @State private var searchResults: [Email] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var nextPageToken: String?
    @State private var isLoadingMore = false

    private let searchExamples = [
        ("Older than 1 year", "older_than:1y"),
        ("Has attachment", "has:attachment"),
        ("From newsletters", "from:newsletter OR from:noreply"),
        ("Invoices", "subject:invoice OR subject:receipt"),
        ("Unsubscribe emails", "unsubscribe"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search Gmail (e.g., from:amazon.com, older_than:1y)", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            Task { await performSearch() }
                        }

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            searchResults = []
                            hasSearched = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        Task { await performSearch() }
                    } label: {
                        Text("Search")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(searchQuery.isEmpty || isSearching)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(searchExamples, id: \.1) { example in
                            Button {
                                searchQuery = example.1
                                Task { await performSearch() }
                            } label: {
                                Text(example.0)
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding()

            Divider()

            if isSearching {
                Spacer()
                ProgressView("Searching Gmail...")
                Spacer()
            } else if !hasSearched {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Search Your Gmail")
                        .font(.title2)
                    Text("Search for older emails not yet synced locally.\nUse Gmail search syntax like from:, subject:, older_than:, has:attachment")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 400)
                }
                Spacer()
            } else if searchResults.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Results")
                        .font(.title2)
                    Text("Try a different search query")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(searchResults, selection: $selectedEmail) { email in
                    EmailRowView(email: email)
                        .tag(email)
                }

                if nextPageToken != nil {
                    HStack {
                        Spacer()
                        Button {
                            Task { await loadMore() }
                        } label: {
                            if isLoadingMore {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Text("Load More Results")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLoadingMore)
                        Spacer()
                    }
                    .padding()
                }
            }
        }
    }

    private func performSearch() async {
        guard !searchQuery.isEmpty else { return }

        isSearching = true
        hasSearched = true
        searchResults = []
        nextPageToken = nil

        do {
            let gmail = GmailService.shared
            let (emails, token) = try await gmail.searchMessages(query: searchQuery)
            searchResults = emails
            nextPageToken = token

            // Auto-save to local cache transparently
            if !emails.isEmpty {
                try? await EmailStore.shared.saveAll(emails)
                try? await SenderStore.shared.updateStats(for: emails)
            }
        } catch {
            logger.error("Search error: \(error.localizedDescription)")
        }

        isSearching = false
    }

    private func loadMore() async {
        guard let token = nextPageToken else { return }

        isLoadingMore = true

        do {
            let gmail = GmailService.shared
            let (emails, newToken) = try await gmail.searchMessages(
                query: searchQuery,
                pageToken: token
            )
            searchResults.append(contentsOf: emails)
            nextPageToken = newToken

            // Auto-save new results to local cache transparently
            if !emails.isEmpty {
                try? await EmailStore.shared.saveAll(emails)
                try? await SenderStore.shared.updateStats(for: emails)
            }
        } catch {
            logger.error("Load more error: \(error.localizedDescription)")
        }

        isLoadingMore = false
    }
}

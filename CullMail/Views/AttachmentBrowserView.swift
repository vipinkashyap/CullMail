//
//  AttachmentBrowserView.swift
//  CullMail
//
//  Browse and manage email attachments by category
//

import SwiftUI
import CullKit
import QuickLook
import os

private let logger = Logger(subsystem: "com.cull.mail", category: "attachmentBrowser")

struct AttachmentBrowserView: View {
    @ObservedObject private var attachmentStore = AttachmentStore.shared
    @ObservedObject private var emailStore = EmailStore.shared

    @State private var selectedCategory: AttachmentCategory?
    @State private var searchText = ""
    @State private var filteredAttachments: [Attachment] = []
    @State private var isLoading = false
    @State private var selectedAttachment: Attachment?
    @State private var showingQuickLook = false
    @State private var downloadingIds: Set<String> = []
    @State private var isBackfilling = false
    @State private var backfillProgress: (current: Int, total: Int)?
    @State private var previewURL: URL?
    @State private var previewingIds: Set<String> = []

    private var displayedAttachments: [Attachment] {
        if !searchText.isEmpty {
            return filteredAttachments
        }
        if let category = selectedCategory {
            return attachmentStore.attachments.filter { $0.category == category }
        }
        return attachmentStore.attachments
    }

    private var totalSize: String {
        let bytes = displayedAttachments.reduce(0) { $0 + Int64($1.sizeBytes) }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with stats
            headerView

            Divider()

            // Show backfill progress if running
            if isBackfilling {
                backfillProgressView
            }

            HStack(spacing: 0) {
                // Category sidebar
                categorySidebar
                    .frame(width: 200)

                Divider()

                // Main content
                if displayedAttachments.isEmpty {
                    emptyStateView
                } else {
                    attachmentGridView
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search attachments...")
        .onChange(of: searchText) { _, newValue in
            Task { await performSearch(newValue) }
        }
        .task {
            await startStore()
            // Auto-backfill if no attachments but emails have attachments
            await checkAndBackfillIfNeeded()
        }
    }

    private var backfillProgressView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.7)

            if let progress = backfillProgress {
                Text("Indexing attachments: \(progress.current)/\(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Checking for attachments...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Attachments")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("\(displayedAttachments.count) files • \(totalSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Filter info
            if let category = selectedCategory {
                HStack(spacing: 4) {
                    Image(systemName: category.systemImage)
                    Text(category.displayName)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.1))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
            }
        }
        .padding()
    }

    // MARK: - Category Sidebar

    private var categorySidebar: some View {
        List(selection: $selectedCategory) {
            Section {
                HStack {
                    Image(systemName: "tray.full")
                    Text("All Attachments")
                    Spacer()
                    Text("\(attachmentStore.attachments.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(nil as AttachmentCategory?)
            }

            Section("Categories") {
                ForEach(AttachmentCategory.allCases, id: \.self) { category in
                    let count = attachmentStore.categoryStats[category] ?? 0
                    if count > 0 {
                        HStack {
                            Image(systemName: category.systemImage)
                            Text(category.displayName)
                            Spacer()
                            Text("\(count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(category as AttachmentCategory?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Attachment Grid

    private var attachmentGridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)], spacing: 16) {
                ForEach(displayedAttachments) { attachment in
                    AttachmentCardView(
                        attachment: attachment,
                        isDownloading: downloadingIds.contains(attachment.id) || previewingIds.contains(attachment.id),
                        onDownload: { downloadAttachment(attachment) },
                        onQuickLook: { quickLookAttachment(attachment) }
                    )
                }
            }
            .padding()
        }
        .quickLookPreview($previewURL)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedCategory?.systemImage ?? "paperclip")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(emptyStateTitle)
                .font(.title3)
                .fontWeight(.medium)

            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyStateTitle: String {
        if !searchText.isEmpty {
            return "No Results"
        }
        if let category = selectedCategory {
            return "No \(category.displayName)s"
        }
        return "No Attachments"
    }

    private var emptyStateMessage: String {
        if !searchText.isEmpty {
            return "No attachments match \"\(searchText)\""
        }
        if selectedCategory != nil {
            return "Attachments in this category will appear here"
        }
        return "Email attachments will appear here after syncing"
    }

    // MARK: - Actions

    private func startStore() async {
        do {
            try attachmentStore.start()
        } catch {
            logger.error("Failed to start attachment store: \(error.localizedDescription)")
        }
    }

    private func checkAndBackfillIfNeeded() async {
        // Only backfill if we have no attachments
        guard attachmentStore.attachments.isEmpty else { return }

        isBackfilling = true
        defer { isBackfilling = false }

        do {
            let attachmentService = AttachmentSyncService.shared
            let count = try await attachmentService.backfillAttachmentsFromExistingEmails { current, total in
                Task { @MainActor in
                    backfillProgress = (current, total)
                }
            }
            if count > 0 {
                logger.info("Backfilled \(count) attachments")
            }
        } catch {
            logger.error("Backfill failed: \(error.localizedDescription)")
        }

        backfillProgress = nil
    }

    private func performSearch(_ query: String) async {
        guard !query.isEmpty else {
            filteredAttachments = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        // Simple filename search (FTS might not be set up)
        let lowercased = query.lowercased()
        filteredAttachments = attachmentStore.attachments.filter { attachment in
            attachment.filename.lowercased().contains(lowercased)
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
                let fileURL = try await downloadAttachmentToTemp(attachment)

                // Move to Downloads folder
                let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                var finalURL = downloadsURL.appendingPathComponent(attachment.filename)

                // Handle duplicate filenames
                var counter = 1
                while FileManager.default.fileExists(atPath: finalURL.path) {
                    let name = (attachment.filename as NSString).deletingPathExtension
                    let ext = (attachment.filename as NSString).pathExtension
                    finalURL = downloadsURL.appendingPathComponent("\(name) (\(counter)).\(ext)")
                    counter += 1
                }

                try FileManager.default.copyItem(at: fileURL, to: finalURL)

                // Open in Finder
                NSWorkspace.shared.activateFileViewerSelecting([finalURL])

                logger.info("Downloaded attachment: \(attachment.filename)")
            } catch {
                logger.error("Failed to download attachment: \(error.localizedDescription)")
            }
        }
    }

    private func quickLookAttachment(_ attachment: Attachment) {
        guard !previewingIds.contains(attachment.id) else { return }

        previewingIds.insert(attachment.id)

        Task {
            defer {
                Task { @MainActor in
                    previewingIds.remove(attachment.id)
                }
            }

            do {
                let fileURL = try await downloadAttachmentToTemp(attachment)

                await MainActor.run {
                    previewURL = fileURL
                }

                logger.info("Quick Look preview: \(attachment.filename)")
            } catch {
                logger.error("Failed to preview attachment: \(error.localizedDescription)")
            }
        }
    }

    /// Downloads attachment to a temporary location and returns the file URL
    private func downloadAttachmentToTemp(_ attachment: Attachment) async throws -> URL {
        let gmail = GmailService.shared

        // Extract the Gmail attachment ID from our composite ID (format: "messageId_attachmentId")
        let gmailAttachmentId = extractGmailAttachmentId(from: attachment.id)

        let data = try await gmail.getAttachment(
            messageId: attachment.emailId,
            attachmentId: gmailAttachmentId
        )

        // Save to temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CullMail", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileURL = tempDir.appendingPathComponent(attachment.filename)
        try data.write(to: fileURL)

        return fileURL
    }

    private func extractGmailAttachmentId(from compositeId: String) -> String {
        // Our IDs are formatted as "messageId_attachmentId"
        let parts = compositeId.split(separator: "_")
        return parts.count >= 2 ? parts.dropFirst().joined(separator: "_") : compositeId
    }
}

// MARK: - Attachment Card View

struct AttachmentCardView: View {
    let attachment: Attachment
    let isDownloading: Bool
    let onDownload: () -> Void
    let onQuickLook: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Icon area
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(categoryColor.opacity(0.1))

                Image(systemName: attachment.category.systemImage)
                    .font(.system(size: 32))
                    .foregroundStyle(categoryColor)
            }
            .frame(height: 80)

            // Info area
            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.filename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack {
                    Text(attachment.formattedSize)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(attachment.category.displayName)
                        .font(.caption2)
                        .foregroundStyle(categoryColor)
                }
            }
            .padding(8)

            // Action buttons (visible on hover)
            if isHovered || isDownloading {
                HStack(spacing: 12) {
                    Button {
                        onQuickLook()
                    } label: {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.borderless)
                    .help("Quick Look")
                    .disabled(isDownloading)

                    Button {
                        onDownload()
                    } label: {
                        if isDownloading {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Download to Downloads folder")
                    .disabled(isDownloading)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.1), radius: isHovered ? 8 : 4, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) {
            onDownload()
        }
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

#Preview {
    AttachmentBrowserView()
}

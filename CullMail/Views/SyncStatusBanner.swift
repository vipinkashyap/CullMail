//
//  SyncStatusBanner.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import SwiftUI

struct SyncStatusBanner: View {
    let isSyncing: Bool
    let syncedEmails: Int
    let totalEmails: Int
    let percentage: Double
    let estimatedTime: String?
    let progress: String
    var gmailTotal: Int = 0
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if isSyncing {
                ProgressView()
                    .scaleEffect(0.9)
                    .accessibilityLabel("Sync in progress")
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(statusTitle)
                        .font(.system(size: 15, weight: .semibold))

                    if syncedEmails > 0 {
                        HStack(spacing: 4) {
                            Text("\(syncedEmails.formatted())")
                                .fontWeight(.medium)
                            if gmailTotal > 0 {
                                Text("of \(gmailTotal.formatted())")
                                    .foregroundStyle(AccessibleColors.secondaryText)
                            }
                            Text("emails")
                                .foregroundStyle(AccessibleColors.secondaryText)
                        }
                        .font(.system(size: 13))
                    }
                }

                Text(statusSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(AccessibleColors.secondaryText)
            }

            Spacer()

            if syncedEmails > 0 && !progress.contains("complete") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(progress)
                        .font(.system(size: 13))
                        .foregroundStyle(AccessibleColors.secondaryText)
                }
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AccessibleColors.secondaryText)
                    .frame(width: AccessibilityConstants.minTouchTarget,
                           height: AccessibilityConstants.minTouchTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss sync status")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.blue.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    private var statusTitle: String {
        if progress.contains("Rate limited") {
            return "Rate limited by Gmail"
        } else if progress.contains("Error") {
            return "Sync paused"
        } else if isSyncing {
            return "Syncing emails..."
        } else if syncedEmails == 0 {
            return "Starting sync"
        } else {
            return "Sync paused"
        }
    }

    private var statusSubtitle: String {
        if progress.contains("Rate limited") {
            return "Gmail limits requests. Will retry automatically."
        } else if !isSyncing && syncedEmails > 0 {
            return "Syncs every 15 min while app is running."
        } else if syncedEmails == 0 {
            return "Large mailboxes may take hours. Syncs continue in background."
        } else {
            return "Syncs every 15 min while app is running."
        }
    }

    private var accessibilityDescription: String {
        var description = statusTitle
        if syncedEmails > 0 {
            description += ". \(syncedEmails) emails synced"
            if gmailTotal > 0 {
                description += " of \(gmailTotal) total"
            }
        }
        description += ". \(statusSubtitle)"
        return description
    }
}

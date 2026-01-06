//
//  OnboardingView.swift
//  CullMail
//
//  First-time user experience explaining the app
//

import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void
    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "envelope.badge.shield.half.filled",
            title: "Welcome to Cull Mail",
            subtitle: "Your email runs itself.\nYou just show up for what matters.",
            features: []
        ),
        OnboardingPage(
            icon: "person.2.circle",
            title: "Organized by Sender",
            subtitle: "See all your emails grouped by who sent them, not buried in folders.",
            features: [
                "View emails by domain (amazon.com, github.com, etc.)",
                "See how many emails each sender has sent you",
                "Bulk archive all emails from a sender with one click"
            ]
        ),
        OnboardingPage(
            icon: "arrow.triangle.2.circlepath",
            title: "Syncs in Background",
            subtitle: "Keep the app running and it syncs automatically.",
            features: [
                "Initial sync may take hours for large mailboxes",
                "Syncs every 15 minutes while app is open",
                "Gmail API limits how fast we can fetch emails",
                "Progress is saved - close and reopen anytime"
            ]
        ),
        OnboardingPage(
            icon: "lock.shield",
            title: "Privacy First",
            subtitle: "Your emails stay on your device.",
            features: [
                "All data stored locally on your Mac",
                "No email content is sent to any server",
                "We only connect to Gmail's official API",
                "Sign out anytime to remove all data"
            ]
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.automatic)

            // Navigation
            HStack {
                // Page indicators
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                // Buttons
                if currentPage < pages.count - 1 {
                    Button("Skip") {
                        onComplete()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button("Next") {
                        withAnimation {
                            currentPage += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(24)
        }
        .frame(width: 500, height: 450)
    }
}

struct OnboardingPage {
    let icon: String
    let title: String
    let subtitle: String
    let features: [String]
}

struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: page.icon)
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text(page.title)
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text(page.subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if !page.features.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(page.features, id: \.self) { feature in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.body)
                            Text(feature)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

#Preview {
    OnboardingView(onComplete: {})
}

//
//  AccessibilityHelpers.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/5/26.
//

import SwiftUI

// MARK: - Accessibility Constants

/// Design system constants for WCAG compliance
enum AccessibilityConstants {
    /// Minimum touch target size (WCAG 2.1 Level AAA recommends 44pt)
    static let minTouchTarget: CGFloat = 44

    /// Minimum font size for body text
    static let minBodyFontSize: CGFloat = 14

    /// Minimum font size for captions
    static let minCaptionFontSize: CGFloat = 12
}

// MARK: - Accessible Colors

/// Color palette with WCAG AA compliant contrast ratios
enum AccessibleColors {
    /// Secondary text with good contrast (4.5:1 ratio on white)
    static let secondaryText = Color.primary.opacity(0.65)

    /// Tertiary text for less important info
    static let tertiaryText = Color.primary.opacity(0.5)

    /// Muted background that's still visible
    static let mutedBackground = Color.secondary.opacity(0.12)

    /// Badge background with sufficient contrast
    static let badgeBackground = Color.secondary.opacity(0.2)

    /// Unread indicator color
    static let unreadIndicator = Color.blue

    /// Success feedback
    static let success = Color.green

    /// Warning/caution
    static let warning = Color.orange

    /// Destructive action
    static let destructive = Color.red
}

// MARK: - Accessible Button Styles

/// Button style ensuring minimum 44pt touch target
struct AccessibleButtonStyle: ButtonStyle {
    var isDestructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: AccessibilityConstants.minTouchTarget,
                   minHeight: AccessibilityConstants.minTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ?
                          Color.secondary.opacity(0.2) :
                          Color.secondary.opacity(0.1))
            )
            .foregroundStyle(isDestructive ? AccessibleColors.destructive : .primary)
            .contentShape(Rectangle())
    }
}

/// Toolbar button style with proper sizing
struct AccessibleToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8)
            .frame(minWidth: AccessibilityConstants.minTouchTarget,
                   minHeight: AccessibilityConstants.minTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color.secondary.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - View Modifiers

/// Ensures minimum touch target size
struct MinTouchTargetModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minWidth: AccessibilityConstants.minTouchTarget,
                   minHeight: AccessibilityConstants.minTouchTarget)
            .contentShape(Rectangle())
    }
}

/// Adds proper focus ring for keyboard navigation
struct FocusRingModifier: ViewModifier {
    @Environment(\.isFocused) var isFocused
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.accentColor, lineWidth: isFocused ? 2 : 0)
            )
    }
}

extension View {
    /// Ensures minimum 44pt touch target
    func accessibleTouchTarget() -> some View {
        modifier(MinTouchTargetModifier())
    }

    /// Adds visible focus ring for keyboard navigation
    func accessibleFocusRing(cornerRadius: CGFloat = 8) -> some View {
        modifier(FocusRingModifier(cornerRadius: cornerRadius))
    }

    /// Adds accessibility label with hint
    func accessibleAction(_ label: String, hint: String? = nil) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
    }
}

// MARK: - Unread Indicator

/// Accessible unread indicator with both color AND shape
struct UnreadIndicator: View {
    let isUnread: Bool
    var size: CGFloat = 10

    var body: some View {
        Group {
            if isUnread {
                // Filled circle for unread - visible to colorblind users
                Circle()
                    .fill(AccessibleColors.unreadIndicator)
                    .frame(width: size, height: size)
            } else {
                // Empty circle outline for read - shape differentiates state
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityLabel(isUnread ? "Unread" : "Read")
    }
}

// MARK: - Accessible Badge

/// Badge with proper contrast and sizing
struct AccessibleBadge: View {
    let count: Int
    var isHighlighted: Bool = false
    var showZero: Bool = false

    var body: some View {
        if count > 0 || showZero {
            Text("\(count)")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minWidth: 24, minHeight: 24)
                .background(
                    Capsule()
                        .fill(isHighlighted ? Color.blue : AccessibleColors.badgeBackground)
                )
                .foregroundStyle(isHighlighted ? .white : .primary)
                .accessibilityLabel("\(count) items")
        }
    }
}

// MARK: - Confirmation Dialog Helper

struct ConfirmationDialogConfig: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmLabel: String
    let isDestructive: Bool
    let action: () -> Void
}

// MARK: - Accessible Action Button

/// Action button with minimum touch target and clear labeling
struct AccessibleActionButton: View {
    let label: String
    let systemImage: String
    var isDestructive: Bool = false
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 14))
                }
                Text(label)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: AccessibilityConstants.minTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDestructive ?
                          Color.red.opacity(0.1) :
                          Color.secondary.opacity(0.1))
            )
            .foregroundStyle(isDestructive ? .red : .primary)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(label)
        .accessibilityHint(isDestructive ? "This action cannot be undone" : "")
    }
}

// MARK: - Accessible Icon Button

/// Icon-only button with proper touch target and accessibility
struct AccessibleIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .frame(width: AccessibilityConstants.minTouchTarget,
                       height: AccessibilityConstants.minTouchTarget)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                )
                .foregroundStyle(isDestructive ? .red : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Keyboard Shortcut Labels

/// Standard keyboard shortcuts for the app
enum AppKeyboardShortcuts {
    static let archive = KeyboardShortcut("e", modifiers: [])
    static let archiveAll = KeyboardShortcut("e", modifiers: [.shift])
    static let trash = KeyboardShortcut(.delete, modifiers: [])
    static let markRead = KeyboardShortcut("r", modifiers: [.shift])
    static let markUnread = KeyboardShortcut("u", modifiers: [.shift])
    static let sync = KeyboardShortcut("r", modifiers: [.command])
    static let search = KeyboardShortcut("f", modifiers: [.command])
}

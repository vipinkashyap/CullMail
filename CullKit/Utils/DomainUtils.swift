//
//  DomainUtils.swift
//  CullKit
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

public struct DomainUtils {

    // MARK: - Email Parsing

    /// Extracts the email address from a "From" header value
    /// Handles formats like: "John Doe <john@example.com>" or "john@example.com"
    public static func extractEmail(from headerValue: String) -> String? {
        let trimmed = headerValue.trimmingCharacters(in: .whitespaces)

        // Try to extract from angle brackets: "Name <email>"
        if let start = trimmed.firstIndex(of: "<"),
           let end = trimmed.firstIndex(of: ">"),
           start < end {
            let emailStart = trimmed.index(after: start)
            return String(trimmed[emailStart..<end]).trimmingCharacters(in: .whitespaces)
        }

        // If no angle brackets, assume the whole thing is an email (if it contains @)
        if trimmed.contains("@") {
            return trimmed
        }

        return nil
    }

    /// Extracts the domain from an email address
    public static func extractDomain(from email: String) -> String? {
        let parts = email.split(separator: "@")
        guard parts.count == 2 else { return nil }
        return String(parts[1]).lowercased()
    }

    /// Extracts the domain directly from a "From" header value
    public static func extractDomainFromHeader(_ headerValue: String) -> String {
        guard let email = extractEmail(from: headerValue),
              let domain = extractDomain(from: email) else {
            return ""
        }
        return domain
    }

    // MARK: - Domain Normalization

    /// Normalizes a domain by extracting the root domain
    /// e.g., "mail.google.com" -> "google.com", "newsletter.company.co.uk" -> "company.co.uk"
    public static func normalizeToRootDomain(_ domain: String) -> String {
        let lowercased = domain.lowercased()
        let parts = lowercased.split(separator: ".")

        guard parts.count >= 2 else { return lowercased }

        // Handle known multi-part TLDs
        let multiPartTLDs = ["co.uk", "com.au", "co.nz", "co.jp", "com.br", "co.in", "org.uk", "net.au"]

        if parts.count >= 3 {
            let lastTwo = "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
            if multiPartTLDs.contains(lastTwo) {
                // Return domain + multi-part TLD (e.g., "company.co.uk")
                if parts.count >= 3 {
                    return "\(parts[parts.count - 3]).\(lastTwo)"
                }
            }
        }

        // Standard case: return last two parts (e.g., "google.com")
        return "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
    }

    /// Groups subdomains under their root domain
    /// e.g., ["mail.google.com", "drive.google.com"] -> "google.com"
    public static func groupByRootDomain(_ domains: [String]) -> [String: [String]] {
        var grouped: [String: [String]] = [:]

        for domain in domains {
            let root = normalizeToRootDomain(domain)
            grouped[root, default: []].append(domain)
        }

        return grouped
    }

    // MARK: - Display Name Extraction

    /// Extracts the display name from a "From" header value
    /// e.g., "John Doe <john@example.com>" -> "John Doe"
    public static func extractDisplayName(from headerValue: String) -> String? {
        let trimmed = headerValue.trimmingCharacters(in: .whitespaces)

        // Check for angle bracket format
        if let angleBracketIndex = trimmed.firstIndex(of: "<") {
            let namePart = trimmed[..<angleBracketIndex].trimmingCharacters(in: .whitespaces)
            // Remove surrounding quotes if present
            let cleaned = namePart.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return cleaned.isEmpty ? nil : cleaned
        }

        return nil
    }

    /// Returns a friendly display name for an email sender
    /// Falls back to domain if no name is available
    public static func friendlyName(from headerValue: String) -> String {
        if let displayName = extractDisplayName(from: headerValue), !displayName.isEmpty {
            return displayName
        }

        if let email = extractEmail(from: headerValue) {
            // Use the local part of the email (before @)
            if let atIndex = email.firstIndex(of: "@") {
                return String(email[..<atIndex])
            }
            return email
        }

        return headerValue
    }

    // MARK: - Domain Classification Helpers

    /// Checks if a domain is likely a personal email provider
    public static func isPersonalEmailProvider(_ domain: String) -> Bool {
        let personalProviders = [
            "gmail.com", "googlemail.com",
            "yahoo.com", "yahoo.co.uk", "yahoo.co.in",
            "hotmail.com", "outlook.com", "live.com", "msn.com",
            "icloud.com", "me.com", "mac.com",
            "aol.com",
            "protonmail.com", "proton.me",
            "fastmail.com", "fastmail.fm",
            "zoho.com",
            "yandex.com", "yandex.ru",
            "mail.com", "email.com",
            "gmx.com", "gmx.net"
        ]

        let normalized = normalizeToRootDomain(domain)
        return personalProviders.contains(normalized) || personalProviders.contains(domain)
    }

    /// Checks if a domain is likely automated/no-reply
    public static func isNoReplyAddress(_ email: String) -> Bool {
        let lowercased = email.lowercased()
        let noReplyPatterns = [
            "noreply", "no-reply", "no_reply",
            "donotreply", "do-not-reply", "do_not_reply",
            "mailer-daemon", "postmaster",
            "bounce", "notifications", "notify",
            "automated", "auto-reply", "autoreply"
        ]

        return noReplyPatterns.contains { lowercased.contains($0) }
    }

    /// Checks if a domain is likely a bulk sender (newsletters, marketing)
    public static func isBulkSenderDomain(_ domain: String) -> Bool {
        let bulkSenderDomains = [
            // Email marketing platforms
            "mailchimp.com", "sendgrid.net", "sendgrid.com",
            "constantcontact.com", "mailgun.org", "mailgun.com",
            "amazonses.com", "postmarkapp.com", "sparkpostmail.com",
            "mandrillapp.com", "sendinblue.com", "klaviyo.com",
            "hubspot.com", "hubspotemail.net", "marketo.com",
            "exacttarget.com", "salesforce.com",
            // Newsletter platforms
            "substack.com", "beehiiv.com", "buttondown.email",
            "convertkit.com", "ghost.io", "revue.co",
            // Transactional
            "transmail.net", "cmail19.com", "cmail20.com",
            "rsgsv.net", "list-manage.com"
        ]

        let normalized = normalizeToRootDomain(domain)
        return bulkSenderDomains.contains(normalized) || bulkSenderDomains.contains(domain)
    }

    // MARK: - HTML Entity Decoding

    /// Decodes HTML entities in a string using NSAttributedString
    /// Handles all standard HTML entities including named, decimal, and hex
    public static func decodeHTMLEntities(_ string: String) -> String {
        // Quick check - if no entities, return as-is
        guard string.contains("&") else { return string }

        // Use NSAttributedString with HTML to decode entities properly
        guard let data = string.data(using: .utf8),
              let attributedString = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else {
            return string
        }

        return attributedString.string
    }
}

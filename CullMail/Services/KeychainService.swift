//
//  KeychainService.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
import Security
import os

/// KeychainService provides secure storage for OAuth tokens
/// Note: This is NOT an actor because Security framework calls are already thread-safe
/// and using an actor causes deadlocks when called from @MainActor context during app startup
public final class KeychainService: @unchecked Sendable {
    public static let shared = KeychainService()

    private let logger = Logger(subsystem: "com.cull.mail", category: "keychain")
    private let service = "com.mrowl.CullMail"

    private init() {}

    // MARK: - Token Keys

    private enum Key {
        static let accessToken = "gmail_access_token"
        static let refreshToken = "gmail_refresh_token"
        static let tokenExpiry = "gmail_token_expiry"
    }

    // MARK: - OAuth Tokens

    public func saveTokens(accessToken: String, refreshToken: String, expiresIn: Int) throws {
        let expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))

        try save(key: Key.accessToken, value: accessToken)
        try save(key: Key.refreshToken, value: refreshToken)
        try save(key: Key.tokenExpiry, value: ISO8601DateFormatter().string(from: expiryDate))

        logger.info("Saved OAuth tokens, expires at \(expiryDate)")
    }

    public func getAccessToken() throws -> String? {
        try get(key: Key.accessToken)
    }

    public func getRefreshToken() throws -> String? {
        try get(key: Key.refreshToken)
    }

    public func getTokenExpiry() throws -> Date? {
        guard let expiryString = try get(key: Key.tokenExpiry) else { return nil }
        return ISO8601DateFormatter().date(from: expiryString)
    }

    public func isTokenExpired() throws -> Bool {
        guard let expiry = try getTokenExpiry() else { return true }
        // Consider expired if less than 5 minutes remaining
        return expiry.timeIntervalSinceNow < 300
    }

    public func clearTokens() throws {
        try delete(key: Key.accessToken)
        try delete(key: Key.refreshToken)
        try delete(key: Key.tokenExpiry)
        logger.info("Cleared all OAuth tokens")
    }

    // MARK: - Generic Keychain Operations

    private func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete existing item first
        try? delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Keychain save failed for \(key): \(status)")
            throw KeychainError.saveFailed(status)
        }
    }

    private func get(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            logger.error("Keychain get failed for \(key): \(status)")
            throw KeychainError.getFailed(status)
        }

        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }

        return value
    }

    private func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Keychain delete failed for \(key): \(status)")
            throw KeychainError.deleteFailed(status)
        }
    }
}

// MARK: - Errors

public enum KeychainError: Error, LocalizedError {
    case encodingFailed
    case decodingFailed
    case saveFailed(OSStatus)
    case getFailed(OSStatus)
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode value for keychain"
        case .decodingFailed:
            return "Failed to decode value from keychain"
        case .saveFailed(let status):
            return "Keychain save failed with status: \(status)"
        case .getFailed(let status):
            return "Keychain get failed with status: \(status)"
        case .deleteFailed(let status):
            return "Keychain delete failed with status: \(status)"
        }
    }
}

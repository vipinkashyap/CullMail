//
//  AuthService.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import Foundation
import AuthenticationServices
import CryptoKit
import os
import Observation

// MARK: - Auth State

/// Observable authentication state using Swift's @Observable macro
/// This provides automatic UI updates without the complexity of @MainActor isolation
@Observable
@MainActor
public final class AuthState {
    public static let shared = AuthState()

    // MARK: - Observable State

    public private(set) var isAuthenticated = false
    public private(set) var isAuthenticating = false
    public private(set) var isCheckingAuth = true
    public private(set) var userEmail: String?
    public private(set) var error: AuthError?

    private init() {}

    // MARK: - State Mutations (only called from AuthService)

    func setAuthenticated(_ value: Bool) {
        isAuthenticated = value
    }

    func setAuthenticating(_ value: Bool) {
        isAuthenticating = value
    }

    func setCheckingAuth(_ value: Bool) {
        isCheckingAuth = value
    }

    func setUserEmail(_ value: String?) {
        userEmail = value
    }

    func setError(_ value: AuthError?) {
        error = value
    }
}

// MARK: - Auth Service

/// Handles all authentication logic - OAuth flow, token management, etc.
/// Separated from AuthState to keep business logic and UI state distinct
public final class AuthService: NSObject, @unchecked Sendable {
    public static let shared = AuthService()

    // MARK: - Dependencies

    private let state: AuthState
    private let keychain: KeychainService
    private let logger = Logger(subsystem: "com.cull.mail", category: "auth")

    // MARK: - Private State

    private var authSession: ASWebAuthenticationSession?
    private var codeVerifier: String?

    // MARK: - OAuth Configuration

    private var clientId: String { Secrets.googleClientId }
    private var clientSecret: String { Secrets.googleClientSecret }
    private var redirectUri: String {
        let clientNumber = clientId.components(separatedBy: "-").first ?? ""
        return "com.googleusercontent.apps.\(clientNumber):/oauth2callback"
    }
    private var callbackScheme: String {
        let clientNumber = clientId.components(separatedBy: "-").first ?? ""
        return "com.googleusercontent.apps.\(clientNumber)"
    }

    private let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenEndpoint = "https://oauth2.googleapis.com/token"

    private let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.labels",
        "https://www.googleapis.com/auth/drive.file",
        "email",
        "profile"
    ]

    // MARK: - Initialization

    private override init() {
        self.state = AuthState.shared
        self.keychain = KeychainService.shared
        super.init()
    }

    // For testing with dependency injection
    init(state: AuthState, keychain: KeychainService) {
        self.state = state
        self.keychain = keychain
        super.init()
    }

    // MARK: - Public Methods

    @MainActor
    public func checkAuthStatus() async {
        logger.info("Checking auth status...")

        defer {
            state.setCheckingAuth(false)
            logger.info("Auth check complete. isAuthenticated=\(self.state.isAuthenticated)")
        }

        // Run keychain access in background to avoid blocking UI
        let tokenResult: String? = await Task.detached { [keychain] in
            try? keychain.getAccessToken()
        }.value

        guard tokenResult != nil else {
            logger.info("No access token found")
            state.setAuthenticated(false)
            return
        }

        // Check expiry in background
        let isExpired = await Task.detached { [keychain] in
            (try? keychain.isTokenExpired()) ?? true
        }.value

        if isExpired {
            logger.info("Token expired, attempting refresh...")
            do {
                try await refreshAccessToken()
                state.setAuthenticated(true)
            } catch {
                logger.error("Token refresh failed: \(error.localizedDescription)")
                state.setAuthenticated(false)
            }
        } else {
            logger.info("Token valid")
            state.setAuthenticated(true)
        }
    }

    @MainActor
    public func signIn() async throws {
        guard !state.isAuthenticating else { return }

        state.setAuthenticating(true)
        state.setError(nil)

        defer { state.setAuthenticating(false) }

        // Generate PKCE code verifier and challenge
        let verifier = generateCodeVerifier()
        self.codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        // Build authorization URL with PKCE
        guard let authURL = buildAuthorizationURL(codeChallenge: challenge) else {
            throw AuthError.invalidConfiguration
        }

        logger.info("Starting OAuth flow with PKCE")

        // Start web authentication session
        let callbackURL = try await startAuthSession(url: authURL)

        // Extract authorization code from callback
        guard let code = extractAuthorizationCode(from: callbackURL) else {
            throw AuthError.noAuthorizationCode
        }

        // Exchange code for tokens with PKCE verifier
        try await exchangeCodeForTokens(code: code, codeVerifier: verifier)

        state.setAuthenticated(true)
        logger.info("Sign in successful")
    }

    @MainActor
    public func signOut() async throws {
        try keychain.clearTokens()
        state.setAuthenticated(false)
        state.setUserEmail(nil)
        logger.info("Signed out")
    }

    public func getValidAccessToken() async throws -> String {
        // Check if we need to refresh (run in background)
        let needsRefresh = await Task.detached { [keychain] in
            (try? keychain.isTokenExpired()) ?? true
        }.value

        if needsRefresh {
            try await refreshAccessToken()
        }

        guard let token = try keychain.getAccessToken() else {
            throw AuthError.notAuthenticated
        }

        return token
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Private Methods

    private func buildAuthorizationURL(codeChallenge: String) -> URL? {
        var components = URLComponents(string: authorizationEndpoint)

        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        return components?.url
    }

    @MainActor
    private func startAuthSession(url: URL) async throws -> URL {
        logger.info("Starting auth session...")

        // Small delay to ensure window is ready
        try? await Task.sleep(for: .milliseconds(100))

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: self.callbackScheme
            ) { callbackURL, error in
                if let error = error {
                    self.logger.error("Auth session error: \(error.localizedDescription)")
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: AuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: AuthError.authSessionFailed(error))
                    }
                    return
                }

                guard let callbackURL = callbackURL else {
                    continuation.resume(throwing: AuthError.noCallbackURL)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false

            self.authSession = session

            if !session.start() {
                self.logger.error("Failed to start auth session")
                continuation.resume(throwing: AuthError.sessionStartFailed)
            }
        }
    }

    private func extractAuthorizationCode(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first { $0.name == "code" }?.value
    }

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectUri
        ]

        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            logger.error("Token exchange failed")
            throw AuthError.tokenExchangeFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        try keychain.saveTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? "",
            expiresIn: tokenResponse.expiresIn
        )

        logger.info("Tokens saved successfully")
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken = try keychain.getRefreshToken(),
              !refreshToken.isEmpty else {
            throw AuthError.noRefreshToken
        }

        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]

        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            logger.error("Token refresh failed")
            try keychain.clearTokens()
            await MainActor.run { state.setAuthenticated(false) }
            throw AuthError.tokenRefreshFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        try keychain.saveTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? refreshToken,
            expiresIn: tokenResponse.expiresIn
        )

        logger.info("Access token refreshed")
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    @MainActor
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let keyWindow = NSApp.keyWindow {
            return keyWindow
        }

        for window in NSApp.windows where window.isVisible {
            return window
        }

        return NSApp.windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - Token Response

private struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - Errors

public enum AuthError: Error, LocalizedError {
    case invalidConfiguration
    case userCancelled
    case authSessionFailed(Error)
    case noCallbackURL
    case noAuthorizationCode
    case sessionStartFailed
    case tokenExchangeFailed
    case tokenRefreshFailed
    case noRefreshToken
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Invalid OAuth configuration"
        case .userCancelled:
            return "Sign in was cancelled"
        case .authSessionFailed(let error):
            return "Authentication failed: \(error.localizedDescription)"
        case .noCallbackURL:
            return "No callback URL received"
        case .noAuthorizationCode:
            return "No authorization code in callback"
        case .sessionStartFailed:
            return "Failed to start authentication session"
        case .tokenExchangeFailed:
            return "Failed to exchange code for tokens"
        case .tokenRefreshFailed:
            return "Failed to refresh access token"
        case .noRefreshToken:
            return "No refresh token available"
        case .notAuthenticated:
            return "User is not authenticated"
        }
    }
}

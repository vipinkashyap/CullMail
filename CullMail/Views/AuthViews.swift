//
//  AuthViews.swift
//  CullMail
//
//  Created by Vipin Kumar Kashyap on 1/4/26.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.cull.mail", category: "auth")

struct CheckingAuthView: View {
    var body: some View {
        VStack {
            ProgressView()
            Text("Checking authentication...")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

struct SignInView: View {
    let authService: AuthService
    @State private var authState = AuthState.shared
    @State private var signInError: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Cull Mail")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Your email runs itself.\nYou just show up for what matters.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                signInError = nil
                Task {
                    do {
                        try await authService.signIn()
                    } catch {
                        signInError = error.localizedDescription
                        logger.error("Sign in error: \(error.localizedDescription)")
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "envelope.fill")
                    Text("Sign in with Google")
                }
                .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .disabled(authState.isAuthenticating)

            if authState.isAuthenticating {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Opening browser...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = signInError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
            }

            if let error = authState.error {
                Text(error.localizedDescription)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 300)
    }
}

//
//  BackgroundSyncScheduler.swift
//  CullMail
//
//  Schedules background sync using NSBackgroundActivityScheduler
//  This works within the sandboxed app without needing a separate daemon
//

import Foundation
import os

@MainActor
class BackgroundSyncScheduler {
    static let shared = BackgroundSyncScheduler()

    private let logger = Logger(subsystem: "com.cull.mail", category: "background")
    private var activity: NSBackgroundActivityScheduler?
    private var isRunning = false

    private init() {}

    /// Start background sync scheduling
    func start() {
        guard activity == nil else {
            logger.info("Background scheduler already running")
            return
        }

        logger.info("Starting background sync scheduler")

        let scheduler = NSBackgroundActivityScheduler(identifier: "com.cull.mail.sync")
        scheduler.repeats = true
        scheduler.interval = 15 * 60  // 15 minutes
        scheduler.qualityOfService = .utility

        scheduler.schedule { [weak self] completion in
            guard let self else {
                completion(.finished)
                return
            }

            Task { @MainActor in
                await self.performBackgroundSync()
                completion(.finished)
            }
        }

        self.activity = scheduler
        logger.info("Background sync scheduled every 15 minutes")
    }

    /// Stop background sync scheduling
    func stop() {
        activity?.invalidate()
        activity = nil
        logger.info("Background sync scheduler stopped")
    }

    private func performBackgroundSync() async {
        guard !isRunning else {
            logger.info("Sync already in progress, skipping")
            return
        }

        isRunning = true
        logger.info("Background sync starting")

        do {
            let syncService = SyncService.shared

            // Run a single sync session
            let result = try await syncService.sync { progress in
                switch progress {
                case .fullSyncComplete(let count):
                    self.logger.info("Background sync: \(count) emails")
                case .complete(let added, let updated, let deleted):
                    self.logger.info("Background sync: +\(added) ~\(updated) -\(deleted)")
                case .error(let message):
                    self.logger.error("Background sync error: \(message)")
                default:
                    break
                }
            }

            switch result {
            case .success(let added, let updated, let deleted):
                logger.info("Background sync complete: +\(added) ~\(updated) -\(deleted)")
                await sendNotificationIfNeeded(added: added)
            case .fullSync(let count):
                logger.info("Background sync session: \(count) emails")
            case .noChanges:
                logger.info("Background sync: no changes")
            case .error(let error):
                logger.error("Background sync failed: \(error.localizedDescription)")
            }

        } catch {
            logger.error("Background sync error: \(error.localizedDescription)")
        }

        isRunning = false
    }

    private func sendNotificationIfNeeded(added: Int) async {
        guard added > 0 else { return }

        // Post notification for UI to refresh
        NotificationCenter.default.post(
            name: .backgroundSyncCompleted,
            object: nil,
            userInfo: ["added": added]
        )
    }
}

extension Notification.Name {
    static let backgroundSyncCompleted = Notification.Name("backgroundSyncCompleted")
}

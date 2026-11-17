#if os(macOS)
    import Foundation
    import WorktimeApplication

    /// Only instantiate from the owning, packaged app. SwiftPM CLI runs do not have a notification identity.
    @MainActor
    final class DesktopReminderCoordinator {
        private let delivery = MacReminderDelivery()
        private lazy var sync = ReminderSync(delivery: delivery)

        static var supported: Bool {
            Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
        }

        func enable() async throws -> Bool {
            try await delivery.requestAuthorization()
        }

        func reconcile(latest: () throws -> ReminderSyncState?, now: () throws -> Int64) async throws
            -> ReminderSyncResult
        {
            try await sync.reconcile(latest: latest, now: now)
        }
    }
#endif

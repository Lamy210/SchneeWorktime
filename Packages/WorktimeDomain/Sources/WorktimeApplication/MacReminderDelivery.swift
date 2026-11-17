#if os(macOS)
    import Foundation
    import UserNotifications
    import WorktimeDomain

    @MainActor
    public final class MacReminderDelivery: ReminderDelivery {
        private let center: UNUserNotificationCenter

        public init() {
            center = .current()
        }

        public func authorization() async -> ReminderAuthorization {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .authorized, .provisional:
                return settings.alertSetting == .enabled ? .allowed : .unavailable
            default: return .unavailable
            }
        }

        public func requestAuthorization() async throws -> Bool {
            guard await authorization() == .notDetermined else {
                return await authorization() == .allowed
            }
            let granted = try await center.requestAuthorization(options: [.alert])
            guard granted else { return false }
            return await authorization() == .allowed
        }

        public func pending() async -> [PendingReminder] {
            let requests = await center.pendingNotificationRequests()
            return requests.filter { $0.identifier.hasPrefix(ReminderReconciliation.ownedPrefix) }.map { request in
                let trigger = request.trigger as? UNCalendarNotificationTrigger
                let actual = trigger?.repeats == false ? trigger?.nextTriggerDate() : nil
                let instant = actual.flatMap { Int64(exactly: $0.timeIntervalSince1970) }
                let fields = request.content.userInfo as? [String: String] ?? [:]
                return ReminderNotificationPayload.pending(
                    id: request.identifier, actualTrigger: instant, fields: fields
                )
            }
        }

        public func cancel(ids: [String]) {
            let owned = ReminderNotificationPayload.ownedIDs(ids)
            if !owned.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: owned)
            }
        }

        public func schedule(_ request: ReminderRequest) async throws {
            guard request.id.hasPrefix(ReminderReconciliation.ownedPrefix), request.revision >= 0,
                  request.payloadVersion == ReminderReconciliation.payloadVersion
            else {
                throw ReminderDeliveryError.invalidRequest
            }
            guard await authorization() == .allowed else { throw ReminderDeliveryError.permissionUnavailable }
            let date = Date(timeIntervalSince1970: Double(request.trigger))
            guard Int64(exactly: date.timeIntervalSince1970) == request.trigger else {
                throw ReminderDeliveryError.invalidRequest
            }
            guard date > Date() else { throw ReminderDeliveryError.expired }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            components.calendar = calendar
            components.timeZone = .gmt
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            guard trigger.nextTriggerDate() == date else { throw ReminderDeliveryError.invalidRequest }
            let content = UNMutableNotificationContent()
            content.title = "SchneeWorktime"
            content.body = ReminderNotificationPayload.body(for: request.kind)
            content.userInfo = ReminderNotificationPayload.fields(for: request)
            guard date > Date() else { throw ReminderDeliveryError.expired }
            try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger))
        }
    }
#endif

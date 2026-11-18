#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import WorktimeApplication

    /// One run-loop timer; replace it only when the observation cadence changes.
    @MainActor
    final class DesktopObservationTimer {
        private var timer: Timer?
        private var cadence: ObservationCadence?
        private var generation = UUID()
        private var lifecycleObservers: Set<AnyCancellable> = []

        /// These events request a fresh observation, never assert that the user worked during sleep.
        func observeLifecycle(refresh: @escaping @MainActor @Sendable () -> Void) {
            guard lifecycleObservers.isEmpty else { return }
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                center.publisher(for: name).sink { _ in
                    Task { @MainActor in refresh() }
                }
                .store(in: &lifecycleObservers)
            }
        }

        func update(to next: ObservationCadence, tick: @escaping @MainActor @Sendable () -> Void) {
            guard cadence != next else { return }
            timer?.invalidate()
            cadence = next
            let token = UUID()
            generation = token
            let replacement = Timer(timeInterval: next.interval, repeats: true) { [weak self] fired in
                guard self != nil else {
                    fired.invalidate()
                    return
                }
                Task { @MainActor [weak self] in
                    guard self?.generation == token else { return }
                    tick()
                }
            }
            replacement.tolerance = next.tolerance
            timer = replacement
            RunLoop.main.add(replacement, forMode: .common)
        }
    }
#endif

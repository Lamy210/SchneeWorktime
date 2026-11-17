#if os(macOS)
    import Foundation
    import WorktimeApplication

    /// One run-loop timer; replace it only when the observation cadence changes.
    @MainActor
    final class DesktopObservationTimer {
        private var timer: Timer?
        private var cadence: ObservationCadence?
        private var generation = UUID()

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

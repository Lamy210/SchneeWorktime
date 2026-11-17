import Foundation
import WorktimeDomain

public enum ApplicationClockError: Error, Equatable {
    case invalidSample, unreliableClock
}

public struct ClockSample: Sendable, Equatable {
    public let wall: Int64
    public let uptime: Double

    public init(wall: Int64, uptime: Double) throws {
        guard (-2_208_988_800 ... 253_402_300_799).contains(wall), uptime.isFinite, uptime >= 0 else {
            throw ApplicationClockError.invalidSample
        }
        self.wall = wall
        self.uptime = uptime
    }
}

/// Conservative polling policy. Missing observations never establish actual attendance.
public struct ClockObservation: Sendable {
    private let anchor: ClockSample
    private var previous: ClockSample

    public init(initial: ClockSample) {
        anchor = initial
        previous = initial
    }

    public mutating func advance(to sample: ClockSample) throws -> ObservationGap? {
        guard sample.wall >= previous.wall, sample.uptime >= previous.uptime else {
            throw ApplicationClockError.unreliableClock
        }
        let wallElapsed = Double(sample.wall - anchor.wall)
        let monotonicElapsed = sample.uptime - anchor.uptime
        guard abs(wallElapsed - monotonicElapsed) <= 2 else {
            throw ApplicationClockError.unreliableClock
        }
        let gap: ObservationGap? = if sample.wall - previous.wall > 15 {
            .init(start: previous.wall, end: sample.wall)
        } else {
            nil
        }
        previous = sample
        return gap
    }
}

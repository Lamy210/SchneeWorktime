import Foundation
import WorktimeDomain

enum JournalCommand: Codable, Equatable {
    case clockIn(id: UUID, target: Int64, expectedRest: Int64)
    case clockInWithReference(id: UUID, target: Int64, expectedRest: Int64, reference: CapturedReference)
    case startBreak, endBreak
    case clockOut(confirmBreak: Bool)
    case resume(id: UUID)

    init(_ command: WorkdayCommand) {
        switch command {
        case let .clockIn(id, profile):
            if let reference = profile.reference {
                self = .clockInWithReference(
                    id: id, target: profile.target, expectedRest: profile.expectedRest, reference: reference
                )
            } else {
                self = .clockIn(id: id, target: profile.target, expectedRest: profile.expectedRest)
            }
        case .startBreak:
            self = .startBreak
        case .endBreak:
            self = .endBreak
        case let .clockOut(confirmBreak):
            self = .clockOut(confirmBreak: confirmBreak)
        case let .resume(id):
            self = .resume(id: id)
        }
    }

    func command() throws -> WorkdayCommand {
        switch self {
        case let .clockIn(id, target, expectedRest):
            try .clockIn(id: id, profile: WorkdayProfile(target: target, expectedRest: expectedRest))
        case let .clockInWithReference(id, target, expectedRest, reference):
            try .clockIn(
                id: id, profile: WorkdayProfile(target: target, expectedRest: expectedRest, reference: reference)
            )
        case .startBreak:
            .startBreak
        case .endBreak:
            .endBreak
        case let .clockOut(confirmBreak):
            .clockOut(confirmBreak: confirmBreak)
        case let .resume(id):
            .resume(id: id)
        }
    }
}

enum JournalClassification: String, Codable, Equatable {
    case work, rest, gap

    init(_ classification: ReviewClassification) {
        switch classification {
        case .work: self = .work
        case .rest: self = .rest
        case .gap: self = .gap
        }
    }

    var domain: ReviewClassification {
        switch self {
        case .work: .work
        case .rest: .rest
        case .gap: .gap
        }
    }
}

enum JournalAction: Codable, Equatable {
    case command(JournalCommand, at: Int64)
    case observation(dayID: UUID, start: Int64, end: Int64)
    case futureRest(dayID: UUID, remainingSeconds: Int64?)
    case desiredDeparture(dayID: UUID, candidate: Int64?, warningAcknowledged: Bool)
    case review(dayID: UUID, start: Int64, end: Int64, classification: JournalClassification)
    case correctRestEnd(dayID: UUID, oldEnd: Int64, newEnd: Int64)
    case correctRestStart(dayID: UUID, oldStart: Int64, newStart: Int64)
}

struct JournalEvent: Codable, Equatable {
    let action: JournalAction
    let now: Int64

    func apply(to catalog: inout WorkdayCatalog) throws {
        switch action {
        case let .command(command, instant):
            try catalog.apply(command.command(), at: instant, now: now, expectedRevision: catalog.revision)
        case let .futureRest(dayID, remainingSeconds):
            try catalog.setFutureRest(dayID: dayID, remainingSeconds: remainingSeconds,
                                      now: now, expectedRevision: catalog.revision)
        case let .observation(dayID, start, end):
            try catalog.recordObservation(dayID: dayID, gap: .init(start: start, end: end),
                                          now: now, expected: catalog.reviewVersion)
        case let .desiredDeparture(dayID, candidate, warningAcknowledged):
            try catalog.setDesiredDeparture(
                dayID: dayID, candidate: candidate, warningAcknowledged: warningAcknowledged,
                now: now, expected: catalog.reviewVersion
            )
        case let .review(dayID, start, end, classification):
            let preview = try catalog.previewReview(dayID: dayID, selection: .init(start: start, end: end),
                                                    classification: classification.domain, now: now)
            try catalog.commitReview(preview, now: now)
        case let .correctRestEnd(dayID, oldEnd, newEnd):
            let preview = try catalog.previewRestEndCorrection(dayID: dayID, oldEnd: oldEnd, newEnd: newEnd, now: now)
            try catalog.commitRestEndCorrection(preview, now: now)
        case let .correctRestStart(dayID, oldStart, newStart):
            let preview = try catalog.previewRestStartCorrection(
                dayID: dayID, oldStart: oldStart, newStart: newStart, now: now
            )
            try catalog.commitRestStartCorrection(preview, now: now)
        }
    }
}

struct CatalogJournal: Codable, Equatable {
    var schemaVersion = 1
    var events: [JournalEvent] = []

    static let maxEvents = 10000

    func replay(now: Int64) throws -> WorkdayCatalog {
        guard schemaVersion == 1 else { throw CatalogPersistenceError.unsupportedSchema }
        guard events.count <= Self.maxEvents else { throw CatalogPersistenceError.eventLimit }
        var catalog = WorkdayCatalog()
        for event in events {
            guard event.now <= now else { throw CatalogPersistenceError.futureEvent }
            let version = catalog.reviewVersion
            try event.apply(to: &catalog)
            guard catalog.reviewVersion != version else { throw CatalogPersistenceError.invalidJournal }
        }
        return catalog
    }
}

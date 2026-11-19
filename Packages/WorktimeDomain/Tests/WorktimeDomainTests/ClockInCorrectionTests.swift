import Foundation
import Testing
@testable import WorktimeDomain

struct ClockInCorrectionTests {
    private func ended(profile: WorkdayProfile, start: Int64 = 3600, end: Int64 = 7200) throws -> WorkdayCatalog {
        var catalog = WorkdayCatalog()
        try catalog.apply(.clockIn(id: UUID(), profile: profile), at: start, now: start, expectedRevision: 0)
        try catalog.apply(.clockOut(confirmBreak: false), at: end, now: end, expectedRevision: 1)
        return catalog
    }

    @Test func `earlier and later start previews preserve original and captured reference`() throws {
        let reference = try CapturedReference(startedAt: 3600, timeZoneID: "Asia/Tokyo", wallTime: ReferenceWallTime())
        let catalog = try ended(profile: WorkdayProfile(reference: reference))
        let day = try #require(catalog.days.last)
        let earlier = try catalog.previewClockInCorrection(dayID: day.id, oldStart: 3600, newStart: 1800, now: 7300)
        let later = try catalog.previewClockInCorrection(dayID: day.id, oldStart: 3600, newStart: 5400, now: 7300)
        #expect(try earlier.after.snapshot(now: 7300).bounds.lower == 5400)
        #expect(try later.after.snapshot(now: 7300).bounds.lower == 1800)
        #expect(earlier.after.profile.reference?.startedAt == 1800)
        #expect(earlier.after.profile.reference?.referenceAt == reference.referenceAt)
        #expect(earlier.after.profile.reference?.logicalDate == reference.logicalDate)
        #expect(earlier.after.id == day.id)
        #expect(earlier.review.classification == .work)
        #expect(later.review.classification == .gap)
        #expect(catalog.days.last == day)
        #expect(catalog.reviewAudit.isEmpty)
    }

    @Test func `reject previous day overlap and permit touching legacy boundary`() throws {
        var catalog = try ended(profile: WorkdayProfile())
        let id = UUID()
        try catalog.apply(.clockIn(id: id, profile: WorkdayProfile()), at: 8000, now: 8000, expectedRevision: 2)
        try catalog.apply(.clockOut(confirmBreak: false), at: 9000, now: 9000, expectedRevision: 3)
        #expect(throws: ClockInCorrectionError.overlapsPreviousDay) {
            try catalog.previewClockInCorrection(dayID: id, oldStart: 8000, newStart: 7199, now: 9001)
        }
        let proposal = try catalog.previewClockInCorrection(dayID: id, oldStart: 8000, newStart: 7200, now: 9001)
        #expect(proposal.after.profile.reference == nil)
        #expect(proposal.after.intervals.first?.start == 7200)
        #expect(catalog.days.last?.intervals.first?.start == 8000)
    }

    @Test func `reject captured date and resolution changes`() throws {
        let reference = try CapturedReference(startedAt: 3600, timeZoneID: "UTC", wallTime: ReferenceWallTime())
        let catalog = try ended(profile: WorkdayProfile(reference: reference), end: 72000)
        let day = try #require(catalog.days.last)
        #expect(throws: ClockInCorrectionError.changesReference) {
            try catalog.previewClockInCorrection(dayID: day.id, oldStart: 3600, newStart: -60, now: 72001)
        }
        #expect(throws: ClockInCorrectionError.changesReference) {
            try catalog.previewClockInCorrection(dayID: day.id, oldStart: 3600, newStart: 64801, now: 72001)
        }
        #expect(throws: ClockInCorrectionError.invalidBoundary) {
            try catalog.previewClockInCorrection(dayID: day.id, oldStart: 3600, newStart: 72000, now: 72001)
        }
    }

    @Test func `reject unresolved observation overlap and active day correction`() throws {
        var catalog = WorkdayCatalog()
        let id = UUID()
        try catalog.apply(.clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expectedRevision: 0)
        #expect(throws: ClockInCorrectionError.invalidBoundary) {
            try catalog.previewClockInCorrection(dayID: id, oldStart: 100, newStart: 90, now: 200)
        }
        try catalog.recordObservation(dayID: id, gap: .init(start: 110, end: 150),
                                      now: 150, expected: catalog.reviewVersion)
        try catalog.apply(.clockOut(confirmBreak: false), at: 200, now: 200, expectedRevision: 1)
        #expect(throws: ClockInCorrectionError.overlapsUncertainty) {
            try catalog.previewClockInCorrection(dayID: id, oldStart: 100, newStart: 120, now: 201)
        }
    }
}

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

    @Test func `rest anchor is retained and a later start cannot cross it`() throws {
        var catalog = WorkdayCatalog()
        let id = UUID()
        try catalog.apply(.clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expectedRevision: 0)
        try catalog.setFutureRest(dayID: id, remainingSeconds: 60, now: 150, expectedRevision: 1)
        try catalog.apply(.clockOut(confirmBreak: false), at: 300, now: 300, expectedRevision: 2)
        let original = catalog
        #expect(throws: ClockInCorrectionError.crossesRestAnchor) {
            try catalog.previewClockInCorrection(dayID: id, oldStart: 100, newStart: 151, now: 301)
        }
        let proposal = try catalog.previewClockInCorrection(dayID: id, oldStart: 100, newStart: 150, now: 301)
        #expect(proposal.after.futureRestPlan == proposal.before.futureRestPlan)
        #expect(try proposal.after.snapshot(now: 301).remainingRest == 60)
        #expect(proposal.version == original.reviewVersion)
        #expect(catalog == original)
    }

    @Test func `historical start preview preserves breaks and a subsequent active workday`() throws {
        var catalog = WorkdayCatalog()
        let id = UUID()
        let activeID = UUID()
        try catalog.apply(.clockIn(id: id, profile: WorkdayProfile()), at: 100, now: 100, expectedRevision: 0)
        try catalog.apply(.startBreak, at: 200, now: 200, expectedRevision: 1)
        try catalog.apply(.endBreak, at: 250, now: 250, expectedRevision: 2)
        try catalog.apply(.clockOut(confirmBreak: false), at: 400, now: 400, expectedRevision: 3)
        try catalog.apply(.clockIn(id: activeID, profile: WorkdayProfile()), at: 500, now: 500, expectedRevision: 4)
        let original = catalog
        let proposal = try catalog.previewClockInCorrection(dayID: id, oldStart: 100, newStart: 80, now: 600)
        #expect(proposal.after.intervals.dropFirst() == proposal.before.intervals.dropFirst())
        #expect(try proposal.after.snapshot(now: 600).bounds.lower == 270)
        #expect(try proposal.after.snapshot(now: 600).recordedRest == 50)
        #expect(catalog.activeID == activeID)
        #expect(catalog == original)
    }
}

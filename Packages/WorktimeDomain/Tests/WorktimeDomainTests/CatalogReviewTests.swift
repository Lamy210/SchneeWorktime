import Foundation
import Testing
@testable import WorktimeDomain

struct CatalogReviewTests {
    private func observed() throws -> (WorkdayCatalog, UUID) {
        let id = UUID()
        var catalog = WorkdayCatalog()
        let profile = try WorkdayProfile(target: 80, expectedRest: 60)
        try catalog.apply(.clockIn(id: id, profile: profile), at: 0, now: 0, expectedRevision: 0)
        try catalog.recordObservation(dayID: id, gap: .init(start: 20, end: 70),
                                      now: 100, expected: catalog.reviewVersion)
        return (catalog, id)
    }

    @Test func `review commits intervals observations and audit together`() throws {
        var (catalog, id) = try observed()
        let original = catalog
        let preview = try catalog.previewReview(dayID: id, selection: .init(start: 30, end: 60),
                                                classification: .rest, now: 100)
        #expect(catalog == original)
        try catalog.commitReview(preview, now: 110)
        #expect(catalog.revision == 2)
        #expect(catalog.observationGeneration == 2)
        #expect(catalog.days.first?.revision == 2)
        let audit = try #require(catalog.reviewAudit.first)
        #expect(audit.review.reviewedAt == 110)
        #expect(audit.review.beforeIntervals == original.days.first?.intervals)
        #expect(audit.review.afterIntervals == catalog.days.first?.intervals)
        let totals = try catalog.snapshot(dayID: id, now: 110)
        #expect(totals.bounds.lower == 60)
        #expect(totals.bounds.upper == 80)
        #expect(totals.recordedRest == 30)
    }

    @Test func `observation generation invalidates review without attendance edit`() throws {
        var (catalog, id) = try observed()
        let preview = try catalog.previewReview(dayID: id, selection: .init(start: 30, end: 60),
                                                classification: .work, now: 100)
        try catalog.recordObservation(dayID: id, gap: .init(start: 80, end: 90),
                                      now: 100, expected: catalog.reviewVersion)
        #expect(catalog.revision == 1)
        let before = catalog
        #expect(throws: CatalogReviewError.staleObservation) {
            try catalog.commitReview(preview, now: 100)
        }
        #expect(catalog == before)
    }

    @Test func `canonical mutation invalidates review`() throws {
        var (catalog, id) = try observed()
        let preview = try catalog.previewReview(dayID: id, selection: .init(start: 30, end: 60),
                                                classification: .work, now: 100)
        try catalog.apply(.startBreak, at: 100, now: 100, expectedRevision: 1)
        let before = catalog
        #expect(throws: WorkdayError.staleRevision) {
            try catalog.commitReview(preview, now: 100)
        }
        #expect(catalog == before)
    }

    @Test func `late observations cannot resurrect confirmed range`() throws {
        var (catalog, id) = try observed()
        let stale = catalog.reviewVersion
        let preview = try catalog.previewReview(dayID: id, selection: .init(start: 20, end: 70),
                                                classification: .work, now: 100)
        try catalog.commitReview(preview, now: 100)
        #expect(throws: WorkdayError.staleRevision) {
            try catalog.recordObservation(dayID: id, gap: .init(start: 20, end: 70), now: 110, expected: stale)
        }
        let version = catalog.reviewVersion
        try catalog.recordObservation(dayID: id, gap: .init(start: 20, end: 70), now: 110, expected: version)
        #expect(catalog.reviewVersion == version)
        try catalog.recordObservation(dayID: id, gap: .init(start: 10, end: 80),
                                      now: 110, expected: version)
        let totals = try catalog.snapshot(dayID: id, now: 110)
        #expect(totals.bounds.lower == 90)
        #expect(catalog.observations[id] == [.init(start: 10, end: 20), .init(start: 70, end: 80)])
    }

    @Test func `review prior ended day preserves newer active day`() throws {
        var (catalog, id) = try observed()
        try catalog.apply(.clockOut(confirmBreak: false), at: 100, now: 100, expectedRevision: 1)
        let newID = UUID()
        let profile = try WorkdayProfile()
        try catalog.apply(.clockIn(id: newID, profile: profile), at: 120, now: 120, expectedRevision: 2)
        let active = catalog.days.last
        let preview = try catalog.previewReview(dayID: id, selection: .init(start: 20, end: 70),
                                                classification: .gap, now: 150)
        try catalog.commitReview(preview, now: 150)
        #expect(catalog.activeID == newID)
        #expect(catalog.days.last == active)
        #expect(catalog.days.first?.state == .ended)
        let totals = try catalog.snapshot(dayID: id, now: 150)
        #expect(totals.bounds.lower == 50)
        #expect(totals.recordedRest == 0)
    }

    @Test func `invalid observation and duplicate review do not mutate catalog`() throws {
        var (catalog, id) = try observed()
        let before = catalog
        #expect(throws: WorktimeError.invalidInterval) {
            try catalog.recordObservation(dayID: id, gap: .init(start: 80, end: 101),
                                          now: 100, expected: catalog.reviewVersion)
        }
        #expect(catalog == before)
        let preview = try catalog.previewReview(dayID: id, selection: .init(start: 20, end: 70),
                                                classification: .work, now: 100)
        try catalog.commitReview(preview, now: 100)
        let resolved = catalog
        #expect(throws: WorkdayError.staleRevision) {
            try catalog.commitReview(preview, now: 100)
        }
        #expect(catalog == resolved)
    }
}

import WorktimeDomain
import WorktimeStore

public struct WorktimeReviewProposal: Sendable {
    let stored: StoredReviewPreview
    public let before: WorktimeGlance
    public let after: WorktimeGlance

    public var selection: ObservationGap {
        stored.preview.review.selection
    }

    public var classification: ReviewClassification {
        stored.preview.review.classification
    }

    public var observedAt: Int64 {
        stored.preview.review.reviewedAt
    }
}

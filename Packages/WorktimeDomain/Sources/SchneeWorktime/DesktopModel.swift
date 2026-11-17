#if os(macOS)
import Combine
import Foundation
import WorktimeApplication
import WorktimeDomain

@MainActor
final class DesktopModel: ObservableObject {
    @Published private(set) var glance: WorktimeGlance?
    @Published private(set) var ready = false
    @Published private(set) var message: String?
    @Published private(set) var reviewProposal: WorktimeReviewProposal?
    @Published private(set) var reviewNotice: String?

    private var controller: WorktimeController?

    init() {
        open(create: false)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func open(create: Bool) {
        cancelReview()
        controller = nil
        ready = false
        glance = nil
        do {
            let url = try databaseURL()
            if create {
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    message = "既存のデータベースがあります。初期化せず再読込してください。"
                    return
                }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let sample = try Self.sample()
            var opened = try WorktimeController(url: url, createIfMissing: create, sample: sample)
            glance = try opened.refresh(sample: sample)
            controller = opened
            ready = true
            message = nil
        } catch {
            fail(error)
        }
    }

    func start() {
        do {
            perform(.clockIn(id: UUID(), profile: try WorkdayProfile()))
        } catch {
            fail(error)
        }
    }

    func perform(_ command: WorkdayCommand) {
        cancelReview()
        guard var current = controller else { return }
        do {
            glance = try current.perform(command, sample: Self.sample())
            controller = current
        } catch {
            fail(error)
        }
    }

    func prepareReview(selection: ObservationGap, classification: ReviewClassification) {
        guard var current = controller else { return }
        do {
            let sample = try Self.sample()
            let proposal = try current.previewReview(selection: selection, classification: classification, sample: sample)
            glance = proposal.before
            controller = current
            reviewProposal = proposal
            reviewNotice = nil
        } catch {
            fail(error)
        }
    }

    func cancelReview() {
        reviewProposal = nil
        reviewNotice = nil
    }

    func acceptReview() {
        guard var current = controller, let proposal = reviewProposal else { return }
        do {
            glance = try current.commitReview(proposal, sample: Self.sample())
            controller = current
            cancelReview()
        } catch {
            if current.isCurrent(proposal) {
                fail(error)
            } else {
                do {
                    glance = try current.refresh(sample: Self.sample())
                    controller = current
                    invalidateReview()
                } catch {
                    fail(error)
                }
            }
        }
    }

    private func invalidateReview() {
        reviewProposal = nil
        reviewNotice = "記録が更新されたため、訂正案をもう一度確認してください。"
    }

    private func tick() {
        guard var current = controller else { return }
        do {
            glance = try current.refresh(sample: Self.sample())
            controller = current
            if let proposal = reviewProposal, !current.isCurrent(proposal) {
                invalidateReview()
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        cancelReview()
        controller = nil
        glance = nil
        ready = false
        message = "記録を停止：\(error)。時刻・データを確認して再読込してください。"
    }

    private func databaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        return support.appendingPathComponent("SchneeWorktime", isDirectory: true)
            .appendingPathComponent("worktime.sqlite")
    }

    private static func sample() throws -> ClockSample {
        guard let wall = Int64(exactly: Date().timeIntervalSince1970.rounded(.down)) else {
            throw ApplicationClockError.invalidSample
        }
        return try ClockSample(wall: wall, uptime: ProcessInfo.processInfo.systemUptime)
    }
}
#endif

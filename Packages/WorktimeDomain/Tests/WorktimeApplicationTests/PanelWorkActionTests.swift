import Foundation
import Testing
import WorktimeApplication
import WorktimeDomain

struct PanelWorkActionTests {
    @Test func `invalid settings or blocked state cannot start work`() throws {
        let profile = try WorkdayProfile()
        let blocked = PanelActionContext(day: nil, enabled: false)
        let empty = PanelActionContext(day: nil, enabled: true)
        let id = UUID()
        #expect(blocked.available(at: 100).isEmpty)
        #expect(blocked.command(for: .start, at: 100, profile: profile, newID: id) == nil)
        #expect(empty.command(for: .start, at: 100) == nil)
        let command = empty.command(for: .start, at: 100, profile: profile, newID: id)
        #expect(command == .clockIn(id: id, profile: profile))
    }

    @Test func `work and break actions are mutually exclusive and forbid zero length intervals`() throws {
        var catalog = WorkdayCatalog()
        let profile = try WorkdayProfile()
        try catalog.apply(.clockIn(id: UUID(), profile: profile), at: 100, now: 100, expectedRevision: 0)
        let work = PanelActionContext(day: catalog.days.last, enabled: true)
        #expect(work.available(at: 100).isEmpty)
        #expect(work.available(at: 101) == [.startBreak, .clockOut])
        #expect(work.command(for: .endBreak, at: 101) == nil)
        try catalog.apply(.startBreak, at: 110, now: 110, expectedRevision: catalog.revision)
        let rest = PanelActionContext(day: catalog.days.last, enabled: true)
        #expect(rest.available(at: 110).isEmpty)
        #expect(rest.available(at: 111) == [.endBreak, .clockOut])
        #expect(rest.command(for: .startBreak, at: 111) == nil)
        #expect(rest.command(for: .clockOut, at: 111) == nil)
        #expect(rest.command(for: .clockOut, at: 111, confirmed: true) == .clockOut(confirmBreak: true))
    }

    @Test func `same day state after another transition invalidates old confirmation`() throws {
        var catalog = WorkdayCatalog()
        let profile = try WorkdayProfile()
        try catalog.apply(.clockIn(id: UUID(), profile: profile), at: 100, now: 100, expectedRevision: 0)
        let old = PanelActionContext(day: catalog.days.last, enabled: true)
        #expect(old.command(for: .clockOut, at: 101) == nil)
        try catalog.apply(.startBreak, at: 110, now: 110, expectedRevision: catalog.revision)
        try catalog.apply(.endBreak, at: 120, now: 120, expectedRevision: catalog.revision)
        let new = PanelActionContext(day: catalog.days.last, enabled: true)
        #expect(old.day?.state == new.day?.state)
        #expect(old != new)
        #expect(new.command(for: .clockOut, at: 121, confirmed: true) == .clockOut(confirmBreak: false))
    }

    @Test func `ended day offers start and resume but not active commands`() throws {
        var catalog = WorkdayCatalog()
        let id = UUID()
        let profile = try WorkdayProfile()
        try catalog.apply(.clockIn(id: id, profile: profile), at: 100, now: 100, expectedRevision: 0)
        try catalog.apply(.clockOut(confirmBreak: false), at: 120, now: 120, expectedRevision: catalog.revision)
        let ended = PanelActionContext(day: catalog.days.last, enabled: true)
        #expect(ended.available(at: 120) == [.start, .resume])
        #expect(ended.command(for: .resume, at: 120) == .resume(id: id))
        #expect(ended.command(for: .clockOut, at: 120, confirmed: true) == nil)
    }
}

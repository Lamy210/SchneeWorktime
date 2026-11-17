import Foundation

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

import Testing
import WorktimeApplication

struct PanelDisplayModeTests {
    @Test func `missing and unknown settings fall back to detailed`() {
        #expect(PanelDisplayMode(storedValue: nil) == .detailed)
        #expect(PanelDisplayMode(storedValue: "invalid") == .detailed)
        #expect(PanelDisplayMode(storedValue: "compact") == .compact)
        #expect(PanelDisplayMode.compact.alternate == .detailed)
        #expect(PanelDisplayMode.detailed.alternate == .compact)
    }

    @Test func `mode changes preserve the upper edge`() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let old = CGRect(x: 100, y: 400, width: 320, height: 300)
        let expected = CGRect(x: 100, y: 520, width: 320, height: 180)
        #expect(PanelDisplayMode.compact.resizedFrame(previous: old, screens: [screen]) == expected)
        #expect(PanelDisplayMode.detailed.resizedFrame(previous: expected, screens: [screen]) == old)
    }

    @Test func `expansion clamps to a small screen`() {
        let screen = CGRect(x: 0, y: 0, width: 240, height: 200)
        let old = CGRect(x: 100, y: 10, width: 320, height: 180)
        #expect(PanelDisplayMode.detailed.resizedFrame(previous: old, screens: [screen]) == screen)
        #expect(PanelDisplayMode.compact.resizedFrame(previous: old, screens: []) == nil)
    }
}

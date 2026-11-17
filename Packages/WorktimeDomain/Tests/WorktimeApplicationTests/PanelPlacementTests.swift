import Foundation

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

import Testing
import WorktimeApplication

struct PanelPlacementTests {
    @Test func `visible placement is unchanged`() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 100, y: 100, width: 320, height: 220)
        #expect(PanelPlacement.visibleFrame(preferred: frame, screens: [screen]) == frame)
    }

    @Test func `disconnected monitor clamps onto remaining screen`() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 2000, y: 100, width: 320, height: 220)
        let expected = CGRect(x: 1120, y: 100, width: 320, height: 220)
        #expect(PanelPlacement.visibleFrame(preferred: frame, screens: [screen]) == expected)
    }

    @Test func `negative coordinate monitor is retained`() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let second = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let frame = CGRect(x: -400, y: 100, width: 320, height: 220)
        #expect(PanelPlacement.visibleFrame(preferred: frame, screens: [main, second]) == frame)
    }

    @Test func `oversized panel shrinks and no screen returns nil`() {
        let screen = CGRect(x: 0, y: 0, width: 200, height: 150)
        let frame = CGRect(x: -100, y: -100, width: 320, height: 220)
        #expect(PanelPlacement.visibleFrame(preferred: frame, screens: [screen]) == screen)
        #expect(PanelPlacement.visibleFrame(preferred: frame, screens: []) == nil)
    }
}

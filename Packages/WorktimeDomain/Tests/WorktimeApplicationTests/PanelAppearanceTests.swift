import Foundation

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

import Testing
import WorktimeApplication

struct PanelAppearanceTests {
    @Test func `opacity only permits known presets`() {
        #expect(PanelOpacity(storedValue: nil) == .opaque)
        #expect(PanelOpacity(storedValue: "invalid") == .opaque)
        #expect(PanelOpacity(storedValue: "translucent").alpha == 0.85)
        #expect(PanelOpacity.subtle.alpha == 0.95)
        #expect(PanelOpacity.opaque.alpha == 1)
    }

    @Test func `anchor round trips and does not store the old size`() throws {
        let original = CGRect(x: -500, y: 100, width: 320, height: 300)
        let anchor = try #require(PanelAnchor(frame: original))
        let data = try anchor.encoded()
        let restored = try #require(PanelAnchor.restore(data))
        #expect(restored == anchor)
        #expect(restored.preferredFrame(width: 320, height: 180) == CGRect(x: -500, y: 220, width: 320, height: 180))
    }

    @Test func `invalid or oversized stored anchors are ignored`() {
        #expect(PanelAnchor.restore(nil) == nil)
        #expect(PanelAnchor.restore(Data(count: 1025)) == nil)
        #expect(PanelAnchor.restore(Data("broken".utf8)) == nil)
        #expect(PanelAnchor.restore(Data(#"{"x":1000001,"top":0}"#.utf8)) == nil)
        #expect(PanelAnchor.restore(Data(#"{"x":0}"#.utf8)) == nil)
    }

    @Test func `restored position on disconnected screen can be clamped`() throws {
        let anchor = try #require(PanelAnchor(frame: CGRect(x: 1800, y: 100, width: 320, height: 300)))
        let preferred = anchor.preferredFrame(width: 320, height: 180)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let expected = CGRect(x: 1120, y: 220, width: 320, height: 180)
        #expect(PanelPlacement.visibleFrame(preferred: preferred, screens: [screen]) == expected)
    }
}

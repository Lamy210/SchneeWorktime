#if os(macOS)
    import AppKit
    import Combine
    import SwiftUI
    import WorktimeApplication

    @MainActor
    final class WorktimePanelCoordinator: NSObject, ObservableObject, NSWindowDelegate {
        @Published private(set) var visible = false
        @Published private(set) var alwaysOnTop = UserDefaults.standard.bool(forKey: "worktimePanelAlwaysOnTop")
        @Published private(set) var opacity = PanelOpacity(
            storedValue: UserDefaults.standard.string(forKey: "worktimePanelOpacity")
        )
        @Published private(set) var displayMode = PanelDisplayMode(
            storedValue: UserDefaults.standard.string(forKey: "worktimePanelDisplayMode")
        )
        private var panel: NSPanel?
        private var previousFrame: CGRect?

        func toggle(model: DesktopModel) {
            if visible {
                hide()
            } else {
                show(model: model)
            }
        }

        func toggleAlwaysOnTop() {
            alwaysOnTop.toggle()
            UserDefaults.standard.set(alwaysOnTop, forKey: "worktimePanelAlwaysOnTop")
            panel?.level = alwaysOnTop ? .floating : .normal
        }

        func setOpacity(_ value: PanelOpacity) {
            opacity = value
            UserDefaults.standard.set(value.rawValue, forKey: "worktimePanelOpacity")
            panel?.alphaValue = value.alpha
        }

        func resetPosition() {
            UserDefaults.standard.removeObject(forKey: "worktimePanelAnchor")
            previousFrame = nil
            guard let window = panel, let screen = NSScreen.screens.first?.visibleFrame else { return }
            let preferred = defaultFrame(on: screen)
            guard let frame = displayMode.resizedFrame(
                previous: preferred, screens: NSScreen.screens.map(\.visibleFrame)
            ) else { return }
            window.setFrame(frame, display: true)
        }

        private func defaultFrame(on screen: CGRect) -> CGRect {
            CGRect(x: screen.maxX - 336, y: screen.maxY - 320, width: 320, height: 300)
        }

        private func saveAnchor(_ frame: CGRect) {
            guard let anchor = PanelAnchor(frame: frame), let data = try? anchor.encoded() else { return }
            UserDefaults.standard.set(data, forKey: "worktimePanelAnchor")
        }

        func toggleDisplayMode() {
            displayMode = displayMode.alternate
            UserDefaults.standard.set(displayMode.rawValue, forKey: "worktimePanelDisplayMode")
            guard let window = panel else { return }
            guard let frame = displayMode.resizedFrame(
                previous: window.frame, screens: NSScreen.screens.map(\.visibleFrame)
            ) else { return }
            window.setFrame(frame, display: true)
        }

        private func show(model: DesktopModel) {
            guard panel == nil else { return }
            let screens = NSScreen.screens.map(\.visibleFrame)
            guard let screen = screens.first else { return }
            let anchor = PanelAnchor.restore(UserDefaults.standard.data(forKey: "worktimePanelAnchor"))
            let restored = anchor?.preferredFrame(width: 320, height: displayMode.height)
            let preferred = previousFrame ?? restored ?? defaultFrame(on: screen)
            guard let frame = displayMode.resizedFrame(previous: preferred, screens: screens) else { return }
            let window = NSPanel(
                contentRect: frame, styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            window.title = "SchneeWorktime"
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.alphaValue = opacity.alpha
            window.level = alwaysOnTop ? .floating : .normal
            window.delegate = self
            let view = WorktimePanelView(model: model, repairPlacement: { [weak self] in
                self?.repairPlacement()
            })
            window.contentView = NSHostingView(rootView: view)
            window.setFrame(frame, display: true)
            panel = window
            visible = true
            window.orderFrontRegardless()
        }

        private func hide() {
            guard let window = panel else { return }
            previousFrame = window.frame
            saveAnchor(window.frame)
            window.orderOut(nil)
            window.contentView = nil
            panel = nil
            visible = false
        }

        func windowDidMove(_ notification: Notification) {
            guard let window = notification.object as? NSPanel, window === panel else { return }
            saveAnchor(window.frame)
        }

        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSPanel, window === panel else { return }
            previousFrame = window.frame
            saveAnchor(window.frame)
            window.contentView = nil
            panel = nil
            visible = false
        }

        func repairPlacement() {
            guard let window = panel,
                  let frame = PanelPlacement.visibleFrame(
                      preferred: window.frame, screens: NSScreen.screens.map(\.visibleFrame)
                  ), frame != window.frame else { return }
            window.setFrame(frame, display: true)
        }
    }
#endif

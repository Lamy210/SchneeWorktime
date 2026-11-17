#if os(macOS)
    import AppKit
    import Combine
    import SwiftUI
    import WorktimeApplication

    @MainActor
    final class WorktimePanelCoordinator: NSObject, ObservableObject, NSWindowDelegate {
        @Published private(set) var visible = false
        @Published private(set) var alwaysOnTop = false
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
            panel?.level = alwaysOnTop ? .floating : .normal
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
            let defaultFrame = CGRect(x: screen.maxX - 336, y: screen.maxY - 320, width: 320, height: 300)
            let preferred = previousFrame ?? defaultFrame
            guard let frame = displayMode.resizedFrame(previous: preferred, screens: screens) else { return }
            let window = NSPanel(
                contentRect: frame, styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            window.title = "SchneeWorktime"
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
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
            window.orderOut(nil)
            window.contentView = nil
            panel = nil
            visible = false
        }

        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSPanel, window === panel else { return }
            previousFrame = window.frame
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

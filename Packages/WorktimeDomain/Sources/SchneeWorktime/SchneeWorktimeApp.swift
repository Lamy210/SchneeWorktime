#if os(macOS)
    import SwiftUI
    import WorktimeApplication

    @main
    @MainActor
    struct SchneeWorktimeApp: App {
        @StateObject private var model = DesktopModel()
        @StateObject private var panel = WorktimePanelCoordinator()

        var body: some Scene {
            MenuBarExtra {
                VStack(spacing: 0) {
                    HStack {
                        Button(panel.visible ? "パネルを隠す" : "パネルを表示") {
                            panel.toggle(model: model)
                        }
                        Button(panel.alwaysOnTop ? "最前面を解除" : "最前面にする") {
                            panel.toggleAlwaysOnTop()
                        }
                    }
                    .padding(8)
                    Divider()
                    WorktimeMenu(model: model)
                }
            } label: {
                Label(menuTitle, systemImage: "clock")
                    .monospacedDigit()
            }
            .menuBarExtraStyle(.window)
        }

        private var menuTitle: String {
            guard model.ready, let glance = model.glance else { return "SchneeWorktime" }
            return DepartureCountdown(goal: glance.forecast.goal, observedAt: glance.observedAt).menuTitle
        }
    }
#else
    import Foundation

    @main
    enum SchneeWorktimeApp {
        static func main() {
            FileHandle.standardError.write(Data("SchneeWorktime requires macOS 15 or later.\n".utf8))
        }
    }
#endif

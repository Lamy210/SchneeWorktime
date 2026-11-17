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
                        Menu("パネル設定") {
                            Button(panel.alwaysOnTop ? "最前面を解除" : "最前面にする") {
                                panel.toggleAlwaysOnTop()
                            }
                            Button(panel.displayMode == .compact ? "詳細表示" : "コンパクト表示") {
                                panel.toggleDisplayMode()
                            }
                            Menu("不透明度") {
                                ForEach(PanelOpacity.allCases, id: \.rawValue) { value in
                                    Button(value.title + (panel.opacity == value ? " (選択中)" : "")) {
                                        panel.setOpacity(value)
                                    }
                                }
                            }
                            Button("表示位置をリセット") { panel.resetPosition() }
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

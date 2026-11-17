#if os(macOS)
import SwiftUI

@main
@MainActor
struct SchneeWorktimeApp: App {
    @StateObject private var model = DesktopModel()

    var body: some Scene {
        MenuBarExtra("SchneeWorktime", systemImage: "clock") {
            WorktimeMenu(model: model)
        }
        .menuBarExtraStyle(.window)
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

#if os(macOS)
    import AppKit
    import Foundation

    @MainActor
    enum BackupInspectionPanel {
        static func choose(initialDirectory: URL?) -> URL? {
            let panel = NSOpenPanel()
            panel.title = "バックアップの内容を確認"
            panel.prompt = "確認"
            panel.message = "検証のみ行います。現在の勤務記録を置き換えることはありません。"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.resolvesAliases = false
            panel.directoryURL = initialDirectory
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    }
#endif

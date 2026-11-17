#if os(macOS)
    import AppKit
    import Foundation
    import WorktimeApplication

    enum WorktimeExportFormat {
        case backup, csv

        var filename: String {
            let id = UUID().uuidString
            switch self {
            case .backup: return "SchneeWorktime-backup-\(id).json"
            case .csv: return "SchneeWorktime-history-\(id).csv"
            }
        }

        func write(controller: WorktimeController, to url: URL, now: Int64) throws {
            switch self {
            case .backup: try controller.writeBackup(to: url, now: now)
            case .csv: try controller.writeCSV(to: url, now: now)
            }
        }

        @MainActor
        func chooseDirectory(initialDirectory: URL?) -> URL? {
            let panel = NSOpenPanel()
            panel.title = self == .csv ? "勤務履歴CSVの保存先" : "勤務履歴バックアップの保存先"
            panel.prompt = "このフォルダに保存"
            panel.message = "勤務履歴は暗号化されません。所有者だけがアクセスできるローカルフォルダを選択してください。"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.resolvesAliases = false
            panel.directoryURL = initialDirectory
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    }
#endif

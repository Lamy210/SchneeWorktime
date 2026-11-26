#if os(macOS)
    import Foundation
    import WorktimeApplication

    extension DesktopModel {
        /// Export a validated, restorable schema-2 JSON Journal without using
        /// the legacy schema-1 archive encoder or changing any live attendance.
        func chooseSchemaTwoBackupDestination() {
            guard !ready, controller == nil, sessionLock != nil,
                  !schemaTwoWorkBusy, !maintenanceInProgress, !choosingBackupDestination,
                  schemaTwoInspection != nil || schemaTwoWorkSession != nil
            else { return }
            choosingBackupDestination = true
            defer { choosingBackupDestination = false }
            backupNotice = nil

            // Never default to the app-owned database directory: archived work
            // history must be deliberately saved as an external user-managed file.
            guard let directory = WorktimeExportFormat.backup.chooseDirectory(initialDirectory: nil) else {
                return
            }
            guard sessionLock != nil, !ready, controller == nil,
                  !schemaTwoWorkBusy, !maintenanceInProgress
            else {
                backupNotice = "記録状態が変わりました。バックアップを保存せず再確認してください。"
                return
            }
            let name = "SchneeWorktime-schema2-backup-\(UUID().uuidString).json"
            let destination = directory.appendingPathComponent(name)
            do {
                let sourceDirectory = try databaseURL().deletingLastPathComponent()
                    .resolvingSymlinksInPath().pathComponents
                guard !directory.resolvingSymlinksInPath().pathComponents.starts(with: sourceDirectory) else {
                    backupNotice = "保存先にアプリのDBフォルダは選べません。別の所有者専用フォルダを指定してください。"
                    return
                }
                let now = try Self.sample().wall
                if let inspection = schemaTwoInspection, schemaTwoWorkSession == nil {
                    try inspection.writeBackup(from: databaseURL(), to: destination, now: now)
                } else if let current = schemaTwoWorkSession, schemaTwoInspection == nil {
                    try current.writeBackup(to: destination, now: now)
                } else {
                    backupNotice = "記録セッションが変わりました。バックアップは作成していません。"
                    return
                }
                backupNotice = "schema-2履歴を保存しました：\(destination.path)。平文JSONです。"
            } catch {
                // Publication may have succeeded just before readback failed.
                // Never unlink or blindly retry a possibly published archive.
                backupNotice = "バックアップの完了を確認できませんでした。保存先に同名ファイルが存在する可能性があります。原本・保存先・空き容量を確認してください。"
            }
        }
    }
#endif

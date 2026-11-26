#if os(macOS)
    import Foundation
    import WorktimeApplication

    extension DesktopModel {
        /// A fail-closed release guard until all UI actions, notifications, history
        /// corrections and reset/rollback operate exclusively on the schema-2 Journal.
        /// DEBUG retains the existing schema-1 developer workflow without migration.
        func schemaTwoStartupBlockReason(url: URL, create: Bool) throws -> String? {
            #if DEBUG
                let allowLegacyDevelopment = true
            #else
                let allowLegacyDevelopment = false
            #endif
            let decision = try DesktopStorageLaunchGuard.decide(
                url: url, createIfMissing: create,
                allowLegacyDevelopment: allowLegacyDevelopment
            )
            switch decision {
            case .legacyDevelopmentOnly:
                return nil
            case .missingDatabase:
                return "勤務データはまだありません。schema-2対応の初回作成画面が完成するまで、記録を開始しません。"
            case .schemaTwoAwaitingUI:
                return "schema-2の保存データが見つかりました。現行画面は旧形式専用のため、データを変更せず停止しました。対応版で再読込してください。"
            case .legacyRequiresPreservation:
                return "既存の開発用schema-1データです。自動変換・上書きはしません。保存フォルダ全体を保全してください。"
            case .unknownRequiresPreservation:
                return "未対応の保存形式です。初期化せず、保存フォルダ全体を保全して検証してください。"
            case .newInstallRequiresSchemaTwoUI:
                return "配布版は旧schema-1の新規データベースを作成しません。schema-2の画面接続が完了するまで開始できません。"
            }
        }
    }
#endif

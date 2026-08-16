import Foundation

/// 「這一輪 publish 該不該真的把 snapshot 寫進磁碟」的純決策。
///
/// `UsageCoordinator` 每次 `scanLocal()`（~15 秒一輪）都會呼叫 `publish()`，但把
/// snapshot 寫進 widget 的 sandbox container 是跨 App 邊界的 I/O，會被 macOS 的 TCC
/// 「App 資料」保護盯上——內容沒變就沒有理由每 15 秒都寫一次（一天 5,760 次），這裡
/// 把「該不該寫」從 `UsageCoordinator` 抽成純函式，方便測試。
///
/// **比較刻意排除 `updatedAt`，其餘欄位（包含 `officialFetchedAt`）全部參與比較**：
///
/// - `updatedAt` 只是「這輪 publish 發生的時間」，本來就每次都不同；若拿來比較，
///   節流就形同虛設。
/// - 但**不能**沿用 `WidgetReloadPolicy` 已有的 `isEquivalent`——那個比較連
///   `officialFetchedAt` 都一起忽略了，因為 widget reload 只在乎「畫面上的數字有沒有
///   變」。這裡恰恰需要 `officialFetchedAt` 參與比較：它是撐住 `SnapshotPresenter`
///   staleness 判斷的關鍵欄位——每次 API 成功輪詢（600 秒一次）都會推進它，即使
///   session／weekly 的百分比數字本身沒變，也讓 `updatedAt` 至少每 600 秒前進一次，
///   遠低於 1800 秒的 staleness 門檻。如果比較時把它排除掉，session／weekly／state
///   三者都沒變的常態情況會被判定「沒變」而永久跳過寫入，`updatedAt` 就此凍結，
///   最終讓讀端把一個健康、仍在正常輪詢的 host app 誤判成「已經沒在跑」。
public enum SnapshotWritePolicy {

    /// - Parameters:
    ///   - snapshot: 這一輪打算寫入的 snapshot。
    ///   - lastWritten: 上一次「實際成功寫入磁碟」的 snapshot；`nil` 代表這是啟動後
    ///     coordinator 記憶體裡還沒有任何「已寫入」的紀錄——不論是真的第一次 publish，
    ///     還是先前的寫入嘗試全部失敗／被跳過（widget 容器尚不存在、寫入被拒）。這種
    ///     情況必須無條件回傳 `true`：就算這一輪算出來的內容恰好跟磁碟上現存的檔案相同，
    ///     coordinator 也無法從記憶體得知這件事，寧可多寫一次，也不能因為巧合相等就
    ///     永遠跳過、讓一次原本該發生的寫入憑空消失。
    public static func shouldWrite(_ snapshot: UsageSnapshot, lastWritten: UsageSnapshot?) -> Bool {
        guard let lastWritten else { return true }
        return !isEquivalentIgnoringUpdatedAt(snapshot, lastWritten)
    }

    private static func isEquivalentIgnoringUpdatedAt(_ lhs: UsageSnapshot, _ rhs: UsageSnapshot) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.officialFetchedAt == rhs.officialFetchedAt
            && lhs.session == rhs.session
            && lhs.weekly == rhs.weekly
            && lhs.state == rhs.state
    }
}

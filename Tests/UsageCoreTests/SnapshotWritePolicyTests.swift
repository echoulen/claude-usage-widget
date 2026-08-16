import Testing
import Foundation
@testable import UsageCore

/// `SnapshotWritePolicy.shouldWrite` 是「寫入 snapshot.json 只在內容真的變動時才動筆」
/// 這個修復的核心：見 `SnapshotWritePolicy` 的文件註解，尤其是為什麼 `officialFetchedAt`
/// **必須**參與比較（跟 `WidgetReloadPolicy.isEquivalent` 刻意不同）——那是撐住讀端
/// staleness 判斷、避免健康的 host app 被誤判為「已經沒在跑」的關鍵欄位。
@Suite("SnapshotWritePolicy")
struct SnapshotWritePolicyTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        updatedAt: Date = t0,
        officialFetchedAt: Date? = t0,
        usedPercent: Double = 10,
        state: SnapshotState = .ok
    ) -> UsageSnapshot {
        UsageSnapshot(
            updatedAt: updatedAt,
            officialFetchedAt: officialFetchedAt,
            session: SnapshotWindow(
                usedPercent: usedPercent, resetsAt: Self.t0.addingTimeInterval(5 * 3600), confidence: .exact
            ),
            weekly: SnapshotWindow(
                usedPercent: 20, resetsAt: Self.t0.addingTimeInterval(7 * 86400), confidence: .exact
            ),
            state: state
        )
    }

    @Test("從未寫過（lastWritten 為 nil）：無條件要寫，就算內容碰巧會跟磁碟上現存的一樣")
    func alwaysWritesWhenNothingWrittenYet() {
        let s = snapshot()
        #expect(SnapshotWritePolicy.shouldWrite(s, lastWritten: nil))
    }

    @Test("只有 updatedAt 不同：視為沒變動，不寫")
    func skipsWhenOnlyUpdatedAtDiffers() {
        let last = snapshot(updatedAt: Self.t0)
        let new = snapshot(updatedAt: Self.t0.addingTimeInterval(15))
        #expect(!SnapshotWritePolicy.shouldWrite(new, lastWritten: last))
    }

    @Test("officialFetchedAt 前進，即使 session/weekly 數字完全沒變：仍算變動，要寫")
    func writesWhenOfficialFetchedAtAdvancesEvenIfPercentagesDidNot() {
        let last = snapshot(officialFetchedAt: Self.t0)
        let new = snapshot(
            updatedAt: Self.t0.addingTimeInterval(600),
            officialFetchedAt: Self.t0.addingTimeInterval(600)
        )
        #expect(SnapshotWritePolicy.shouldWrite(new, lastWritten: last))
    }

    @Test("session 的百分比變了：要寫")
    func writesWhenSessionPercentChanges() {
        let last = snapshot(usedPercent: 10)
        let new = snapshot(usedPercent: 12)
        #expect(SnapshotWritePolicy.shouldWrite(new, lastWritten: last))
    }

    @Test("state 變了：要寫")
    func writesWhenStateChanges() {
        let last = snapshot(state: .ok)
        let new = snapshot(state: .windowResetPending)
        #expect(SnapshotWritePolicy.shouldWrite(new, lastWritten: last))
    }

    @Test("本機 token 數移動、但還沒有可信的內插基準，計算出來的 usedPercent 沒變：不寫")
    func skipsWhenOnlyLocalTokensMovedButPercentagesDidNot() {
        // 對應 UsageCoordinator 的真實情境：`currentLocalTokens()` 每 15 秒都會前進，
        // 但只要 `UsageStore.makeWindow` 還沒有可信的內插基準（例如還沒有第二次 API
        // 樣本），session/weekly 就仍是官方讀數原封不動的 `.exact` 值，snapshot 內容
        // 完全沒有反映本機 token 的變化——這種情況也該被判定「沒變動」。
        let last = snapshot(updatedAt: Self.t0)
        let new = snapshot(updatedAt: Self.t0.addingTimeInterval(15))
        #expect(!SnapshotWritePolicy.shouldWrite(new, lastWritten: last))
    }

    @Test("完全相同的兩份 snapshot（含 updatedAt）：不寫")
    func skipsWhenIdentical() {
        let s = snapshot()
        #expect(!SnapshotWritePolicy.shouldWrite(s, lastWritten: s))
    }
}

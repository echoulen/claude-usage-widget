import Foundation

/// 讀端（widget）在渲染前，對「就這份 snapshot 而言，現在還算不算數」做一次把關。
///
/// 寫入端（`UsageStore`）已經在寫入當下做過同一輪判斷，但 `snapshot.json` 寫完之後
/// 可能被讀很久：`--login-item` 預設不裝，host app 沒有隨系統登入啟動的話，重開機後
/// host app 根本不會再跑；widget 卻仍會靠自己的 `TimelineProvider` 每 15 分鐘重新整理，
/// 一次又一次把同一份越來越舊的 snapshot 當成「現在」渲染——ring 停在最後一次的百分比，
/// 倒數計時因為已經過了 `resetsAt` 反而開始往回數「N 小時前」。
///
/// 這裡把寫入端已經有的兩條規則原樣搬到讀端再執行一次：
///
/// 1. 視窗一旦過了 `resetsAt`，舊百分比就毫無意義——回傳 nil，跟 `UsageStore.makeWindow`
///    的規則完全一致（同一句「寧可顯示不知道，也不顯示可能是錯的數字」）。
/// 2. snapshot 距離上次寫入超過寬限期，就不能再當作「目前為準」呈現——降級成
///    `.estimated`，讓 widget 的信心度標籤如實反映「這是凍結的舊讀數」，而不是繼續用
///    `.exact` 或 `.interpolated` 暗示這個數字剛剛才算出來。
///
/// 純函式，不做 I/O、不讀時鐘——`now` 一律由呼叫端注入，因此完全可測。
public struct SnapshotPresenter {

    private let staleAfter: TimeInterval

    /// 預設沿用 `UsageStore` 既有的寬限期常數，不另外發明第二個「多久算舊」的數字。
    public init(staleAfter: TimeInterval = UsageStore.defaultAPIFailureGracePeriod) {
        self.staleAfter = staleAfter
    }

    public func present(_ snapshot: UsageSnapshot, now: Date) -> UsageSnapshot {
        let isStale = now.timeIntervalSince(snapshot.updatedAt) > staleAfter

        let session = present(snapshot.session, now: now, isStale: isStale)
        let weekly = present(snapshot.weekly, now: now, isStale: isStale)

        // 跟 `UsageStore.makeSnapshot` 用同一套判斷，但拆成兩層，理由見 defect 2：
        // 「視窗剛重置、API 其實健康」跟「真的過舊／打不通」不是同一件事，訊息不能混。
        // 已經是更明確的失敗狀態（`.signedOut` / `.noData`）一律不覆寫——那些狀態底下
        // 本來就沒有視窗可言。
        var state = snapshot.state
        if isStale {
            // 放太久：不論寫入當下判的是 `.ok` 還是 `.windowResetPending`，現在都不能
            // 再說「只是視窗剛重置、稍後自動更新」——host app 可能根本沒在跑，不會有人
            // 幫忙把新讀數寫進來，這才是真正的「打不通／看不到」。
            if state == .ok || state == .windowResetPending {
                state = .apiUnavailable
            }
        } else if state == .ok, session == nil || weekly == nil {
            // snapshot 本身仍新鮮，只是視窗在讀取當下（而非寫入當下）跨過了
            // `resetsAt`——跟寫入端同一種「剛重置」情況，不是 API 出問題。
            state = .windowResetPending
        }

        return UsageSnapshot(
            schemaVersion: snapshot.schemaVersion,
            updatedAt: snapshot.updatedAt,
            officialFetchedAt: snapshot.officialFetchedAt,
            session: session,
            weekly: weekly,
            state: state
        )
    }

    private func present(_ window: SnapshotWindow?, now: Date, isStale: Bool) -> SnapshotWindow? {
        guard let window, now < window.resetsAt else { return nil }
        guard isStale, window.confidence != .estimated else { return window }
        return SnapshotWindow(
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt,
            confidence: .estimated
        )
    }
}

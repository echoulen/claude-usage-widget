import Foundation

/// 一次 API 取樣，以及取樣當下的本機 token 累計值。
/// 兩者配對才能算出「每個本機 token 對應多少百分點」。
public struct APISample: Equatable, Sendable {
    public let usage: OfficialUsage
    public let localTokensAtFetch: Int

    public init(usage: OfficialUsage, localTokensAtFetch: Int) {
        self.usage = usage
        self.localTokensAtFetch = localTokensAtFetch
    }
}

/// 把官方 API 資料與本機 token 統計合併成一份 snapshot。
///
/// 純函式，不做 I/O、不讀時鐘 —— `now` 一律由呼叫端注入，因此完全可測。
public struct UsageStore {

    /// API 連續失敗超過這麼久，讀數才降級為「僅供參考」；讀寫兩側共用同一個數字，
    /// 避免各自定義出兩個「多久算舊」的答案。也給讀端（widget 的 `SnapshotPresenter`）
    /// 重用，而不是各自硬寫一次 1800。
    public static let defaultAPIFailureGracePeriod: TimeInterval = 1800

    /// 兩次 API 取樣至少要間隔這麼久，才信任兩者算出的「每 token 對應多少百分點」。
    /// 手動重新整理按太快（見 `UsageCoordinator.refreshNow` 的 debounce）或系統時鐘抖動，
    /// 都可能把分母（取樣間隔）壓到趨近於零，讓 rate 失真到離譜的量級——這是 Blocking 2
    /// 的成因之一。30 秒遠低於平常的輪詢週期（10 分鐘），只用來擋「幾乎同時的兩次取樣」
    /// 這種病態情況。`UsageCoordinator` 的手動刷新 debounce 直接重用同一個數字，讓兩層
    /// 防線用同一把尺。
    public static let minSampleInterval: TimeInterval = 30

    /// 兩次取樣之間，本機 token 至少要成長這麼多，才信任用它算出的 rate。單一輪
    /// assistant 回覆常見的 cache_read token 就有數十萬（見 design doc §6.2 的實測樣本
    /// 352509）；1000 只是一個很低的門檻，用來擋「本機幾乎沒有活動」的病態分母，
    /// 不是想反映真實的活動量級。
    public static let minSampleTokenDelta = 1_000

    /// 外插結果與最新 API 讀數之間，最多容許差這麼多百分點。API 輪詢週期是 10 分鐘，
    /// 沒有正常使用場景能在這麼短時間內把用量真的推移超過整個額度的四分之一；算出來
    /// 若超過這個界線，幾乎可以確定是分子（官方 API，涵蓋所有裝置）與分母（僅本機
    /// transcript token）這兩個不同母體被誤當同一件事相除（Blocking 2 的成因），而不是
    /// 真實暴衝。這是偵測用的界線，不是拿來夾住數字用的——踩到就直接放棄外插、
    /// 退回最新的官方原始值。
    public static let maxPlausibleProjectedDelta: Double = 25

    public let apiFailureGracePeriod: TimeInterval

    public init(apiFailureGracePeriod: TimeInterval = UsageStore.defaultAPIFailureGracePeriod) {
        self.apiFailureGracePeriod = apiFailureGracePeriod
    }

    /// 「下一次該在幾秒後打 API」的純函式。平常用 flat `interval`；但若手上任一視窗
    /// 即將重置，改成提早在重置之後留一點 `buffer` 再打，不再傻等滿一整個 flat interval
    /// 才發現視窗已經空了——這正是 session ring 在每次 5 小時視窗重置後最長空白 10 分鐘
    /// 的成因（`UsageCoordinator.apiInterval` 原本是盲目的 600 秒）。
    ///
    /// - Parameters:
    ///   - now: 目前時間，測試需要注入。
    ///   - resetsAt: 目前手上持有的視窗重置時間（例如最新一次 API 樣本的 session／weekly
    ///     `resetsAt`）。可能是空陣列——例如冷啟動、還從未成功打過一次 API。
    ///   - interval: 平常的輪詢週期（flat interval）；沒有視窗即將重置時就是這個數字。
    ///   - buffer: 重置時刻之後再多留幾秒，讓伺服器端有機會真的把視窗翻過去——
    ///     太早打大機率還是拿到重置前的舊讀數。
    ///   - floor: 兩次輪詢之間的下限。重用 `minSampleInterval`，不另外發明第二個
    ///     「取樣至少要隔多久」的數字：打太密會直接把 `makeWindow` 賴以判斷外插可信度的
    ///     `sampleInterval` 壓到失真（見該常數的文件註解）。
    /// - Returns: 距離下一次該打 API 還要睡多久（秒），保證 `>= floor`。
    public static func nextAPIPollDelay(
        now: Date,
        resetsAt: [Date],
        interval: TimeInterval,
        buffer: TimeInterval = 5,
        floor: TimeInterval = UsageStore.minSampleInterval
    ) -> TimeInterval {
        let flatDeadline = now.addingTimeInterval(interval)
        // 已經過去的重置時間不能當「即將重置」處理——那代表這一輪本來就該處理過了，
        // 若不濾掉，算出來的 deadline 會落在 now 之前甚至等於 now，讓呼叫端睡負值／零秒，
        // 變成忙迴圈。過去式的重置一律當成「沒有已知的即將重置」，退回 flat interval。
        let earliestUpcomingReset = resetsAt.filter { $0 > now }.min()
        let deadline = earliestUpcomingReset
            .map { min(flatDeadline, $0.addingTimeInterval(buffer)) } ?? flatDeadline
        return max(deadline.timeIntervalSince(now), floor)
    }

    public func makeSnapshot(
        latest: APISample?,
        previous: APISample?,
        localTokensNow: Int,
        lastAPIFailureSince: Date?,
        now: Date
    ) -> UsageSnapshot {

        guard let latest else {
            return UsageSnapshot(
                updatedAt: now, session: nil, weekly: nil, state: .signedOut
            )
        }

        let degraded = lastAPIFailureSince.map {
            now.timeIntervalSince($0) > apiFailureGracePeriod
        } ?? false

        // 兩次 API 取樣本身相隔多久——跟 sampleTokenDelta 一樣是外插能不能信任的前提，
        // 在這裡算一次給 session／weekly 共用（同一對 APISample，時間差當然相同）。
        let sampleInterval = previous.map { latest.usage.fetchedAt.timeIntervalSince($0.usage.fetchedAt) }

        let session = makeWindow(
            latest: latest.usage.session,
            previous: previous?.usage.session,
            tokenDelta: localTokensNow - latest.localTokensAtFetch,
            sampleTokenDelta: previous.map { latest.localTokensAtFetch - $0.localTokensAtFetch },
            sampleInterval: sampleInterval,
            degraded: degraded,
            now: now
        )

        let weekly = makeWindow(
            latest: latest.usage.weekly,
            previous: previous?.usage.weekly,
            tokenDelta: localTokensNow - latest.localTokensAtFetch,
            sampleTokenDelta: previous.map { latest.localTokensAtFetch - $0.localTokensAtFetch },
            sampleInterval: sampleInterval,
            degraded: degraded,
            now: now
        )

        // `degraded` 代表 API 真的連續失敗超過寬限期，是唯一該說「打不通」的情況。
        // session／weekly 為 nil 只可能來自 `makeWindow` 的「已過 resetsAt」分支
        // （見其文件註解），跟 API 健不健康是兩件事：一個視窗剛重置、正等著下一次官方
        // 讀數，不該被說成「API 暫時無法取得」——那是在 API 完全正常時說謊（defect 2）。
        let state: SnapshotState
        if degraded {
            state = .apiUnavailable
        } else if session == nil || weekly == nil {
            state = .windowResetPending
        } else {
            state = .ok
        }

        return UsageSnapshot(
            updatedAt: now,
            officialFetchedAt: latest.usage.fetchedAt,
            session: session, weekly: weekly, state: state
        )
    }

    /// 重置時間已過的視窗回傳 nil —— 舊百分比在重置後毫無意義，
    /// 寧可顯示「不知道」也不顯示可能是錯的數字。
    private func makeWindow(
        latest: UsageWindow,
        previous: UsageWindow?,
        tokenDelta: Int,
        sampleTokenDelta: Int?,
        sampleInterval: TimeInterval?,
        degraded: Bool,
        now: Date
    ) -> SnapshotWindow? {
        guard now < latest.resetsAt else { return nil }

        guard !degraded else {
            // 這裡刻意不做任何本機外插——見 `Confidence.estimated` 的文件註解，
            // 這個分支呈現的是原封不動的最後一次官方讀數，只是誠實標成「舊」。
            return SnapshotWindow(
                usedPercent: latest.usedPercent,
                resetsAt: latest.resetsAt,
                confidence: .estimated
            )
        }

        let exact = SnapshotWindow(
            usedPercent: latest.usedPercent,
            resetsAt: latest.resetsAt,
            confidence: .exact
        )

        guard let previous,
              previous.resetsAt == latest.resetsAt,
              let sampleTokenDelta, sampleTokenDelta >= Self.minSampleTokenDelta,
              tokenDelta > 0,
              let sampleInterval, sampleInterval >= Self.minSampleInterval
        else {
            return exact
        }

        let percentDelta = latest.usedPercent - previous.usedPercent
        let ratePerToken = percentDelta / Double(sampleTokenDelta)
        let projected = latest.usedPercent + ratePerToken * Double(tokenDelta)

        // 把 [0, 100] 與「跟最新讀數差多少」這兩個檢查當成**偵測器**，不是修正器：
        // 只要外插結果不合理，就代表分子（官方 API，涵蓋所有裝置）跟分母（僅本機
        // transcript token）這兩個母體對不上（Blocking 2），不是真的暴衝。與其夾出一個
        // 看起來篤定、實則捏造的數字，不如直接放棄外插、退回最新的官方原始值——
        // 顯示「上一個可信的數字」是誠實的，顯示編出來的 100% 不是。
        guard projected >= 0, projected <= 100,
              abs(projected - latest.usedPercent) <= Self.maxPlausibleProjectedDelta
        else {
            return exact
        }

        return SnapshotWindow(
            usedPercent: projected,
            resetsAt: latest.resetsAt,
            confidence: .interpolated
        )
    }
}

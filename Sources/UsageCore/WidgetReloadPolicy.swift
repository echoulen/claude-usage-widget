import Foundation

/// 「這一輪 publish 該不該真的叫 widget reload」的純決策——不碰 `WidgetCenter`，
/// 因此完全可測（`WidgetCenter` 呼叫本身仍留在 app target 的 `WidgetBridge`，那裡沒有
/// 可測的邏輯，只是把這裡算出來的決定付諸執行）。
///
/// defect 3 的第二輪修復：`forceReload` 只在「snapshot 遞送狀態剛從失敗轉為成功」那一次
/// publish 為 true，下一輪就變回 false——它是一個邊緣事件（edge），不是持續的狀態。
/// 但 `minimumInterval` 節流是獨立的一條線，兩者疊在一起時，被節流擋下的那一次
/// `forceReload` 意圖如果就這樣被丟掉，永遠不會有人再幫忙重試一次，widget 又會空等自己
/// 最長 15 分鐘的 timeline 排程——跟 defect 3 原本要解決的問題一模一樣。這裡把它變成一個
/// latch（`pendingForceReload`）：一旦某次呼叫「想」強制 reload 卻被節流擋下，就把這個
/// 意圖记住、原样交回给呼叫端，下一輪呼叫再傳回來繼續帶著它重試，直到真的 reload 成功
/// 為止（`Decision.pendingForceReload` 變回 `false`）。
///
/// 單純因為數值變動（`valuesChanged`）而想 reload、卻被節流擋下的情況**不需要**這個
/// latch：只要 `lastPushed` 沒被更新，數值變動這個條件在下一輪重新求值時本來就還是
/// `true`，會自然重新觸發，不會被遺忘——只有一次性的邊緣事件（`forceReload`）才會在
/// 下一輪憑空消失，才需要额外记住。
public enum WidgetReloadPolicy {

    public struct Decision: Equatable, Sendable {
        /// 這一次呼叫端該不該真的去 reload widget timeline。
        public let shouldReload: Bool
        /// 呼叫端要記住、下一次呼叫再原樣傳回來的 latch 狀態。
        public let pendingForceReload: Bool

        public init(shouldReload: Bool, pendingForceReload: Bool) {
            self.shouldReload = shouldReload
            self.pendingForceReload = pendingForceReload
        }
    }

    /// - Parameters:
    ///   - snapshot: 這一輪要推送的 snapshot。
    ///   - lastPushed: 上一次實際推送成功時的 snapshot；`nil` 代表從未推送過。
    ///   - forceReload: 這一輪呼叫端是否明確要求強制 reload（defect 3：snapshot 遞送狀態
    ///     剛從失敗轉為成功）——只在事件發生的那一輪 publish 為 `true`。
    ///   - pendingForceReload: 呼叫端從上一次 `Decision.pendingForceReload` 原樣帶回來的
    ///     latch；代表「之前有一次想強制 reload、卻被節流擋下，還沒真的做到」。
    ///   - lastReload: 上一次實際 reload 的時間；`nil` 代表從未 reload 過。
    ///   - now: 目前時間，測試需要注入。
    ///   - minimumInterval: 兩次 reload 之間的下限——reload 預算有限，這條節流線本身
    ///     不能拿掉，defect 3 的修復只解決「意圖被節流擋下後就永遠消失」，不是拿掉節流。
    public static func decide(
        snapshot: UsageSnapshot,
        lastPushed: UsageSnapshot?,
        forceReload: Bool,
        pendingForceReload: Bool,
        lastReload: Date?,
        now: Date,
        minimumInterval: TimeInterval
    ) -> Decision {
        let valuesChanged = !isEquivalent(snapshot, lastPushed)
        let wantsReload = valuesChanged || forceReload || pendingForceReload

        guard wantsReload else {
            return Decision(shouldReload: false, pendingForceReload: false)
        }

        if let lastReload, now.timeIntervalSince(lastReload) < minimumInterval {
            // 被節流擋下。只有「強制」成分（這一輪新出現的 forceReload，或上一輪就已經在
            // 等的 pendingForceReload）需要 latch 住繼續等下一輪——單純的數值變動不需要，
            // 見上方型別文件註解。
            return Decision(shouldReload: false, pendingForceReload: forceReload || pendingForceReload)
        }

        return Decision(shouldReload: true, pendingForceReload: false)
    }

    /// 只有 `updatedAt` 不同不算變動——否則每次掃描都會推一次。
    private static func isEquivalent(_ lhs: UsageSnapshot, _ rhs: UsageSnapshot?) -> Bool {
        guard let rhs else { return false }
        return lhs.session == rhs.session
            && lhs.weekly == rhs.weekly
            && lhs.state == rhs.state
    }
}

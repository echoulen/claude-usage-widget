import Foundation
import WidgetKit
import UsageCore

/// 節流 widget 刷新。系統對 reloadTimelines 有自己的節流，
/// 高頻呼叫既無效也浪費，因此這裡先擋一層。
///
/// 決策邏輯本身（要不要 reload、`forceReload` 被節流擋下時的 latch）都在
/// `UsageCore.WidgetReloadPolicy`，是純函式、有完整測試（見 `WidgetReloadPolicyTests`）。
/// 這裡只保存跨呼叫的可變狀態（`lastReload`／`lastPushed`／`pendingForceReload`），
/// 並在決策為「要 reload」時真的去呼叫 `WidgetCenter`——那是唯一不可測、也不需要測的部分。
@MainActor
final class WidgetBridge {

    private let minimumInterval: TimeInterval
    private var lastReload: Date?
    private var lastPushed: UsageSnapshot?
    /// defect 3 的 latch：某次呼叫想強制 reload（`forceReload: true`）卻被 `minimumInterval`
    /// 節流擋下時，`WidgetReloadPolicy.decide` 會把這個意圖記在這裡，下一次呼叫原樣帶回去
    /// 繼續重試，直到真的 reload 成功為止——不會被單一輪的節流永久吞掉。
    private var pendingForceReload = false

    init(minimumInterval: TimeInterval = 60) {
        self.minimumInterval = minimumInterval
    }

    /// 一般情況只在數值實際變動且距上次推送夠久時才觸發（節流器，理由見 initializer）。
    ///
    /// `forceReload` 用來蓋掉「數值變動」這一條檢查——但**不**蓋掉 `minimumInterval` 節流，
    /// reload 預算依然有限。目前唯一的呼叫端是 defect 3：snapshot 遞送狀態剛從失敗
    /// （`.widgetContainerMissing` / `.writeDenied`）轉為 `.ok` 的那一刻，此時桌面 widget
    /// 的容器可能才第一次真的寫得進去，但這一輪算出來的用量數字很可能跟上一輪（寫入失敗前
    /// 記在 `lastPushed` 的那份）一模一樣，若不繞過數值比較，就會照舊被判定「沒變動」而
    /// 不推播。若這次剛好又被 `minimumInterval` 節流擋下，`pendingForceReload` 會記住這個
    /// 意圖並在下一輪重試，不會像單純「傳一次 forceReload」那樣被節流永久吞掉。
    func pushIfNeeded(_ snapshot: UsageSnapshot, forceReload: Bool = false, now: Date = Date()) {
        let decision = WidgetReloadPolicy.decide(
            snapshot: snapshot,
            lastPushed: lastPushed,
            forceReload: forceReload,
            pendingForceReload: pendingForceReload,
            lastReload: lastReload,
            now: now,
            minimumInterval: minimumInterval
        )
        pendingForceReload = decision.pendingForceReload
        guard decision.shouldReload else { return }

        WidgetCenter.shared.reloadTimelines(ofKind: "UsageWidget")
        lastReload = now
        lastPushed = snapshot
    }
}

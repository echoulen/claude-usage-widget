import Testing
import Foundation
@testable import UsageCore

/// `WidgetReloadPolicy.decide` 是 defect 3 第二輪修復的核心：`forceReload` 是一次性的邊緣
/// 事件（只在遞送狀態剛從失敗轉為成功那一輪 publish 為 true），若被 `minimumInterval`
/// 節流擋下卻沒有記住，這個意圖就永遠消失，widget 又會空等自己最長 15 分鐘的 timeline
/// 排程——equivalent 於 defect 3 原本要解決的問題。
@Suite("WidgetReloadPolicy")
struct WidgetReloadPolicyTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(usedPercent: Double, state: SnapshotState = .ok) -> UsageSnapshot {
        UsageSnapshot(
            updatedAt: Self.t0,
            session: SnapshotWindow(
                usedPercent: usedPercent, resetsAt: Self.t0.addingTimeInterval(5 * 3600), confidence: .exact
            ),
            weekly: SnapshotWindow(
                usedPercent: 10, resetsAt: Self.t0.addingTimeInterval(7 * 86400), confidence: .exact
            ),
            state: state
        )
    }

    @Test("數值變動、從未推送過：直接 reload")
    func reloadsOnFirstPush() {
        let decision = WidgetReloadPolicy.decide(
            snapshot: snapshot(usedPercent: 10),
            lastPushed: nil,
            forceReload: false,
            pendingForceReload: false,
            lastReload: nil,
            now: Self.t0,
            minimumInterval: 60
        )
        #expect(decision.shouldReload)
        #expect(!decision.pendingForceReload)
    }

    @Test("數值沒變、沒有 forceReload：不 reload，也不 latch")
    func doesNotReloadWhenNothingChanged() {
        let same = snapshot(usedPercent: 10)
        let decision = WidgetReloadPolicy.decide(
            snapshot: same,
            lastPushed: same,
            forceReload: false,
            pendingForceReload: false,
            lastReload: Self.t0,
            now: Self.t0.addingTimeInterval(5),
            minimumInterval: 60
        )
        #expect(!decision.shouldReload)
        #expect(!decision.pendingForceReload)
    }

    @Test("forceReload 且未被節流：直接 reload，latch 清空")
    func forceReloadFiresImmediatelyWhenNotThrottled() {
        let same = snapshot(usedPercent: 10)
        let decision = WidgetReloadPolicy.decide(
            snapshot: same,
            lastPushed: same,
            forceReload: true,
            pendingForceReload: false,
            lastReload: Self.t0,
            now: Self.t0.addingTimeInterval(61),   // 距上次 reload 已超過 60 秒
            minimumInterval: 60
        )
        #expect(decision.shouldReload)
        #expect(!decision.pendingForceReload)
    }

    @Test("forceReload 被 minimumInterval 節流擋下：不 reload，但意圖被 latch 住，不會憑空消失")
    func throttledForceReloadIsLatchedNotDropped() {
        let same = snapshot(usedPercent: 10)
        let decision = WidgetReloadPolicy.decide(
            snapshot: same,
            lastPushed: same,
            forceReload: true,
            pendingForceReload: false,
            lastReload: Self.t0,
            now: Self.t0.addingTimeInterval(30),   // 距上次 reload 只有 30 秒 < 60 秒
            minimumInterval: 60
        )
        #expect(!decision.shouldReload)
        #expect(decision.pendingForceReload)
    }

    @Test("latch 住的 pendingForceReload，即使這一輪 forceReload 已經變回 false，只要仍在節流窗內就繼續 latch")
    func pendingForceReloadPersistsAcrossCyclesWhileStillThrottled() {
        let same = snapshot(usedPercent: 10)
        // 上一輪：forceReload 曾經是 true 且被擋下，latch 住。這一輪 forceReload 已經變回
        // false（邊緣事件只發生一次），但 pendingForceReload 原樣從呼叫端傳回來。
        let decision = WidgetReloadPolicy.decide(
            snapshot: same,
            lastPushed: same,
            forceReload: false,
            pendingForceReload: true,
            lastReload: Self.t0,
            now: Self.t0.addingTimeInterval(45),   // 仍在節流窗內
            minimumInterval: 60
        )
        #expect(!decision.shouldReload)
        #expect(decision.pendingForceReload)
    }

    @Test("latch 住的 pendingForceReload，等到節流窗過了就真的 reload、latch 清空")
    func pendingForceReloadEventuallyFiresOnceThrottleWindowPasses() {
        let same = snapshot(usedPercent: 10)
        let decision = WidgetReloadPolicy.decide(
            snapshot: same,
            lastPushed: same,
            forceReload: false,
            pendingForceReload: true,
            lastReload: Self.t0,
            now: Self.t0.addingTimeInterval(61),   // 節流窗剛過
            minimumInterval: 60
        )
        #expect(decision.shouldReload)
        #expect(!decision.pendingForceReload)
    }

    @Test("單純數值變動被節流擋下：不需要 latch——數值變動本身下一輪會自然重新觸發")
    func throttledValueChangeDoesNotNeedLatch() {
        let decision = WidgetReloadPolicy.decide(
            snapshot: snapshot(usedPercent: 20),
            lastPushed: snapshot(usedPercent: 10),
            forceReload: false,
            pendingForceReload: false,
            lastReload: Self.t0,
            now: Self.t0.addingTimeInterval(10),   // 被節流擋下
            minimumInterval: 60
        )
        #expect(!decision.shouldReload)
        #expect(!decision.pendingForceReload)
    }

    @Test("六步驟重現場景：新裝 widget 的強制 reload 被節流擋下後，即使數值之後都沒再變、也沒有新的 forceReload 事件，仍會在節流窗過後補上那次 reload")
    func reproducesSixStepScenarioFromReview() {
        let baseline = snapshot(usedPercent: 10)
        let afterConversation = snapshot(usedPercent: 12)

        // 1) 使用者結束對話，本機 token 讓百分比變動，在時間 t 觸發一次真正的 reload。
        let t = Self.t0
        let step1 = WidgetReloadPolicy.decide(
            snapshot: afterConversation,
            lastPushed: baseline,
            forceReload: false,
            pendingForceReload: false,
            lastReload: nil,
            now: t,
            minimumInterval: 60
        )
        #expect(step1.shouldReload)   // lastReload = t, lastPushed = afterConversation

        // 2)/3) t+30s：widget 容器剛建立、host app 第一次寫入成功，
        //    snapshotDeliveryStatus 從失敗轉 .ok，UsageCoordinator 傳入 forceReload: true。
        //    這一輪的數值（假設使用者已閒置）跟 afterConversation 相同，若不是 forceReload
        //    本來就不會想 reload；但因為距上次 reload（t）只過了 30 秒 < 60 秒，被節流擋下。
        let step2 = WidgetReloadPolicy.decide(
            snapshot: afterConversation,
            lastPushed: afterConversation,
            forceReload: true,
            pendingForceReload: false,
            lastReload: t,
            now: t.addingTimeInterval(30),
            minimumInterval: 60
        )
        #expect(!step2.shouldReload)          // 這一輪還是被節流擋下……
        #expect(step2.pendingForceReload)     // ……但意圖被 latch 住，不是憑空消失。

        // 4)/5) 使用者閒置，之後幾輪 publish 數值都跟 afterConversation 相同、也沒有新的
        //    forceReload 事件（狀態已經是 .ok，不會再從失敗轉成功）。若沒有 latch，
        //    這裡永遠不會再有人請求 reload——這正是這一輪 review 抓到的 regression。
        //    帶著上一輪的 pendingForceReload 繼續呼叫，模擬下一次 scanLocal 週期（t+45s，
        //    仍在節流窗內）：
        let step3 = WidgetReloadPolicy.decide(
            snapshot: afterConversation,
            lastPushed: afterConversation,
            forceReload: false,
            pendingForceReload: step2.pendingForceReload,
            lastReload: t,
            now: t.addingTimeInterval(45),
            minimumInterval: 60
        )
        #expect(!step3.shouldReload)          // 節流窗（t+60）還沒過。
        #expect(step3.pendingForceReload)     // 意圖持續 latch。

        // 6) 節流窗終於過了（t+61s）：即使數值仍相同、也沒有新的 forceReload 事件，
        //    latch 住的意圖讓 reload 終於真的發生——widget 不會永遠空等自己的 timeline 排程。
        let step4 = WidgetReloadPolicy.decide(
            snapshot: afterConversation,
            lastPushed: afterConversation,
            forceReload: false,
            pendingForceReload: step3.pendingForceReload,
            lastReload: t,
            now: t.addingTimeInterval(61),
            minimumInterval: 60
        )
        #expect(step4.shouldReload)
        #expect(!step4.pendingForceReload)
    }
}

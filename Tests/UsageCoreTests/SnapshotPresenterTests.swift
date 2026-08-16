import Testing
import Foundation
@testable import UsageCore

@Suite("SnapshotPresenter")
struct SnapshotPresenterTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// 跟 production 預設一致：直接沿用 `UsageStore.defaultAPIFailureGracePeriod`（1800 秒），
    /// 不另外發明一個測試專用的門檻數字。
    private let presenter = SnapshotPresenter()

    private func snapshot(
        updatedAt: Date,
        officialFetchedAt: Date? = nil,
        session: SnapshotWindow?,
        weekly: SnapshotWindow?,
        state: SnapshotState = .ok
    ) -> UsageSnapshot {
        UsageSnapshot(
            updatedAt: updatedAt, officialFetchedAt: officialFetchedAt,
            session: session, weekly: weekly, state: state
        )
    }

    private func window(
        usedPercent: Double = 40,
        resetsAt: Date,
        confidence: Confidence = .exact
    ) -> SnapshotWindow {
        SnapshotWindow(usedPercent: usedPercent, resetsAt: resetsAt, confidence: confidence)
    }

    @Test("新鮮的 snapshot 原封不動地通過")
    func freshSnapshotPassesThroughUntouched() {
        let original = snapshot(
            updatedAt: Self.t0,
            session: window(usedPercent: 40, resetsAt: Self.t0.addingTimeInterval(5 * 3600), confidence: .exact),
            weekly: window(usedPercent: 60, resetsAt: Self.t0.addingTimeInterval(7 * 86400), confidence: .interpolated)
        )
        let presented = presenter.present(original, now: Self.t0.addingTimeInterval(60))
        #expect(presented == original)
    }

    @Test("視窗已過 resetsAt 時整個拿掉，即使 snapshot 本身還很新鮮——state 是 windowResetPending 不是 apiUnavailable（defect 2）")
    func windowPastResetIsDropped() {
        let original = snapshot(
            updatedAt: Self.t0,
            session: window(usedPercent: 80, resetsAt: Self.t0.addingTimeInterval(-1), confidence: .exact),
            weekly: window(usedPercent: 60, resetsAt: Self.t0.addingTimeInterval(7 * 86400), confidence: .exact)
        )
        let presented = presenter.present(original, now: Self.t0)
        #expect(presented.session == nil)
        // weekly 沒過期、snapshot 也沒有放太久,原樣保留。
        #expect(presented.weekly == original.weekly)
        // API 本身沒有任何問題（snapshot 新鮮），只是視窗剛重置——不能說成 apiUnavailable。
        #expect(presented.state == .windowResetPending)
    }

    @Test("視窗剛重置且 snapshot 已經放到超過寬限期：升級為真正的 apiUnavailable，不再說「稍後自動更新」")
    func windowResetCombinedWithStalenessBecomesApiUnavailable() {
        let original = snapshot(
            updatedAt: Self.t0,
            session: window(usedPercent: 80, resetsAt: Self.t0.addingTimeInterval(-1), confidence: .exact),
            weekly: window(usedPercent: 60, resetsAt: Self.t0.addingTimeInterval(7 * 86400), confidence: .exact)
        )
        // 超過 1800 秒寬限期一分鐘：host app 很可能根本沒在跑，不會有新讀數自動補上。
        let presented = presenter.present(original, now: Self.t0.addingTimeInterval(1800 + 60))
        #expect(presented.session == nil)
        #expect(presented.state == .apiUnavailable)
    }

    @Test("已經是更明確失敗狀態（signedOut）時，視窗重置不會覆寫成 windowResetPending")
    func windowResetPendingDoesNotOverwriteMoreSpecificFailureState() {
        let original = snapshot(
            updatedAt: Self.t0,
            session: nil,
            weekly: nil,
            state: .signedOut
        )
        let presented = presenter.present(original, now: Self.t0.addingTimeInterval(60))
        #expect(presented.state == .signedOut)
    }

    @Test("snapshot 距離上次寫入超過寬限期時降級為 estimated")
    func snapshotOlderThanThresholdIsDegraded() {
        let original = snapshot(
            updatedAt: Self.t0,
            session: window(usedPercent: 12, resetsAt: Self.t0.addingTimeInterval(5 * 3600), confidence: .exact),
            weekly: window(usedPercent: 34, resetsAt: Self.t0.addingTimeInterval(7 * 86400), confidence: .interpolated)
        )
        // 超過 1800 秒的寬限期一分鐘。
        let now = Self.t0.addingTimeInterval(1800 + 60)
        let presented = presenter.present(original, now: now)

        let session = presented.session
        let weekly = presented.weekly
        #expect(session?.usedPercent == 12)
        #expect(session?.confidence == .estimated)
        #expect(weekly?.usedPercent == 34)
        #expect(weekly?.confidence == .estimated)
        #expect(presented.state == .apiUnavailable)
    }

    @Test("恰好等於寬限期門檻時仍算新鮮，不降級（跟 UsageStore 的 > 語意一致）")
    func exactlyAtThresholdIsStillFresh() {
        let original = snapshot(
            updatedAt: Self.t0,
            session: window(usedPercent: 12, resetsAt: Self.t0.addingTimeInterval(5 * 3600), confidence: .exact),
            weekly: nil
        )
        let now = Self.t0.addingTimeInterval(1800)   // 恰好等於門檻，不是超過。
        let presented = presenter.present(original, now: now)
        #expect(presented.session?.confidence == .exact)
    }

    @Test("超過門檻一秒即視為過舊，觸發降級")
    func oneSecondPastThresholdIsStale() {
        let original = snapshot(
            updatedAt: Self.t0,
            session: window(usedPercent: 12, resetsAt: Self.t0.addingTimeInterval(5 * 3600), confidence: .exact),
            weekly: nil
        )
        let now = Self.t0.addingTimeInterval(1801)
        let presented = presenter.present(original, now: now)
        #expect(presented.session?.confidence == .estimated)
    }

    @Test("已經是 estimated 的視窗，降級判斷是幂等的")
    func alreadyEstimatedStaysEstimated() {
        let original = snapshot(
            updatedAt: Self.t0,
            session: window(usedPercent: 12, resetsAt: Self.t0.addingTimeInterval(5 * 3600), confidence: .estimated),
            weekly: nil,
            state: .apiUnavailable
        )
        let now = Self.t0.addingTimeInterval(3600)
        let presented = presenter.present(original, now: now)
        #expect(presented.session?.confidence == .estimated)
        #expect(presented.session?.usedPercent == 12)
    }

    @Test("已經是更明確失敗狀態（signedOut）時不覆寫成 apiUnavailable")
    func doesNotOverwriteMoreSpecificFailureState() {
        let original = snapshot(updatedAt: Self.t0, session: nil, weekly: nil, state: .signedOut)
        let presented = presenter.present(original, now: Self.t0.addingTimeInterval(3600))
        #expect(presented.state == .signedOut)
    }

    @Test("officialFetchedAt 原樣傳遞，不論 snapshot 是否被判定過舊")
    func passesThroughOfficialFetchedAt() {
        let fetchedAt = Self.t0.addingTimeInterval(-120)
        let original = snapshot(
            updatedAt: Self.t0,
            officialFetchedAt: fetchedAt,
            session: window(usedPercent: 12, resetsAt: Self.t0.addingTimeInterval(5 * 3600), confidence: .exact),
            weekly: window(usedPercent: 34, resetsAt: Self.t0.addingTimeInterval(7 * 86400), confidence: .interpolated)
        )
        // 新鮮的情況。
        let fresh = presenter.present(original, now: Self.t0.addingTimeInterval(60))
        #expect(fresh.officialFetchedAt == fetchedAt)

        // 過舊、觸發降級的情況——officialFetchedAt 描述的是官方讀數本身多舊，
        // 跟這份 snapshot 有沒有被判定過舊是兩件事，不該被降級判斷影響。
        let stale = presenter.present(original, now: Self.t0.addingTimeInterval(1800 + 60))
        #expect(stale.officialFetchedAt == fetchedAt)
    }

    @Test("沒有 officialFetchedAt 的舊版 snapshot，present() 之後仍是 nil")
    func missingOfficialFetchedAtStaysNil() {
        let original = snapshot(
            updatedAt: Self.t0,
            session: window(usedPercent: 12, resetsAt: Self.t0.addingTimeInterval(5 * 3600), confidence: .exact),
            weekly: nil
        )
        let presented = presenter.present(original, now: Self.t0.addingTimeInterval(1801))
        #expect(presented.officialFetchedAt == nil)
    }

    @Test("自訂 staleAfter 也會被遵守")
    func respectsCustomStaleAfter() {
        let custom = SnapshotPresenter(staleAfter: 60)
        let original = snapshot(
            updatedAt: Self.t0,
            session: window(usedPercent: 12, resetsAt: Self.t0.addingTimeInterval(5 * 3600), confidence: .exact),
            weekly: nil
        )
        let presented = custom.present(original, now: Self.t0.addingTimeInterval(61))
        #expect(presented.session?.confidence == .estimated)
    }
}

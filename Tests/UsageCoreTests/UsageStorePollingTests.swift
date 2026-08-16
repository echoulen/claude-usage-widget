import Testing
import Foundation
@testable import UsageCore

/// `UsageStore.nextAPIPollDelay` 是 defect 1 的核心：重置感知輪詢。
/// `UsageCoordinator.apiInterval` 原本是盲目的 600 秒，即使某個視窗即將重置，
/// 也要傻等滿一整個 flat interval 才會發現視窗已經空了——session ring 因此在
/// 每次 5 小時視窗重置後最長空白 10 分鐘，一天發生約五次。
@Suite("UsageStore.nextAPIPollDelay")
struct UsageStorePollingTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("重置時間比 flat interval 更早：提早到重置之後 + buffer 就打，而不是傻等滿 flat interval")
    func resetSoonerThanIntervalShortensDelay() {
        // 重現 defect 1 描述的實況：13:49:39 觀測到 resets_at 只剩 21 秒。
        let delay = UsageStore.nextAPIPollDelay(
            now: Self.t0,
            resetsAt: [Self.t0.addingTimeInterval(21)],
            interval: 600,
            buffer: 5,
            floor: 30
        )
        // 21 + 5 buffer = 26 秒，但 floor 是 30 秒，取二者較大值。
        #expect(delay == 30)
        #expect(delay < 600)
    }

    @Test("重置時間比 flat interval 更晚：維持原本的 flat interval，不提早")
    func resetLaterThanIntervalKeepsFlatInterval() {
        let delay = UsageStore.nextAPIPollDelay(
            now: Self.t0,
            resetsAt: [Self.t0.addingTimeInterval(1_000)],
            interval: 600,
            buffer: 5,
            floor: 30
        )
        #expect(delay == 600)
    }

    @Test("重置時間已經過去：視為沒有已知的即將重置，退回 flat interval，不會睡負值或零秒")
    func pastResetFallsBackToFlatInterval() {
        let delay = UsageStore.nextAPIPollDelay(
            now: Self.t0,
            resetsAt: [Self.t0.addingTimeInterval(-10)],
            interval: 600,
            buffer: 5,
            floor: 30
        )
        #expect(delay == 600)
    }

    @Test("完全沒有已知視窗（例如冷啟動、還沒打過任何一次 API）：退回 flat interval")
    func noWindowsFallsBackToFlatInterval() {
        let delay = UsageStore.nextAPIPollDelay(
            now: Self.t0,
            resetsAt: [],
            interval: 600,
            buffer: 5,
            floor: 30
        )
        #expect(delay == 600)
    }

    @Test("floor 下限受尊重：即使重置近在眼前，也不會比 floor 更快發下一次請求")
    func floorIsRespectedEvenForImminentReset() {
        let delay = UsageStore.nextAPIPollDelay(
            now: Self.t0,
            resetsAt: [Self.t0.addingTimeInterval(1)],
            interval: 600,
            buffer: 5,
            floor: 30
        )
        #expect(delay == 30)
    }

    @Test("多個視窗時取最早的未來重置時間")
    func picksEarliestUpcomingResetAmongMultipleWindows() {
        let delay = UsageStore.nextAPIPollDelay(
            now: Self.t0,
            // weekly 還很久，session 快到了——應該被 session 主導。
            resetsAt: [Self.t0.addingTimeInterval(300_000), Self.t0.addingTimeInterval(100)],
            interval: 600,
            buffer: 5,
            floor: 30
        )
        #expect(delay == 105)   // 100 + buffer(5)
    }

    @Test("已過去的重置與尚未到來的重置混在一起時，只採計尚未到來的那個")
    func ignoresPastResetsWhenPickingEarliest() {
        let delay = UsageStore.nextAPIPollDelay(
            now: Self.t0,
            resetsAt: [Self.t0.addingTimeInterval(-5), Self.t0.addingTimeInterval(50)],
            interval: 600,
            buffer: 5,
            floor: 30
        )
        #expect(delay == 55)   // 50 + buffer(5)
    }

    @Test("預設參數：buffer 為 5 秒、floor 沿用 UsageStore.minSampleInterval")
    func usesDocumentedDefaults() {
        let delay = UsageStore.nextAPIPollDelay(
            now: Self.t0,
            resetsAt: [Self.t0.addingTimeInterval(1)],
            interval: 600
        )
        #expect(delay == UsageStore.minSampleInterval)
    }
}

import Testing
import Foundation
@testable import UsageCore

@Suite("UsageStore")
struct UsageStoreTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let store = UsageStore()

    private func usage(
        sessionPercent: Double,
        weeklyPercent: Double,
        at offset: TimeInterval = 0
    ) -> OfficialUsage {
        OfficialUsage(
            session: UsageWindow(
                usedPercent: sessionPercent,
                resetsAt: Self.t0.addingTimeInterval(5 * 3600)
            ),
            weekly: UsageWindow(
                usedPercent: weeklyPercent,
                resetsAt: Self.t0.addingTimeInterval(7 * 86400)
            ),
            fetchedAt: Self.t0.addingTimeInterval(offset)
        )
    }

    @Test("只有一次取樣時直接採用 API 值，信心度為 exact")
    func singleSampleIsExact() {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 40, weeklyPercent: 60), localTokensAtFetch: 1000),
            previous: nil,
            localTokensNow: 5000,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(60)
        )
        #expect(snapshot.state == .ok)
        #expect(snapshot.session?.usedPercent == 40)
        #expect(snapshot.session?.confidence == .exact)
        #expect(snapshot.weekly?.usedPercent == 60)
    }

    @Test("有兩次取樣時做線性外插，信心度為 interpolated")
    func interpolatesFromTwoSamples() throws {
        // 前次 30% @ 1000 tokens，最新 40% @ 2000 tokens → 每 token 0.01 個百分點
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 40, weeklyPercent: 60, at: 300), localTokensAtFetch: 2000),
            previous: APISample(usage: usage(sessionPercent: 30, weeklyPercent: 55), localTokensAtFetch: 1000),
            localTokensNow: 2500,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(400)
        )
        let session = try #require(snapshot.session)
        #expect(abs(session.usedPercent - 45.0) < 0.001)   // 40 + 0.01 * 500
        #expect(session.confidence == .interpolated)
    }

    @Test("本機 token 未增加時不外插")
    func noInterpolationWithoutNewTokens() throws {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 40, weeklyPercent: 60, at: 300), localTokensAtFetch: 2000),
            previous: APISample(usage: usage(sessionPercent: 30, weeklyPercent: 55), localTokensAtFetch: 1000),
            localTokensNow: 2000,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(400)
        )
        #expect(try #require(snapshot.session).usedPercent == 40)
    }

    @Test("兩次取樣的本機 token 相同時不除以零")
    func handlesZeroTokenDelta() throws {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 40, weeklyPercent: 60, at: 300), localTokensAtFetch: 1000),
            previous: APISample(usage: usage(sessionPercent: 30, weeklyPercent: 55), localTokensAtFetch: 1000),
            localTokensNow: 9999,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(400)
        )
        #expect(try #require(snapshot.session).usedPercent == 40)
        #expect(try #require(snapshot.session).confidence == .exact)
    }

    @Test("外插結果超出 0 到 100 範圍時放棄外插，退回最新的官方原始值（clamp 是偵測器，不是修正器）")
    func abandonsExtrapolationWhenProjectionExceedsValidRange() throws {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 95, weeklyPercent: 60, at: 300), localTokensAtFetch: 2000),
            previous: APISample(usage: usage(sessionPercent: 30, weeklyPercent: 55), localTokensAtFetch: 1000),
            localTokensNow: 100_000,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(400)
        )
        let session = try #require(snapshot.session)
        // 沒有被夾成一個看起來篤定的 100——而是退回最新的官方原始值 95，並如實標成 exact。
        #expect(session.usedPercent == 95)
        #expect(session.confidence == .exact)
    }

    @Test("兩個母體對不上導致外插結果超出合理範圍（雖然仍落在 0–100 內）時也放棄外插")
    func abandonsExtrapolationWhenProjectionExceedsSaneDeltaBound() throws {
        // 重現 Blocking 2 的場景：分子是涵蓋所有裝置的官方 utilization 差值，
        // 分母卻只是本機 token 差值——兩者不是同一個母體。這裡刻意讓算出來的 rate
        // 偏高到會把 projected 推出 latest ± maxPlausibleProjectedDelta 之外，
        // 但仍落在合法的 0...100 範圍內，藉此單獨驗證「跟最新值差太多」這條防線，
        // 不是靠 [0, 100] 那條防線意外擋下的。
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 10, weeklyPercent: 60, at: 300), localTokensAtFetch: 2000),
            previous: APISample(usage: usage(sessionPercent: 8, weeklyPercent: 55), localTokensAtFetch: 1000),
            localTokensNow: 22_000,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(400)
        )
        // rate = (10-8)/1000 = 0.002／token；tokenDelta = 22000-2000 = 20000
        // → projected = 10 + 0.002*20000 = 50，跟 latest(10) 差 40 > maxPlausibleProjectedDelta(25)，
        // 但 50 本身仍在 0...100 內，確認是差值防線而非範圍防線在起作用。
        let session = try #require(snapshot.session)
        #expect(session.usedPercent == 10)
        #expect(session.confidence == .exact)
    }

    @Test("兩次取樣的本機 token 差值低於最小門檻時不外插")
    func requiresMinimumSampleTokenDeltaToInterpolate() throws {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 40, weeklyPercent: 60, at: 300), localTokensAtFetch: 1999),
            previous: APISample(usage: usage(sessionPercent: 30, weeklyPercent: 55), localTokensAtFetch: 1000),
            localTokensNow: 5000,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(400)
        )
        // sampleTokenDelta = 1999 - 1000 = 999，低於門檻 1000。
        let session = try #require(snapshot.session)
        #expect(session.usedPercent == 40)
        #expect(session.confidence == .exact)
    }

    @Test("兩次 API 取樣間隔低於最小門檻時不外插")
    func requiresMinimumSampleIntervalToInterpolate() throws {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 40, weeklyPercent: 60, at: 29), localTokensAtFetch: 2000),
            previous: APISample(usage: usage(sessionPercent: 30, weeklyPercent: 55), localTokensAtFetch: 1000),
            localTokensNow: 5000,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(100)
        )
        // 兩次取樣只隔 29 秒，低於門檻 30 秒——即使 token 與時間差都夠，仍不信任這組樣本。
        let session = try #require(snapshot.session)
        #expect(session.usedPercent == 40)
        #expect(session.confidence == .exact)
    }

    @Test("剛好卡在門檻上（sampleTokenDelta、sampleInterval、maxPlausibleProjectedDelta 皆等於下限/上限）時仍會外插")
    func interpolatesExactlyAtGuardBoundaries() throws {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 40, weeklyPercent: 60, at: 30), localTokensAtFetch: 2000),
            previous: APISample(usage: usage(sessionPercent: 15, weeklyPercent: 55), localTokensAtFetch: 1000),
            localTokensNow: 3000,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(60)
        )
        // sampleTokenDelta = 1000（== 門檻）；sampleInterval = 30 秒（== 門檻）；
        // rate = (40-15)/1000 = 0.025；tokenDelta = 3000-2000 = 1000 →
        // projected = 40 + 0.025*1000 = 65，差值 25，恰好等於 maxPlausibleProjectedDelta。
        let session = try #require(snapshot.session)
        #expect(abs(session.usedPercent - 65.0) < 0.001)
        #expect(session.confidence == .interpolated)
    }

    @Test("視窗重置後不沿用舊的 session 百分比，且 state 是 windowResetPending 不是 apiUnavailable（defect 2：API 本身健康，不是打不通）")
    func doesNotCarryStaleSessionPastReset() {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 80, weeklyPercent: 60), localTokensAtFetch: 1000),
            previous: nil,
            localTokensNow: 1000,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(6 * 3600)   // 已超過 resetsAt
        )
        #expect(snapshot.session == nil)
        #expect(snapshot.state == .windowResetPending)
    }

    @Test("API 真的連續失敗超過寬限期時（degraded），即使視窗同時重置，state 仍是 apiUnavailable 不是 windowResetPending")
    func degradedTakesPriorityOverWindowReset() {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 80, weeklyPercent: 60), localTokensAtFetch: 1000),
            previous: nil,
            localTokensNow: 1000,
            lastAPIFailureSince: Self.t0,
            // 視窗已過 resetsAt（6 小時後）且 API 失敗已超過 30 分鐘寬限期。
            now: Self.t0.addingTimeInterval(6 * 3600)
        )
        #expect(snapshot.session == nil)
        #expect(snapshot.state == .apiUnavailable)
    }

    @Test("兩次取樣橫跨重置邊界時不外插")
    func doesNotInterpolateAcrossResetBoundary() throws {
        // 前次取樣屬於舊視窗（95% used，即將於 t0+1h 重置），
        // 最新取樣屬於重置後的新視窗（5% used，於 t0+6h 重置）。
        // 若誤把兩者當同一視窗做線性外插，Δpercent = 5 - 95 = -90，
        // 會把使用率往下拉甚至夾到 0 —— 亦即「剩餘 100%」，方向性地錯誤。
        let previousSample = APISample(
            usage: OfficialUsage(
                session: UsageWindow(usedPercent: 95, resetsAt: Self.t0.addingTimeInterval(3600)),
                weekly: UsageWindow(usedPercent: 55, resetsAt: Self.t0.addingTimeInterval(7 * 86400)),
                fetchedAt: Self.t0
            ),
            localTokensAtFetch: 1000
        )
        let latestSample = APISample(
            usage: OfficialUsage(
                session: UsageWindow(usedPercent: 5, resetsAt: Self.t0.addingTimeInterval(6 * 3600)),
                weekly: UsageWindow(usedPercent: 60, resetsAt: Self.t0.addingTimeInterval(7 * 86400)),
                fetchedAt: Self.t0.addingTimeInterval(3660)
            ),
            localTokensAtFetch: 2000
        )
        let snapshot = store.makeSnapshot(
            latest: latestSample,
            previous: previousSample,
            localTokensNow: 3000,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(2 * 3600)
        )
        let session = try #require(snapshot.session)
        #expect(session.usedPercent == 5)
        #expect(session.confidence == .exact)
    }

    @Test("完全沒有 API 取樣時為 signedOut")
    func noSampleIsSignedOut() {
        let snapshot = store.makeSnapshot(
            latest: nil, previous: nil, localTokensNow: 500,
            lastAPIFailureSince: nil, now: Self.t0
        )
        #expect(snapshot.state == .signedOut)
        #expect(snapshot.session == nil)
        #expect(snapshot.weekly == nil)
    }

    @Test("API 失敗但未超過寬限期時沿用最後快照")
    func keepsLastSnapshotDuringGracePeriod() throws {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 40, weeklyPercent: 60), localTokensAtFetch: 1000),
            previous: nil,
            localTokensNow: 1000,
            lastAPIFailureSince: Self.t0.addingTimeInterval(60),
            now: Self.t0.addingTimeInterval(600)   // 失敗 9 分鐘 < 30 分鐘寬限
        )
        #expect(snapshot.state == .ok)
        #expect(try #require(snapshot.session).usedPercent == 40)
    }

    @Test("API 連續失敗超過寬限期時降級為 estimated")
    func degradesAfterGracePeriod() throws {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 40, weeklyPercent: 60), localTokensAtFetch: 1000),
            previous: nil,
            localTokensNow: 1000,
            lastAPIFailureSince: Self.t0.addingTimeInterval(60),
            now: Self.t0.addingTimeInterval(3600)   // 失敗 59 分鐘 > 30 分鐘寬限
        )
        #expect(snapshot.state == .apiUnavailable)
        #expect(try #require(snapshot.session).confidence == .estimated)
    }

    @Test("updatedAt 使用傳入的 now")
    func stampsProvidedNow() {
        let now = Self.t0.addingTimeInterval(12345)
        let snapshot = store.makeSnapshot(
            latest: nil, previous: nil, localTokensNow: 0, lastAPIFailureSince: nil, now: now
        )
        #expect(snapshot.updatedAt == now)
    }

    @Test("有官方取樣時，officialFetchedAt 取自該次取樣的 fetchedAt，不是 updatedAt")
    func populatesOfficialFetchedAtFromLatestSample() {
        // fetchedAt（取樣時間）刻意跟 now（updatedAt，snapshot 寫入時間）不同，
        // 驗證兩者不會被混用——這正是 Blocking「凍結多久」bug 的成因。
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 40, weeklyPercent: 60, at: 30), localTokensAtFetch: 1000),
            previous: nil,
            localTokensNow: 1000,
            lastAPIFailureSince: nil,
            now: Self.t0.addingTimeInterval(9999)
        )
        #expect(snapshot.officialFetchedAt == Self.t0.addingTimeInterval(30))
        #expect(snapshot.officialFetchedAt != snapshot.updatedAt)
    }

    @Test("從未取得過 API 樣本（signedOut）時，officialFetchedAt 為 nil")
    func officialFetchedAtIsNilWhenSignedOut() {
        let snapshot = store.makeSnapshot(
            latest: nil, previous: nil, localTokensNow: 0, lastAPIFailureSince: nil, now: Self.t0
        )
        #expect(snapshot.officialFetchedAt == nil)
    }

    @Test("降級為 estimated 時，officialFetchedAt 仍是最後一次官方取樣的時間，不是 now")
    func officialFetchedAtSurvivesDegradation() {
        let snapshot = store.makeSnapshot(
            latest: APISample(usage: usage(sessionPercent: 40, weeklyPercent: 60, at: 30), localTokensAtFetch: 1000),
            previous: nil,
            localTokensNow: 1000,
            lastAPIFailureSince: Self.t0.addingTimeInterval(60),
            now: Self.t0.addingTimeInterval(3600)   // 失敗超過寬限期，進入 degraded
        )
        #expect(snapshot.state == .apiUnavailable)
        #expect(snapshot.officialFetchedAt == Self.t0.addingTimeInterval(30))
    }
}

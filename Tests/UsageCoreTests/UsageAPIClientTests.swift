import Testing
import Foundation
@testable import UsageCore

/// 依序回傳不同 status/body 的 transport 替身，用來模擬「這次呼叫內部先後打了不只一次
/// API」的情境（例如快取的憑證被 401 拒絕後的單次重試）。正式原始碼裡的 `StubTransport`
/// 每次固定回同一組 status/body，不足以表達這種序列。回應用盡時拋錯而非
/// `precondition`：若實作真的違反「只重試一次」跑出第三次請求，測試要能乾淨地
/// 回報失敗，而不是讓整個測試進程當掉。
private actor SequentialTransport: HTTPTransport {
    private var responses: [(status: Int, body: Data)]

    init(_ responses: [(status: Int, body: Data)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !responses.isEmpty else {
            throw UsageAPIError.transport("測試替身沒有更多預先設定的回應——可能發生了未預期的額外重試")
        }
        let next = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil
        )!
        return (next.body, response)
    }
}

/// 可外部推進的時鐘，用來測試「憑證快取隨時間過期」——`UsageAPIClient` 的 `now` 參數
/// 在同一個 client 實例的多次 `fetch()` 呼叫之間必須能回傳不同的時間點。
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

@Suite("UsageAPIClient")
struct UsageAPIClientTests {

    private func makeClient(
        status: Int,
        body: String,
        credentials: Result<Credentials, CredentialError> = .success(
            Credentials(accessToken: "tok", expiresAt: nil)
        )
    ) -> UsageAPIClient {
        UsageAPIClient(
            credentialStore: StubCredentialStore(result: credentials),
            transport: StubTransport(status: status, body: Data(body.utf8))
        )
    }

    @Test("解析成功的 response，數值須與 fixture 一致（避免 session/weekly 被互換仍測不出來）")
    func parsesSuccessfulResponse() async throws {
        let url = try #require(Bundle.module.url(
            forResource: "usage-api-response", withExtension: "json", subdirectory: "Fixtures"
        ))
        let body = try String(contentsOf: url, encoding: .utf8)
        let usage = try await makeClient(status: 200, body: body).fetch()

        // Fixtures/usage-api-response.json: five_hour.utilization = 38.2, seven_day.utilization = 61.0
        let session = try #require(usage.session)
        let weekly = try #require(usage.weekly)
        #expect(session.usedPercent == 38.2)
        #expect(weekly.usedPercent == 61.0)
        #expect(session.resetsAt == Date(timeIntervalSince1970: 1_786_810_199.604))
    }

    @Test("帶上 Authorization、anthropic-beta、User-Agent header")
    func sendsAuthorizationHeader() async throws {
        let transport = StubTransport(status: 200, body: Data("{}".utf8))
        let client = UsageAPIClient(
            credentialStore: StubCredentialStore(result: .success(
                Credentials(accessToken: "secret-tok", expiresAt: nil)
            )),
            transport: transport
        )
        _ = try? await client.fetch()
        let request = await transport.lastRequest
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer secret-tok")
        #expect(request?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request?.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.232")
    }

    @Test("401 視為未授權")
    func unauthorizedOn401() async {
        await #expect(throws: UsageAPIError.unauthorized) {
            try await makeClient(status: 401, body: "{}").fetch()
        }
    }

    @Test("403 視為未授權")
    func unauthorizedOn403() async {
        await #expect(throws: UsageAPIError.unauthorized) {
            try await makeClient(status: 403, body: "{}").fetch()
        }
    }

    @Test("500 視為傳輸錯誤")
    func transportErrorOn500() async {
        await #expect(throws: UsageAPIError.self) {
            try await makeClient(status: 500, body: "{}").fetch()
        }
    }

    @Test("兩個視窗都缺席（如 {\"something_else\":1}）視為兩者皆 null，不拋錯")
    func absentWindowsAreNilNotSchemaError() async throws {
        let usage = try await makeClient(status: 200, body: #"{"something_else":1}"#).fetch()
        #expect(usage.session == nil)
        #expect(usage.weekly == nil)
    }

    @Test("整份 payload 無法解碼（非 JSON 物件）時視為 schema 非預期")
    func unexpectedSchemaWhenPayloadUndecodable() async {
        await #expect(throws: UsageAPIError.unexpectedSchema) {
            try await makeClient(status: 200, body: "not json").fetch()
        }
    }

    @Test("five_hour 為 null、seven_day 有值時：解析成功、session 為 nil、weekly 有值，不拋錯")
    func nullSessionWindowParsesAsNilWithoutThrowing() async throws {
        let body = """
        {
            "five_hour": null,
            "seven_day": {"utilization": 21.0, "resets_at": "2026-08-20T14:59:59.604356+00:00"}
        }
        """
        let usage = try await makeClient(status: 200, body: body).fetch()
        #expect(usage.session == nil)
        let weekly = try #require(usage.weekly)
        #expect(weekly.usedPercent == 21.0)
    }

    @Test("five_hour、seven_day 皆為 null 時：解析成功、兩者皆 nil，不拋錯")
    func bothWindowsNullParseAsNilWithoutThrowing() async throws {
        let body = #"{"five_hour": null, "seven_day": null}"#
        let usage = try await makeClient(status: 200, body: body).fetch()
        #expect(usage.session == nil)
        #expect(usage.weekly == nil)
    }

    @Test("視窗存在但缺 utilization 時仍視為 schema 非預期")
    func unexpectedSchemaWhenWindowMissingUtilization() async {
        let body = """
        {
            "five_hour": {"resets_at": "2026-08-20T14:59:59.604356+00:00"},
            "seven_day": null
        }
        """
        await #expect(throws: UsageAPIError.unexpectedSchema) {
            try await makeClient(status: 200, body: body).fetch()
        }
    }

    @Test("視窗存在但 resets_at 無法解析時仍視為 schema 非預期")
    func unexpectedSchemaWhenResetsAtUnparseable() async {
        let body = """
        {
            "five_hour": {"utilization": 4.0, "resets_at": "not-a-date"},
            "seven_day": null
        }
        """
        await #expect(throws: UsageAPIError.unexpectedSchema) {
            try await makeClient(status: 200, body: body).fetch()
        }
    }

    @Test("無憑證時視為未授權")
    func unauthorizedWhenNoCredentials() async {
        await #expect(throws: UsageAPIError.unauthorized) {
            try await makeClient(status: 200, body: "{}", credentials: .failure(.notFound)).fetch()
        }
    }

    @Test("resets_at 為六位小數秒 + +00:00 位移的真實格式時可正確解析")
    func parsesRealSixDigitFractionalOffsetTimestamp() async throws {
        let body = """
        {
            "five_hour": {"utilization": 4.0, "resets_at": "2026-08-15T16:09:59.604337+00:00"},
            "seven_day": {"utilization": 21.0, "resets_at": "2026-08-20T14:59:59.604356+00:00"}
        }
        """
        let usage = try await makeClient(status: 200, body: body).fetch()
        #expect(usage.session?.resetsAt == Date(timeIntervalSince1970: 1_786_810_199.604))
        #expect(usage.weekly?.resetsAt == Date(timeIntervalSince1970: 1_787_237_999.604))
    }

    @Test("errorDescription 為中文說明，且不是 Swift 給不出意義的預設訊息")
    func errorDescriptionsAreLocalized() {
        #expect(UsageAPIError.unauthorized.errorDescription == "尚未登入 Claude Code，或授權已失效。")
        #expect(UsageAPIError.unexpectedSchema.errorDescription == "官方額度資料格式異常，可能是 API 已變更。")
        #expect(UsageAPIError.transport("HTTP 500").errorDescription == "無法連上官方額度服務（HTTP 500）。")
    }

    @Test(".transport 的 errorDescription 只能帶狀態碼描述，絕不能夾帶憑證內容")
    func transportErrorDescriptionCarriesOnlyStatusCode() {
        let description = UsageAPIError.transport("HTTP 500").errorDescription ?? ""
        #expect(!description.contains("Bearer"))
        #expect(!description.contains("tok"))
    }

    // MARK: - 憑證快取

    @Test("快取在有效期內：第二次呼叫不重讀 Keychain")
    func secondCallWithinValidityWindowSkipsKeychainRead() async throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let store = CountingCredentialStore(result: .success(
            Credentials(accessToken: "tok", expiresAt: t0.addingTimeInterval(8 * 3600))
        ))
        let client = UsageAPIClient(
            credentialStore: store,
            transport: StubTransport(status: 200, body: Data("{}".utf8)),
            now: { t0 }
        )

        _ = try await client.fetch()
        _ = try await client.fetch()

        #expect(store.loadCount == 1)
    }

    @Test("憑證過期後：下一次呼叫會重讀 Keychain")
    func readsAgainAfterExpiryHasPassed() async throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = MutableClock(t0)
        let store = CountingCredentialStore(result: .success(
            Credentials(accessToken: "tok", expiresAt: t0.addingTimeInterval(3600))
        ))
        let client = UsageAPIClient(
            credentialStore: store,
            transport: StubTransport(status: 200, body: Data("{}".utf8)),
            now: clock.now
        )

        _ = try await client.fetch()
        clock.set(t0.addingTimeInterval(3600 + 1))   // 已過 expiresAt
        _ = try await client.fetch()

        #expect(store.loadCount == 2)
    }

    @Test("尚未到期但已進入安全邊界內：下一次呼叫也會重讀")
    func readsAgainWithinSafetyMargin() async throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = MutableClock(t0)
        let store = CountingCredentialStore(result: .success(
            Credentials(accessToken: "tok", expiresAt: t0.addingTimeInterval(3600))
        ))
        let client = UsageAPIClient(
            credentialStore: store,
            transport: StubTransport(status: 200, body: Data("{}".utf8)),
            now: clock.now
        )

        _ = try await client.fetch()
        // 距離 expiresAt 只剩 60 秒，小於 300 秒的安全邊界——即使技術上還沒真的過期。
        clock.set(t0.addingTimeInterval(3600 - 60))
        _ = try await client.fetch()

        #expect(store.loadCount == 2)
    }

    @Test("expiresAt 為 nil 時：每次呼叫都重讀 Keychain（沒有依據可以快取）")
    func readsEveryTimeWhenExpiryUnknown() async throws {
        let store = CountingCredentialStore(result: .success(
            Credentials(accessToken: "tok", expiresAt: nil)
        ))
        let client = UsageAPIClient(
            credentialStore: store,
            transport: StubTransport(status: 200, body: Data("{}".utf8))
        )

        _ = try await client.fetch()
        _ = try await client.fetch()

        #expect(store.loadCount == 2)
    }

    @Test("快取的憑證被 401 拒絕：丟棄快取、重讀一次後成功")
    func retriesOnceAfter401WithCachedCredentialThenSucceeds() async throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let store = CountingCredentialStore(results: [
            .success(Credentials(accessToken: "stale", expiresAt: t0.addingTimeInterval(8 * 3600))),
            .success(Credentials(accessToken: "fresh", expiresAt: t0.addingTimeInterval(8 * 3600))),
        ])
        let transport = SequentialTransport([
            (200, Data("{}".utf8)),   // 第一次 fetch：成功，把 "stale" 放進快取
            (401, Data("{}".utf8)),   // 第二次 fetch：快取的 "stale" 被伺服器拒絕
            (200, Data("{}".utf8)),   // 丟棄快取、重讀 "fresh" 後的重試：成功
        ])
        let client = UsageAPIClient(credentialStore: store, transport: transport, now: { t0 })

        _ = try await client.fetch()
        #expect(store.loadCount == 1)

        let usage = try await client.fetch()
        #expect(usage.session == nil)
        #expect(store.loadCount == 2)
    }

    @Test("重試後仍是 401：回報 .unauthorized，不會無窮重試")
    func persistentUnauthorizedAfterRetryDoesNotLoop() async throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let store = CountingCredentialStore(results: [
            .success(Credentials(accessToken: "stale", expiresAt: t0.addingTimeInterval(8 * 3600))),
            .success(Credentials(accessToken: "still-bad", expiresAt: t0.addingTimeInterval(8 * 3600))),
        ])
        let transport = SequentialTransport([
            (200, Data("{}".utf8)),   // 第一次 fetch：成功，把 "stale" 放進快取
            (401, Data("{}".utf8)),   // 第二次 fetch：快取的 "stale" 被拒絕
            (401, Data("{}".utf8)),   // 重讀後仍被拒絕——這裡必須停手，不能再重試
        ])
        let client = UsageAPIClient(credentialStore: store, transport: transport, now: { t0 })

        _ = try await client.fetch()

        await #expect(throws: UsageAPIError.unauthorized) {
            try await client.fetch()
        }
        // 只重讀一次（初次快取 1 次 + 401 後重試 1 次），確認沒有陷入重試迴圈；
        // 若真的迴圈了，`SequentialTransport` 的第四次請求會沒有預備回應可用，
        // 拋出跟 `.unauthorized` 不同的錯誤，讓上面的 `#expect(throws:)` 直接測不過。
        #expect(store.loadCount == 2)
    }
}

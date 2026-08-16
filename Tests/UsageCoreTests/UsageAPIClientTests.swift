import Testing
import Foundation
@testable import UsageCore

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
        #expect(usage.session.usedPercent == 38.2)
        #expect(usage.weekly.usedPercent == 61.0)
        #expect(usage.session.resetsAt == Date(timeIntervalSince1970: 1_786_810_199.604))
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

    @Test("欄位缺失時視為 schema 非預期，不猜測數值")
    func unexpectedSchemaWhenFieldsMissing() async {
        await #expect(throws: UsageAPIError.unexpectedSchema) {
            try await makeClient(status: 200, body: #"{"something_else":1}"#).fetch()
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
        #expect(usage.session.resetsAt == Date(timeIntervalSince1970: 1_786_810_199.604))
        #expect(usage.weekly.resetsAt == Date(timeIntervalSince1970: 1_787_237_999.604))
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
}

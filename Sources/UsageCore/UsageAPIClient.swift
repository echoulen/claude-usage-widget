import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError.transport("非 HTTP 回應")
        }
        return (data, http)
    }
}

/// 測試用替身，記錄最後一次請求供斷言。
public actor StubTransport: HTTPTransport {
    public private(set) var lastRequest: URLRequest?
    private let status: Int
    private let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

public enum UsageAPIError: Error, Equatable {
    case unauthorized
    /// Response 格式非預期 —— endpoint 可能已改版。不猜測欄位，直接降級。
    case unexpectedSchema
    case transport(String)
}

extension UsageAPIError: LocalizedError {
    /// 沒有這個 conformance 的話，Swift 對這種 enum 的預設 `localizedDescription`
    /// 會印出像「The operation couldn't be completed. (UsageCore.UsageAPIError error 0.)」
    /// 這種對使用者毫無意義的字串。這裡逐一給出中文說明，跟其餘 UI 文案一致。
    ///
    /// `.transport` 的關聯字串只能是狀態碼描述（例如 `"HTTP 500"`）——絕不能讓
    /// 憑證內容流進這裡。呼叫端目前只餵入狀態碼字串，這裡原樣顯示，不做任何猜測式拼接。
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "尚未登入 Claude Code，或授權已失效。"
        case .unexpectedSchema:
            return "官方額度資料格式異常，可能是 API 已變更。"
        case .transport(let detail):
            return "無法連上官方額度服務（\(detail)）。"
        }
    }
}

public protocol UsageAPI: Sendable {
    func fetch() async throws -> OfficialUsage
}

public struct UsageAPIClient: UsageAPI {

    /// 確認見 docs/spike-1-result.md 步驟 2：實測回傳 HTTP 200。
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let credentialStore: CredentialStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        credentialStore: CredentialStore,
        transport: HTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
        self.now = now
    }

    public func fetch() async throws -> OfficialUsage {
        let credentials: Credentials
        do {
            credentials = try credentialStore.load()
        } catch {
            throw UsageAPIError.unauthorized
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // 三個 header 均為 spike 實測時一次全帶並成功的組合；spike 未逐一拆解驗證何者必要，
        // 因此三者皆保留，不憑猜測精簡（見 docs/spike-1-result.md 步驟 2）。
        request.setValue("claude-cli/2.1.232", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await transport.send(request)

        switch response.statusCode {
        case 200: break
        case 401, 403: throw UsageAPIError.unauthorized
        default: throw UsageAPIError.transport("HTTP \(response.statusCode)")
        }

        return try parse(data)
    }

    /// Response schema 依 docs/spike-1-result.md 步驟 3 實測確認：
    /// 只需 `five_hour`/`seven_day`，其 `utilization` 已是「已使用」百分比（0–100），不需轉換；
    /// `resets_at` 為 ISO8601 字串，六位小數秒 + `+00:00` 位移（非常見的 `Z` 結尾）。
    private func parse(_ data: Data) throws -> OfficialUsage {
        struct Payload: Decodable {
            struct Window: Decodable {
                let utilization: Double
                let resets_at: String
            }
            let five_hour: Window?
            let seven_day: Window?
        }

        // 步驟 4 實測：真實時間戳（六位小數秒 + `+00:00`）只有 fractional formatter 能解析；
        // 若日後遇到無小數秒的 `Z` 結尾格式，只有 plain formatter 能解析。兩者缺一都會漏掉合法輸入，
        // 因此固定「fractional 優先、plain 後備」的順序。
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        func window(_ raw: Payload.Window?) throws -> UsageWindow {
            guard let raw,
                  let resets = formatter.date(from: raw.resets_at) ?? plain.date(from: raw.resets_at)
            else { throw UsageAPIError.unexpectedSchema }
            return UsageWindow(usedPercent: raw.utilization, resetsAt: resets)
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw UsageAPIError.unexpectedSchema
        }

        return OfficialUsage(
            session: try window(payload.five_hour),
            weekly: try window(payload.seven_day),
            fetchedAt: now()
        )
    }
}

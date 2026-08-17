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

/// `UsageAPIClient` 的記憶體憑證快取。
///
/// 用 actor 而非鎖：快取的「讀取現有值 → 判斷是否仍在有效期內 → （必要時）寫入新值」
/// 這三步必須是不可分割的單一操作，否則兩個並發 `fetch()`（例如手動重新整理撞上輪詢的
/// 那次呼叫）可能同時判定「快取已過期」而各自觸發一次 Keychain 讀取，白白浪費掉這支
/// 快取原本要省下的那一次讀取。actor 天生把「對自身狀態的存取」序列化，比手動上鎖
/// 更不容易寫錯（例如在某個 early return 之前忘記解鎖），語意也更貼近「這是一段需要
/// 互斥的狀態機」而不是「這是一段需要保護的臨界區」。
actor CredentialCache {
    private var cached: Credentials?

    /// Claude Code 大約每 8 小時 refresh 一次 OAuth token（見 issue 附的 `mdat` 量測：
    /// 08-16 04:19、08-16 12:14、08-17 13:55，三次間隔皆約 8 小時）。5 分鐘的安全邊界
    /// 只佔這個週期不到 1%：夠大，足以吸收「輪詢週期（10 分鐘）剛好卡在過期前一刻讀到
    /// 快取、下一輪馬上又要重讀」這種邊界抖動；夠小，不會在 token 其實還沒過期時就提早
    /// 放棄快取、讓每天的實際讀取次數明顯偏離「token 壽命內只讀一次」這個目標。
    static let expirySafetyMargin: TimeInterval = 300

    /// 目前手上的快取是否仍可用；`now` 由呼叫端注入以利測試。
    ///
    /// `expiresAt == nil`：Keychain payload 沒帶過期時間，沒有依據判斷這份憑證何時作廢，
    /// 快取它是不安全的——有可能長期卡在一份其實早被 Claude Code 換掉的舊 token 上，
    /// 因此一律視為「已過期」，效果等同修復前的行為：每次呼叫都重讀 Keychain。
    func valid(now: Date) -> Credentials? {
        guard let cached, let expiresAt = cached.expiresAt else { return nil }
        return now.addingTimeInterval(Self.expirySafetyMargin) < expiresAt ? cached : nil
    }

    func store(_ credentials: Credentials) {
        cached = credentials
    }

    /// 收到 401／403 時呼叫：Claude Code 可能已經提前 refresh 過 token，快取的是舊的，
    /// 不代表使用者真的登出了——見 `UsageAPIClient.fetch()` 的重試邏輯。
    func invalidate() {
        cached = nil
    }
}

public struct UsageAPIClient: UsageAPI {

    /// 確認見 docs/spike-1-result.md 步驟 2：實測回傳 HTTP 200。
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let credentialStore: CredentialStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let cache = CredentialCache()

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
        let credentials = try await loadCredentials()
        do {
            return try await performRequest(with: credentials)
        } catch UsageAPIError.unauthorized {
            // 快取的憑證被伺服器拒絕：可能是 Claude Code 在我們上次讀取之後又 refresh
            // 過一次 token（大約每 8 小時發生一次），快取因此變舊，並不代表使用者真的
            // 登出了。丟掉快取、強制重讀一次 Keychain 再重試——但只重試這一次：真的
            // 登出的使用者仍要馬上看到 `.unauthorized`，不能被卡在一個看不到盡頭的
            // 重試迴圈裡。
            await cache.invalidate()
            let fresh = try await loadCredentials()
            return try await performRequest(with: fresh)
        }
    }

    private func loadCredentials() async throws -> Credentials {
        if let cached = await cache.valid(now: now()) {
            return cached
        }
        let credentials: Credentials
        do {
            credentials = try credentialStore.load()
        } catch {
            throw UsageAPIError.unauthorized
        }
        await cache.store(credentials)
        return credentials
    }

    private func performRequest(with credentials: Credentials) async throws -> OfficialUsage {
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

        // `raw == nil` 代表官方 API 把這個視窗回成 `null`——這是這支 API 的常態，
        // 同一份回應裡 `seven_day_opus`／`tangelo`／`nimbus_quill`／`cinder_cove`／
        // `amber_ladder` 等其他視窗也經常是 `null`，`five_hour` 在重置邊界附近同樣可能
        // 短暫回成 `null`。這不是 schema 壞掉，回傳「這個視窗現在沒有讀數」（`nil`），
        // 不拋錯。只有視窗**確實存在**卻缺 `utilization`（會讓上面的 `JSONDecoder.decode`
        // 直接失敗，走到下面的 `try?` 分支）、或 `resets_at` 解不出來，才是真正的 schema
        // 違反，繼續拋 `.unexpectedSchema`。
        func window(_ raw: Payload.Window?) throws -> UsageWindow? {
            guard let raw else { return nil }
            guard let resets = formatter.date(from: raw.resets_at) ?? plain.date(from: raw.resets_at)
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

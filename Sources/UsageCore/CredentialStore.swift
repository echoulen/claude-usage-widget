import Foundation
import Security

public struct Credentials: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

public enum CredentialError: Error, Equatable {
    /// Keychain 中找不到項目 —— 使用者未登入 Claude Code。
    case notFound
    /// 找到了但內容不是預期的 JSON 結構。
    case malformed
    /// 使用者拒絕授權，或 app 簽章與授權紀錄不符。
    case denied
}

public protocol CredentialStore: Sendable {
    func load() throws -> Credentials
}

/// 從 macOS Keychain 讀取 Claude Code 的 OAuth 憑證。
///
/// 首次讀取會觸發系統授權對話框。使用者勾選「總是允許」後，授權會綁定
/// 本 app 的簽章 —— app 重新簽章後會再次跳出，開發期間屬預期行為。
public struct KeychainCredentialStore: CredentialStore {

    private let service: String
    private let account: String

    public init(service: String = "Claude Code-credentials", account: String? = nil) {
        self.service = service
        self.account = account ?? NSUserName()
    }

    public func load() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CredentialError.malformed }
            return try Self.decode(data)
        case errSecItemNotFound:
            throw CredentialError.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw CredentialError.denied
        default:
            throw CredentialError.denied
        }
    }

    /// 解析 Keychain payload。
    ///
    /// 依 docs/spike-1-result.md 步驟 1 的實測：`accessToken` 與 `expiresAt`
    /// 巢狀於 `claudeAiOauth` 之下，並非頂層。`expiresAt` 是毫秒 epoch。
    /// `refreshToken`、`scopes`、`subscriptionType`、`rateLimitTier` 等欄位
    /// 目前無消費者，故意不建模（YAGNI）。
    static func decode(_ data: Data) throws -> Credentials {
        struct Payload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String?
                /// 毫秒 epoch。
                let expiresAt: Double?
            }
            let claudeAiOauth: OAuth?
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let oauth = payload.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty
        else { throw CredentialError.malformed }

        return Credentials(
            accessToken: token,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}

/// 測試與預覽用的替身。
public struct StubCredentialStore: CredentialStore {
    private let result: Result<Credentials, CredentialError>

    public init(result: Result<Credentials, CredentialError>) {
        self.result = result
    }

    public func load() throws -> Credentials {
        try result.get()
    }
}

/// 計數版測試替身：記錄 `load()` 被呼叫的次數，用來驗證
/// `UsageAPIClient` 的憑證快取是否真的省下了 Keychain 讀取。
///
/// 另開一個型別而不是幫 `StubCredentialStore` 加這個副作用，是因為既有測試依賴
/// 後者「單純回傳固定結果、無任何副作用」的行為，不能被計數邏輯污染。
///
/// `load()` 依協定是同步方法，可能被並發呼叫（`UsageAPIClient.fetch()` 的重試路徑
/// 就是一例），因此用鎖而非 actor 保護內部狀態——actor 的隔離方法一律是 `async`，
/// 無法滿足 `CredentialStore` 要求的同步簽章。
public final class CountingCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [Result<Credentials, CredentialError>]
    private var index = 0
    private var count = 0

    /// 依序回傳 `results` 裡的每一筆；呼叫次數超過陣列長度時，重複回傳最後一筆——
    /// 讓呼叫端不必為了「這輪測試只需要固定值」而特地把同一個結果重複填好幾次。
    public init(results: [Result<Credentials, CredentialError>]) {
        precondition(!results.isEmpty, "results 不可為空——沒有任何結果可回傳")
        self.results = results
    }

    public convenience init(result: Result<Credentials, CredentialError>) {
        self.init(results: [result])
    }

    public func load() throws -> Credentials {
        lock.lock()
        let result = results[min(index, results.count - 1)]
        if index < results.count - 1 { index += 1 }
        count += 1
        lock.unlock()
        return try result.get()
    }

    public var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

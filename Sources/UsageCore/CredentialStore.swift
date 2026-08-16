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

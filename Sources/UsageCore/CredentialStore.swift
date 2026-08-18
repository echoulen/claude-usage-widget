import Foundation

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

    /// 透過 `/usr/bin/security` 讀取，而不是從本行程直接呼叫 `SecItemCopyMatching`。
    ///
    /// Keychain 的 ACL 記的是「哪個程式」可以讀某個項目。這個項目由 Claude Code 建立，
    /// 而它看來是透過 `security` 命令列工具寫入的——於是 `/usr/bin/security` 一直是該
    /// 項目 ACL 裡的信任程式，每次改寫後依然是。直接用 Security framework 呼叫時，提出
    /// 請求的是本 app，它不在 ACL 裡，所以每次 token 更新（約 8 小時）清掉 ACL 之後，
    /// 使用者就會再被要求授權一次。
    ///
    /// 實測：項目改寫兩小時後，`security find-generic-password -w` 仍可零延遲讀取、
    /// 不跳任何對話框。同一個項目，本 app 直接讀則必定跳框。
    ///
    /// 代價要說清楚：這依賴「Claude Code 用 `security` 寫入」這個事實。哪天它改用
    /// Security framework 直接寫，`/usr/bin/security` 就不會再自動落在 ACL 裡，我們
    /// 會退回每 8 小時跳一次框——功能仍然正確，只是又變吵。
    public func load() throws -> Credentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]

        // 以 pipe 取回，不經過 shell：token 因此不會出現在任何指令列字串裡，
        // 也就不會落入 shell 歷史或行程列表。
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw CredentialError.denied
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // `security` 找不到項目時回傳 44；其餘非零狀態一律當成被拒，
            // 因為使用者按「拒絕」或授權失敗都走這條路。
            throw process.terminationStatus == 44 ? CredentialError.notFound : CredentialError.denied
        }

        // `-w` 會在密碼後面附一個換行，JSON 解析前要修掉。
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CredentialError.notFound }

        return try Self.decode(Data(trimmed.utf8))
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

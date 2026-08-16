import Testing
import Foundation
@testable import UsageCore

@Suite("CredentialStore")
struct CredentialStoreTests {

    @Test("解析 Keychain payload（巢狀於 claudeAiOauth 之下）")
    func parsesPayload() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok_123","expiresAt":1786000000000}}"#
        let creds = try KeychainCredentialStore.decode(Data(json.utf8))
        #expect(creds.accessToken == "tok_123")
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_786_000_000))
    }

    @Test("expiresAt 可缺席")
    func expiryIsOptional() throws {
        let creds = try KeychainCredentialStore.decode(Data(#"{"claudeAiOauth":{"accessToken":"t"}}"#.utf8))
        #expect(creds.accessToken == "t")
        #expect(creds.expiresAt == nil)
    }

    @Test("缺少 accessToken 時視為格式錯誤")
    func missingTokenIsMalformed() {
        #expect(throws: CredentialError.malformed) {
            try KeychainCredentialStore.decode(Data(#"{"claudeAiOauth":{"refreshToken":"r"}}"#.utf8))
        }
    }

    @Test("非 JSON 時視為格式錯誤")
    func nonJSONIsMalformed() {
        #expect(throws: CredentialError.malformed) {
            try KeychainCredentialStore.decode(Data("not json".utf8))
        }
    }

    @Test("accessToken 在頂層（非巢狀於 claudeAiOauth）時視為格式錯誤")
    func topLevelAccessTokenIsRejected() {
        // 舊假設（spike 前）誤以為 accessToken/expiresAt 在頂層。
        // 若未來又退化回這個扁平形狀，必須大聲失敗，而不是靜默回傳 nil。
        #expect(throws: CredentialError.malformed) {
            try KeychainCredentialStore.decode(Data(#"{"accessToken":"tok_123","expiresAt":1786000000000}"#.utf8))
        }
    }

    @Test("stub 可回傳指定憑證")
    func stubReturnsConfiguredCredentials() throws {
        let store = StubCredentialStore(result: .success(Credentials(accessToken: "x", expiresAt: nil)))
        #expect(try store.load().accessToken == "x")
    }

    @Test("stub 可拋出指定錯誤")
    func stubThrowsConfiguredError() {
        let store = StubCredentialStore(result: .failure(CredentialError.notFound))
        #expect(throws: CredentialError.notFound) { try store.load() }
    }
}

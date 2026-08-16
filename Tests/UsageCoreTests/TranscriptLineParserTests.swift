import Testing
import Foundation
@testable import UsageCore

@Suite("TranscriptLineParser")
struct TranscriptLineParserTests {

    /// 取自本機真實 transcript 的 assistant 行（2026-08-14 取樣）
    static let validLine = """
    {"type":"assistant","timestamp":"2026-08-14T13:19:57.932Z","requestId":"req_abc123","sessionId":"s1","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":1428,"cache_read_input_tokens":352509,"output_tokens":1854}}}
    """

    @Test("解析有效的 assistant 行")
    func parsesValidLine() throws {
        let record = try #require(TranscriptLineParser.parse(Data(Self.validLine.utf8)))
        #expect(record.dedupKey == "req_abc123")
        #expect(record.model == "claude-opus-5")
        #expect(record.inputTokens == 2)
        #expect(record.outputTokens == 1854)
        #expect(record.cacheCreationTokens == 1428)
        #expect(record.cacheReadTokens == 352509)
        #expect(record.totalTokens == 355_793)
    }

    @Test("正確解析含小數秒的 ISO8601 時間戳")
    func parsesFractionalSecondTimestamp() throws {
        let record = try #require(TranscriptLineParser.parse(Data(Self.validLine.utf8)))
        let expected = ISO8601DateFormatter()
        expected.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(record.timestamp == expected.date(from: "2026-08-14T13:19:57.932Z"))
    }

    @Test("requestId 缺失時退回 message.id")
    func fallsBackToMessageID() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-08-14T13:19:57.932Z","message":{"id":"msg_only","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        let record = try #require(TranscriptLineParser.parse(Data(line.utf8)))
        #expect(record.dedupKey == "msg_only")
    }

    @Test("略過非 assistant 的行", arguments: [
        #"{"type":"user","timestamp":"2026-08-14T13:19:57.932Z","message":{"content":"hi"}}"#,
        #"{"type":"system","timestamp":"2026-08-14T13:19:57.932Z"}"#,
    ])
    func skipsNonAssistantLines(line: String) {
        #expect(TranscriptLineParser.parse(Data(line.utf8)) == nil)
    }

    @Test("略過壞掉或無用的行", arguments: [
        "",
        "   ",
        "{ this is not json",
        #"{"type":"assistant","timestamp":"2026-08-14T13:19:57.932Z","message":{"model":"m"}}"#,      // 無 usage
        #"{"type":"assistant","timestamp":"2026-08-14T13:19:57.932Z","message":{"model":"m","usage":{"input_tokens":1}}}"#,  // 無 id 也無 requestId
    ])
    func skipsUnusableLines(line: String) {
        #expect(TranscriptLineParser.parse(Data(line.utf8)) == nil)
    }

    @Test("缺席的 token 欄位視為 0")
    func missingTokenFieldsDefaultToZero() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-08-14T13:19:57.932Z","requestId":"r1","message":{"model":"m","usage":{"output_tokens":5}}}
        """
        let record = try #require(TranscriptLineParser.parse(Data(line.utf8)))
        #expect(record.inputTokens == 0)
        #expect(record.cacheReadTokens == 0)
        #expect(record.totalTokens == 5)
    }
}

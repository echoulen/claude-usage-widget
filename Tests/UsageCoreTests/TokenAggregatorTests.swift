import Testing
import Foundation
@testable import UsageCore

@Suite("TokenAggregator")
struct TokenAggregatorTests {

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        key: String,
        offsetMinutes: Double,
        tokens: Int
    ) -> UsageRecord {
        UsageRecord(
            dedupKey: key,
            timestamp: Self.base.addingTimeInterval(offsetMinutes * 60),
            model: "claude-opus-5",
            inputTokens: tokens,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }

    @Test("加總區間內的記錄")
    func sumsRecordsInWindow() {
        let records = [
            record(key: "a", offsetMinutes: 1, tokens: 100),
            record(key: "b", offsetMinutes: 2, tokens: 200),
        ]
        let result = TokenAggregator.aggregate(
            records, from: Self.base, to: Self.base.addingTimeInterval(3600)
        )
        #expect(result.totalTokens == 300)
        #expect(result.recordCount == 2)
        #expect(result.duplicatesDropped == 0)
    }

    @Test("相同 dedupKey 只算一次")
    func deduplicatesByKey() {
        let records = [
            record(key: "dup", offsetMinutes: 1, tokens: 100),
            record(key: "dup", offsetMinutes: 2, tokens: 100),
            record(key: "dup", offsetMinutes: 3, tokens: 100),
        ]
        let result = TokenAggregator.aggregate(
            records, from: Self.base, to: Self.base.addingTimeInterval(3600)
        )
        #expect(result.totalTokens == 100)
        #expect(result.recordCount == 1)
        #expect(result.duplicatesDropped == 2)
    }

    @Test("排除區間外的記錄")
    func excludesRecordsOutsideWindow() {
        let records = [
            record(key: "before", offsetMinutes: -10, tokens: 999),
            record(key: "inside", offsetMinutes: 5, tokens: 100),
            record(key: "after", offsetMinutes: 120, tokens: 999),
        ]
        let result = TokenAggregator.aggregate(
            records, from: Self.base, to: Self.base.addingTimeInterval(3600)
        )
        #expect(result.totalTokens == 100)
        #expect(result.recordCount == 1)
    }

    @Test("區間為左閉右開")
    func windowIsHalfOpen() {
        let records = [
            record(key: "at-start", offsetMinutes: 0, tokens: 10),
            record(key: "at-end", offsetMinutes: 60, tokens: 20),
        ]
        let result = TokenAggregator.aggregate(
            records, from: Self.base, to: Self.base.addingTimeInterval(3600)
        )
        #expect(result.totalTokens == 10)
    }

    @Test("去重發生在區間過濾之前，區間外的重複不算 dropped")
    func duplicatesOutsideWindowAreNotCounted() {
        let records = [
            record(key: "x", offsetMinutes: -100, tokens: 5),
            record(key: "x", offsetMinutes: -99, tokens: 5),
            record(key: "y", offsetMinutes: 5, tokens: 50),
        ]
        let result = TokenAggregator.aggregate(
            records, from: Self.base, to: Self.base.addingTimeInterval(3600)
        )
        #expect(result.totalTokens == 50)
        #expect(result.recordCount == 1)
        #expect(result.duplicatesDropped == 0)
    }

    @Test("空輸入回傳全零")
    func emptyInputIsZero() {
        let result = TokenAggregator.aggregate(
            [], from: Self.base, to: Self.base.addingTimeInterval(3600)
        )
        #expect(result.totalTokens == 0)
        #expect(result.recordCount == 0)
        #expect(result.duplicatesDropped == 0)
    }
}

import Foundation

public struct UsageAggregate: Equatable, Sendable {
    public let totalTokens: Int
    public let recordCount: Int
    /// 因 dedupKey 重複而被丟棄的區間內記錄數，用於診斷。
    public let duplicatesDropped: Int

    public init(totalTokens: Int, recordCount: Int, duplicatesDropped: Int) {
        self.totalTokens = totalTokens
        self.recordCount = recordCount
        self.duplicatesDropped = duplicatesDropped
    }
}

public enum TokenAggregator {

    /// 加總 `[from, to)` 區間內的 token 用量，以 dedupKey 去重。
    ///
    /// 先過濾區間再去重，因此區間外的重複不計入 `duplicatesDropped`。
    public static func aggregate(
        _ records: [UsageRecord],
        from: Date,
        to: Date
    ) -> UsageAggregate {
        var seen = Set<String>()
        var total = 0
        var counted = 0
        var dropped = 0

        for record in records where record.timestamp >= from && record.timestamp < to {
            guard seen.insert(record.dedupKey).inserted else {
                dropped += 1
                continue
            }
            total += record.totalTokens
            counted += 1
        }

        return UsageAggregate(
            totalTokens: total,
            recordCount: counted,
            duplicatesDropped: dropped
        )
    }
}

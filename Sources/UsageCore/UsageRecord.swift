import Foundation

/// 一則 assistant 回應的 token 用量。
public struct UsageRecord: Equatable, Sendable {
    /// 去重主鍵：requestId，缺失時為 message.id。
    public let dedupKey: String
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int

    public init(
        dedupKey: String,
        timestamp: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int
    ) {
        self.dedupKey = dedupKey
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}

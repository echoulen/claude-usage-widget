import Foundation

public enum TranscriptLineParser {

    private struct RawLine: Decodable {
        let type: String?
        let timestamp: Date?
        let requestId: String?
        let message: RawMessage?

        struct RawMessage: Decodable {
            let id: String?
            let model: String?
            let usage: RawUsage?
        }

        struct RawUsage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
        }
    }

    // ISO8601DateFormatter 建構成本高。掃描器會對每一行呼叫 parse，若放在 decoder
    // 的 closure 內每行都會重新配置，實測 1000+ 檔會拖到 30+ 秒。改用
    // nonisolated(unsafe) static let 快取單一實例；兩者僅供內部唯讀格式化使用，無資料競爭。
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)

            if let date = fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "無法解析時間戳: \(raw)")
            )
        }
        return decoder
    }()

    /// 解析一行 transcript JSONL。非 assistant、無用量、或無法去重的行回傳 nil。
    public static func parse(_ line: Data) -> UsageRecord? {
        guard !line.isEmpty,
              let raw = try? decoder.decode(RawLine.self, from: line),
              raw.type == "assistant",
              let timestamp = raw.timestamp,
              let message = raw.message,
              let usage = message.usage,
              let key = raw.requestId ?? message.id
        else { return nil }

        return UsageRecord(
            dedupKey: key,
            timestamp: timestamp,
            model: message.model ?? "unknown",
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheCreationTokens: usage.cache_creation_input_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0
        )
    }
}

import Foundation

/// 增量掃描 Claude Code 的 transcript 目錄。
///
/// 兩層過濾避免每次重讀全部檔案（本機實測約 1078 個 jsonl）：
/// 1. 以 mtime 排除早於分析區間起點的檔案
/// 2. 以 byte offset 從上次讀到的位置續讀
public struct TranscriptScanner {

    private let rootDirectory: URL
    private let fileManager: FileManager

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    /// 掃描並回傳新增的用量記錄，以及更新後的 cursor。
    ///
    /// - Parameter notBefore: mtime 早於此時間的檔案直接跳過。
    public func scan(
        cursor: ScanCursor,
        notBefore: Date
    ) throws -> (records: [UsageRecord], cursor: ScanCursor) {
        var newCursor = cursor
        var records: [UsageRecord] = []

        guard fileManager.fileExists(atPath: rootDirectory.path) else {
            return ([], newCursor)
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return ([], newCursor)
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  let size = values?.fileSize
            else { continue }

            guard modifiedAt >= notBefore else { continue }

            let path = url.path
            let previous = newCursor.files[path]
            // 檔案縮小代表被截斷或重建，從頭讀起。
            let startOffset = (previous.map { UInt64(size) < $0.byteOffset } ?? false)
                ? 0
                : (previous?.byteOffset ?? 0)

            guard startOffset < UInt64(size) else {
                newCursor.files[path] = .init(byteOffset: UInt64(size), modifiedAt: modifiedAt)
                continue
            }

            // 單一檔案的 I/O 失敗（例如掃描期間檔案被刪除或輪替）不應中止整個掃描；
            // 略過該檔並保留舊 cursor（或不設定），讓下次掃描重試，而不是靜默跳過該段內容。
            do {
                let lines = try readLines(at: url, from: startOffset)
                records.append(contentsOf: lines)
                newCursor.files[path] = .init(byteOffset: UInt64(size), modifiedAt: modifiedAt)
            } catch {
                continue
            }
        }

        return (records, newCursor)
    }

    private func readLines(at url: URL, from offset: UInt64) throws -> [UsageRecord] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readToEnd() else { return [] }

        return data
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { TranscriptLineParser.parse(Data($0)) }
    }
}

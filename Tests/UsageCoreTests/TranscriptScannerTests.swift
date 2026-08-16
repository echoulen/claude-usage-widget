import Testing
import Foundation
@testable import UsageCore

@Suite("TranscriptScanner")
struct TranscriptScannerTests {

    /// 建立臨時目錄，測試結束後清掉。
    private func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanner-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    private func line(key: String, timestamp: String, tokens: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(key)","message":{"id":"m_\(key)","model":"claude-opus-5","usage":{"input_tokens":\(tokens),"output_tokens":0}}}
        """
    }

    @Test("掃描巢狀目錄下的所有 jsonl")
    func scansNestedDirectories() throws {
        try withTempDirectory { root in
            let nested = root.appendingPathComponent("proj-a/sub")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try (line(key: "r1", timestamp: "2026-08-14T10:00:00.000Z", tokens: 10) + "\n")
                .write(to: nested.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

            let scanner = TranscriptScanner(rootDirectory: root)
            let (records, _) = try scanner.scan(cursor: ScanCursor(), notBefore: .distantPast)
            #expect(records.count == 1)
            #expect(records.first?.dedupKey == "r1")
        }
    }

    @Test("第二次掃描只讀新增的內容")
    func secondScanReadsOnlyAppendedContent() throws {
        try withTempDirectory { root in
            let file = root.appendingPathComponent("a.jsonl")
            try (line(key: "r1", timestamp: "2026-08-14T10:00:00.000Z", tokens: 10) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)

            let scanner = TranscriptScanner(rootDirectory: root)
            let (first, cursor1) = try scanner.scan(cursor: ScanCursor(), notBefore: .distantPast)
            #expect(first.count == 1)

            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(
                (line(key: "r2", timestamp: "2026-08-14T11:00:00.000Z", tokens: 20) + "\n").utf8
            ))
            try handle.close()

            let (second, _) = try scanner.scan(cursor: cursor1, notBefore: .distantPast)
            #expect(second.count == 1)
            #expect(second.first?.dedupKey == "r2")
        }
    }

    @Test("檔案被截斷時整檔重讀")
    func rereadsWhenFileShrinks() throws {
        try withTempDirectory { root in
            let file = root.appendingPathComponent("a.jsonl")
            let two = (line(key: "r1", timestamp: "2026-08-14T10:00:00.000Z", tokens: 10) + "\n")
                    + (line(key: "r2", timestamp: "2026-08-14T11:00:00.000Z", tokens: 20) + "\n")
            try two.write(to: file, atomically: true, encoding: .utf8)

            let scanner = TranscriptScanner(rootDirectory: root)
            let (_, cursor1) = try scanner.scan(cursor: ScanCursor(), notBefore: .distantPast)

            // 重建成只有一行，長度變短
            try (line(key: "r9", timestamp: "2026-08-14T12:00:00.000Z", tokens: 1) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)

            let (records, _) = try scanner.scan(cursor: cursor1, notBefore: .distantPast)
            #expect(records.count == 1)
            #expect(records.first?.dedupKey == "r9")
        }
    }

    @Test("略過 mtime 早於 notBefore 的檔案")
    func skipsFilesModifiedBeforeCutoff() throws {
        try withTempDirectory { root in
            let file = root.appendingPathComponent("old.jsonl")
            try (line(key: "old", timestamp: "2020-01-01T00:00:00.000Z", tokens: 10) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            let ancient = Date(timeIntervalSince1970: 0)
            try FileManager.default.setAttributes([.modificationDate: ancient], ofItemAtPath: file.path)

            let scanner = TranscriptScanner(rootDirectory: root)
            let (records, _) = try scanner.scan(cursor: ScanCursor(), notBefore: Date())
            #expect(records.isEmpty)
        }
    }

    @Test("忽略非 jsonl 副檔名")
    func ignoresNonJsonlFiles() throws {
        try withTempDirectory { root in
            try "not json at all".write(
                to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8
            )
            let scanner = TranscriptScanner(rootDirectory: root)
            let (records, _) = try scanner.scan(cursor: ScanCursor(), notBefore: .distantPast)
            #expect(records.isEmpty)
        }
    }

    @Test("壞掉的行不影響同檔其他行")
    func malformedLinesDoNotAbortFile() throws {
        try withTempDirectory { root in
            let content = "{ broken\n"
                + line(key: "good", timestamp: "2026-08-14T10:00:00.000Z", tokens: 7) + "\n"
                + "\n"
            try content.write(to: root.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

            let scanner = TranscriptScanner(rootDirectory: root)
            let (records, _) = try scanner.scan(cursor: ScanCursor(), notBefore: .distantPast)
            #expect(records.count == 1)
            #expect(records.first?.dedupKey == "good")
        }
    }

    @Test("單一檔案讀取失敗不影響其他檔案掃描，且該檔 cursor 不前進")
    func unreadableFileDoesNotAbortSiblingFiles() throws {
        try withTempDirectory { root in
            let goodFile = root.appendingPathComponent("good.jsonl")
            try (line(key: "good", timestamp: "2026-08-14T10:00:00.000Z", tokens: 5) + "\n")
                .write(to: goodFile, atomically: true, encoding: .utf8)

            let brokenFile = root.appendingPathComponent("broken.jsonl")
            try (line(key: "broken", timestamp: "2026-08-14T10:00:00.000Z", tokens: 5) + "\n")
                .write(to: brokenFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: brokenFile.path
            )
            defer {
                // 還原權限，讓 withTempDirectory 的清理步驟能正常刪除目錄。
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: brokenFile.path
                )
            }

            let scanner = TranscriptScanner(rootDirectory: root)
            let (records, cursor) = try scanner.scan(cursor: ScanCursor(), notBefore: .distantPast)

            #expect(records.count == 1)
            #expect(records.first?.dedupKey == "good")
            #expect(cursor.files[brokenFile.path] == nil)
        }
    }

    @Test("根目錄不存在時回傳空結果而非拋錯")
    func missingRootReturnsEmpty() throws {
        let scanner = TranscriptScanner(
            rootDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        )
        let (records, _) = try scanner.scan(cursor: ScanCursor(), notBefore: .distantPast)
        #expect(records.isEmpty)
    }

    @Test("cursor 可 round-trip 編解碼")
    func cursorIsCodable() throws {
        var cursor = ScanCursor()
        cursor.files["/a/b.jsonl"] = .init(byteOffset: 42, modifiedAt: Date(timeIntervalSince1970: 100))
        let data = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(ScanCursor.self, from: data)
        #expect(decoded == cursor)
    }

    // 生產情境用 8 天 cutoff（Task 10 協調者固定傳入，因為 app 追蹤的最寬視窗是 7 天）。
    // 對照組：notBefore: .distantPast（全量掃描，不設 mtime 下限）在同一台機器上
    // 實測約 14.7 秒、95,634 筆記錄（formatter 快取化後）；只作為 cold-start 的最壞情況
    // 參考數字留存，不代表生產路徑的實際負擔，見 task-4-report.md「Fix Report」一節。
    @Test(
        "對真實 ~/.claude/projects 目錄做效能與正確性驗證（8 天 cutoff，即生產情境）",
        .disabled("依賴本機環境，手動執行")
    )
    func scansRealClaudeProjectsDirectory() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let scanner = TranscriptScanner(rootDirectory: root)
        let notBefore = Date().addingTimeInterval(-8 * 86400)

        let start = Date()
        let (records, _) = try scanner.scan(cursor: ScanCursor(), notBefore: notBefore)
        let elapsed = Date().timeIntervalSince(start)

        print("scansRealClaudeProjectsDirectory: \(records.count) records in \(elapsed)s")
        #expect(elapsed < 5.0)
        #expect(records.count > 0)
    }
}

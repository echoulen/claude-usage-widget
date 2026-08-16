import Testing
import Foundation
@testable import UsageCore

@Suite("SnapshotFile")
struct SnapshotFileTests {

    @discardableResult
    private func withTempFile<T>(_ body: (URL) throws -> T) rethrows -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snap-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir.appendingPathComponent("snapshot.json"))
    }

    private var sample: UsageSnapshot {
        UsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            session: SnapshotWindow(
                usedPercent: 38.2,
                resetsAt: Date(timeIntervalSince1970: 1_700_010_000),
                confidence: .exact
            ),
            weekly: SnapshotWindow(
                usedPercent: 61.0,
                resetsAt: Date(timeIntervalSince1970: 1_700_400_000),
                confidence: .interpolated
            ),
            state: .ok
        )
    }

    @Test("寫入後可讀回相同內容")
    func roundTrips() throws {
        try withTempFile { url in
            let file = SnapshotFile(url: url)
            try file.write(sample)
            #expect(try file.read() == sample)
        }
    }

    @Test("schemaVersion 預設為當前版本")
    func defaultsToCurrentSchemaVersion() {
        #expect(sample.schemaVersion == UsageSnapshot.currentSchemaVersion)
    }

    @Test("檔案不存在時拋 missing")
    func missingFileThrows() throws {
        withTempFile { url in
            #expect(throws: SnapshotError.missing) { try SnapshotFile(url: url).read() }
        }
    }

    @Test("內容損毀時拋 corrupt")
    func corruptFileThrows() throws {
        try withTempFile { url in
            try "{ not valid".write(to: url, atomically: true, encoding: .utf8)
            #expect(throws: SnapshotError.corrupt) { try SnapshotFile(url: url).read() }
        }
    }

    @Test("schemaVersion 較新時拒絕解析")
    func rejectsNewerSchema() throws {
        try withTempFile { url in
            let future = #"{"schemaVersion":99,"updatedAt":0,"state":"ok"}"#
            try future.write(to: url, atomically: true, encoding: .utf8)
            #expect(throws: SnapshotError.schemaTooNew(99)) { try SnapshotFile(url: url).read() }
        }
    }

    @Test("重複寫入會覆蓋且不留下暫存檔")
    func overwritesWithoutLeavingTempFiles() throws {
        try withTempFile { url in
            let file = SnapshotFile(url: url)
            try file.write(sample)
            let updated = UsageSnapshot(
                updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
                session: sample.session, weekly: sample.weekly, state: .ok
            )
            try file.write(updated)
            #expect(try file.read().updatedAt == updated.updatedAt)

            let siblings = try FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path
            )
            #expect(siblings == ["snapshot.json"])
        }
    }

    @Test("state 為非 ok 時視窗可為 nil")
    func allowsNilWindowsForNonOKStates() throws {
        try withTempFile { url in
            let snapshot = UsageSnapshot(
                updatedAt: Date(timeIntervalSince1970: 1), session: nil, weekly: nil, state: .signedOut
            )
            let file = SnapshotFile(url: url)
            try file.write(snapshot)
            let read = try file.read()
            #expect(read.state == .signedOut)
            #expect(read.session == nil)
        }
    }
}

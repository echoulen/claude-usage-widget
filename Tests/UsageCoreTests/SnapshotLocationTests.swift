import Testing
import Foundation
@testable import UsageCore

@Suite("SnapshotLocation")
struct SnapshotLocationTests {

    @discardableResult
    private func withTempDir<T>(_ body: (URL) throws -> T) rethrows -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snapshot-location-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    @Test("widget 與 host app 算出同一個路徑，位於家目錄的 Library/Application Support/ClaudeUsage")
    func bothSidesResolveToSameFile() {
        withTempDir { fakeHome in
            let expected = fakeHome
                .appendingPathComponent("Library/Application Support/ClaudeUsage")
                .appendingPathComponent("snapshot.json")
            #expect(SnapshotLocation.fromInsideWidget(homeURL: fakeHome) == expected)
            #expect(SnapshotLocation.fromHostApp(homeURL: fakeHome) == expected)
        }
    }

    @Test("host app 端：共享目錄不存在時會建立，供後續寫入使用")
    func hostSideCreatesDirectory() {
        withTempDir { fakeHome in
            let url = SnapshotLocation.fromHostApp(homeURL: fakeHome)

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url!.deletingLastPathComponent().path, isDirectory: &isDirectory
            )
            #expect(exists)
            #expect(isDirectory.boolValue)
        }
    }

    @Test("host app 端：共享目錄的位置被檔案佔住、無法建立時回傳 nil")
    func hostSideReturnsNilWhenDirectoryCannotBeCreated() {
        withTempDir { fakeHome in
            let library = fakeHome.appendingPathComponent("Library")
            try! Data().write(to: library)

            #expect(SnapshotLocation.fromHostApp(homeURL: fakeHome) == nil)
        }
    }

    @Test("realHomeDirectory 是真正的家目錄，不是 sandbox 容器")
    func realHomeIsNotAContainer() {
        #expect(!SnapshotLocation.realHomeDirectory().path.contains("/Library/Containers/"))
    }
}

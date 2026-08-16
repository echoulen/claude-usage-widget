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

    @Test("widget 端：以注入的 applicationSupportDirectory 組出 snapshot.json 路徑")
    func widgetSidePathComposition() {
        withTempDir { fakeAppSupport in
            let url = SnapshotLocation.fromInsideWidget(applicationSupportURL: fakeAppSupport)
            #expect(url == fakeAppSupport.appendingPathComponent("snapshot.json"))
        }
    }

    @Test("widget 端：applicationSupportDirectory 不可用時回傳 nil")
    func widgetSideReturnsNilWhenUnavailable() {
        let url = SnapshotLocation.fromInsideWidget(applicationSupportURL: nil)
        #expect(url == nil)
    }

    @Test("host app 端：容器根目錄已存在時，組出 Data/Library/Application Support/snapshot.json")
    func hostSidePathComposition() {
        withTempDir { fakeContainersRoot in
            let containerRoot = fakeContainersRoot.appendingPathComponent(SnapshotLocation.widgetBundleID)
            try! FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)

            let url = SnapshotLocation.fromHostApp(containersRootURL: fakeContainersRoot)

            let expected = containerRoot
                .appendingPathComponent("Data/Library/Application Support")
                .appendingPathComponent("snapshot.json")
            #expect(url == expected)

            // 中介目錄應該已經被建立，供後續寫入使用。
            var isDirectory: ObjCBool = false
            let dirExists = FileManager.default.fileExists(
                atPath: expected.deletingLastPathComponent().path, isDirectory: &isDirectory
            )
            #expect(dirExists)
            #expect(isDirectory.boolValue)
        }
    }

    @Test("host app 端：容器根目錄不存在時回傳 nil，且不會自己建立它")
    func hostSideReturnsNilWhenContainerRootMissing() {
        withTempDir { fakeContainersRoot in
            // 刻意不建立 <fakeContainersRoot>/<widgetBundleID>。
            let url = SnapshotLocation.fromHostApp(containersRootURL: fakeContainersRoot)
            #expect(url == nil)

            let containerRoot = fakeContainersRoot.appendingPathComponent(SnapshotLocation.widgetBundleID)
            #expect(!FileManager.default.fileExists(atPath: containerRoot.path))
        }
    }

    @Test("host app 端：容器根目錄存在但是個檔案（不是目錄）時回傳 nil")
    func hostSideReturnsNilWhenContainerRootIsAFile() {
        withTempDir { fakeContainersRoot in
            let containerRoot = fakeContainersRoot.appendingPathComponent(SnapshotLocation.widgetBundleID)
            try! Data().write(to: containerRoot)

            let url = SnapshotLocation.fromHostApp(containersRootURL: fakeContainersRoot)
            #expect(url == nil)
        }
    }
}

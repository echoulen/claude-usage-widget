import Foundation

public enum SnapshotError: Error, Equatable {
    case missing
    case corrupt
    /// 由較新版本的 host app 寫入，本 widget 無法安全解析。
    case schemaTooNew(Int)
}

/// 讀寫 App Group 中的 snapshot.json。
///
/// 寫入採 atomic replace，避免 widget 在 host app 寫到一半時讀到半份檔案。
public struct SnapshotFile {

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func write(_ snapshot: UsageSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        // Data.write(options: .atomic) 會寫暫存檔再 rename，且不留下殘骸。
        try data.write(to: url, options: .atomic)
    }

    public func read() throws -> UsageSnapshot {
        guard let data = try? Data(contentsOf: url) else {
            throw SnapshotError.missing
        }

        struct VersionProbe: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            throw SnapshotError.corrupt
        }
        guard probe.schemaVersion <= UsageSnapshot.currentSchemaVersion else {
            throw SnapshotError.schemaTooNew(probe.schemaVersion)
        }
        guard let snapshot = try? decoder.decode(UsageSnapshot.self, from: data) else {
            throw SnapshotError.corrupt
        }
        return snapshot
    }
}

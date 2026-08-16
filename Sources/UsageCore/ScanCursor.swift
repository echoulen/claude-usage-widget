import Foundation

/// 記錄每個 transcript 檔上次讀到的位置，讓下次掃描只需讀取新增內容。
public struct ScanCursor: Codable, Equatable, Sendable {

    public struct FileCursor: Codable, Equatable, Sendable {
        public var byteOffset: UInt64
        public var modifiedAt: Date

        public init(byteOffset: UInt64, modifiedAt: Date) {
            self.byteOffset = byteOffset
            self.modifiedAt = modifiedAt
        }
    }

    /// key 為檔案絕對路徑。
    public var files: [String: FileCursor]

    public init(files: [String: FileCursor] = [:]) {
        self.files = files
    }
}

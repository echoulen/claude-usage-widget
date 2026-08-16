import Foundation

/// 單一額度視窗的狀態。`usedPercent` 為**已使用**比例，UI 顯示剩餘時自行取 100 - usedPercent。
public struct UsageWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date

    public init(usedPercent: Double, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct OfficialUsage: Equatable, Sendable {
    /// 5 小時 session 視窗。
    public let session: UsageWindow
    /// 7 天週視窗。
    public let weekly: UsageWindow
    public let fetchedAt: Date

    public init(session: UsageWindow, weekly: UsageWindow, fetchedAt: Date) {
        self.session = session
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }
}

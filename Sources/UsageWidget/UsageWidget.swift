import WidgetKit
import SwiftUI
import UsageCore

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct UsageProvider: TimelineProvider {

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: UsageSnapshot(
            updatedAt: Date(),
            session: SnapshotWindow(
                usedPercent: 35, resetsAt: Date().addingTimeInterval(9000), confidence: .exact
            ),
            weekly: SnapshotWindow(
                usedPercent: 55, resetsAt: Date().addingTimeInterval(400_000), confidence: .exact
            ),
            state: .ok
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let now = Date()
        completion(UsageEntry(date: now, snapshot: readSnapshot(now: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let snapshot = readSnapshot(now: now)
        // 倒數計時由 Text(_:style:.relative) 自行更新，不需靠 reload。
        // 這裡只需在下一次預期的 host app 推送前留一個保險刷新點。
        let entry = UsageEntry(date: now, snapshot: snapshot)
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(900))))
    }

    /// 讀出來的 snapshot 一律先過 `SnapshotPresenter`：host app 沒有隨系統啟動時
    /// （`--login-item` 預設不裝），這份檔案可能是重開機前留下的舊資料，
    /// 讀端必須自己再把「視窗是否已過 resetsAt」「距離上次寫入是否太久」查一次，
    /// 不能只信任寫入當下已經做過的判斷。
    private func readSnapshot(now: Date) -> UsageSnapshot? {
        guard let url = SnapshotLocation.fromInsideWidget() else { return nil }
        guard let snapshot = try? SnapshotFile(url: url).read() else { return nil }
        return SnapshotPresenter().present(snapshot, now: now)
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UsageWidget", provider: UsageProvider()) { entry in
            UsageWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude 用量")
        .description("顯示 5 小時與本週額度已使用的比例。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct UsageWidgetBundle: WidgetBundle {
    var body: some Widget { UsageWidget() }
}

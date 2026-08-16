import SwiftUI
import WidgetKit
import UsageCore
import AppKit

struct UsageWidgetView: View {
    let snapshot: UsageSnapshot?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall: smallBody
        default: mediumBody
        }
    }

    /// 只顯示 5 小時窗口——這個尺寸容不下兩個環,而 5 小時是唯一「現在該做什麼」有意義的數字。
    @ViewBuilder
    private var smallBody: some View {
        if let snapshot, let session = snapshot.session {
            VStack(spacing: 6) {
                Text("5 小時").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RingGauge(window: session, diameter: 86, lineWidth: 10, centerFontSize: 26)
                Text(session.resetsAt, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
                if session.confidence != .exact {
                    confidenceCaption(session.confidence, officialFetchedAt: snapshot.officialFetchedAt)
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailableBody
        }
    }

    @ViewBuilder
    private var mediumBody: some View {
        if let snapshot, snapshot.session != nil || snapshot.weekly != nil {
            HStack(spacing: 20) {
                windowColumn(title: "5 小時", window: snapshot.session, officialFetchedAt: snapshot.officialFetchedAt, diameter: 68, lineWidth: 8, centerFontSize: 20)
                Divider()
                windowColumn(title: "本週", window: snapshot.weekly, officialFetchedAt: snapshot.officialFetchedAt, diameter: 68, lineWidth: 8, centerFontSize: 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailableBody
        }
    }

    /// 兩欄無論哪一邊有資料、信心度為何，永遠渲染同樣的列數與環的固定 frame，
    /// 藉此保證兩欄同高。空窗口用空 track 環 +「—」置中,以及 em dash 佔位列。
    ///
    /// `confidenceCaption` 那一列額外套一個固定 `.frame(height:)`
    /// （見 `confidenceCaptionHeight`）：不能只靠「這個分支剛好會渲染出一個有高度的
    /// view」來保證同高——`.exact` 曾經因為從 `Text("")` 改成 `EmptyView()` 就打破了
    /// 這個假設（`EmptyView()` 完全不佔版面），兩欄信心度不同時就會一邊高一邊矮。
    /// 固定高度是由版面系統直接保證的，不受未來 `confidenceCaption` 內部實作變動影響。
    @ViewBuilder
    private func windowColumn(
        title: String, window: SnapshotWindow?, officialFetchedAt: Date?, diameter: CGFloat, lineWidth: CGFloat, centerFontSize: CGFloat
    ) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            RingGauge(window: window, diameter: diameter, lineWidth: lineWidth, centerFontSize: centerFontSize)
            if let window {
                Text(window.resetsAt, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
                confidenceCaption(window.confidence, officialFetchedAt: officialFetchedAt)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(height: Self.confidenceCaptionHeight, alignment: .leading)
            } else {
                Text("—").font(.caption2).foregroundStyle(.secondary)
                Text("—").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(height: Self.confidenceCaptionHeight, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `confidenceCaption` 那一列的固定高度：直接用 `NSFont` 量測 9pt 字級的行高，
    /// 不是憑感覺猜的常數，也不是依賴某個分支「剛好」渲染出多高的 view——結構性地
    /// 保證兩欄同高，即使未來 `confidenceCaption` 的某個 case 改成 `EmptyView()`
    /// 或別的實作，這裡的 `.frame(height:)` 依然會把它撐開到跟有內容的那一欄一樣高。
    private static let confidenceCaptionHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: 9)
        return font.ascender - font.descender + font.leading
    }()

    @ViewBuilder
    private var unavailableBody: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.medium").foregroundStyle(.tertiary)
            Text(message(for: snapshot?.state)).font(.caption2)
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 270° 弧形量表,缺口置中於底部——幾何與 app icon 一致（見 Tools/make-icon.py 的
/// ARC_START=135°／ARC_SWEEP=270°）。弧長是主要訊號,顏色只是輔助強化：value 弧在
/// `.fullColor` 模式下依用量嚴重度上色,但在 `.vibrant`／`.accented` 等系統會去飽和
/// 的模式下退回 `.primary`,絕不讓色相成為唯一可辨識的資訊——弧長本身已經表達同一件事。
private struct RingGauge: View {
    let window: SnapshotWindow?
    let diameter: CGFloat
    let lineWidth: CGFloat
    let centerFontSize: CGFloat

    @Environment(\.widgetRenderingMode) private var renderingMode

    /// 270 / 360。
    private static let sweepFraction = 0.75
    /// trim(from:0, to:0.75) 預設從 3 點鐘方向順時鐘掃 270° 到 12 點鐘方向,
    /// 缺口(未掃到的 90°)落在右上角、以 315° 為中心。順時鐘再轉 135°,
    /// 把缺口中心移到 315°+135°=450°=90°,也就是正下方——與 app icon 用
    /// PIL 畫的 ARC_START=135°/ARC_SWEEP=270° 是同一個角度系統下的等價結果
    /// （PIL 的 y 軸朝下,角度同樣以順時鐘為正、0° 在 3 點鐘方向）。
    private static let startRotation = Angle.degrees(135)

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweepFraction)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .foregroundStyle(.quaternary)
                .rotationEffect(Self.startRotation)

            if let window {
                Circle()
                    .trim(from: 0, to: Self.sweepFraction * usedFraction(window.usedPercent))
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .foregroundStyle(valueArcColor(for: window.usedPercent))
                    .rotationEffect(Self.startRotation)
            }

            Text(window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—")
                .font(.system(size: centerFontSize, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .foregroundStyle(.primary)
        }
        .frame(width: diameter, height: diameter)
    }

    /// 防止 usedPercent 若脫離 0...100（不該發生,但資料是跨行程讀入的）把 trim
    /// 餵進非法範圍。
    private func usedFraction(_ usedPercent: Double) -> Double {
        max(0, min(1, usedPercent / 100))
    }

    /// `.fullColor` 下才用嚴重度色階；其餘渲染模式一律退回 `.primary`,
    /// 因為系統會把顏色去飽和,此時色相不再可靠,弧長仍是唯一訊號。
    private func valueArcColor(for usedPercent: Double) -> Color {
        renderingMode == .fullColor ? severityColor(for: usedPercent) : .primary
    }
}

/// 用量嚴重度色階,唯一定義處：0–59 comfortable(綠)、60–84 watch it(橘)、
/// 85–100 near the limit(紅)。下限含頭（60.0 算橘、85.0 算紅）。
private func severityColor(for usedPercent: Double) -> Color {
    switch usedPercent {
    case ..<60: .green
    case ..<85: .orange
    default: .red
    }
}

/// `.estimated` 不保證是**原封不動**的最後一次官方讀數（見 `Confidence.estimated` 的文件
/// 註解）：寫入端（`UsageStore` 降級路徑）給的確實是原封不動、未經任何本機重新估算的舊值；
/// 但讀端（`SnapshotPresenter`）在 snapshot 本身放太久時，也會把當下已經是 `.interpolated`
/// 的本機外插值一併降級標成 `.estimated`。這裡統一用「已凍結」而非「離線推估」，因為兩種
/// 來源共通的重點都是「現在不能再當即時看」，不是在區分數字本身怎麼算出來的。
///
/// `officialFetchedAt` 是官方讀數**取得**的時間（不是 snapshot 寫入時間）；為 `nil`
/// 時（例如讀到舊版、還沒有這個欄位的 snapshot）不裝作知道，只顯示「已凍結」，不附相對時間，
/// 因為附上去只會是編出來的數字——見 `UsageSnapshot.officialFetchedAt` 的文件註解。
/// `Text(date, style: .relative)` 讓「多久以前」隨時間自動跳動，不用等下一次 reload。
///
/// `.exact` 這個 case 必須渲染出跟其他 case 同樣行高的 view（`Text("")` 而非
/// `EmptyView()`）——`EmptyView()` 完全不佔版面，會讓兩欄信心度不同時高度對不齊
/// （見 `windowColumn` 的 `confidenceCaptionHeight` 註解，那裡另外用固定 frame
/// 再上一道結構性保險，不只靠這裡的 `Text("")`）。
@ViewBuilder
private func confidenceCaption(_ confidence: Confidence, officialFetchedAt: Date?) -> some View {
    switch confidence {
    case .exact:
        Text("")
    case .interpolated:
        Text("推估中")
    case .estimated:
        if let officialFetchedAt {
            Text("已凍結 ") + Text(officialFetchedAt, style: .relative)
        } else {
            Text("已凍結")
        }
    }
}

private func message(for state: SnapshotState?) -> String {
    switch state {
    case .signedOut: "請開啟 Claude Usage 登入"
    case .apiUnavailable: "暫時無法取得額度"
    // 跟 .apiUnavailable 刻意不同文案——API 本身正常，只是視窗剛重置，不是服務中斷（defect 2）。
    case .windowResetPending: "視窗剛重置，讀數更新中"
    case .noData: "找不到用量資料"
    case .ok, .none: "尚未取得資料"
    }
}

#Preview("Small", as: .systemSmall) {
    UsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: UsageSnapshot(
        updatedAt: .now,
        session: SnapshotWindow(usedPercent: 38.2, resetsAt: .now.addingTimeInterval(10_800), confidence: .exact),
        weekly: SnapshotWindow(usedPercent: 61, resetsAt: .now.addingTimeInterval(345_600), confidence: .interpolated),
        state: .ok
    ))
    UsageEntry(date: .now, snapshot: UsageSnapshot(
        updatedAt: .now, session: nil, weekly: nil, state: .signedOut
    ))
}

#Preview("Medium", as: .systemMedium) {
    UsageWidget()
} timeline: {
    // .ok,兩個窗口都有,信心度混合(session .exact / weekly .interpolated)。
    UsageEntry(date: .now, snapshot: UsageSnapshot(
        updatedAt: .now,
        session: SnapshotWindow(usedPercent: 38.2, resetsAt: .now.addingTimeInterval(10_800), confidence: .exact),
        weekly: SnapshotWindow(usedPercent: 61, resetsAt: .now.addingTimeInterval(345_600), confidence: .interpolated),
        state: .ok
    ))
    // 已登出。
    UsageEntry(date: .now, snapshot: UsageSnapshot(
        updatedAt: .now, session: nil, weekly: nil, state: .signedOut
    ))
    // 高度一致性案例:session 缺席、weekly 有資料——兩欄仍須同高。
    UsageEntry(date: .now, snapshot: UsageSnapshot(
        updatedAt: .now,
        session: nil,
        weekly: SnapshotWindow(usedPercent: 61, resetsAt: .now.addingTimeInterval(345_600), confidence: .interpolated),
        state: .ok
    ))
    // 真零案例:usedPercent 為合法的 0（尚未使用),必須與缺席資料的「—」明顯不同。
    UsageEntry(date: .now, snapshot: UsageSnapshot(
        updatedAt: .now,
        session: SnapshotWindow(usedPercent: 0, resetsAt: .now.addingTimeInterval(10_800), confidence: .exact),
        weekly: SnapshotWindow(usedPercent: 21, resetsAt: .now.addingTimeInterval(345_600), confidence: .exact),
        state: .ok
    ))
    // 嚴重度色階一覽:comfortable(綠,~20%)、watch it(橘,~70%)、near the limit(紅,~92%)。
    UsageEntry(date: .now, snapshot: UsageSnapshot(
        updatedAt: .now,
        session: SnapshotWindow(usedPercent: 20, resetsAt: .now.addingTimeInterval(10_800), confidence: .exact),
        weekly: SnapshotWindow(usedPercent: 70, resetsAt: .now.addingTimeInterval(345_600), confidence: .exact),
        state: .ok
    ))
    UsageEntry(date: .now, snapshot: UsageSnapshot(
        updatedAt: .now,
        session: SnapshotWindow(usedPercent: 92, resetsAt: .now.addingTimeInterval(10_800), confidence: .exact),
        weekly: SnapshotWindow(usedPercent: 92, resetsAt: .now.addingTimeInterval(345_600), confidence: .exact),
        state: .ok
    ))
}

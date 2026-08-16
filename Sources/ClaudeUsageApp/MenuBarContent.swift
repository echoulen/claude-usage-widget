import SwiftUI
import UsageCore
import AppKit

struct MenuBarContent: View {
    let coordinator: UsageCoordinator

    /// 用來把 `officialFetchedAt`（官方讀數實際取得的時間，不是 snapshot 寫入時間
    /// `updatedAt`）換算成「3 小時前」這種人看得懂的相對時間，讓凍結中的讀數清楚標出
    /// 「有多舊」，而不是只說「已凍結」卻不說多久之前。刻意不用 `updatedAt`：host app
    /// 每 15 秒都會 `publish()` 一次，不論 API 有沒有打通，用 `updatedAt` 會讓斷線六小時
    /// 的讀數看起來只舊了幾秒。
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        if let session = coordinator.snapshot?.session {
            Text("5 小時已用：\(usedPercentText(session.usedPercent))")
        } else {
            Text("5 小時已用：—")
        }

        if let weekly = coordinator.snapshot?.weekly {
            Text("本週已用：\(usedPercentText(weekly.usedPercent))")
        } else {
            Text("本週已用：—")
        }

        if let stateMessage {
            Divider()
            Text(stateMessage).font(.caption)
        }

        if let transcriptWarningMessage {
            Divider()
            Text(transcriptWarningMessage).font(.caption)
        }

        if let deliveryMessage {
            Divider()
            Text(deliveryMessage).font(.caption)
        }

        if let error = coordinator.lastError {
            Divider()
            Text(error).font(.caption)
        }

        Divider()
        Button("立即重新整理") { coordinator.refreshNow() }
        Button("結束") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// 依 `SnapshotState` 給出使用者看得懂的一句話。governing principle：
    /// 寧可顯示「不知道」，也不顯示可能是錯的數字——因此沒有資料時一定要說明原因，
    /// 不能只留一個安靜的「—」。
    private var stateMessage: String? {
        guard let state = coordinator.snapshot?.state else { return nil }
        switch state {
        case .ok:
            return nil
        case .signedOut:
            // `UsageStore` 在從未取得過有效 API 樣本時一律回傳 `.signedOut`，但這個狀態
            // 底下可能是兩種完全不同的原因：真的沒登入，或只是連不上服務（斷網、逾時）。
            // `UsageCoordinator.lastAPIFailureReason` 記錄了實際分類，`.service` 代表
            // 明確知道不是登入問題，這裡就不能沿用「尚未登入」這句話——那是誤判。
            if coordinator.lastAPIFailureReason == .service {
                return "目前連不上官方額度服務，尚無法確認登入狀態（非登入問題）。"
            }
            return "尚未登入 Claude Code，或 Keychain 授權被拒。"
        case .apiUnavailable:
            // 這句話必須在 `.apiUnavailable` 底下的每一種情況都成立——這個狀態不只是
            // 「API 斷線超過寬限期、讀數原樣凍結」一種：session 視窗一過 resetsAt 就會
            // 被拿掉，此時即使 API 仍連得上、weekly 仍是本機外插出來的 .interpolated
            // 值，整體狀態一樣是 .apiUnavailable。因此不能斷言「已原樣凍結、未做任何
            // 本機重新估算」——那在 weekly 是 .interpolated 時就是假的。這裡改成同時
            // 涵蓋兩種可能，不挑邊。
            let base = "官方額度 API 暫時無法取得或部分視窗已重置。畫面上若仍顯示數字，" +
                "可能是最後一次成功取得的官方讀數（已凍結），也可能是依本機使用量在兩次" +
                "官方讀數之間推估出來的數字，並非保證即時。"
            guard let officialFetchedAt = coordinator.snapshot?.officialFetchedAt else { return base }
            let age = Self.relativeFormatter.localizedString(for: officialFetchedAt, relativeTo: Date())
            return base + "（官方讀數取得於：\(age)）"
        case .windowResetPending:
            // 跟 .apiUnavailable 刻意不同：API 本身正常，只是視窗剛重置、還沒有新讀數，
            // 不能讓使用者誤以為服務出問題（見 defect 2）。
            let base = "視窗剛重置，正在等待下一次官方讀數，畫面稍後會自動更新。"
            guard let officialFetchedAt = coordinator.snapshot?.officialFetchedAt else { return base }
            let age = Self.relativeFormatter.localizedString(for: officialFetchedAt, relativeTo: Date())
            return base + "（上一次官方讀數：\(age)）"
        case .noData:
            return "找不到 ~/.claude/projects，或沒有讀取權限。"
        }
    }

    /// defect 4：`~/.claude/projects` 讀不到時，畫面上仍可能顯示官方 API 的原始數字
    /// （`.exact`，見 `UsageCoordinator.publish()`），但兩次官方讀數之間的本機外插已經
    /// 關閉了——這件事必須讓使用者知道，不能只默默把 `.interpolated` 換成 `.exact`
    /// 卻不說原因。`state == .noData` 時 `stateMessage` 已經講過同一件事，這裡不重複。
    private var transcriptWarningMessage: String? {
        guard !coordinator.transcriptRootAccessible, coordinator.snapshot?.state != .noData else {
            return nil
        }
        return "找不到 ~/.claude/projects 或沒有讀取權限：畫面上的數字仍是官方讀數，" +
            "但兩次讀數之間暫時不提供本機推估。"
    }

    /// snapshot.json 是否成功送到 widget 容器；兩種失敗形態訊息不同（見
    /// `SnapshotDeliveryStatus`），都必須讓使用者看得到，不能悄悄失敗。
    private var deliveryMessage: String? {
        switch coordinator.snapshotDeliveryStatus {
        case .ok:
            return nil
        case .widgetContainerMissing:
            return "尚未偵測到桌面 widget。請先把「Claude 用量」widget 加到桌面或通知中心一次，之後會自動同步。"
        case .writeDenied(let message):
            return "無法寫入 widget 資料（\(message)）。請至 系統設定 → 隱私權與安全性 檢查是否封鎖了本 App 對其他 App 資料的存取。"
        }
    }

    /// **已使用**比例——跟桌面 widget（`UsageWidgetView`）同一個量，避免同一個視窗
    /// 在選單列與 widget 上顯示互相矛盾的數字（例如選單列說 93%、widget 說 7%）。
    private func usedPercentText(_ usedPercent: Double) -> String {
        "\(Int(usedPercent.rounded()))%"
    }
}

/// 選單列標題：純文字，`「5h 33%」`——window 縮寫＋**已使用**百分比，跟下拉選單裡
/// 「5 小時已用：33%」同一個量，避免同一個視窗在選單列與下拉選單顯示互相矛盾的數字
/// （例如選單列說 93%、下拉選單說 7%）。光看一個孤零零的「28%」看不出是哪個視窗、也看
/// 不出是用掉還是剩下，因此一律帶上 `5h` 這個窗口縮寫。
///
/// 這裡不再嘗試畫環形量表：`MenuBarExtra` 的 label 只可靠支援 `Text`／`Image`，
/// 先前用 `ImageRenderer` 把環點陣化成 `NSImage` 勉強繞過這個限制，但環本身是為桌面
/// widget 的 ~70pt 尺寸設計的 270° 弧形，縮到選單列的 ~16pt、又只能用單色 template
/// image 呈現時，看起來只是一段沒有意義的弧、缺口還在底部，不像任何比例讀數。純文字
/// 標籤才是選單列這個尺度下唯一讀得懂的呈現方式。
///
/// **色彩不可靠，不用來承載意義**：`MenuBarExtra` 的 label 內容在選單列裡對彩色前景
/// 不生效——這不是憑空假設，是 Apple Developer Forums thread 738716
/// （https://developer.apple.com/forums/thread/738716）裡其他開發者的實測回報：對
/// label 套用 `.foregroundStyle(.red)` / `Image.renderingMode(.original)`，選單列
/// 仍舊只顯示單色，跟一般視窗裡的行為不同。這裡因此完全不引入嚴重度顏色（`.green`／
/// `.orange`／`.red`，即使桌面 widget 在 `.fullColor` 模式下有這層加強），只用
/// `.opacity` 表示凍結狀態，弧長已經不存在，數字本身才是唯一訊號。
struct MenuBarLabel: View {
    let coordinator: UsageCoordinator

    var body: some View {
        Text(labelText)
            .opacity(isFrozen ? 0.5 : 1)
    }

    /// 兩個視窗都顯示，以中點分隔。視窗為 `nil` 時該側顯示 em-dash，不能顯示一個
    /// 編出來的 `0%`——那會被誤讀成「已用 0%」這個具體讀數。`usedPercent` 真的是
    /// `0` 時（合法的「尚未使用」讀數）則正常顯示 `0%`，靠「有沒有這個視窗」而不是
    /// 「數值是不是 0」來分辨這兩種狀態，跟桌面 widget `RingGauge` 中心文字的
    /// `window.map { ... } ?? "—"` 是同一個分界。
    private var labelText: String {
        "5h \(format(session)) · W \(format(weekly))"
    }

    private func format(_ window: SnapshotWindow?) -> String {
        window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—"
    }

    private var session: SnapshotWindow? {
        coordinator.snapshot?.session
    }

    private var weekly: SnapshotWindow? {
        coordinator.snapshot?.weekly
    }

    /// 只有「已凍結」（`Confidence.estimated`，見該 case 的文件註解）才算凍結——
    /// `.interpolated` 仍是本機即時外插出來的數字，不該被一起悶掉。跟桌面 widget 的
    /// `confidenceCaption`（`.estimated` → 「已凍結」）用同一個分界，避免選單列與
    /// widget 兩邊對「這是不是舊數字」給出不同答案。用淡化透明度表示，不是顏色——
    /// 選單列上色相不可靠（見型別文件註解），只有 alpha 是保證生效的呈現方式。
    /// 任一視窗凍結就淡化整行——兩個數字並列時只淡其中一個會看起來像渲染壞掉，
    /// 而「這排數字現在不能當即時看」本來就是整體性的判斷。
    private var isFrozen: Bool {
        session?.confidence == .estimated || weekly?.confidence == .estimated
    }
}

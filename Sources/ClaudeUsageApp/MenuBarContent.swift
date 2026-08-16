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

/// 選單列標題：一個小環形量表＋百分比數字，弧長對應**已使用**比例——跟 app icon、桌面
/// widget（`UsageWidgetView.RingGauge`）同一套視覺語言，讓三處讀起來是同一個記號。
/// 光看一個孤零零的「13%」看不出是哪個視窗、也看不出是用掉還是剩下，環本身把「這是一個
/// 用量讀數、而且是已使用比例」這件事一併帶出來，不用等使用者點開下拉選單才看到
/// 「5 小時已用：13%」這句話。
///
/// **色彩不可靠，不用來承載意義**：`MenuBarExtra` 的 label 內容在選單列裡對彩色前景
/// 不生效——這不是憑空假設，是 Apple Developer Forums thread 738716
/// （https://developer.apple.com/forums/thread/738716）裡其他開發者的實測回報：對
/// label 套用 `.foregroundStyle(.red)` / `Image.renderingMode(.original)`，選單列
/// 仍舊只顯示單色，跟一般視窗裡的行為不同。這裡因此完全不引入嚴重度顏色（`.green`／
/// `.orange`／`.red`，即使桌面 widget 在 `.fullColor` 模式下有這層加強），全程只用
/// `.primary`／`.secondary`／`.opacity` 這些語意色階與透明度，弧長本身才是唯一訊號。
struct MenuBarLabel: View {
    let coordinator: UsageCoordinator

    /// 已經點陣化的環形量表。`body` 每次 coordinator 發佈都會重新求值，但這張圖只有在
    /// `imageKey`（見下方）真的變動時才重畫——見 `.onChange` 那行。
    @State private var renderedRingImage: NSImage?

    var body: some View {
        HStack(spacing: 4) {
            ringImageView
            if let session {
                Text("\(Int(session.usedPercent.rounded()))%")
                    .opacity(isFrozen ? 0.5 : 1)
            }
        }
        // `initial: true`：View 第一次出現時 `onChange` 不會平白略過，一定會先畫一次，
        // 不必額外靠 `.onAppear` 重複一套邏輯。之後只有 `imageKey` 真的改變（四捨五入後
        // 的百分比、凍結旗標、或畫布像素尺寸其中之一變了）才會重新呼叫 `ImageRenderer`——
        // 不是每次 body 求值（coordinator 15 秒發佈一次，但多半數字不會四捨五入後改變）
        // 都重畫，避免離譜的重複點陣化成本。
        .onChange(of: imageKey, initial: true) {
            renderedRingImage = Self.renderRingImage(key: imageKey)
        }
    }

    /// `MenuBarExtra` 的 label 只可靠支援 `Text`／`Image`——任意 SwiftUI view（`Circle`
    /// 疊 `trim`／`stroke` 這種畫圖 primitive）常被直接吃掉、什麼都不畫，這正是這次
    /// bug 的成因：`RingGaugeGlyph` 編譯得過、單元測試看不出問題，選單列上卻是空的。
    /// 修法是把 `RingGaugeGlyph` 透過 `ImageRenderer` 點陣化成 `NSImage` 再餵給
    /// `Image(nsImage:)`——`Image` 是 label 保證支援的型別。畫面還沒點陣化出第一張圖前
    /// （理論上只有極短暫的第一個 frame），用同尺寸的透明色塊占位，避免版面跳動。
    @ViewBuilder
    private var ringImageView: some View {
        if let renderedRingImage {
            Image(nsImage: renderedRingImage)
                .frame(width: diameter, height: diameter)
        } else {
            Color.clear.frame(width: diameter, height: diameter)
        }
    }

    /// 決定要不要重畫點陣圖的完整依據——刻意只放「會影響畫出來的像素」的東西：
    /// 四捨五入後的百分比（不是連續的 `usedPercent`，因為畫面上的弧長本來就只精細到
    /// 整數百分比，且要跟旁邊 `Text` 顯示的數字用同一個四捨五入結果，避免環跟數字兩邊
    /// 各自四捨五入出現肉眼看得出的不一致）、凍結旗標、以及畫布的點尺寸／螢幕縮放
    /// （decides pixel size）。`nil` 表示「沒有 session 視窗」，跟「有 session 但值是
    /// 0」（`roundedPercent == 0`）刻意分成兩種不同的 key，讓 `renderRingImage` 能各自
    /// 畫出「空 track」跟「track + 一段長度為 0 的 value 弧（視覺上跟空 track 幾乎相同，
    /// 但語意上是不同狀態，由旁邊有沒有 `Text` 來區分）」。
    private var imageKey: RingImageKey {
        RingImageKey(
            roundedPercent: session.map { Int($0.usedPercent.rounded()) },
            isFrozen: isFrozen,
            diameter: diameter,
            lineWidth: lineWidth,
            scale: backingScale
        )
    }

    /// 把凍結時的淡化直接烤進點陣圖的 alpha channel，不依賴事後對 `Image(nsImage:)`
    /// 套用 `.opacity()` modifier——`MenuBarExtra` 的 label 對「事後套用的 view
    /// modifier」有沒有可靠生效本來就是這次 bug 的源頭，沒有理由假設 `.opacity()`
    /// 套在 `Image` 上就一定沒事。烤進 bitmap 之後，`isTemplate = true` 這條路徑上
    /// alpha 本來就是 template image 的遮罩強度，淡化直接對應「這塊遮罩比較透明」，
    /// 是 AppKit 保證支援的行為，不是賭 SwiftUI label 的 modifier 有沒有生效。
    @MainActor
    private static func renderRingImage(key: RingImageKey) -> NSImage? {
        let usedPercent = key.roundedPercent.map(Double.init)
        let glyph = RingGaugeGlyph(usedPercent: usedPercent, diameter: key.diameter, lineWidth: key.lineWidth)
            .opacity(key.isFrozen ? 0.5 : 1)
        let renderer = ImageRenderer(content: glyph)
        renderer.scale = key.scale
        guard let nsImage = renderer.nsImage else { return nil }
        // 標成 template image，讓 macOS 依淺色／深色選單列與 highlighted 狀態自動套色，
        // 跟桌面 widget 靠色彩傳意義的做法不同——選單列上色相不可靠（見型別文件註解），
        // 弧長才是唯一訊號，template image 正好把色相這件事整個交給系統決定。
        nsImage.isTemplate = true
        return nsImage
    }

    /// 選單列反映的是 5 小時 session 視窗——唯一「現在該做什麼」有實際意義的數字；
    /// 本週視窗仍只在下拉選單裡（見上方 `MenuBarContent.body`）。
    private var session: SnapshotWindow? {
        coordinator.snapshot?.session
    }

    /// 只有「已凍結」（`Confidence.estimated`，見該 case 的文件註解）才算凍結——
    /// `.interpolated` 仍是本機即時外插出來的數字，不該被一起悶掉。跟桌面 widget 的
    /// `confidenceCaption`（`.estimated` → 「已凍結」）用同一個分界，避免選單列與
    /// widget 兩邊對「這是不是舊數字」給出不同答案。用淡化透明度表示，不是顏色——
    /// alpha 是形狀本身的一部分，不受「色相在選單列可能被丟棄」這件事影響。
    private var isFrozen: Bool {
        session?.confidence == .estimated
    }

    /// 選單列高度隨機種不同（帶瀏海機型的選單列比一般機型高），從系統即時讀取、
    /// 不寫死；扣掉一點內距，避免環貼滿到跟旁邊的選單列圖示黏在一起或被系統裁掉一圈。
    private var diameter: CGFloat {
        let thickness = NSStatusBar.system.thickness
        return max(10, thickness - 6)
    }

    /// 粗細跟直徑成比例：直徑小時筆畫也跟著細，但設下限，避免小尺寸下細到看不清楚
    /// 這是一圈弧而不是一個點。
    private var lineWidth: CGFloat {
        max(1.5, diameter * 0.18)
    }

    /// 點陣化用的縮放係數——從當前螢幕的 backing scale factor 讀，不寫死 `2`：
    /// 非 Retina 外接螢幕是 `1`，一般內建螢幕是 `2`，寫死會在非 Retina 螢幕上算出用不到
    /// 的多餘像素、或反過來在更高密度螢幕上不夠銳利。`NSScreen.main` 理論上不該是
    /// `nil`（選單列 app 執行中必然有主螢幕），這裡的 `?? 2` 純粹是防禦性下限，不是
    /// 主要取值路徑。
    private var backingScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }
}

/// 決定 `MenuBarLabel.renderedRingImage` 要不要重畫的完整依據——只放「會影響畫出來的
/// 像素」的欄位，讓 `.onChange(of:)` 能準確判斷「這次 coordinator 發佈有沒有真的動到
/// 畫面」，而不是每次 body 求值都無條件重跑 `ImageRenderer`。
private struct RingImageKey: Equatable {
    let roundedPercent: Int?
    let isFrozen: Bool
    let diameter: CGFloat
    let lineWidth: CGFloat
    let scale: CGFloat
}

/// 270° 弧形量表，缺口置中於底部——幾何常數（`sweepFraction`／`startRotation`）直接
/// 複製自桌面 widget 的 `UsageWidgetView.RingGauge`（該型別是 `UsageWidget` target
/// 內的 `private` 型別，且兩個 target 沒有共用的 UI 模組可以匯入，因此這裡刻意重寫
/// 同一套幾何常數，而不是改動 `UsageWidget` target 把它公開出來——後者超出本次改動
/// 範圍）。務必保持兩邊角度系統一致，這樣 app icon、widget、選單列才會讀起來是同一個
/// 記號，而不是三種不同的弧形語言。
///
/// `usedPercent == nil` 時只畫空 track、不畫 value 弧，代表「沒有 session 視窗」；
/// `usedPercent == 0` 時仍然呼叫 `trim(from:0, to:0)`（等於不畫出可見弧長，視覺上
/// 跟空 track 幾乎相同）——這兩種情況單靠環本身無法分辨，刻意如此：分辨兩者的責任
/// 交給 `MenuBarLabel.body`，只有「有 session」才會在環旁邊多畫一個百分比數字，
/// 「沒有 session」則完全不畫數字。「有沒有數字」才是這兩種狀態唯一的區分依據，
/// 避免環本身用一個以假亂真的近似弧長來暗示一個並不存在的讀數。
private struct RingGaugeGlyph: View {
    let usedPercent: Double?
    let diameter: CGFloat
    let lineWidth: CGFloat

    private static let sweepFraction = 0.75
    private static let startRotation = Angle.degrees(135)

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweepFraction)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .foregroundStyle(.secondary)
                .rotationEffect(Self.startRotation)

            if let usedPercent {
                Circle()
                    .trim(from: 0, to: Self.sweepFraction * usedFraction(usedPercent))
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .foregroundStyle(.primary)
                    .rotationEffect(Self.startRotation)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// 防止 usedPercent 若脫離 0...100（不該發生，但資料是跨行程讀入的）把 trim
    /// 餵進非法範圍——跟 `UsageWidgetView.RingGauge.usedFraction` 同樣的防線。
    private func usedFraction(_ usedPercent: Double) -> Double {
        max(0, min(1, usedPercent / 100))
    }
}

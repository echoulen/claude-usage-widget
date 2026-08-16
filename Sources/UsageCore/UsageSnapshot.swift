import Foundation

public enum Confidence: String, Codable, Sendable {
    /// 直接來自官方 API。
    case exact
    /// API 基準點 + 本機 token 補間外插。
    case interpolated
    /// API 已經斷線超過寬限期，或這份 snapshot 本身已經放太久——不再有把握它反映現在。
    /// 有兩個不同的產生來源，代表的意思不完全一樣：
    /// 1. 寫入端（`UsageStore.makeWindow` 的 degraded 分支）：API 失敗超過寬限期時，
    ///    直接把最後一次官方讀數**原封不動**標成 `.estimated`，刻意不做任何本機外插。
    /// 2. 讀端（`SnapshotPresenter.present`）：snapshot 本身放太久時，把當下這個視窗
    ///    ——不論它原本是 `.exact` 還是 `.interpolated`（也就是可能已經是本機外插出來的
    ///    數字）——一律降級標成 `.estimated`。這裡標的是「這個數字現在不能再當即時看」，
    ///    不代表它本身未經任何本機推算。
    /// 兩者共通點只有一件事：這個數字現在不保證反映當下，該提醒使用者「這是舊/凍結的」。
    case estimated
}

public enum SnapshotState: String, Codable, Sendable {
    case ok
    case signedOut
    case apiUnavailable
    /// 至少一個視窗剛重置（已過 `resetsAt`），但 API 本身健康——只是還沒有新視窗的官方
    /// 讀數，不是打不通。跟 `.apiUnavailable` 混為一談會讓使用者在 API 完全正常時，
    /// 看到「官方額度 API 暫時無法取得」這種不存在的失敗（見 defect 2）。
    ///
    /// 新增、非破壞性的 case，`schemaVersion` 不需要調高：`SnapshotFile.read()` 對任何
    /// 解碼失敗（包含舊版 widget 遇到不認得的 raw string）一律視為 `SnapshotError.corrupt`，
    /// 呼叫端（`UsageProvider.readSnapshot`）再把它當成 `nil` snapshot 處理，widget 會顯示
    /// 「尚未取得資料」——不是崩潰，也不是把新狀態誤讀成別的合法狀態而顯示錯誤數字。
    /// 這是安全的降級，符合「寧可顯示不知道」的原則，因此不需要新的 schema 版本。
    case windowResetPending
    case noData
}

public struct SnapshotWindow: Codable, Equatable, Sendable {
    /// **已使用**比例。UI 顯示剩餘時取 100 - usedPercent。
    public let usedPercent: Double
    public let resetsAt: Date
    public let confidence: Confidence

    public init(usedPercent: Double, resetsAt: Date, confidence: Confidence) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.confidence = confidence
    }
}

/// Host app 與 widget 之間的共享資料契約。Host app 是唯一寫入者。
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let updatedAt: Date
    /// 官方讀數實際**取得**的時間（`OfficialUsage.fetchedAt`），跟 `updatedAt`（snapshot
    /// **寫入**的時間）不是同一件事：host app 每 15 秒都會 `publish()` 一次，不論這一輪
    /// API 有沒有打通，所以降級模式下 `updatedAt` 幾乎永遠只有幾秒舊，會誤導使用者以為
    /// 讀數很新鮮。這個欄位才是「這份官方讀數是多久以前拿到的」該問的問題。
    ///
    /// 新增、可選欄位，不影響 `schemaVersion`：舊版 widget 解碼新版 snapshot 時會忽略它；
    /// 新版 widget 解碼舊版 snapshot（沒有這個 key）時，`JSONDecoder` 會把它填成 `nil`——
    /// 呼叫端必須明確處理 `nil`（顯示「沒有這個資訊」），不能悄悄退回用 `updatedAt` 頂替，
    /// 那正是這個欄位想解決的問題本身。
    public let officialFetchedAt: Date?
    public let session: SnapshotWindow?
    public let weekly: SnapshotWindow?
    public let state: SnapshotState

    public init(
        schemaVersion: Int = UsageSnapshot.currentSchemaVersion,
        updatedAt: Date,
        officialFetchedAt: Date? = nil,
        session: SnapshotWindow?,
        weekly: SnapshotWindow?,
        state: SnapshotState
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.officialFetchedAt = officialFetchedAt
        self.session = session
        self.weekly = weekly
        self.state = state
    }
}

/// Host app 與 widget 之間共享 `snapshot.json` 的位置解析。
///
/// **這裡的不對稱是刻意的，也是整個資料通道能運作的關鍵：**
/// widget 與 host app 用完全不同的方式算出同一個目錄。App Group 在 ad-hoc 簽章、
/// 無付費 Apple Developer team 的情況下被證實不可行（sandboxed widget 對 App Group
/// container 的讀、列、寫全部被拒絕，見 design doc §3.1）。改用的通道是 widget
/// **自己的** sandbox container——非 sandbox 的 host app 可以用一般使用者權限直接
/// 寫進這個目錄，不需要任何 entitlement 或 provisioning profile。
public enum SnapshotLocation {
    /// Widget extension 的 bundle identifier。容器路徑由它決定，兩者必須保持同步。
    public static let widgetBundleID = "io.echoulen.ClaudeUsage.Widget"

    /// 由 **widget 自己** 呼叫：sandbox 內 `applicationSupportDirectory` 已經指向
    /// widget 自有的容器，系統自動重導向，不需要拼路徑。
    ///
    /// - Parameter applicationSupportURL: 供測試注入假路徑；production 呼叫端一律省略，
    ///   使用系統真正的 `applicationSupportDirectory`。
    public static func fromInsideWidget(
        applicationSupportURL: URL? = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
    ) -> URL? {
        applicationSupportURL?.appendingPathComponent("snapshot.json")
    }

    /// 由 **host app** 呼叫：host app 不在 sandbox 內，必須明確組出 widget 容器的路徑，
    /// 也就是 `~/Library/Containers/<widgetBundleID>/Data/Library/Application Support/snapshot.json`。
    ///
    /// 容器根目錄（`~/Library/Containers/<widgetBundleID>/`）只在 widget **至少執行過一次**
    /// 後才會由系統建立。若這個根目錄還不存在，代表 widget 從未執行過（例如剛裝好、
    /// 使用者尚未把 widget 加到桌面），此時回傳 nil，呼叫端應該在下一個週期重試，
    /// **絕不能自己 mkdir 出這個根目錄**——手動生出來的容器根目錄不會被系統的
    /// container manager 承認，可能造成後續狀態混亂。只有在根目錄已存在的前提下，
    /// 才建立更深一層的中介目錄（`Data/Library/Application Support`）。
    ///
    /// - Parameter containersRootURL: 供測試注入假的 `~/Library/Containers` 路徑；
    ///   production 呼叫端一律省略，使用目前使用者真正的家目錄。
    public static func fromHostApp(
        containersRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")
    ) -> URL? {
        let containerRoot = containersRootURL.appendingPathComponent(widgetBundleID)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: containerRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }

        let appSupportDir = containerRoot
            .appendingPathComponent("Data/Library/Application Support")
        guard (try? FileManager.default.createDirectory(
            at: appSupportDir, withIntermediateDirectories: true
        )) != nil else {
            return nil
        }

        return appSupportDir.appendingPathComponent("snapshot.json")
    }
}

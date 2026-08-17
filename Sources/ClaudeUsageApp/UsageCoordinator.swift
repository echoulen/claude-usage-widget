import Foundation
import Observation
import UsageCore

/// snapshot.json 的寫入結果，用來在選單列上區分兩種完全不同的失敗形態：
/// widget 容器還不存在（正常的「尚未安裝」狀態）vs. 系統拒絕寫入（多半是 TCC 權限問題）。
/// 兩者都不可以讓使用者誤以為「app 正常運作、只是沒有資料」。
enum SnapshotDeliveryStatus: Equatable, Sendable {
    case ok
    /// `SnapshotLocation.fromHostApp()` 回傳 nil —— widget 從未執行過，容器根目錄不存在。
    /// 這是預期中的正常狀態（例如剛安裝好），不是錯誤，下一輪會自動重試。
    case widgetContainerMissing
    /// 寫入呼叫本身丟出錯誤 —— 最常見的原因是 macOS TCC「App Data」保護擋下對其他
    /// App 容器的寫入。這一定要讓使用者看到，不能悄悄吞掉。
    case writeDenied(String)
}

@MainActor
@Observable
final class UsageCoordinator {

    private(set) var snapshot: UsageSnapshot?
    private(set) var lastError: String?
    private(set) var lastAPIFailureReason: APIFailureReason?
    private(set) var snapshotDeliveryStatus: SnapshotDeliveryStatus = .widgetContainerMissing

    private let transcriptRoot: URL
    private let api: UsageAPI
    private let store = UsageStore()
    private let bridge = WidgetBridge()
    private let cursorURL: URL

    private var cursor: ScanCursor
    private var records: [UsageRecord] = []
    private var latestSample: APISample?
    private var previousSample: APISample?
    private var apiFailureSince: Date?
    /// 上一次「實際成功寫入磁碟」的 snapshot；`nil` 代表啟動後還沒有任何一次成功寫入的
    /// 記憶（含真的第一次、或先前的嘗試全部失敗／被跳過）。只在 `writeSnapshot` 真正
    /// 寫入成功時更新——寫入失敗或容器還不存在都不能碰它，否則下一輪會誤判成「內容
    /// 沒變」而永遠跳過重試。`SnapshotWritePolicy.shouldWrite` 拿它跟這一輪算出來的
    /// snapshot 比較（排除 `updatedAt`），決定要不要真的動筆——見該型別的文件註解。
    private var lastWrittenSnapshot: UsageSnapshot?
    /// 上次檢查 transcript root 時是否存在且可讀。初始樂觀為 true，第一次掃描就會校正。
    /// `private(set)`：選單需要讀它來提示使用者「數字仍在，但本機外插已關閉」（defect 4），
    /// 寫入仍只能在本檔案內（`scanLocal()`）發生。
    private(set) var transcriptRootAccessible = true

    private var scanTask: Task<Void, Never>?
    private var apiTask: Task<Void, Never>?
    /// 上一次「立即重新整理」實際被接受執行的時間，供 `refreshNow()` debounce 用。
    private var lastManualRefresh: Date?

    private static let scanInterval: Duration = .seconds(15)
    /// 平常的 API 輪詢週期（flat interval）。`start()` 的 apiTask 迴圈不再盲目睡滿這個
    /// 數字——見 `nextAPIPollDelay()`：手上任一視窗即將重置時會提早在重置後補一次。
    private static let apiInterval: TimeInterval = 600
    /// 視窗重置時刻之後再多留幾秒才打 API，讓伺服器端有機會真的把視窗翻過去——
    /// 太早打大機率還是拿到重置前的舊讀數。
    private static let apiPollResetBuffer: TimeInterval = 5
    /// 掃描保留的回看區間；略寬於 7 天週視窗，留一點緩衝。
    private static let recordWindow: TimeInterval = 8 * 86400
    /// `refreshNow()` 的 debounce 下限。重用 `UsageStore.minSampleInterval`，不另外發明
    /// 第二個「兩次取樣至少要隔多久」的數字：連點兩次選單「立即重新整理」若沒有這道防線，
    /// 會直接把 `UsageStore` 賴以判斷外插可信度的取樣間隔（`sampleInterval`）壓到趨近於零，
    /// 反而是 Blocking 2 那個「分子分母不同母體」錯誤的加速器。
    private static let manualRefreshDebounce = UsageStore.minSampleInterval

    init(
        transcriptRoot: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects"),
        api: UsageAPI = UsageAPIClient(
            credentialStore: KeychainCredentialStore(),
            transport: URLSessionTransport()
        )
    ) {
        self.transcriptRoot = transcriptRoot
        self.api = api
        self.cursorURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage/scan-cursor.json")
        self.cursor = Self.loadCursor(from: cursorURL)
    }

    /// 重入安全：多次呼叫（例如 SwiftUI 重新評估 body）只會啟動一次輪詢。
    ///
    /// scan 迴圈與 API 迴圈刻意不各自獨立啟動：`refreshFromAPI()` 用
    /// `currentLocalTokens()` 對 `records` 取樣，若 API 迴圈搶先在第一次 scan 完成前
    /// 跑完，取到的會是 0（冷啟動）或殘缺的本機 token 數，讓內插從一開始就失真，
    /// 要等到第三次 API 取樣（近 20 分鐘後）才會恢復正常。這裡改成兩個迴圈都先
    /// `await` 同一個 `initialScan` task，確保第一次 API 取樣發生時，本機記錄至少
    /// 已完整跑過一輪。`initialScan` 本身呼叫的 `scanLocal()` 內部仍是丟給
    /// `Task.detached` 做實際 I/O，這裡的 `await` 不會卡住 MainActor，只是讓
    /// `start()` 回傳後的兩個背景 Task 照順序接力。
    func start() {
        guard scanTask == nil else { return }

        let initialScan = Task { [weak self] in
            await self?.scanLocal()
        }

        scanTask = Task { [weak self] in
            _ = await initialScan.value
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.scanInterval)
                // `Task.sleep` 被取消時會立刻回傳（`try?` 吞掉 `CancellationError`），
                // 若不在這裡再檢查一次就直接往下做 scanLocal()，`stop()` 之後仍會跑完
                // 一整輪掃描＋persistCursor＋publish（含寫 widget 容器），拖慢
                // `applicationWillTerminate`。sleep 醒來後、真正動手前必須再確認一次。
                guard !Task.isCancelled else { break }
                await self?.scanLocal()
            }
        }
        apiTask = Task { [weak self] in
            _ = await initialScan.value
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshFromAPI()
                // 重置感知輪詢（defect 1）：不再盲目睡滿 `apiInterval`——若手上任一視窗
                // 即將重置，提早在重置之後補一次，避免 session ring 空等到下一個 flat
                // interval（最長 10 分鐘）才發現視窗已經空了。純函式本身在 UsageCore，
                // 這裡只負責把「目前手上的視窗」餵進去。
                let delay = self.nextAPIPollDelay()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// 見 `UsageStore.nextAPIPollDelay` 的文件註解——這裡只是把目前手上的視窗
    /// （最新一次 API 樣本的 session／weekly `resetsAt`）餵給那個純函式。
    /// 還沒有任何樣本時 `resetsAt` 是空陣列，函式會照原樣退回 flat interval。
    private func nextAPIPollDelay() -> TimeInterval {
        let resetsAt = [latestSample?.usage.session?.resetsAt, latestSample?.usage.weekly?.resetsAt]
            .compactMap { $0 }
        return UsageStore.nextAPIPollDelay(
            now: Date(),
            resetsAt: resetsAt,
            interval: Self.apiInterval,
            buffer: Self.apiPollResetBuffer
        )
    }

    func stop() {
        scanTask?.cancel()
        apiTask?.cancel()
        scanTask = nil
        apiTask = nil
    }

    /// 使用者從選單列手動觸發。debounce 過於接近前一次的呼叫並直接忽略（不排隊、不延後
    /// 執行）——理由見 `manualRefreshDebounce` 的文件註解：連點兩次會把 `UsageStore`
    /// 外插用的取樣間隔壓到趨近於零，是 Blocking 2 那個母體不一致錯誤的加速器。
    func refreshNow() {
        let now = Date()
        if let lastManualRefresh, now.timeIntervalSince(lastManualRefresh) < Self.manualRefreshDebounce {
            return
        }
        lastManualRefresh = now
        Task { await refreshFromAPI() }
    }

    private func scanLocal() async {
        guard isTranscriptRootAccessible() else {
            transcriptRootAccessible = false
            await publish()
            return
        }
        transcriptRootAccessible = true

        // 只保留週視窗範圍內的記錄，避免無限成長。
        let cutoff = Date().addingTimeInterval(-Self.recordWindow)
        let root = transcriptRoot
        let cursorSnapshot = cursor

        do {
            // 實際的檔案 I/O（可達千餘個 jsonl、數秒鐘）丟到背景執行緒，避免卡住
            // MainActor（選單列）。Task.detached 完全脫離目前的 actor context；
            // 跨越邊界的只有 Sendable 的值型別（URL、ScanCursor、Date、[UsageRecord]），
            // scanner 本身在背景 closure 內用 root URL 現造，不需要證明
            // TranscriptScanner 這個型別本身可 Sendable。
            let result = try await Task.detached(priority: .utility) {
                try Self.performScan(transcriptRoot: root, cursor: cursorSnapshot, notBefore: cutoff)
            }.value

            cursor = result.cursor
            records.append(contentsOf: result.records)
            records.removeAll { $0.timestamp < cutoff }
            persistCursor()
            await publish()
        } catch {
            lastError = "掃描本機記錄失敗：\(error.localizedDescription)"
            await publish()
        }
    }

    /// 在背景執行緒上執行的實際掃描邏輯。刻意宣告為 `nonisolated static`，
    /// 不接觸任何 MainActor 狀態，也不假設呼叫者的 isolation。
    private nonisolated static func performScan(
        transcriptRoot: URL,
        cursor: ScanCursor,
        notBefore: Date
    ) throws -> (records: [UsageRecord], cursor: ScanCursor) {
        let scanner = TranscriptScanner(rootDirectory: transcriptRoot)
        return try scanner.scan(cursor: cursor, notBefore: notBefore)
    }

    /// spec §8：`~/.claude/projects` 不存在或無權限時 state 應為 `noData`。
    /// `TranscriptScanner.scan()` 對「根目錄不存在」是回傳空結果而不拋錯（見 Task 4），
    /// 所以這個訊號必須在呼叫 scan 之前自己先查一次。
    private func isTranscriptRootAccessible() -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: transcriptRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        return FileManager.default.isReadableFile(atPath: transcriptRoot.path)
    }

    private func refreshFromAPI() async {
        do {
            // `UsageAPIClient.fetch()` 內部先呼叫 `SecItemCopyMatching`（Keychain，同步、
            // 可能因授權對話框耗時數秒）才發網路請求；兩者都不能直接留在 MainActor 上跑，
            // 否則跟掃描一樣會卡住選單列。跟 scanLocal 用同一招：丟到 detached task，
            // 只有 Sendable 的 `api`（`UsageAPI: Sendable`）跨界，結果 hop 回來才寫入狀態。
            let capturedAPI = api
            let usage = try await Task.detached(priority: .utility) {
                try await capturedAPI.fetch()
            }.value
            previousSample = latestSample
            latestSample = APISample(usage: usage, localTokensAtFetch: currentLocalTokens())
            apiFailureSince = nil
            lastError = nil
            lastAPIFailureReason = nil
        } catch {
            if apiFailureSince == nil { apiFailureSince = Date() }
            // `UsageAPIError` 具體區分「沒登入」（`.unauthorized`）與「連不上／回傳格式異常」
            // （`.transport`／`.unexpectedSchema`）；只有前者才是真正的登入問題。不 pattern-match
            // 直接丟掉這個資訊的話，`UsageStore` 在 `latestSample == nil` 時一律回傳 `.signedOut`，
            // 選單就會把單純的斷網誤判成「尚未登入」。這裡把分類結果存進
            // `lastAPIFailureReason`，交給選單列決定要不要覆寫那句話。
            if let apiError = error as? UsageAPIError {
                lastError = apiError.errorDescription
                lastAPIFailureReason = (apiError == .unauthorized) ? .credential : .service
            } else {
                lastError = "取得官方額度失敗：\(error.localizedDescription)"
                lastAPIFailureReason = .service
            }
        }
        await publish()
    }

    /// API 失敗的分類：只用來讓選單列在 `.signedOut` 狀態下挑對訊息，
    /// 不取代 `lastError`（那仍是給人看的完整訊息）。
    enum APIFailureReason: Equatable, Sendable {
        /// 憑證問題——沒登入，或 Keychain 授權被拒。
        case credential
        /// 非憑證問題——連不上服務或回傳格式異常，不可誤判為登入問題。
        case service
    }

    private func currentLocalTokens() -> Int {
        TokenAggregator.aggregate(
            records,
            from: Date().addingTimeInterval(-Self.recordWindow),
            to: Date().addingTimeInterval(60)
        ).totalTokens
    }

    private func publish() async {
        let new: UsageSnapshot
        if transcriptRootAccessible {
            new = store.makeSnapshot(
                latest: latestSample,
                previous: previousSample,
                localTokensNow: currentLocalTokens(),
                lastAPIFailureSince: apiFailureSince,
                now: Date()
            )
        } else if let latestSample {
            // transcript root 不可讀，但已經有官方 API 資料——本機 token 不可信、不能拿
            // 來外插，但官方讀數本身完全有效，不該被一起丟棄（defect 4：「看得到卻不
            // 顯示」跟「看不到」一樣是失敗，見 governing principle 的推論）。傳入
            // `previous: nil` 讓 `makeWindow` 直接跳過外插分支，只回傳 `.exact`（或 API
            // 本身已降級時的 `.estimated`），不偽稱有本機推估依據。使用者端的「本機外插
            // 已關閉」提示由選單另外用 `transcriptRootAccessible` 呈現，不靠這裡的狀態。
            new = store.makeSnapshot(
                latest: latestSample,
                previous: nil,
                localTokensNow: latestSample.localTokensAtFetch,
                lastAPIFailureSince: apiFailureSince,
                now: Date()
            )
        } else {
            // 本機沒有 transcript 可讀，也還沒有任何官方 API 樣本——這才是真的沒東西
            // 可顯示，`.noData` 才是誠實的狀態。
            new = UsageSnapshot(updatedAt: Date(), session: nil, weekly: nil, state: .noData)
        }
        snapshot = new

        let previousDeliveryStatus = snapshotDeliveryStatus
        await writeSnapshot(new)
        // defect 3：遞送狀態剛從失敗（widget 容器還不存在／寫入被拒）轉為成功時，
        // 強制推播一次、不受「數值沒變」節流——這正是「剛把 widget 拖上桌面」那一刻：
        // 容器第一次寫得進去，但這一輪數字很可能跟上一輪（寫入失敗前記住的那份）一樣，
        // 若不繞過數值比較就會被判定「沒變動」而不推播，widget 因此空等自己最長 15
        // 分鐘的 timeline 排程才會顯示第一份資料。理由詳見 `WidgetBridge.pushIfNeeded`。
        let justRecovered = Self.isFailingDelivery(previousDeliveryStatus) && snapshotDeliveryStatus == .ok
        bridge.pushIfNeeded(new, forceReload: justRecovered)
    }

    private static func isFailingDelivery(_ status: SnapshotDeliveryStatus) -> Bool {
        switch status {
        case .ok: return false
        case .widgetContainerMissing, .writeDenied: return true
        }
    }

    /// 寫入目的地是 widget 自己的 sandbox container（`SnapshotLocation.fromHostApp()`），
    /// 不是 App Group（design doc §3.1）。容器根目錄要等 widget 至少執行過一次才存在，
    /// 尚不存在時回傳 nil 屬預期狀態，跳過這輪寫入、留給下一輪重試，不當成錯誤處理——
    /// 但仍要透過 `snapshotDeliveryStatus` 讓使用者在選單列上看到「為什麼還沒同步」，
    /// 跟「容器存在但寫入被拒」清楚分開，不能兩者都顯示成同一種沉默的無資料狀態。
    private func writeSnapshot(_ snapshot: UsageSnapshot) async {
        // 內容跟上次成功寫入的那份等價（`updatedAt` 以外全部欄位都相同，見
        // `SnapshotWritePolicy` 的文件註解）——不必再多寫一次跨 sandbox 邊界的檔案。
        // `snapshotDeliveryStatus` 刻意維持原樣：它反映的是「上一次真正嘗試寫入」的
        // 結果，這一輪根本沒有嘗試，沒有新資訊可以覆寫過去的結果——既不能被誤讀成
        // 「這一輪也成功了」，也不能被誤判成失敗、變舊。
        guard SnapshotWritePolicy.shouldWrite(snapshot, lastWritten: lastWrittenSnapshot) else {
            return
        }

        // 實測發現：跨 sandbox 邊界第一次寫入另一個 App 的 container 時，
        // macOS 的 TCC「App 資料」保護會做一次同步查核，耗時可達 3 秒
        // （見 task-10-report.md 的量測）——這跟掃描一樣會直接凍結選單列，
        // 因此整段也丟到 detached task，只有 Sendable 的 UsageSnapshot 進去、
        // SnapshotDeliveryStatus 出來，結果 hop 回 MainActor 才寫入可觀察狀態。
        let status = await Task.detached(priority: .utility) { () -> SnapshotDeliveryStatus in
            guard let url = SnapshotLocation.fromHostApp() else {
                return .widgetContainerMissing
            }
            do {
                try SnapshotFile(url: url).write(snapshot)
                return .ok
            } catch {
                // 最可能的原因：系統設定 → 隱私權與安全性 底下的「App 資料」保護
                // 擋下了對 widget 容器的寫入（TCC）。這裡只留下訊息本身，
                // 不含任何憑證或 token 內容。
                return .writeDenied(error.localizedDescription)
            }
        }.value
        snapshotDeliveryStatus = status
        if status == .ok {
            // 只有真正寫進磁碟成功，才能更新「上次寫了什麼」的記憶——寫入失敗或容器
            // 還不存在都不能記成「已寫入」，否則下一輪會誤判成「內容沒變」而永遠跳過
            // 重試（見 `lastWrittenSnapshot` 的文件註解）。
            lastWrittenSnapshot = snapshot
        }
    }

    private static func loadCursor(from url: URL) -> ScanCursor {
        guard let data = try? Data(contentsOf: url) else { return ScanCursor() }
        return (try? JSONDecoder().decode(ScanCursor.self, from: data)) ?? ScanCursor()
    }

    /// 跨啟動持久化 cursor，避免每次重啟都要重新啃過上千個 jsonl（spec §7.4）。
    /// 存在 host app 自己的 Application Support 目錄，跟 widget 容器無關——host app
    /// 從第一次啟動就一定能寫，不需要等 widget 先跑過一次。
    private func persistCursor() {
        do {
            try FileManager.default.createDirectory(
                at: cursorURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cursor)
            try data.write(to: cursorURL, options: .atomic)
        } catch {
            lastError = "寫入掃描游標失敗：\(error.localizedDescription)"
        }
    }
}

import SwiftUI

/// AppDelegate 擁有唯一一份 `UsageCoordinator`，並在 `applicationDidFinishLaunching`
/// 呼叫 `start()`。刻意不用「computed property + `.onChange`」那種側效果藏在讀取裡的寫法——
/// SwiftUI 不保證一個 Scene body 會被求值幾次，用那種寫法輪詢可能被啟動不只一次。
/// `UsageCoordinator.start()` 本身也對重入安全（`guard scanTask == nil else { return }`），
/// 這裡的 delegate 只是確保「啟動」這件事只被觸發一次、且時機明確（launch 完成後）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = UsageCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: appDelegate.coordinator)
        } label: {
            MenuBarLabel(coordinator: appDelegate.coordinator)
        }
        .menuBarExtraStyle(.menu)
    }
}

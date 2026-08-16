# claude-usage-widget

`ClaudeUsage`——一個 macOS 選單列 app，加上桌面 WidgetKit widget，顯示 Claude 訂閱額度：

- **5 小時 session 視窗**已使用的百分比，附重置倒數
- **7 天週視窗**已使用的百分比，附重置日期

數字以官方 usage API 為準（`GET https://api.anthropic.com/api/oauth/usage`）。兩次成功的 API
取樣之間，會用本機 `~/.claude/projects` 下的 transcript token 成長量做線性外插，讓數字在兩次
輪詢之間也能跟著變化，畫面上標示 `推估中`。若 API 持續連不上超過寬限期，app **不會**用本機
資料重新估算一個新數字——而是原封不動地凍結最後一次成功取得的官方讀數，標示 `已凍結`，並附上
這個讀數是多久以前取得的。另外，畫面上這份快照本身若放太久沒被更新過（例如 host app 沒有隨
系統登入啟動、重開機後一直沒再跑），widget 也會把當下顯示的數字——不論它原本是官方讀數還是
兩次讀數之間的本機外插值——一併改標成 `已凍結`：這種情況下「已凍結」代表「現在不能再當即時
看」，未必代表這個數字本身完全沒經過本機推算。不論哪一種來源，都不會安靜地顯示一個可能是錯的
數字。

顯示的是**已使用**比例，環形量表隨額度消耗而填滿。嚴重度顏色（<60% 綠、60–84% 橘、≥85% 紅）只在
系統的 `.fullColor` 渲染模式下出現——見下方「顏色」一節。

選單列提供秒級即時數字；桌面 widget 是分鐘級（WidgetKit 的刷新預算天花板，非本專案能控制）。
兩者顯示同一組數字，不會互相矛盾。

## 需求

- macOS 14 (Sonoma) 以上
- **完整版 Xcode**（不能只有 Command Line Tools——`xcodebuild` 需要完整 SDK 才能建置 widget
  extension）
- git

這個 app 沒有 Apple Developer team、無法 notarize，所以一律從原始碼在你自己的機器上建置，
不提供預先建置好的二進位檔。

## 安裝

```sh
curl -fsSL https://raw.githubusercontent.com/echoulen/claude-usage-widget/main/install.sh | bash
```

也可以在既有的 clone 內執行：

```sh
./install.sh
```

安裝腳本做的事：檢查環境 → 用 `xcodegen generate` 產生 Xcode 專案 → `xcodebuild` Release 建置 →
安裝到 `/Applications`（可用 `--prefix` 改路徑）→ 啟動 app。裝好之後，把「Claude 用量」widget 從
桌面 widget 選單（或通知中心）加到桌面，就會開始顯示數字。

常用選項（完整列表見 `./install.sh --help`）：

| 選項 | 作用 |
|---|---|
| `-h`, `--help` | 顯示完整說明 |
| `--login-item` | 安裝 LaunchAgent，讓 app 隨系統登入自動啟動（預設不裝，opt-in） |
| `--clean-derived-data` | 清除 Xcode DerivedData 底下這個專案的殘留目錄；如果你曾經直接用 Xcode Run 過這個專案，widget 選單可能會出現兩筆重複項目，用這個選項清掉舊的殘留即可修正 |
| `--no-signing-identity` | 不建立/使用本機自簽憑證，改用 ad-hoc 簽章（代價見下方「三個提示」） |
| `--uninstall` | 移除 app 與 LaunchAgent（若有），並印出 widget 容器路徑（不會自動刪除，由你自行決定） |

## 首次使用會看到的三個系統提示

裝好第一次啟動、以及第一次把 widget 加到桌面時，會依序看到三個 macOS 系統對話框。都是正常且
必要的，不是惡意軟體的跡象：

1. **建立本機簽章憑證**：`install.sh` 預設會在你的 login keychain 裡建立一張名為
   「ClaudeUsage Local Signing」的自簽憑證，只用來簽這個 app，不授予任何權限、也不會被信任
   用於其他用途。
2. **Keychain 授權**：app 讀取 Claude Code 存在 Keychain 裡的登入憑證（service
   `Claude Code-credentials`）時，系統會跳出授權對話框，選「總是允許」即可。
3. **「App 資料」存取提示（TCC）**：host app 第一次把 `snapshot.json` 寫進 widget 自己的 sandbox
   容器時，macOS 會跳出「想要存取其他 App 的資料」之類的提示，這是 TCC 保護容器目錄的正常行為，
   同意即可。

**為什麼要用穩定的本機簽章身分，而不是 ad-hoc 簽章：** macOS 把上面這些授權都綁在 app 的簽章身分
上。ad-hoc 簽章的身分是從二進位檔內容算出來的雜湊，每次重新建置都不一樣，身分一變，先前的授權
就全部失效，等於每次更新都要重新走一次上面三個提示。用同一張本機憑證簽章可以讓身分維持穩定，
這是這些提示不會在每次更新後重複出現的原因。加上 `--no-signing-identity` 可以跳過建立、改用
ad-hoc 簽章，但代價就是每次重新建置都會重新觸發這三個提示。

## 顏色：桌面 widget 預設會被系統調成單色

macOS 預設會把桌面上的 widget 去飽和成灰階，這是**系統設定，不是這個 app 的設定**，本專案的嚴重度
色階（綠／橘／紅）在這個模式下不會出現，只有拖曳 widget 移動時才會短暫看到全彩。

修法（已在作者本機驗證有效）：

```
系統設定 → 桌面與 Dock → 「讓桌面上的小工具變暗」→ 選「永不」
```

改完之後桌面 widget 才會一直顯示彩色的嚴重度提示，不用靠拖曳才看得到。

## 已知限制

- **Keychain 授權對話框大約每 8 小時會再跳一次。** 這是 Claude Code 自己刷新 OAuth token 時連帶
  影響 Keychain 項目 ACL 造成的（強烈推測，非直接證實），不是這個 app 重新觸發授權，也不在本專案
  控制範圍內。
- **Widget 尺寸是 WidgetKit 規定的固定幾種**（`systemSmall` / `systemMedium` / `systemLarge` /
  `systemExtraLarge` / `systemExtraLargePortrait`），做不出貼齊 Dock 高度的窄長條顯示；那需要
  host app 另開一個浮動視窗，目前刻意沒有做。
- **host app 寫進 widget 容器的這條管道不是 Apple 認可的 IPC 機制。** 若未來 macOS 收緊
  `~/Library/Containers` 的存取，替代方案是付費 Apple Developer team 加上 App Group。
- **widget 至少要執行過一次，它的容器才會存在**，所以全新安裝在把 widget 加到桌面之前，host app
  沒有地方可寫；加上去之後下一個寫入週期就會補上。

## 為什麼不用 App Group

一般 app 與它的 widget extension 之間是靠 **App Group** 共享容器傳資料。這個專案不行，而且是實測
出來的：widget extension 被系統強制 sandbox，在 ad-hoc 簽章（無付費 Apple Developer team）下，它
對 App Group container 的讀、列出目錄、寫入全部被系統拒絕（`NSCocoaErrorDomain` 257 / 513）。改用
付費 team 也救不回來——`xcodebuild` 在命令列環境下從未真正配出 App Group 的 provisioning profile，
而沒有 profile 的 extension 會卡在 `_libsecinit_appsandbox` 被 watchdog 強制終止。

實際可行的管道是 **widget 自己的 sandbox container**：host app 刻意不進 sandbox，因此能用一般使用者
權限直接寫進 `~/Library/Containers/<widget bundle id>/Data/Library/Application Support/`，而 widget
讀自己的容器不需要任何 entitlement。同一次診斷執行中，對自有容器的讀取成功、對 App Group 的讀取
失敗，兩個結果並列，這就是選擇它的依據。

## 移除

```sh
./install.sh --uninstall
```

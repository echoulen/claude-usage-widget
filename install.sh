#!/usr/bin/env bash
#
# install.sh — 從原始碼建置並安裝 ClaudeUsage（menu-bar app + 桌面 widget）
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/echoulen/claude-usage-widget/main/install.sh | bash
#   ./install.sh   （在既有的 clone 內執行）
#
# 為什麼要從原始碼建置？此 app 是 ad-hoc 簽章、沒有 Apple Developer team，
# 無法送 notarize。直接發預先建置好的二進位檔會被 Gatekeeper 擋下，
# 而要求使用者關掉 Gatekeeper 對公開的安裝腳本來說是不能接受的作法。
# 在使用者自己的機器上從原始碼建置可以完全避開這個問題。
set -euo pipefail

APP_NAME="ClaudeUsage"
APP_DISPLAY_NAME="Claude Usage"
BUNDLE_ID="io.echoulen.ClaudeUsage"
WIDGET_BUNDLE_ID="io.echoulen.ClaudeUsage.Widget"
SCHEME="ClaudeUsage"
REPO_URL="https://github.com/echoulen/claude-usage-widget.git"
REPO_RAW_INSTALL_URL="https://raw.githubusercontent.com/echoulen/claude-usage-widget/main/install.sh"
LAUNCH_AGENT_LABEL="${BUNDLE_ID}"
LAUNCH_AGENT_PLIST="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
# 資料不走 App Group（在 ad-hoc 簽章下已證實不可行，見 docs/superpowers/specs/2026-08-14-claude-usage-widget-design.md §3.1）。
# host app 是把 snapshot.json 直接寫進 widget 自己的 sandbox container。
WIDGET_CONTAINER="${HOME}/Library/Containers/${WIDGET_BUNDLE_ID}"
DERIVED_DATA_ROOT="${HOME}/Library/Developer/Xcode/DerivedData"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 此 app 一律用 CODE_SIGN_IDENTITY 簽章。ad-hoc 簽章（"-"）的身分是從二進位檔
# 內容算出來的雜湊，每次重新建置都不一樣；macOS 把 Keychain 的「永遠允許」與
# TCC 權限授權都綁在這個身分上，身分一變，先前的授權就全部失效，導致每次重新
# 建置都要重新授權一次。改用同一張本機自簽憑證簽章，可以讓簽章身分在重新建置
# 之間維持穩定。
SIGNING_CERT_NAME="ClaudeUsage Local Signing"
SIGNING_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

PREFIX="/Applications"
DO_LAUNCH=1
DO_LOGIN_ITEM=1
DO_CLEAN_DERIVED_DATA=0
DO_UNINSTALL=0
DO_SIGNING_IDENTITY=1

TMP_DIR=""

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

info() { printf '[install] %s\n' "$*"; }
warn() { printf '[install] 警告：%s\n' "$*" >&2; }
err()  { printf '[install] 錯誤：%s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

print_help() {
  cat <<EOF
install.sh — 從原始碼建置並安裝 ${APP_DISPLAY_NAME}

用法：
  ./install.sh [選項]
  curl -fsSL ${REPO_RAW_INSTALL_URL} | bash

選項：
  --prefix DIR           安裝目的地（預設：/Applications）
  --no-launch            安裝完成後不要自動啟動 app
  --login-item           安裝 LaunchAgent，讓 app 隨系統登入自動啟動（預設行為）
  --no-login-item        不安裝 LaunchAgent。注意：app 不會隨系統啟動，重開機或
                         登出後就停止運作，而桌面小工具仍會顯示最後一次的數字
                         （標示為已凍結），看起來像還在運作
  --clean-derived-data    清除這個專案在 Xcode DerivedData 底下的殘留目錄
  --no-signing-identity   不要建立/使用本機自簽憑證，改用 ad-hoc 簽章
                          （每次重新建置都要重新授權 Keychain／個人資料夾等
                          權限；見下方「本機簽章憑證」說明）
  --uninstall             移除 app、LaunchAgent（若有），並印出
                          widget 容器路徑（不會刪除，由你自行決定）
  -h, --help              顯示這個說明

需求：
  - macOS 14 (Sonoma) 以上
  - 已安裝並選取完整版 Xcode（不能只有 Command Line Tools）
  - git
  - xcodegen（若未安裝且已有 Homebrew，會詢問是否協助安裝）

本機簽章憑證：
  預設情況下，這個腳本會在你的 login keychain 裡建立一張名為
  「${SIGNING_CERT_NAME}」的本機自簽憑證（如果還不存在的話），
  只用來讓這個 app 每次重新建置後的簽章身分維持穩定，這樣 macOS
  才不會每次更新後又重新詢問 Keychain／個人資料夾等權限。這張憑證
  本身不授予任何權限，也不會被信任用於其他用途。加上
  --no-signing-identity 可以跳過建立，改用 ad-hoc 簽章。

已知狀況（DerivedData 殘留造成 widget 出現兩筆）：
  如果你之前曾經直接用 Xcode 執行過這個 app（Run），macOS 會把
  widget extension 註冊在 Xcode DerivedData 底下那份殘留的 .app 上。
  之後再用這個腳本安裝到 /Applications，Widget 選單裡就會看到兩筆
  「Claude 用量」，其中一筆其實是死的。用 --clean-derived-data 清掉
  Xcode DerivedData 裡這個專案的目錄即可解決。
EOF
}

# ---------------------------------------------------------------------------
# 參數解析
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      [[ $# -ge 2 ]] || die "--prefix 需要一個目錄參數"
      PREFIX="$2"
      shift 2
      ;;
    --prefix=*)
      PREFIX="${1#--prefix=}"
      shift
      ;;
    --no-launch)
      DO_LAUNCH=0
      shift
      ;;
    --login-item)
      DO_LOGIN_ITEM=1
      shift
      ;;
    --no-login-item)
      DO_LOGIN_ITEM=0
      shift
      ;;
    --clean-derived-data)
      DO_CLEAN_DERIVED_DATA=1
      shift
      ;;
    --no-signing-identity)
      DO_SIGNING_IDENTITY=0
      shift
      ;;
    --uninstall)
      DO_UNINSTALL=1
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      err "未知的選項：$1"
      print_help
      exit 1
      ;;
  esac
done

# 去掉結尾斜線，避免出現雙斜線；若使用者直接傳 "/" 則保留單一斜線。
PREFIX="${PREFIX%/}"
[[ -n "${PREFIX}" ]] || PREFIX="/"
TARGET_APP="${PREFIX}/${APP_NAME}.app"

# ---------------------------------------------------------------------------
# 清除運行中的實例（複製新版本前一定要先做，否則覆蓋 running .app 會壞掉）
# ---------------------------------------------------------------------------

quit_running_app() {
  local was_running=0

  if command -v osascript >/dev/null 2>&1; then
    if osascript -e "application id \"${BUNDLE_ID}\" is running" 2>/dev/null | grep -qi '^true$'; then
      was_running=1
      info "偵測到 ${APP_DISPLAY_NAME} 正在執行，正在關閉…"
      osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
      local _i
      for _i in $(seq 1 20); do
        osascript -e "application id \"${BUNDLE_ID}\" is running" 2>/dev/null | grep -qi '^true$' || break
        sleep 0.25
      done
    fi
  fi

  # 保底：只比對「這個 app 自己的可執行檔絕對路徑」，絕不使用寬鬆的
  # pkill -f ClaudeUsage 之類的比對方式，避免誤殺無關的程序。
  local exe_path="${TARGET_APP}/Contents/MacOS/${APP_NAME}"
  local -a pids=()
  local pid
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] && pids+=("${pid}")
  done <<< "$(pgrep -f "^${exe_path}\$" 2>/dev/null || true)"
  if [[ "${#pids[@]}" -gt 0 ]]; then
    was_running=1
    kill "${pids[@]}" 2>/dev/null || true
    sleep 0.5
    pids=()
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] && pids+=("${pid}")
    done <<< "$(pgrep -f "^${exe_path}\$" 2>/dev/null || true)"
    if [[ "${#pids[@]}" -gt 0 ]]; then
      kill -9 "${pids[@]}" 2>/dev/null || true
    fi
  fi

  if [[ "${was_running}" -eq 1 ]]; then
    info "已關閉舊的執行實例。"
  fi
}

# ---------------------------------------------------------------------------
# Preflight 檢查
# ---------------------------------------------------------------------------

check_macos_version() {
  local ver major
  ver="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  major="${ver%%.*}"
  if ! [[ "${major}" =~ ^[0-9]+$ ]] || [[ "${major}" -lt 14 ]]; then
    die "需要 macOS 14 (Sonoma) 以上，目前偵測到版本為 ${ver}。請先更新 macOS 再重新執行。"
  fi
}

check_xcode() {
  command -v xcode-select >/dev/null 2>&1 || die "找不到 xcode-select，請先安裝 Xcode。"

  local dev_dir
  dev_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -z "${dev_dir}" ]]; then
    die "尚未設定 Xcode 開發者目錄。請從 App Store 安裝 Xcode，再執行：
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  fi
  if [[ "${dev_dir}" == *CommandLineTools* ]]; then
    die "目前 xcode-select 指向的是 Command Line Tools（${dev_dir}），
    但 xcodebuild 需要完整版 Xcode 的 SDK 才能建置。請從 App Store 安裝
    Xcode，然後執行：
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  fi

  if ! command -v xcodebuild >/dev/null 2>&1; then
    die "找不到 xcodebuild，請確認已安裝完整版 Xcode。"
  fi
  if ! xcodebuild -version >/dev/null 2>&1; then
    die "xcodebuild 無法執行。請先打開一次 Xcode.app 完成授權/元件安裝
    （或執行 sudo xcodebuild -license accept），再重新執行這個腳本。"
  fi
}

check_git() {
  command -v git >/dev/null 2>&1 || die "找不到 git，請先安裝（例如：xcode-select --install 或 brew install git）。"
}

install_xcodegen_via_brew() {
  info "正在透過 Homebrew 安裝 xcodegen…"
  if ! brew install xcodegen; then
    die "透過 Homebrew 安裝 xcodegen 失敗，請手動執行 brew install xcodegen 後再重試。"
  fi
}

check_xcodegen() {
  if command -v xcodegen >/dev/null 2>&1; then
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    if [[ -t 0 ]]; then
      local reply
      printf '[install] 找不到 xcodegen。要現在用 Homebrew 安裝嗎？[y/N] ' >&2
      read -r reply || reply=""
      case "${reply}" in
        y|Y|yes|YES)
          install_xcodegen_via_brew
          ;;
        *)
          die "已取消。請自行安裝 xcodegen 後再重新執行（brew install xcodegen）。"
          ;;
      esac
    else
      die "找不到 xcodegen，且目前是非互動模式（例如透過 curl | bash 執行），
    不會未經同意就自動安裝。請先執行：
    brew install xcodegen
    再重新執行這個腳本。"
    fi
  else
    die "找不到 xcodegen，也找不到 Homebrew。請先安裝 xcodegen，例如：
    1) 安裝 Homebrew：https://brew.sh
       然後執行：brew install xcodegen
    2) 或參考 https://github.com/yonaskolb/XcodeGen 的手動安裝說明
    安裝完成後再重新執行這個腳本。"
  fi
}

signing_identity_exists() {
  security find-certificate -c "${SIGNING_CERT_NAME}" "${SIGNING_KEYCHAIN}" >/dev/null 2>&1
}

create_signing_identity() {
  command -v openssl >/dev/null 2>&1 \
    || die "找不到 openssl，無法建立簽章憑證。可加上 --no-signing-identity 跳過
    （會退回 ad-hoc 簽章，代價是每次重新建置都要重新授權 Keychain／個人資料夾等權限）。"

  info "找不到本機簽章憑證「${SIGNING_CERT_NAME}」，正在建立…"
  info "這是一張只用於這個 app、放在你自己 login keychain 裡的本機自簽憑證，目的是"
  info "讓這個 app 每次重新建置後的簽章身分維持穩定，這樣 macOS 才不會每次更新後"
  info "又重新詢問 Keychain／個人資料夾等權限。這張憑證本身不授予任何權限。"

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-cert.XXXXXX")" || die "建立暫存目錄失敗。"

  local conf="${tmp}/cert.conf"
  cat > "${conf}" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = codesign

[dn]
CN = ${SIGNING_CERT_NAME}

[codesign]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

  openssl genrsa -out "${tmp}/key.pem" 2048 \
    >/dev/null 2>&1 || { rm -rf "${tmp}"; die "產生私鑰失敗（openssl genrsa）。"; }

  openssl req -new -x509 -key "${tmp}/key.pem" -out "${tmp}/cert.pem" -days 3650 -config "${conf}" \
    >/dev/null 2>&1 || { rm -rf "${tmp}"; die "建立自簽憑證失敗（openssl req）。"; }

  # 分別匯入私鑰與憑證這兩個 PEM 檔（而不是包成單一 PKCS12 容器），macOS 會
  # 自動用公鑰把兩者配對起來，完全不需要處理 PKCS12 的加密格式相容性問題
  # （OpenSSL 3.x 與 LibreSSL 對 PKCS12 的預設編碼不同，`security import` 只讀得懂
  # 其中一種），也不需要為了滿足 `security import` 而生一組本來沒有意義的密碼。
  #
  # 這裡用 `-A` 而不是 `-T /usr/bin/codesign`：`-T` 只是把特定程式加進「信任清單」，
  # 但自 macOS Sierra 起，實際存取私鑰還要看另一組 ACL 的 partition list，沒有它
  # `codesign` 每次建置還是會跳出授權提示，而設定 partition list
  # （`security set-key-partition-list`）需要輸入 login keychain 密碼，無法在
  # 無人值守的腳本裡自動完成。`-A` 則是直接允許任何程式存取這把 key，不會再有
  # per-use 提示，但代價是這不只開放給 codesign／security，是任何程式都能無提示
  # 使用這把私鑰。對一張「只用來簽這個 app」的本機憑證來說，這個取捨可以接受，
  # 但這裡誠實寫出來，不要包裝成單純比 `-T` 更好。
  security import "${tmp}/key.pem" -k "${SIGNING_KEYCHAIN}" -A \
    >/dev/null 2>&1 || { rm -rf "${tmp}"; die "匯入私鑰到 Keychain 失敗（security import）。"; }

  security import "${tmp}/cert.pem" -k "${SIGNING_KEYCHAIN}" -A \
    >/dev/null 2>&1 || { rm -rf "${tmp}"; die "匯入憑證到 Keychain 失敗（security import）。"; }

  rm -rf "${tmp}"
  info "已建立本機簽章憑證「${SIGNING_CERT_NAME}」。"
}

ensure_signing_identity() {
  if [[ "${DO_SIGNING_IDENTITY}" -eq 0 ]]; then
    info "已指定 --no-signing-identity，改用 ad-hoc 簽章（每次重新建置都會被要求重新授權 Keychain／個人資料夾等權限）。"
    return 0
  fi

  if signing_identity_exists; then
    info "已存在本機簽章憑證「${SIGNING_CERT_NAME}」，略過建立。"
    return 0
  fi

  create_signing_identity
}

preflight() {
  info "檢查環境需求…"
  check_macos_version
  check_xcode
  check_git
  check_xcodegen
  check_prefix_writable
  ensure_signing_identity
  info "環境檢查通過。"
}

# ---------------------------------------------------------------------------
# 來源解析：在既有 clone 內執行就地建置，否則 clone 到暫存目錄
# ---------------------------------------------------------------------------

is_source_root() {
  local dir="$1"
  [[ -f "${dir}/project.yml" && -f "${dir}/Package.swift" ]]
}

resolve_source() {
  local candidate=""

  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if is_source_root "${script_dir}"; then
      candidate="${script_dir}"
    fi
  fi

  if [[ -z "${candidate}" ]] && is_source_root "${PWD}"; then
    candidate="${PWD}"
  fi

  if [[ -n "${candidate}" ]]; then
    SRC_DIR="${candidate}"
    info "偵測到既有的 repo，將就地建置：${SRC_DIR}"
  else
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-widget.XXXXXX")"
    info "未偵測到既有 repo，clone 到暫存目錄：${TMP_DIR}"
    git clone --depth 1 "${REPO_URL}" "${TMP_DIR}" || die "clone repo 失敗：${REPO_URL}"
    SRC_DIR="${TMP_DIR}"
  fi
}

# ---------------------------------------------------------------------------
# 建置
# ---------------------------------------------------------------------------

build_app() {
  info "執行 xcodegen generate…"
  ( cd "${SRC_DIR}" && xcodegen generate ) || die "xcodegen generate 失敗。"

  local project="${SRC_DIR}/${APP_NAME}.xcodeproj"
  [[ -d "${project}" ]] || die "找不到產生出來的 ${APP_NAME}.xcodeproj。"

  local derived_data="${SRC_DIR}/build"
  local sign_identity="${SIGNING_CERT_NAME}"
  if [[ "${DO_SIGNING_IDENTITY}" -eq 0 ]]; then
    sign_identity="-"
  fi

  info "執行 xcodebuild（Release）…這可能需要一點時間。"
  xcodebuild \
    -project "${project}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${derived_data}" \
    CODE_SIGN_IDENTITY="${sign_identity}" \
    build || die "xcodebuild 建置失敗，請往上檢查完整錯誤訊息。"

  BUILT_APP="${derived_data}/Build/Products/Release/${APP_NAME}.app"
  [[ -d "${BUILT_APP}" ]] || die "建置完成但找不到 ${BUILT_APP}。"
  info "建置完成：${BUILT_APP}"
}

# ---------------------------------------------------------------------------
# 安裝
# ---------------------------------------------------------------------------

check_prefix_writable() {
  if [[ ! -d "${PREFIX}" ]]; then
    if ! mkdir -p "${PREFIX}" 2>/dev/null; then
      die "無法建立安裝目錄 ${PREFIX}（權限不足）。
    請改用：./install.sh --prefix ~/Applications"
    fi
  fi
  if [[ ! -w "${PREFIX}" ]]; then
    die "沒有寫入 ${PREFIX} 的權限。
    請改用：./install.sh --prefix ~/Applications"
  fi
}

install_app() {
  check_prefix_writable
  quit_running_app

  if [[ -e "${TARGET_APP}" ]]; then
    info "移除舊版本：${TARGET_APP}"
    rm -rf "${TARGET_APP}"
  fi

  info "安裝到：${TARGET_APP}"
  cp -R "${BUILT_APP}" "${TARGET_APP}"

  # 安裝完成後驗證：目錄存在、可執行檔存在、bundle identifier 正確。
  [[ -d "${TARGET_APP}" ]] || die "複製後找不到 ${TARGET_APP}，安裝失敗。"
  [[ -x "${TARGET_APP}/Contents/MacOS/${APP_NAME}" ]] || die "複製後找不到可執行檔，安裝失敗。"

  local installed_id
  installed_id="$(defaults read "${TARGET_APP}/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")"
  if [[ "${installed_id}" != "${BUNDLE_ID}" ]]; then
    die "安裝後的 bundle identifier 不符（取得：'${installed_id}'，預期：'${BUNDLE_ID}'），安裝失敗。"
  fi

  info "安裝驗證通過。"

  # 建置會在 build/ 留下一份完整的 .app，而 macOS 只要看到 app bundle 就會把它
  # （連同裡面的 widget extension）註冊進 LaunchServices。結果是同一個 bundle id
  # 有兩份註冊互相競爭，實測 pluginkit 會挑中建置輸出那份，於是小工具圖庫顯示的
  # icon 與說明來自 build/ 而非 /Applications，看起來就像「圖示一直沒更新」。
  # 安裝完成後主動取消註冊並移除建置輸出，讓系統只認得 /Applications 那一份。
  if [[ -n "${BUILT_APP:-}" && -e "${BUILT_APP}" ]]; then
    "${LSREGISTER}" -u "${BUILT_APP}" >/dev/null 2>&1 || true
  fi
  "${LSREGISTER}" -f "${TARGET_APP}" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Login item（opt-in）
# ---------------------------------------------------------------------------

setup_login_item() {
  info "安裝 LaunchAgent（登入自動啟動）：${LAUNCH_AGENT_PLIST}"
  mkdir -p "$(dirname "${LAUNCH_AGENT_PLIST}")"

  # 若之前已載入過，先卸載，避免重複載入造成的錯誤。
  launchctl bootout "gui/$(id -u)" "${LAUNCH_AGENT_PLIST}" >/dev/null 2>&1 || true

  cat > "${LAUNCH_AGENT_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCH_AGENT_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-a</string>
		<string>${TARGET_APP}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
EOF

  launchctl bootstrap "gui/$(id -u)" "${LAUNCH_AGENT_PLIST}" >/dev/null 2>&1 \
    || warn "launchctl bootstrap 失敗，但 LaunchAgent 檔案已寫入，下次登入應該仍會生效。"
  info "已設定登入自動啟動。"
}

# ---------------------------------------------------------------------------
# DerivedData 清理
# ---------------------------------------------------------------------------

clean_derived_data() {
  info "清除 Xcode DerivedData 裡 ${APP_NAME} 的殘留目錄…"
  if [[ ! -d "${DERIVED_DATA_ROOT}" ]]; then
    info "找不到 DerivedData 目錄（${DERIVED_DATA_ROOT}），略過。"
    return 0
  fi

  local -a matches=()
  local d
  shopt -s nullglob
  for d in "${DERIVED_DATA_ROOT}/${APP_NAME}-"*; do
    matches+=("${d}")
  done
  shopt -u nullglob

  if [[ "${#matches[@]}" -eq 0 ]]; then
    info "沒有找到殘留的 DerivedData 目錄。"
    return 0
  fi

  for d in "${matches[@]}"; do
    info "移除：${d}"
    rm -rf "${d}"
  done
  info "DerivedData 清理完成（共 ${#matches[@]} 筆）。"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

do_uninstall() {
  info "開始移除 ${APP_DISPLAY_NAME}…"
  quit_running_app

  if [[ -e "${TARGET_APP}" ]]; then
    rm -rf "${TARGET_APP}"
    info "已移除 app：${TARGET_APP}"
  else
    info "找不到已安裝的 app（${TARGET_APP}），略過。"
  fi

  if [[ -f "${LAUNCH_AGENT_PLIST}" ]]; then
    launchctl bootout "gui/$(id -u)" "${LAUNCH_AGENT_PLIST}" >/dev/null 2>&1 || true
    rm -f "${LAUNCH_AGENT_PLIST}"
    info "已移除 LaunchAgent：${LAUNCH_AGENT_PLIST}"
  else
    info "沒有找到 LaunchAgent，略過。"
  fi

  if [[ -d "${WIDGET_CONTAINER}" ]]; then
    info "Widget 資料仍保留在：${WIDGET_CONTAINER}"
    info "（不會自動刪除，是否移除請自行決定。實際的 snapshot.json 位於"
    info "${WIDGET_CONTAINER}/Data/Library/Application Support/ 底下。）"
  else
    info "找不到 widget 容器目錄（${WIDGET_CONTAINER}），可能從未執行過。"
  fi

  if signing_identity_exists; then
    info "本機簽章憑證「${SIGNING_CERT_NAME}」仍保留在你的 login keychain 裡。"
    info "（不會自動移除，是否移除請自行決定。若要手動刪除，可執行："
    info "security delete-certificate -c \"${SIGNING_CERT_NAME}\" \"${SIGNING_KEYCHAIN}\"）"
  else
    info "找不到本機簽章憑證「${SIGNING_CERT_NAME}」，可能從未建立過。"
  fi

  info "移除完成。"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

main() {
  if [[ "${DO_CLEAN_DERIVED_DATA}" -eq 1 ]]; then
    clean_derived_data
  fi

  if [[ "${DO_UNINSTALL}" -eq 1 ]]; then
    do_uninstall
    exit 0
  fi

  preflight
  resolve_source
  build_app
  install_app

  if [[ "${DO_LOGIN_ITEM}" -eq 1 ]]; then
    setup_login_item
  else
    warn "已依 --no-login-item 略過 LaunchAgent。${APP_DISPLAY_NAME} 不會隨系統啟動——"
    warn "重開機或登出後它就停止運作，但桌面小工具仍會顯示最後一次的數字（標示為"
    warn "已凍結），看起來像還在運作。之後想改回來，重跑安裝即可。"
  fi

  if [[ "${DO_LAUNCH}" -eq 1 ]]; then
    info "啟動 ${APP_DISPLAY_NAME}…"
    open "${TARGET_APP}"
  fi

  info "完成！${APP_DISPLAY_NAME} 已安裝到 ${TARGET_APP}"
}

main "$@"

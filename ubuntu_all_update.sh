#!/bin/bash

set -u
set -o pipefail

# --------- 顏色 ----------

if [[ -t 1 ]]; then
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
BOLD="\033[1m"
RESET="\033[0m"
else
GREEN=""
YELLOW=""
RED=""
BLUE=""
CYAN=""
BOLD=""
RESET=""
fi

# --------- 防止整份腳本以 root 身分執行 ----------

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
echo -e "${RED}❌ 請不要用 sudo 或 root 執行這個腳本。${RESET}"
echo "   腳本會在需要的步驟自行呼叫 sudo；以 root 執行會讓 \$HOME 變成 /root，"
echo "   失敗 log 寫到錯誤的位置，snap／flatpak 的使用者層級更新也會失效。"
echo "   請改用：./$(basename "$0")"
exit 1
fi

# --------- 中斷處理 ----------
# 沒有這段的話，Ctrl+C 時 EXIT trap 收到的 $? 是 0，會誤判為正常結束而刪掉 log。

on_signal() {
echo
echo -e "${YELLOW}⚠ 收到中斷訊號，正在結束...${RESET}"
exit 130
}

trap on_signal INT TERM HUP

# --------- sudo 憑證檢查 ----------
# 註：不在全域設定 LC_ALL=C，只加在需要解析英文輸出的 apt／dpkg 指令上，
#     避免影響其他工具的語系與 UTF-8 輸出。

# 一旦確認取不到 sudo 權限就不再重複詢問，避免每個步驟都跳一次提示
SUDO_UNAVAILABLE=false

ensure_sudo() {

# 確認 sudo 憑證仍有效。若已過期，在這裡當著使用者的面重新驗證；
# 否則密碼提示會被 run_with_progress 的 stderr 重導向吃掉，畫面看起來像當機。

[[ "$SUDO_UNAVAILABLE" == true ]] && return 1

sudo -n true 2>/dev/null && return 0

echo
echo -e "${YELLOW}⚠ sudo 憑證已過期，請重新輸入密碼${RESET}"

sudo -v && return 0

SUDO_UNAVAILABLE=true

echo -e "${RED}❌ 無法取得 sudo 權限${RESET}"
return 1

}

# --------- sudo 驗證 ----------

echo
echo -e "${BOLD}======================================${RESET}"
echo -e "${BOLD}       Ubuntu 系統更新開始${RESET}"
echo -e "${BOLD}======================================${RESET}"
echo

echo -e "${BLUE}▶ 驗證 sudo 權限...${RESET}"

if ! sudo -v; then
echo -e "${RED}❌ sudo 驗證失敗，停止執行。${RESET}"
exit 1
fi

echo -e "${GREEN}✓ sudo 驗證完成${RESET}"
echo

# --------- 修復可能殘留的未完成 dpkg 狀態 ----------

echo -e "${BLUE}▶ 檢查並修復未完成的套件設定...${RESET}"
sudo DEBIAN_FRONTEND=noninteractive LC_ALL=C dpkg --configure -a >/dev/null 2>&1
echo -e "${GREEN}✓ 檢查完成${RESET}"
echo

# --------- 暫存 log ----------

LOG_DIR="$(mktemp -d)"

if [[ -z "$LOG_DIR" || ! -d "$LOG_DIR" ]]; then
echo -e "${RED}❌ 無法建立暫存目錄，停止執行。${RESET}"
exit 1
fi

APT_UPDATE_LOG="$LOG_DIR/apt-update.log"
APT_UPGRADE_LOG="$LOG_DIR/apt-upgrade.log"
APT_FIX_LOG="$LOG_DIR/apt-fix.log"
SNAP_LOG="$LOG_DIR/snap.log"
FLATPAK_LOG="$LOG_DIR/flatpak.log"

# 若失敗，完整 log 會複製到這裡（不會被 cleanup 刪除）

FAIL_LOG_BASE="$HOME/.local/share/system-update-logs"
FAIL_LOG_DIR="$FAIL_LOG_BASE/$(date +%Y%m%d-%H%M%S)"

# 最多保留幾份失敗 log
FAIL_LOG_KEEP=10

# log 是否已保留，避免 cleanup 重複處理
LOG_PRESERVED=false

# 只保留最近幾份失敗 log，避免無限累積
#
# 這裡刻意不使用 `ls -1dt ... | while read`：那種寫法在檔名含空白或換行時會解析錯誤。
# 雖然目錄名稱是腳本自己產生的時間戳，但改用純 bash 內建比較可以完全避開這個脆弱點。
prune_fail_logs() {

[[ -d "$FAIL_LOG_BASE" ]] || return 0

local -a dirs=()
local -a sorted=()
local d i inserted
local restore_nullglob=false

shopt -q nullglob && restore_nullglob=true
shopt -s nullglob
dirs=( "$FAIL_LOG_BASE"/*/ )
[[ "$restore_nullglob" == true ]] || shopt -u nullglob

(( ${#dirs[@]} > FAIL_LOG_KEEP )) || return 0

# 用 bash 的 -nt 做插入排序（新 → 舊），完全不解析外部指令的輸出
for d in "${dirs[@]}"; do

    inserted=false

    for ((i=0; i<${#sorted[@]}; i++)); do
        if [[ "$d" -nt "${sorted[$i]}" ]]; then
            sorted=( "${sorted[@]:0:i}" "$d" "${sorted[@]:i}" )
            inserted=true
            break
        fi
    done

    [[ "$inserted" == true ]] || sorted+=( "$d" )
done

# 排序後第 FAIL_LOG_KEEP 筆之後的都是較舊的，刪掉
for ((i=FAIL_LOG_KEEP; i<${#sorted[@]}; i++)); do
    rm -rf -- "${sorted[$i]}"
done

}

preserve_logs() {

# 在子 shell 中把 umask 設為 077 再建立目錄：目錄從誕生的那一刻就是 700，
# 不存在「先以寬鬆權限建立、之後才 chmod 收緊」的短暫窗口。
# 注意這裡不用 `install -d -m 700`：它只把權限套用在最末層，
# 中間建立的父目錄仍會是 755，而 FAIL_LOG_BASE 正是我們也想收緊的對象。
( umask 077 && mkdir -p "$FAIL_LOG_DIR" ) 2>/dev/null || return 1

# umask 只影響「新建」的目錄；若目錄是先前執行留下的，這裡補上收緊。
chmod 700 "$FAIL_LOG_BASE" "$FAIL_LOG_DIR" 2>/dev/null

cp "$LOG_DIR"/*.log "$FAIL_LOG_DIR"/ 2>/dev/null

prune_fail_logs

LOG_PRESERVED=true

return 0

}

cleanup() {
local exit_code=$?

# 非預期結束（Ctrl+C、被中斷、提早失敗）時也要保留 log，
# 否則最有價值的診斷資訊會被 rm -rf 刪掉。
if [[ "$exit_code" -ne 0 && "$LOG_PRESERVED" != true ]]; then
    if preserve_logs; then
        echo
        echo -e "${YELLOW}⚠ 腳本非正常結束，完整 log 已保留於：${BOLD}$FAIL_LOG_DIR${RESET}"
    fi
fi

# 防禦性檢查：正常情況下 LOG_DIR 已驗證非空，這裡避免任何情況下變成 rm -rf ""
[[ -n "${LOG_DIR:-}" ]] && rm -rf "$LOG_DIR"
}
trap cleanup EXIT

# --------- 狀態 ----------

APT_STATUS="SKIP"
SNAP_STATUS="SKIP"
FLATPAK_STATUS="SKIP"

WARNINGS=()

# ============================================================

# APT / Snap 活動進度條

# 注意：此進度條表示程序正在執行，不代表實際百分比

# ============================================================

run_with_progress() {

local title="$1"
local logfile="$2"
shift 2

# 需要 sudo 的步驟，先在終端機上確認憑證，避免密碼提示被寫進 log 而卡住
if [[ "${1:-}" == "sudo" ]] && ! ensure_sudo; then
    echo -e "${RED}✗ $title 失敗（無法取得 sudo 權限）${RESET}"
    return 1
fi

# 非互動式輸出（管線／重導向／排程）時不畫動畫，避免 log 被控制字元塞滿
if [[ ! -t 1 ]]; then

    echo -e "${CYAN}▶ $title${RESET} 執行中..."

    "$@" >"$logfile" 2>&1
    local status=$?

    if [[ "$status" -eq 0 ]]; then
        echo -e "${GREEN}✓ $title 完成${RESET}"
    else
        echo -e "${RED}✗ $title 失敗${RESET}"
    fi

    return "$status"
fi

"$@" >"$logfile" 2>&1 &
local pid=$!

local width=30
local block_width=5
local pos=0
local direction=1

while kill -0 "$pid" 2>/dev/null; do

    local bar=""
    local i

    for ((i=0; i<width; i++)); do
        if (( i >= pos && i < pos + block_width )); then
            bar+="█"
        else
            bar+="░"
        fi
    done

    printf "\r${CYAN}▶ %-12s${RESET} [%s] 執行中..." "$title" "$bar"

    sleep 0.15

    pos=$((pos + direction))

    if (( pos >= width - block_width )); then
        direction=-1
    elif (( pos <= 0 )); then
        direction=1
    fi
done

wait "$pid"
local status=$?

printf "\r\033[K"

if [[ "$status" -eq 0 ]]; then
    echo -e "${GREEN}✓ $title 完成${RESET}"
else
    echo -e "${RED}✗ $title 失敗${RESET}"
fi

return "$status"

}

# ============================================================

# APT

# ============================================================

# --------- needrestart 是否安裝，決定 NEEDRESTART_MODE=a 是否有效 ----------

if command -v needrestart >/dev/null 2>&1; then
echo -e "${YELLOW}ℹ 偵測到 needrestart：升級後會自動重啟受影響的服務（NEEDRESTART_MODE=a）${RESET}"
else
echo -e "${YELLOW}ℹ 未安裝 needrestart：NEEDRESTART_MODE 不會生效，升級後不會自動重啟服務${RESET}"
fi
echo

# --------- 檢查套件鎖是否已被其他程序占用 ----------
# Ubuntu 的 apt-daily.timer／unattended-upgrades 常在背景執行，正好撞上就會直接失敗。
#
# 注意：這只是「禮貌性」的提前等待。檢查與實際執行之間存在 check-then-act 競態窗口，
#       這裡不重複實作鎖定機制，真正的互斥仍由 apt／dpkg 自己在底層保證。

apt_lock_held() {

local lockfile

for lockfile in /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock; do
    [[ -e "$lockfile" ]] || continue

    # 以 sudo 執行才看得到 root 或其他使用者的程序
    if sudo -n fuser -s "$lockfile" 2>/dev/null; then
        return 0
    fi
done

return 1

}

if command -v fuser >/dev/null 2>&1 && ensure_sudo && apt_lock_held; then

echo -e "${YELLOW}⚠ 偵測到其他套件管理程序正在執行（可能是 apt-daily.timer／unattended-upgrades）${RESET}"
echo -e "${BLUE}▶ 等待鎖釋放（最多 5 分鐘）...${RESET}"

LOCK_WAITED=0

while apt_lock_held && [[ "$LOCK_WAITED" -lt 300 ]]; do
    echo -e "  等待中... 已等 ${LOCK_WAITED} 秒（最多 300 秒）"
    sleep 5
    LOCK_WAITED=$((LOCK_WAITED + 5))
done

if apt_lock_held; then
    echo -e "${RED}❌ 等待逾時，套件鎖仍被占用${RESET}"
    WARNINGS+=("套件鎖被其他程序占用，APT 更新可能失敗")
else
    echo -e "${GREEN}✓ 鎖已釋放，繼續執行${RESET}"
fi

echo

fi

echo -e "${BOLD}[ APT ]${RESET}"

# 升級前的已安裝套件數，供最後統計使用

PKG_COUNT_BEFORE="$(dpkg -l 2>/dev/null | grep -c '^ii')"

if run_with_progress \
"apt update" \
"$APT_UPDATE_LOG" \
sudo DEBIAN_FRONTEND=noninteractive LC_ALL=C apt update \
-o Acquire::Retries=3; then

if run_with_progress \
    "apt upgrade" \
    "$APT_UPGRADE_LOG" \
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a LC_ALL=C apt upgrade -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        -o Acquire::Retries=3; then

    APT_STATUS="OK"
else
    APT_STATUS="FAIL"
    WARNINGS+=("APT upgrade 執行失敗")

    # 升級失敗可能留下 broken 相依，嘗試修復，避免系統停在半殘狀態
    echo -e "${BLUE}▶ 嘗試修復套件相依（apt-get -f install）...${RESET}"

    if run_with_progress \
        "apt fix-broken" \
        "$APT_FIX_LOG" \
        sudo DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get -f install -y \
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold; then

        echo -e "${YELLOW}  已嘗試修復相依，請確認系統狀態${RESET}"
    else
        echo -e "${RED}  修復失敗，建議手動執行：sudo apt-get -f install${RESET}"
    fi
fi

else
APT_STATUS="FAIL"
WARNINGS+=("APT update 執行失敗")
fi

PKG_COUNT_AFTER="$(dpkg -l 2>/dev/null | grep -c '^ii')"

# 檢查 APT Warning / Error（只鎖定 apt/dpkg 自身輸出的固定格式，避免把無關文字誤判為錯誤）

if grep -Eq '^(W:|E:)|^dpkg: error' \
"$APT_UPDATE_LOG" "$APT_UPGRADE_LOG" 2>/dev/null; then

WARNINGS+=("APT log 中有 Warning / Error，建議檢查詳細資訊")

fi

echo

# ============================================================

# Snap

# ============================================================

echo -e "${BOLD}[ Snap ]${RESET}"

if command -v snap >/dev/null 2>&1; then

if run_with_progress \
    "Snap" \
    "$SNAP_LOG" \
    sudo snap refresh; then

    SNAP_STATUS="OK"
else
    SNAP_STATUS="FAIL"
    WARNINGS+=("Snap 更新失敗")
fi

else
SNAP_STATUS="NOT_INSTALLED"
echo -e "${YELLOW}➖ Snap 未安裝，略過${RESET}"
fi

echo

# ============================================================

# Flatpak

# ============================================================

echo -e "${BOLD}[ Flatpak ]${RESET}"

if command -v flatpak >/dev/null 2>&1; then

echo -e "${BLUE}▶ 正在更新 Flatpak...${RESET}"
echo -e "${YELLOW}  以下顯示 Flatpak 即時下載進度與速度${RESET}"
echo

# Flatpak 即時輸出到終端，同時保存至 log；--noninteractive 避免卡在確認提示
flatpak update -y --noninteractive 2>&1 | tee "$FLATPAK_LOG"

# PIPESTATUS[0] 是 flatpak update 本身的 exit code
FLATPAK_EXIT=${PIPESTATUS[0]}

echo

if [[ "$FLATPAK_EXIT" -eq 0 ]]; then
    FLATPAK_STATUS="OK"
    echo -e "${GREEN}✓ Flatpak 完成${RESET}"
else
    FLATPAK_STATUS="FAIL"
    WARNINGS+=("Flatpak 更新失敗")
    echo -e "${RED}✗ Flatpak 失敗${RESET}"
fi

else
FLATPAK_STATUS="NOT_INSTALLED"
echo -e "${YELLOW}➖ Flatpak 未安裝，略過${RESET}"
fi

# ============================================================

# 其他檢查

# ============================================================

REBOOT_REQUIRED=false

if [[ -f /run/reboot-required ]]; then
REBOOT_REQUIRED=true
WARNINGS+=("系統需要重新啟動")
fi

# --------- apt autoremove ----------

AUTOREMOVE_COUNT=0

if command -v apt-get >/dev/null 2>&1; then

AUTOREMOVE_COUNT="$(
    LC_ALL=C apt-get -s autoremove 2>/dev/null |
    awk '/^Remv / {count++} END {print count+0}'
)"

if [[ "$AUTOREMOVE_COUNT" -gt 0 ]]; then
    WARNINGS+=("有 $AUTOREMOVE_COUNT 個套件可以使用 apt autoremove 移除")
fi

fi

# ============================================================

# 顯示狀態函式

# ============================================================

print_status() {

local name="$1"
local status="$2"

case "$status" in

    OK)
        printf "%-10s : ${GREEN}✅ 成功${RESET}\n" "$name"
        ;;

    FAIL)
        printf "%-10s : ${RED}❌ 失敗${RESET}\n" "$name"
        ;;

    NOT_INSTALLED)
        printf "%-10s : ${YELLOW}➖ 未安裝，略過${RESET}\n" "$name"
        ;;

    *)
        printf "%-10s : ${YELLOW}➖ 略過${RESET}\n" "$name"
        ;;
esac

}

# ============================================================

# 最終結果

# ============================================================

echo
echo -e "${BOLD}======================================${RESET}"
echo -e "${BOLD}             更新結果${RESET}"
echo -e "${BOLD}======================================${RESET}"

print_status "APT" "$APT_STATUS"
print_status "Snap" "$SNAP_STATUS"
print_status "Flatpak" "$FLATPAK_STATUS"

echo -e "${BOLD}======================================${RESET}"

if [[ "$APT_STATUS" == "OK" ]]; then
    PKG_DIFF=$(( PKG_COUNT_AFTER - PKG_COUNT_BEFORE ))
if [[ "$PKG_DIFF" -gt 0 ]]; then
PKG_DIFF_STR="+$PKG_DIFF"
else
PKG_DIFF_STR="$PKG_DIFF"
    fi
    echo -e "已安裝套件數：${PKG_COUNT_BEFORE} → ${PKG_COUNT_AFTER}（${PKG_DIFF_STR}）"
fi

# ============================================================

# 注意事項

# ============================================================

if [[ ${#WARNINGS[@]} -gt 0 ]]; then

echo
echo -e "${YELLOW}${BOLD}⚠ 注意事項${RESET}"

for warning in "${WARNINGS[@]}"; do
    echo -e "  ${YELLOW}•${RESET} $warning"
done

else
echo
echo -e "${GREEN}✅ 沒有發現需要注意的問題。${RESET}"
fi

# --------- reboot ----------

if [[ "$REBOOT_REQUIRED" == true ]]; then

echo
echo -e "${YELLOW}${BOLD}🔄 建議重新啟動系統：${RESET}"
echo "   sudo reboot"

fi

# --------- autoremove ----------

if [[ "$AUTOREMOVE_COUNT" -gt 0 ]]; then

echo
echo -e "${YELLOW}${BOLD}🧹 可以清除不再需要的套件：${RESET}"
echo "   sudo apt autoremove"

fi

# ============================================================

# 失敗時顯示 log 並保留完整檔案（避免只留 30 行不夠診斷）

# ============================================================

if [[ "$APT_STATUS" == "FAIL" ||
"$SNAP_STATUS" == "FAIL" ||
"$FLATPAK_STATUS" == "FAIL" ]]; then

if preserve_logs; then

echo
echo -e "${RED}${BOLD}========== 錯誤詳細資訊 ==========${RESET}"

else

echo
echo -e "${YELLOW}⚠ 無法寫入 log 目錄：$FAIL_LOG_DIR${RESET}"

fi

if [[ "$APT_STATUS" == "FAIL" ]]; then

    echo
    echo -e "${BOLD}[ APT ]${RESET}"

    grep -E \
        '^(W:|E:)|^dpkg: error' \
        "$APT_UPDATE_LOG" \
        "$APT_UPGRADE_LOG" \
        "$APT_FIX_LOG" \
        2>/dev/null |
        tail -n 30
fi

if [[ "$SNAP_STATUS" == "FAIL" ]]; then

    echo
    echo -e "${BOLD}[ Snap ]${RESET}"
    tail -n 30 "$SNAP_LOG"
fi

if [[ "$FLATPAK_STATUS" == "FAIL" ]]; then

    echo
    echo -e "${BOLD}[ Flatpak ]${RESET}"

    # Flatpak 前面已經即時顯示過，這裡只重列最後 30 行方便找錯誤
    tail -n 30 "$FLATPAK_LOG"
fi

if [[ "$LOG_PRESERVED" == true ]]; then

echo
echo -e "完整 log 已保留於：${BOLD}$FAIL_LOG_DIR${RESET}"

fi

fi

# ============================================================

# 清理 apt 快取（僅在成功時執行）

# ============================================================

if [[ "$APT_STATUS" == "OK" ]]; then

# autoclean 本身不需確認，憑證可能已過期，先確認一次避免提示被 /dev/null 吃掉
ensure_sudo && sudo apt-get autoclean >/dev/null 2>&1

fi

# ============================================================

# 結束前等待，避免終端機視窗自動關閉

# ============================================================

pause_before_exit() {

# 只在互動式終端機中等待；排程或管線執行時不會卡住

if [[ -t 0 ]]; then
    echo
    printf "%b" "${BOLD}按 Enter 鍵關閉視窗...${RESET}"
    read -r _ || true
    echo
fi

}

# ============================================================

# Exit code

# ============================================================

if [[ "$APT_STATUS" == "FAIL" ||
"$SNAP_STATUS" == "FAIL" ||
"$FLATPAK_STATUS" == "FAIL" ]]; then

echo
echo -e "${RED}${BOLD}❌ 更新完成，但有部分項目失敗。${RESET}"
pause_before_exit
exit 1

else

echo
echo -e "${GREEN}${BOLD}✅ 所有可用的更新項目皆已完成。${RESET}"
pause_before_exit
exit 0

fi

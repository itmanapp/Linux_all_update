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
echo "   失敗 log 寫到錯誤的位置，flatpak 的使用者層級更新也會失效。"
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

# --------- 確認是 SUSE 系系統，並偵測版本 ----------

if ! command -v zypper >/dev/null 2>&1; then
echo -e "${RED}❌ 找不到 zypper，這個腳本只能在 openSUSE／SUSE 上執行。${RESET}"
echo "   Ubuntu／Debian 請改用 ubuntu_all_update.sh"
exit 1
fi

OS_ID=""
OS_NAME="unknown"

# 在 subshell（command substitution）中讀取 /etc/os-release：不污染本 shell 環境。
# 若該檔權限被竄改成可寫，代表系統早已被入侵，不在這支腳本的威脅模型內；
# 這裡只做欄位取值，不對檔案內容做任何執行以外的處理。
if [[ -r /etc/os-release ]]; then
OS_ID="$( . /etc/os-release; echo "${ID:-}" )"
OS_NAME="$( . /etc/os-release; echo "${PRETTY_NAME:-unknown}" )"
fi

# Tumbleweed／Slowroll／Aeon 等滾動版本要用 dup 才是完整升級；Leap／SLE 用 update
case "$OS_ID" in
opensuse-tumbleweed|opensuse-slowroll|opensuse-aeon|opensuse-kalpa|opensuse-microos)
ZYPPER_UPGRADE_CMD="dup"
UPGRADE_LABEL="zypper dup"
;;
*)
ZYPPER_UPGRADE_CMD="update"
UPGRADE_LABEL="zypper update"
;;
esac

# --------- sudo 憑證檢查 ----------
# 註：不在全域設定 LC_ALL=C，只加在需要解析英文輸出的 zypper／rpm 指令上，
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
echo -e "${BOLD}       openSUSE 系統更新開始${RESET}"
echo -e "${BOLD}======================================${RESET}"
echo
echo -e "${BLUE}▶ 系統：${OS_NAME}${RESET}"
echo -e "${BLUE}▶ 升級方式：${UPGRADE_LABEL}${RESET}"
echo

echo -e "${BLUE}▶ 驗證 sudo 權限...${RESET}"

if ! sudo -v; then
echo -e "${RED}❌ sudo 驗證失敗，停止執行。${RESET}"
exit 1
fi

echo -e "${GREEN}✓ sudo 驗證完成${RESET}"
echo

# --------- 檢查是否有殘留的 zypper 鎖檔 ----------

if [[ -e /var/run/zypp.pid ]]; then

ZYPP_PID="$(sudo cat /var/run/zypp.pid 2>/dev/null)"

if [[ -n "$ZYPP_PID" ]] && ! sudo kill -0 "$ZYPP_PID" 2>/dev/null; then
echo -e "${YELLOW}⚠ 發現殘留的 zypper 鎖檔（PID $ZYPP_PID 已不存在）${RESET}"
echo -e "${YELLOW}  若確定沒有其他套件管理程序在跑，可執行：sudo rm -f /var/run/zypp.pid${RESET}"
echo
fi
fi

# --------- 暫存 log ----------

LOG_DIR="$(mktemp -d)"

if [[ -z "$LOG_DIR" || ! -d "$LOG_DIR" ]]; then
echo -e "${RED}❌ 無法建立暫存目錄，停止執行。${RESET}"
exit 1
fi

ZYPPER_REFRESH_LOG="$LOG_DIR/zypper-refresh.log"
ZYPPER_UPGRADE_LOG="$LOG_DIR/zypper-upgrade.log"
ZYPPER_VERIFY_LOG="$LOG_DIR/zypper-verify.log"
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

rm -rf "$LOG_DIR"
}
trap cleanup EXIT

# --------- 狀態 ----------

ZYPPER_STATUS="SKIP"
FLATPAK_STATUS="SKIP"

WARNINGS=()

# ============================================================

# Zypper 活動進度條

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

# Zypper

# ============================================================

# --------- 檢查 zypper 是否已被其他程序占用 ----------
# zypper 的鎖是 /var/run/zypp.pid，被占用時直接執行會失敗。
#
# 注意：這只是「禮貌性」的提前等待。檢查與實際執行之間存在 check-then-act 競態窗口，
#       這裡不重複實作鎖定機制，真正的互斥仍由 zypper 自己在底層保證。

zypper_lock_held() {

local lockfile

for lockfile in /var/run/zypp.pid; do
    [[ -e "$lockfile" ]] || continue

    # 以 sudo 執行才看得到 root 或其他使用者的程序
    if sudo -n fuser -s "$lockfile" 2>/dev/null; then
        return 0
    fi
done

return 1

}

if command -v fuser >/dev/null 2>&1 && ensure_sudo && zypper_lock_held; then

echo -e "${YELLOW}⚠ 偵測到其他套件管理程序正在執行（zypper／YaST／PackageKit）${RESET}"
echo -e "${BLUE}▶ 等待鎖釋放（最多 5 分鐘）...${RESET}"

LOCK_WAITED=0

while zypper_lock_held && [[ "$LOCK_WAITED" -lt 300 ]]; do
    echo -e "  等待中... 已等 ${LOCK_WAITED} 秒（最多 300 秒）"
    sleep 5
    LOCK_WAITED=$((LOCK_WAITED + 5))
done

if zypper_lock_held; then
    echo -e "${RED}❌ 等待逾時，套件鎖仍被占用${RESET}"
    WARNINGS+=("套件鎖被其他程序占用，Zypper 更新可能失敗")
else
    echo -e "${GREEN}✓ 鎖已釋放，繼續執行${RESET}"
fi

echo

fi

echo -e "${BOLD}[ Zypper ]${RESET}"

# 升級前的已安裝套件數，供最後統計使用

PKG_COUNT_BEFORE="$(rpm -qa 2>/dev/null | wc -l)"

if run_with_progress \
"zypper refresh" \
"$ZYPPER_REFRESH_LOG" \
sudo LC_ALL=C zypper --non-interactive refresh; then

if run_with_progress \
    "$UPGRADE_LABEL" \
    "$ZYPPER_UPGRADE_LOG" \
    sudo LC_ALL=C zypper --non-interactive --auto-agree-with-licenses "$ZYPPER_UPGRADE_CMD"; then

    ZYPPER_STATUS="OK"
else
    ZYPPER_STATUS="FAIL"
    WARNINGS+=("$UPGRADE_LABEL 執行失敗")

    # 升級失敗可能留下相依問題，用 zypper verify 嘗試修復
    echo -e "${BLUE}▶ 嘗試修復套件相依（zypper verify）...${RESET}"

    if run_with_progress \
        "zypper verify" \
        "$ZYPPER_VERIFY_LOG" \
        sudo LC_ALL=C zypper --non-interactive verify; then

        echo -e "${YELLOW}  已嘗試修復相依，請確認系統狀態${RESET}"
    else
        echo -e "${RED}  修復失敗，建議手動執行：sudo zypper verify${RESET}"
    fi
fi

else
ZYPPER_STATUS="FAIL"
WARNINGS+=("zypper refresh 執行失敗")
fi

PKG_COUNT_AFTER="$(rpm -qa 2>/dev/null | wc -l)"

# 檢查 zypper 的 Warning / Error（鎖定 zypper 自身輸出的固定格式）

if grep -Eq '^(Warning|Error):|^Problem:' \
"$ZYPPER_REFRESH_LOG" "$ZYPPER_UPGRADE_LOG" 2>/dev/null; then

WARNINGS+=("zypper log 中有 Warning / Error，建議檢查詳細資訊")

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
RESTART_REQUIRED=false

# zypper 在需要重開機時回傳 102、需要重啟服務時回傳 103
if command -v zypper >/dev/null 2>&1; then

zypper needs-rebooting >/dev/null 2>&1

case "$?" in
    102) REBOOT_REQUIRED=true ;;
    103) RESTART_REQUIRED=true ;;
esac

fi

# 部分版本／工具會在 /run 下留標記檔
if [[ -f /run/reboot-required || -f /run/reboot-needed ]]; then
REBOOT_REQUIRED=true
fi

if [[ "$REBOOT_REQUIRED" == true ]]; then
WARNINGS+=("系統需要重新啟動")
fi

if [[ "$RESTART_REQUIRED" == true ]]; then
WARNINGS+=("有服務需要重新啟動（可用 sudo zypper ps -s 查看）")
fi

# --------- 不再需要的套件（orphaned packages）---------

UNNEEDED_COUNT=0

if command -v zypper >/dev/null 2>&1; then

# 表格輸出中資料列與表頭都含 ' | '；扣掉表頭即為套件數
UNNEEDED_COUNT="$(
    LC_ALL=C zypper --quiet packages --unneeded 2>/dev/null |
    awk '/ \| / { if (seen++) count++ } END { print count+0 }'
)"

if [[ "$UNNEEDED_COUNT" -gt 0 ]]; then
    WARNINGS+=("有 $UNNEEDED_COUNT 個套件已不再需要，可用 sudo zypper rm -u 移除")
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

print_status "Zypper" "$ZYPPER_STATUS"
print_status "Flatpak" "$FLATPAK_STATUS"

echo -e "${BOLD}======================================${RESET}"

if [[ "$ZYPPER_STATUS" == "OK" ]]; then
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

# --------- 不再需要的套件 ----------

if [[ "$UNNEEDED_COUNT" -gt 0 ]]; then

echo
echo -e "${YELLOW}${BOLD}🧹 可以清除不再需要的套件：${RESET}"
echo "   sudo zypper rm -u"

fi

# ============================================================

# 失敗時顯示 log 並保留完整檔案（避免只留 30 行不夠診斷）

# ============================================================

if [[ "$ZYPPER_STATUS" == "FAIL" ||
"$FLATPAK_STATUS" == "FAIL" ]]; then

if preserve_logs; then

echo
echo -e "${RED}${BOLD}========== 錯誤詳細資訊 ==========${RESET}"

else

echo
echo -e "${YELLOW}⚠ 無法寫入 log 目錄：$FAIL_LOG_DIR${RESET}"

fi

if [[ "$ZYPPER_STATUS" == "FAIL" ]]; then

    echo
    echo -e "${BOLD}[ Zypper ]${RESET}"

    grep -E \
        '^(Warning|Error):|^Problem:' \
        "$ZYPPER_REFRESH_LOG" \
        "$ZYPPER_UPGRADE_LOG" \
        "$ZYPPER_VERIFY_LOG" \
        2>/dev/null |
        tail -n 30
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

# 清理 zypper 快取（僅在成功時執行）

# ============================================================

if [[ "$ZYPPER_STATUS" == "OK" ]]; then

# zypper clean 不需確認，憑證可能已過期，先確認一次避免提示被 /dev/null 吃掉
ensure_sudo && sudo zypper clean --all >/dev/null 2>&1

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

if [[ "$ZYPPER_STATUS" == "FAIL" ||
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

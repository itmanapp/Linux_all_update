#!/bin/bash
# ============================================================
#  ubuntu_all_update_v3.0.sh
#
#  Ubuntu / Debian 系統更新腳本（apt + snap + flatpak）
#
#  這是 v3.0，與 v1／v2.1 並存，不會覆蓋它們。
#  v3.0 修正了 v1 的安全性與正確性問題，並新增命令列選項。
#  變更摘要見 README_v3.0.md。
#  v3.0 相對 v2.1 新增：結束前列出「本次更新的套件」，
#  一行一個套件方便瀏覽；若本次沒有任何套件異動，
#  則顯示「本次無任何套件更新」。
#
#  請勿以 sudo 執行本腳本。
# ============================================================

set -u
set -o pipefail

VERSION="3.0"

# --------- PATH 強化 ----------
# 不信任呼叫者的 PATH：把系統目錄放在最前面，避免有人把假的 sudo／apt
# 放在 PATH 較前面的位置來騙取稍後要輸入的密碼。
# （sudo 的 secure_path 只保護「sudo 執行的指令」，不保護 sudo 本身。）
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
export PATH
readonly PATH

# ============================================================
#  命令列選項
# ============================================================

DRY_RUN=false
ASSUME_YES=false
NO_COLOR="${NO_COLOR:-}"
KEEP_LOGS=10
ONLY_RAW=""
ONLY_APT=true
ONLY_SNAP=true
ONLY_FLATPAK=true

usage() {
cat <<'USAGE'
ubuntu_all_update_v3.0.sh — Ubuntu / Debian 系統更新腳本

用法：
  ./ubuntu_all_update_v3.0.sh [選項]

選項：
  -h, --help          顯示這份說明並結束（不會更新任何東西）
  -n, --dry-run       只模擬，不實際變更系統（apt 用 -s、snap 用 --list、
                      flatpak 用 remote-ls --updates）
      --only LIST     只執行指定項目，逗號分隔：apt,snap,flatpak,all
                       （預設 all）
  -y, --yes           不等待結尾的「按 Enter」
      --keep-logs N   保留最近 N 份失敗 log（預設 10）
      --no-color      關閉顏色輸出
      --version       顯示版本並結束

範例：
  ./ubuntu_all_update_v3.0.sh --dry-run
  ./ubuntu_all_update_v3.0.sh --only apt
  ./ubuntu_all_update_v3.0.sh -y --keep-logs 5

結束碼：
  0  全部成功（可能含非致命警告）
  1  有步驟失敗，或仍有套件被 kept back 而未升級
  2  命令列參數錯誤
  130／143／129  被 Ctrl+C／TERM／HUP 中斷

注意：
  本腳本會呼叫 sudo，但「請勿」用 sudo 執行整份腳本。
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --version)
            echo "ubuntu_all_update_v3.0.sh $VERSION"
            exit 0
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        --no-color)
            NO_COLOR=true
            shift
            ;;
        --keep-logs)
            if [[ $# -lt 2 ]]; then
                echo "錯誤：--keep-logs 需要一個數字。" >&2
                exit 2
            fi
            KEEP_LOGS="$2"
            shift 2
            ;;
        --only)
            if [[ $# -lt 2 ]]; then
                echo "錯誤：--only 需要一個清單。" >&2
                exit 2
            fi
            ONLY_RAW="$2"
            shift 2
            ;;
        *)
            echo "錯誤：未知的選項「$1」。" >&2
            echo "      用 --help 看可用選項。" >&2
            exit 2
            ;;
    esac
done

if ! [[ "$KEEP_LOGS" =~ ^[0-9]+$ ]]; then
    echo "錯誤：--keep-logs 必須是數字，收到「$KEEP_LOGS」。" >&2
    exit 2
fi

if [[ -n "$ONLY_RAW" ]]; then
    ONLY_APT=false
    ONLY_SNAP=false
    ONLY_FLATPAK=false
    IFS=',' read -r -a _only_items <<< "$ONLY_RAW"
    for _it in "${_only_items[@]}"; do
        case "$_it" in
            apt)     ONLY_APT=true ;;
            snap)    ONLY_SNAP=true ;;
            flatpak) ONLY_FLATPAK=true ;;
            all)     ONLY_APT=true; ONLY_SNAP=true; ONLY_FLATPAK=true ;;
            "")
                ;;
            *)
                echo "錯誤：--only 不認得「$_it」（可用：apt,snap,flatpak,all）。" >&2
                exit 2
                ;;
        esac
    done
    if [[ "$ONLY_APT" != true && "$ONLY_SNAP" != true && "$ONLY_FLATPAK" != true ]]; then
        echo "錯誤：--only 沒有選到任何項目。" >&2
        exit 2
    fi
fi

# --------- 顏色 ----------

if [[ -t 1 && -z "$NO_COLOR" ]]; then
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

# ============================================================
#  中斷處理
#
#  v1 的問題：背景執行的套件管理程序在非互動 bash 中會把 SIGINT 設為
#  SIG_IGN（可用 /proc/<pid>/status 的 SigIgn 遮罩驗證），所以 Ctrl+C
#  只會讓「腳本」結束，套件交易仍在以 root 身分進行；而 cleanup 又會
#  立刻 rm -rf 掉那個程序正在寫入的 log 目錄。
#
#  v2.1：追蹤背景子程序，第一次中斷「等它安全結束」，第二次才強制終止，
#        而且 cleanup 一定會先確認子程序沒了才刪目錄。
# ============================================================

CHILD_PID=""
INTERRUPTED=false

signal_exit_code() {
    case "$1" in
        INT)  echo 130 ;;
        TERM) echo 143 ;;
        HUP)  echo 129 ;;
        *)    echo 130 ;;
    esac
}

# 等待背景的套件管理程序結束。
# 套件交易被中途殺掉會留下半殘的 dpkg 狀態，所以預設只等待、不強殺。
reap_child() {

    [[ -n "$CHILD_PID" ]] || return 0
    kill -0 "$CHILD_PID" 2>/dev/null || { CHILD_PID=""; return 0; }

    local pid="$CHILD_PID"

    echo
    echo -e "${YELLOW}⚠ 套件管理程序（PID $pid）仍在執行中。${RESET}"
    echo -e "${YELLOW}  為避免系統停在半殘狀態，會等它結束後才退出；請勿關閉終端機。${RESET}"
    echo -e "${YELLOW}  若確定要強制中止，請再按一次 Ctrl+C。${RESET}"

    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.5
    done

    wait "$pid" 2>/dev/null
    CHILD_PID=""
    return 0
}

on_signal() {

    local sig="$1"

    if [[ "$INTERRUPTED" == true ]]; then
        echo
        echo -e "${RED}⚠ 再次收到中斷訊號，強制終止背景程序。${RESET}"
        [[ -n "$CHILD_PID" ]] && kill -KILL "$CHILD_PID" 2>/dev/null
        CHILD_PID=""
        exit "$(signal_exit_code "$sig")"
    fi

    INTERRUPTED=true
    echo
    echo -e "${YELLOW}⚠ 收到中斷訊號，正在結束...${RESET}"

    reap_child

    exit "$(signal_exit_code "$sig")"
}

trap 'on_signal INT'  INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP'  HUP

# ============================================================
#  sudo 憑證檢查
# ============================================================

SUDO_UNAVAILABLE=false

ensure_sudo() {

    # 確認 sudo 憑證仍有效。若已過期，在這裡當著使用者的面重新驗證。
    # 注意：sudo 的提示是寫到 /dev/tty，不是 stderr；會被重導向「蓋掉」的
    # 是進度條重繪，而不是提示本身。

    [[ "$SUDO_UNAVAILABLE" == true ]] && return 1

    sudo -n true 2>/dev/null && return 0

    echo
    echo -e "${YELLOW}⚠ sudo 憑證已過期，請重新輸入密碼${RESET}"

    sudo -v && return 0

    SUDO_UNAVAILABLE=true

    echo -e "${RED}❌ 無法取得 sudo 權限${RESET}"
    return 1
}

# ============================================================
#  執行紀錄
# ============================================================

RUN_LABEL=()
RUN_STATUS=()
RUN_COMMAND=()
RUN_SECONDS=()
RUN_NOTE=()

HAD_FAILURE=false
HAD_WARNING=false

# $1 步驟名稱　$2 狀態(OK/FAIL/WARN/SKIP)　$3 實際指令　$4 耗時秒數　$5 補充說明(可省略)
record_step() {

    RUN_LABEL+=("$1")
    RUN_STATUS+=("$2")
    RUN_COMMAND+=("$3")
    RUN_SECONDS+=("$4")
    RUN_NOTE+=("${5:-}")

    case "$2" in
        FAIL) HAD_FAILURE=true ;;
        WARN) HAD_WARNING=true ;;
    esac
}

add_warning() {
    WARNINGS+=("$1")
    HAD_WARNING=true
}

# ============================================================
#  暫存 log
# ============================================================

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

FAIL_LOG_BASE="$HOME/.local/share/system-update-logs"
FAIL_LOG_DIR="$FAIL_LOG_BASE/$(date +%Y%m%d-%H%M%S)-$$"

LOG_PRESERVED=false

# 只保留最近幾份失敗 log。
# v2.1：只刪「符合本腳本命名格式」的目錄，且跳過 symlink，
#       避免誤刪使用者自己放在同一個目錄下的東西。
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

    # 先過濾：只留下「YYYYmmdd-HHMMSS-PID」這種自己產生的目錄，並排除 symlink
    local -a keep=()
    for d in "${dirs[@]}"; do
        [[ -L "${d%/}" ]] && continue
        [[ "${d%/}" =~ /[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || continue
        keep+=( "$d" )
    done

    (( ${#keep[@]} > KEEP_LOGS )) || return 0

    # 用 bash 的 -nt 做插入排序（新 → 舊），完全不解析外部指令的輸出
    for d in "${keep[@]}"; do

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

    for ((i=KEEP_LOGS; i<${#sorted[@]}; i++)); do
        rm -rf -- "${sorted[$i]}"
    done

    return 0
}

preserve_logs() {

    # 在子 shell 中把 umask 設為 077 再建立目錄：目錄從誕生的那一刻就是 700，
    # 不存在「先以寬鬆權限建立、之後才 chmod 收緊」的短暫窗口。
    ( umask 077 && mkdir -p "$FAIL_LOG_DIR" ) 2>/dev/null || return 1

    chmod 700 "$FAIL_LOG_BASE" "$FAIL_LOG_DIR" 2>/dev/null

    # v2.1：log 檔本身也收緊為 600，不再只依賴目錄權限；
    #       並且檢查 cp 是否真的成功，不再「什麼都沒複製到也回報成功」。
    local copied=0 f
    local restore_nullglob=false

    shopt -q nullglob && restore_nullglob=true
    shopt -s nullglob
    local -a logs=( "$LOG_DIR"/*.log )
    [[ "$restore_nullglob" == true ]] || shopt -u nullglob

    for f in "${logs[@]}"; do
        if ( umask 077; cp -- "$f" "$FAIL_LOG_DIR"/ ) 2>/dev/null; then
            copied=$((copied + 1))
        fi
    done

    chmod 600 "$FAIL_LOG_DIR"/*.log 2>/dev/null

    if (( copied == 0 )); then
        return 1
    fi

    prune_fail_logs

    LOG_PRESERVED=true

    return 0
}

cleanup() {

    local exit_code=$?

    # 絕對不在背景子程序還活著的時候刪掉它正在寫入的目錄
    reap_child

    # 非預期結束（Ctrl+C、被中斷、提早失敗）時也要保留 log
    if [[ "$exit_code" -ne 0 && "$LOG_PRESERVED" != true ]]; then
        if preserve_logs; then
            echo
            echo -e "${YELLOW}⚠ 腳本非正常結束，完整 log 已保留於：${BOLD}$FAIL_LOG_DIR${RESET}"
        fi
    fi

    [[ -n "${LOG_DIR:-}" ]] && rm -rf -- "$LOG_DIR"

    return 0
}
trap cleanup EXIT

# ============================================================
#  狀態
# ============================================================

APT_STATUS="SKIP"
SNAP_STATUS="SKIP"
FLATPAK_STATUS="SKIP"

WARNINGS=()

# ============================================================
#  進度顯示 + 指令執行
# ============================================================

run_with_progress() {

    local title="$1"
    local logfile="$2"
    shift 2

    local cmd_str="$*"
    local started=$SECONDS
    local status

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}▶ [模擬] $title${RESET}"
    fi

    # 需要 sudo 的步驟，先在終端機上確認憑證
    if [[ "${1:-}" == "sudo" ]] && ! ensure_sudo; then
        echo -e "${RED}✗ $title 失敗（無法取得 sudo 權限）${RESET}"
        record_step "$title" "FAIL" "$cmd_str" "$((SECONDS - started))" "無法取得 sudo 權限"
        return 1
    fi

    # 一律以背景執行：
    #  - 非互動時不必畫動畫
    #  - 背景子程序會忽略 SIGINT，套件交易不會被 Ctrl+C 直接砍斷，
    #    改由 on_signal 的 reap_child 安全地等待
    "$@" >"$logfile" 2>&1 &
    local pid=$!
    CHILD_PID="$pid"

    if [[ -t 1 ]]; then

        local width=30 block_width=5 pos=0 direction=1 bar i

        while kill -0 "$pid" 2>/dev/null; do

            bar=""

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

        printf "\r\033[K"

    else

        echo -e "${CYAN}▶ $title${RESET} 執行中..."

    fi

    wait "$pid"
    status=$?
    CHILD_PID=""

    if [[ "$status" -eq 0 ]]; then
        echo -e "${GREEN}✓ $title 完成${RESET}"
        record_step "$title" "OK" "$cmd_str" "$((SECONDS - started))"
    elif [[ "$DRY_RUN" == true ]]; then
        # 模擬模式的失敗通常只是「非 root 無法讀取套件清單」之類的限制，
        # 不代表實際更新會失敗，因此記為警告。
        echo -e "${YELLOW}⚠ $title 在模擬模式下未成功（多為非 root 的限制）${RESET}"
        record_step "$title" "WARN" "$cmd_str" "$((SECONDS - started))" "exit code $status（模擬模式）"
    else
        echo -e "${RED}✗ $title 失敗${RESET}"
        record_step "$title" "FAIL" "$cmd_str" "$((SECONDS - started))" "exit code $status"
    fi

    return "$status"
}

# ============================================================
#  預先檢查
# ============================================================

echo
echo -e "${BOLD}======================================${RESET}"
echo -e "${BOLD}       Ubuntu 系統更新開始${RESET}"
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${BOLD}       （模擬模式，不會變更系統）${RESET}"
fi
echo -e "${BOLD}======================================${RESET}"
echo

# 確認 apt／dpkg 存在（v1 沒有檢查，在非 Debian 系會以奇怪的方式失敗）
if [[ "$ONLY_APT" == true ]]; then
    for tool in apt-get dpkg; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo -e "${RED}❌ 找不到 $tool，這不是 Debian 系系統。${RESET}"
            echo "   openSUSE／SUSE 請改用 suse_all_update_v2.1.sh"
            exit 1
        fi
    done
fi

# --------- 磁碟空間預檢 ----------
# 核心套件升級時 /boot 或 / 爆滿，是造成 dpkg 半殘最常見的原因之一。
# 這裡在「任何變更之前」先檢查，讓使用者有機會直接 Ctrl+C。

check_disk_space() {

    local path="$1" need_mb="$2" label="$3"
    local avail

    [[ -d "$path" ]] || return 0

    avail="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
    [[ "$avail" =~ ^[0-9]+$ ]] || return 0

    if (( avail < need_mb * 1024 )); then
        add_warning "$label 可用空間僅 $((avail / 1024)) MB（建議至少 ${need_mb} MB）"
        return 1
    fi

    return 0
}

DISK_LOW=false

check_disk_space "/" 1024 "/" || DISK_LOW=true

# /boot 只有是獨立掛載點時才需要單獨檢查
if mountpoint -q /boot 2>/dev/null; then
    check_disk_space "/boot" 256 "/boot" || DISK_LOW=true
fi

if [[ "$DISK_LOW" == true ]]; then

    echo -e "${RED}${BOLD}⚠ 磁碟可用空間偏低${RESET}"

    for w in "${WARNINGS[@]}"; do
        echo -e "  ${RED}•${RESET} $w"
    done

    echo
    echo -e "${YELLOW}  套件升級期間空間不足，可能讓系統停在半殘狀態。${RESET}"
    echo -e "${YELLOW}  建議先清出空間（例如 sudo apt clean、移除舊核心）再執行。${RESET}"
    echo

    # 這裡刻意 fail-closed：無法取得使用者明確同意時一律中止。
    # 非互動（cron／systemd timer／stdin 被重導向）且沒有 -y 時，舊寫法會因為
    # -t 0 不成立而「既沒問、也沒擋」，直接在磁碟偏低的狀況下繼續升級。
    # -y 的語意是「使用者明確同意略過確認」，不是「無法互動時預設同意」。
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}  模擬模式不會變更系統，繼續執行。${RESET}"
    elif [[ "$ASSUME_YES" == true ]]; then
        echo -e "${YELLOW}  已指定 -y（明確同意略過確認），繼續執行。${RESET}"
    elif [[ -t 0 ]]; then
        printf "%b" "${BOLD}仍要繼續嗎？[y/N] ${RESET}"
        read -r _ans || _ans=""
        case "$_ans" in
            [yY]|[yY][eE][sS]) echo -e "${YELLOW}  繼續執行。${RESET}" ;;
            *)
                echo -e "${YELLOW}  已取消，未做任何變更。${RESET}"
                exit 1
                ;;
        esac
    else
        echo -e "${RED}❌ 非互動執行且未指定 -y，磁碟空間不足時不予繼續。${RESET}"
        echo -e "${YELLOW}   若確定要繼續，請加上 -y，或在互動式終端機中執行。${RESET}"
        exit 1
    fi

    echo
fi

# --------- sudo 驗證 ----------

if [[ "$DRY_RUN" == true ]]; then
    echo -e "${BLUE}▶ 模擬模式：不呼叫 sudo，也不會變更系統。${RESET}"
    echo
else

    echo -e "${BLUE}▶ 驗證 sudo 權限...${RESET}"

    if ! sudo -v; then
        echo -e "${RED}❌ sudo 驗證失敗，停止執行。${RESET}"
        exit 1
    fi

    echo -e "${GREEN}✓ sudo 驗證完成${RESET}"
    echo

fi

# --------- 修復可能殘留的未完成 dpkg 狀態 ----------

if [[ "$ONLY_APT" == true ]]; then

    echo -e "${BLUE}▶ 檢查並修復未完成的套件設定...${RESET}"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}▶ [模擬] sudo dpkg --configure -a${RESET}"
        record_step "dpkg configure" "SKIP" "sudo dpkg --configure -a" "0" "模擬模式"
    elif run_with_progress \
        "dpkg configure" \
        "$LOG_DIR/dpkg-configure.log" \
        sudo DEBIAN_FRONTEND=noninteractive LC_ALL=C dpkg --configure -a; then
        :
    else
        # v2.1：dpkg 處於半殘狀態是「真的問題」，要進 WARNINGS 並影響 exit code，
        #       不能再像 v1 那樣只印一行「不影響後續更新」就算了。
        add_warning "dpkg --configure -a 失敗：系統可能有未完成設定的套件，建議手動檢查"
    fi

    echo

fi

# ============================================================
#  APT
# ============================================================

# --------- 檢查套件鎖是否已被其他程序占用 ----------
#
# v2.1：區分三種結果。v1 把「鎖是空的」和「sudo 憑證過期／fuser 執行失敗」
#       都折成「沒被占用」，會在鎖其實還被持有時印出「鎖已釋放」。
# v2.1：原本的 case 仍把 sudo -n 的失敗（exit code 1）與 fuser 的
#       「沒有任何程序持有這個檔案」（也是 exit code 1）混為一談。
#       現在先單獨確認 sudo 憑證，失敗就直接回報 2（無法判定），
#       交由外層 ensure_sudo 重新驗證後再判斷。

# 回傳：0 = 被占用　1 = 確定沒被占用　2 = 無法判定
apt_lock_state() {

    local lockfile rc

    # 先單獨確認 sudo 憑證可用：sudo -n 在沒有快取憑證時會以 exit code 1 失敗，
    # 與 fuser 回報「沒有任何程序持有」的 exit code 1 無法區分。
    # 不先擋掉的話，「不知道」就會被當成「確定沒鎖」。
    if ! sudo -n true 2>/dev/null; then
        return 2
    fi

    for lockfile in /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock; do
        [[ -e "$lockfile" ]] || continue

        sudo -n fuser -s "$lockfile" 2>/dev/null
        rc=$?

        case "$rc" in
            0) return 0 ;;   # 有程序持有
            1) continue ;;   # 這個鎖沒被持有，看下一個
            *) return 2 ;;   # fuser 執行失敗 → 無法判定
        esac
    done

    return 1
}

if [[ "$ONLY_APT" == true && "$DRY_RUN" != true ]]; then

    if ! command -v fuser >/dev/null 2>&1; then
        add_warning "找不到 fuser，略過套件鎖檢查（若同時有其他更新在跑，apt 可能失敗）"
    else

        LOCK_STATE=2
        apt_lock_state && LOCK_STATE=0 || LOCK_STATE=$?

        if [[ "$LOCK_STATE" -eq 2 ]]; then

            if ensure_sudo; then
                apt_lock_state && LOCK_STATE=0 || LOCK_STATE=$?
            fi

        fi

        if [[ "$LOCK_STATE" -eq 0 ]]; then

            echo -e "${YELLOW}⚠ 偵測到其他套件管理程序正在執行（可能是 apt-daily.timer／unattended-upgrades）${RESET}"
            echo -e "${BLUE}▶ 等待鎖釋放（最多 5 分鐘）...${RESET}"

            LOCK_WAITED=0

            while [[ "$LOCK_WAITED" -lt 300 ]]; do

                # 每一輪都重新確認憑證，避免憑證在等待期間過期而誤判「鎖已釋放」
                if ! ensure_sudo; then
                    add_warning "等待套件鎖時無法取得 sudo 權限，無法確認鎖的狀態"
                    LOCK_STATE=2
                    break
                fi

                apt_lock_state
                LOCK_STATE=$?
                [[ "$LOCK_STATE" -eq 1 ]] && break
                [[ "$LOCK_STATE" -eq 2 ]] && break

                echo -e "  等待中... 已等 ${LOCK_WAITED} 秒（最多 300 秒）"
                sleep 5
                LOCK_WAITED=$((LOCK_WAITED + 5))
            done

            case "$LOCK_STATE" in
                1) echo -e "${GREEN}✓ 鎖已釋放，繼續執行${RESET}" ;;
                0) add_warning "等待逾時，套件鎖仍被占用，APT 更新可能失敗" ;;
                2) add_warning "無法判定套件鎖狀態（sudo 或 fuser 失敗），APT 更新可能失敗" ;;
            esac

            echo
        fi
    fi
fi

# --------- 本次更新的套件清單 ----------
# 以「升級前後的已安裝套件快照」求差異，比解析 apt 的輸出可靠：
# 不受語系與輸出格式影響，也能拿到準確的版本變化。

PKG_SNAPSHOT_BEFORE="$LOG_DIR/pkg-before.tsv"
PKG_SNAPSHOT_AFTER="$LOG_DIR/pkg-after.tsv"

PKG_UPDATED_LINES=""
PKG_UPDATED_COUNT=0
PKG_DELTA_OK=false

snapshot_packages() {
    dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | sort > "$1" || return 1
    [[ -s "$1" ]]
}

# 顯示用：把 name<TAB>old<TAB>new 排成一行一個套件
format_pkg_delta() {
    sort -u | awk -F'\t' '
        {
            if ($2 != "")      printf "  %-34s %s → %s\n", $1, $2, $3
            else if ($3 != "") printf "  %-34s %s（新安裝）\n", $1, $3
            else               printf "  %s\n", $1
        }
    '
}

# 真實執行：比對升級前後的快照
pkg_upgraded_lines() {
    [[ -s "$PKG_SNAPSHOT_BEFORE" && -s "$PKG_SNAPSHOT_AFTER" ]] || return 0
    awk -F'\t' '
        NR == FNR { old[$1] = $2; next }
        {
            if (!($1 in old))       printf "%s\t\t%s\n", $1, $2
            else if (old[$1] != $2) printf "%s\t%s\t%s\n", $1, old[$1], $2
        }
    ' "$PKG_SNAPSHOT_BEFORE" "$PKG_SNAPSHOT_AFTER" | format_pkg_delta
}

# 模擬模式：解析 apt-get -s 的 "Inst name [old] (new ...)" 行
pkg_simulated_lines() {
    local log="$1"
    [[ -r "$log" ]] || return 0
    awk '
        /^Inst / {
            n = $2
            sub(/:.*$/, "", n)
            if (n == "") next
            # 只在第一個 "(" 之前找 [舊版本]，否則新安裝的行會把
            # 版本括號內的 [amd64] 誤判成舊版本。
            p = index($0, "(")
            if (p > 0) { head = substr($0, 1, p - 1); tail = substr($0, p) }
            else       { head = $0; tail = "" }
            old = ""
            if (match(head, /\[[^]]*\]/)) old = substr(head, RSTART + 1, RLENGTH - 2)
            new = ""
            if (tail != "" && match(tail, /\([^)]*\)/)) {
                new = substr(tail, RSTART + 1, RLENGTH - 2)
                sub(/[ \t].*$/, "", new)
            }
            printf "%s\t%s\t%s\n", n, old, new
        }
    ' "$log" | format_pkg_delta
}

echo -e "${BOLD}[ APT ]${RESET}"

PKG_COUNT_BEFORE="$(dpkg -l 2>/dev/null | grep -c '^ii' || true)"
[[ "$PKG_COUNT_BEFORE" =~ ^[0-9]+$ ]] || PKG_COUNT_BEFORE=0

# 升級前的套件快照（供最後列出「本次更新了哪些套件」）
snapshot_packages "$PKG_SNAPSHOT_BEFORE" || true

if [[ "$ONLY_APT" != true ]]; then

    APT_STATUS="SKIP"
    record_step "APT" "SKIP" "" "0" "以 --only 排除"

else

    if [[ "$DRY_RUN" == true ]]; then
        # 一定要帶 LC_ALL=C：否則在非英文語系下 "N not upgraded" 的結尾
        # 摘要會被翻譯，kept back／phasing 的偵測就會靜默讀到 0。
        APT_UPGRADE_CMD=(env LC_ALL=C apt-get -s upgrade)
    else
        APT_UPDATE_CMD=(sudo DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get update -o Acquire::Retries=3)
        APT_UPGRADE_CMD=(sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a LC_ALL=C apt-get upgrade -y
                         -o Dpkg::Options::=--force-confdef
                         -o Dpkg::Options::=--force-confold
                         -o Acquire::Retries=3)
    fi

    # apt-get -s update 仍會嘗試取得 /var/lib/apt/lists 的鎖而需要 root，
    # 而且它只重新整理索引、不是「更新」本身；模擬模式直接略過，
    # 讓後面的 -s upgrade 能真正跑出「預計更新哪些套件」。
    APT_UPDATE_OK=false

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}▶ [模擬] 略過 apt update（-s 仍需 root 取鎖，且只更新索引）${RESET}"
        record_step "apt update" "SKIP" "sudo apt-get update" "0" "模擬模式，略過"
        APT_UPDATE_OK=true
    elif run_with_progress "apt update" "$APT_UPDATE_LOG" "${APT_UPDATE_CMD[@]}"; then
        APT_UPDATE_OK=true
    fi

    if [[ "$APT_UPDATE_OK" == true ]]; then

        if run_with_progress "apt upgrade" "$APT_UPGRADE_LOG" "${APT_UPGRADE_CMD[@]}"; then

            APT_STATUS="OK"

        else

            APT_STATUS="FAIL"
            [[ "$DRY_RUN" == true ]] || add_warning "APT upgrade 執行失敗"

            echo -e "${BLUE}▶ 嘗試修復套件相依（apt-get -f install）...${RESET}"

            if [[ "$DRY_RUN" == true ]]; then
                APT_FIX_CMD=(apt-get -s -f install)
            else
                APT_FIX_CMD=(sudo DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get -f install -y
                             -o Dpkg::Options::=--force-confdef
                             -o Dpkg::Options::=--force-confold)
            fi

            if run_with_progress "apt fix-broken" "$APT_FIX_LOG" "${APT_FIX_CMD[@]}"; then
                echo -e "${YELLOW}  已嘗試修復相依，請確認系統狀態${RESET}"
            else
                echo -e "${RED}  修復失敗，建議手動執行：sudo apt-get -f install${RESET}"
                [[ "$DRY_RUN" == true ]] || add_warning "apt-get -f install 修復失敗，系統可能有相依問題"
            fi
        fi

    else

        APT_STATUS="FAIL"
        [[ "$DRY_RUN" == true ]] || add_warning "APT update 執行失敗"

    fi

    PKG_COUNT_AFTER="$(dpkg -l 2>/dev/null | grep -c '^ii' || true)"
    [[ "$PKG_COUNT_AFTER" =~ ^[0-9]+$ ]] || PKG_COUNT_AFTER="$PKG_COUNT_BEFORE"

    # 算出本次的套件異動清單
    if [[ "$DRY_RUN" == true ]]; then
        PKG_UPDATED_LINES="$(pkg_simulated_lines "$APT_UPGRADE_LOG")"
        PKG_DELTA_OK=true
    else
        snapshot_packages "$PKG_SNAPSHOT_AFTER" || true
        if [[ -s "$PKG_SNAPSHOT_BEFORE" && -s "$PKG_SNAPSHOT_AFTER" ]]; then
            PKG_DELTA_OK=true
        fi
        PKG_UPDATED_LINES="$(pkg_upgraded_lines)"
    fi

    if [[ -n "$PKG_UPDATED_LINES" ]]; then
        PKG_UPDATED_COUNT="$(printf '%s\n' "$PKG_UPDATED_LINES" | grep -c . || true)"
        [[ "$PKG_UPDATED_COUNT" =~ ^[0-9]+$ ]] || PKG_UPDATED_COUNT=0
    fi

    # --------- v2.1：偵測「有套件沒有真的被升級」 ----------
    # v1 只 grep '^(W:|E:)'，但 apt upgrade 在有套件被 kept back 或
    # 因 phased update 而延後時，exit code 仍是 0，輸出也不含 W:/E:。
    # 這會讓腳本在系統其實沒補齊的狀態下回報「全部完成」。

    APT_NOT_UPGRADED=0
    APT_KEPT_BACK=false
    APT_PHASED=false

    if [[ -r "$APT_UPGRADE_LOG" ]]; then

        _n="$(sed -n 's/.*and \([0-9][0-9]*\) not upgraded.*/\1/p' "$APT_UPGRADE_LOG" | tail -n1)"
        [[ "$_n" =~ ^[0-9]+$ ]] && APT_NOT_UPGRADED="$_n"

        grep -q 'have been kept back' "$APT_UPGRADE_LOG" 2>/dev/null && APT_KEPT_BACK=true
        grep -q 'deferred due to phasing' "$APT_UPGRADE_LOG" 2>/dev/null && APT_PHASED=true
    fi

    # 套件名稱（最多列 20 個），讓使用者知道到底是哪些沒升到
    apt_pending_names() {
        awk '
            /^The following packages have been kept back:/          { grab=1; next }
            /^The following upgrades have been deferred due to phasing:/ { grab=1; next }
            grab && /^[[:space:]]/ {
                gsub(/^[[:space:]]+/, "")
                n = split($0, a, /[[:space:]]+/)
                for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
                next
            }
            grab { grab = 0 }
        ' "$1" 2>/dev/null | sort -u | head -n 20 | paste -sd' ' -
    }

    if [[ "$APT_KEPT_BACK" == true ]]; then

        # kept back 代表「有相依變更而 apt upgrade 刻意不動它」，
        # 這通常需要 apt full-upgrade，是使用者真正該知道的事。
        _names="$(apt_pending_names "$APT_UPGRADE_LOG")"

        if [[ "$DRY_RUN" == true ]]; then
            # 模擬模式只預告，不影響 exit code
            add_warning "預計有 ${APT_NOT_UPGRADED} 個套件會被 kept back 而不升級${_names:+：$_names}（模擬模式）"
        else
            APT_STATUS="PARTIAL"
            add_warning "有 ${APT_NOT_UPGRADED} 個套件被 kept back 而未升級${_names:+：$_names}"
            add_warning "若確認要一併升級這些套件，請執行：sudo apt full-upgrade"
        fi

    elif [[ "$APT_PHASED" == true ]]; then

        # phased update 是 Ubuntu 刻意的分批推送，會自行陸續生效，
        # 不是錯誤，但也不該讓使用者以為「全部都補完了」。
        _names="$(apt_pending_names "$APT_UPGRADE_LOG")"
        add_warning "有 ${APT_NOT_UPGRADED} 個套件因 phased update 分批推送而暫緩升級${_names:+：$_names}（Ubuntu 會自行陸續生效）"

    elif [[ "$APT_NOT_UPGRADED" -gt 0 ]]; then

        add_warning "有 ${APT_NOT_UPGRADED} 個套件未被升級，建議檢查 $APT_UPGRADE_LOG"

    fi

    # --------- 檢查 APT 的 Error（v2.1：不再把每個 W: 都當成問題） ----------
    # v1 的 '^(W:|E:)' 幾乎每次執行都會命中無害的警告
    # （例如 "W: Key is stored in legacy trusted.gpg keyring"），
    # 讓使用者對警告區塊麻木。

    if [[ "$DRY_RUN" == true ]]; then
        :   # 模擬模式的 log 內容不代表真實結果，不做警告判定
    elif grep -Eq '^(E:)|^dpkg: error' "$APT_UPDATE_LOG" "$APT_UPGRADE_LOG" 2>/dev/null; then
        add_warning "APT log 中有 Error，建議檢查詳細資訊"
    elif grep -Eq '^W:' "$APT_UPDATE_LOG" "$APT_UPGRADE_LOG" 2>/dev/null; then
        _wcount="$(cat "$APT_UPDATE_LOG" "$APT_UPGRADE_LOG" 2>/dev/null | grep -cE '^W:' || true)"
        [[ "$_wcount" =~ ^[0-9]+$ ]] || _wcount=0
        add_warning "APT log 中有 ${_wcount} 則警告（多為無害，需要時再看 log）"
    fi

    echo

fi

# ============================================================
#  Snap
# ============================================================

echo -e "${BOLD}[ Snap ]${RESET}"

if [[ "$ONLY_SNAP" != true ]]; then

    SNAP_STATUS="SKIP"
    record_step "Snap" "SKIP" "" "0" "以 --only 排除"

elif ! command -v snap >/dev/null 2>&1; then

    SNAP_STATUS="NOT_INSTALLED"
    echo -e "${YELLOW}➖ Snap 未安裝，略過${RESET}"
    record_step "Snap" "SKIP" "sudo snap refresh" "0" "未安裝 snap"

else

    if [[ "$DRY_RUN" == true ]]; then
        SNAP_CMD=(snap refresh --list)
    else
        SNAP_CMD=(sudo snap refresh)
    fi

    if run_with_progress "Snap" "$SNAP_LOG" "${SNAP_CMD[@]}"; then
        SNAP_STATUS="OK"
    else
        SNAP_STATUS="FAIL"
        add_warning "Snap 更新失敗"
    fi

fi

echo

# ============================================================
#  Flatpak
# ============================================================

echo -e "${BOLD}[ Flatpak ]${RESET}"

if [[ "$ONLY_FLATPAK" != true ]]; then

    FLATPAK_STATUS="SKIP"
    record_step "Flatpak" "SKIP" "" "0" "以 --only 排除"

elif ! command -v flatpak >/dev/null 2>&1; then

    FLATPAK_STATUS="NOT_INSTALLED"
    echo -e "${YELLOW}➖ Flatpak 未安裝，略過${RESET}"
    record_step "Flatpak" "SKIP" "flatpak update -y --noninteractive" "0" "未安裝 flatpak"

else

    FLATPAK_STARTED=$SECONDS

    if [[ "$DRY_RUN" == true ]]; then

        echo -e "${CYAN}▶ [模擬] flatpak remote-ls --updates${RESET}"
        flatpak remote-ls --updates 2>&1 | tee "$FLATPAK_LOG"
        FLATPAK_EXIT=${PIPESTATUS[0]}
        _fp_cmd="flatpak remote-ls --updates"

    else

        echo -e "${BLUE}▶ 正在更新 Flatpak...${RESET}"
        echo -e "${YELLOW}  以下顯示 Flatpak 即時下載進度與速度${RESET}"
        echo

        flatpak update -y --noninteractive 2>&1 | tee "$FLATPAK_LOG"
        FLATPAK_EXIT=${PIPESTATUS[0]}
        _fp_cmd="flatpak update -y --noninteractive"

    fi

    echo

    if [[ "$FLATPAK_EXIT" -eq 0 ]]; then
        FLATPAK_STATUS="OK"
        echo -e "${GREEN}✓ Flatpak 完成${RESET}"
        record_step "Flatpak" "OK" "$_fp_cmd" "$((SECONDS - FLATPAK_STARTED))"
    else
        FLATPAK_STATUS="FAIL"
        add_warning "Flatpak 更新失敗"
        echo -e "${RED}✗ Flatpak 失敗${RESET}"
        record_step "Flatpak" "FAIL" "$_fp_cmd" "$((SECONDS - FLATPAK_STARTED))" "exit code $FLATPAK_EXIT"
    fi

fi

# ============================================================
#  其他檢查
# ============================================================

REBOOT_REQUIRED=false

if [[ -f /run/reboot-required ]]; then
    REBOOT_REQUIRED=true
    add_warning "系統需要重新啟動"
fi

# --------- apt autoremove ----------

AUTOREMOVE_COUNT=0

if command -v apt-get >/dev/null 2>&1; then

    AUTOREMOVE_COUNT="$(
        LC_ALL=C apt-get -s autoremove 2>/dev/null |
        awk '/^Remv / {count++} END {print count+0}'
    )"
    [[ "$AUTOREMOVE_COUNT" =~ ^[0-9]+$ ]] || AUTOREMOVE_COUNT=0

    if [[ "$AUTOREMOVE_COUNT" -gt 0 ]]; then
        add_warning "有 $AUTOREMOVE_COUNT 個套件可以使用 apt autoremove 移除"
    fi

fi

# ============================================================
#  顯示狀態
# ============================================================

print_status() {

    local name="$1"
    local status="$2"

    case "$status" in

        OK)
            printf "%-10s : ${GREEN}✅ 成功${RESET}\n" "$name"
            ;;

        PARTIAL)
            printf "%-10s : ${YELLOW}⚠  部分完成${RESET}\n" "$name"
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
#  執行摘要
# ============================================================

print_run_summary() {

    local i icon result

    (( ${#RUN_LABEL[@]} == 0 )) && return 0

    echo
    echo -e "${BOLD}======================================${RESET}"
    echo -e "${BOLD}           本次執行摘要${RESET}"
    echo -e "${BOLD}======================================${RESET}"
    echo

    for ((i=0; i<${#RUN_LABEL[@]}; i++)); do

        case "${RUN_STATUS[$i]}" in
            OK)   icon="${GREEN}✅${RESET}";  result="成功" ;;
            FAIL) icon="${RED}❌${RESET}";    result="失敗" ;;
            WARN) icon="${YELLOW}⚠${RESET}";  result="警告" ;;
            *)    icon="${YELLOW}➖${RESET}";  result="略過" ;;
        esac

        if [[ "${RUN_STATUS[$i]}" == "SKIP" ]]; then
            printf "%b %-15s %s\n" "$icon" "${RUN_LABEL[$i]}" "$result"
        else
            printf "%b %-15s %s（%s 秒）\n" "$icon" "${RUN_LABEL[$i]}" "$result" "${RUN_SECONDS[$i]}"
        fi

        if [[ -n "${RUN_COMMAND[$i]}" ]]; then
            echo -e "      ${BOLD}\$${RESET} ${RUN_COMMAND[$i]}"
        fi

        if [[ -n "${RUN_NOTE[$i]}" ]]; then
            echo -e "      ${YELLOW}↳ ${RUN_NOTE[$i]}${RESET}"
        fi

    done

    echo -e "${BOLD}======================================${RESET}"
}

# ============================================================
#  最終結果
# ============================================================

# 模擬模式的「失敗」多半只是非 root 的限制，不該讓 exit code 變成 1
if [[ "$DRY_RUN" == true ]]; then
    HAD_FAILURE=false
    [[ "$APT_STATUS" == "FAIL" ]] && APT_STATUS="SKIP"
    [[ "$SNAP_STATUS" == "FAIL" ]] && SNAP_STATUS="SKIP"
    [[ "$FLATPAK_STATUS" == "FAIL" ]] && FLATPAK_STATUS="SKIP"
fi

echo
echo -e "${BOLD}======================================${RESET}"
echo -e "${BOLD}             更新結果${RESET}"
echo -e "${BOLD}======================================${RESET}"

print_status "APT" "$APT_STATUS"
print_status "Snap" "$SNAP_STATUS"
print_status "Flatpak" "$FLATPAK_STATUS"

echo -e "${BOLD}======================================${RESET}"

if [[ "$APT_STATUS" == "OK" || "$APT_STATUS" == "PARTIAL" ]]; then
    PKG_DIFF=$(( PKG_COUNT_AFTER - PKG_COUNT_BEFORE ))
    if [[ "$PKG_DIFF" -gt 0 ]]; then
        PKG_DIFF_STR="+$PKG_DIFF"
    else
        PKG_DIFF_STR="$PKG_DIFF"
    fi
    echo -e "已安裝套件數：${PKG_COUNT_BEFORE} → ${PKG_COUNT_AFTER}（${PKG_DIFF_STR}）"
fi

# --------- 本次更新的套件（一行一個，方便瀏覽） ----------

echo
echo -e "${BOLD}======================================${RESET}"
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${BOLD}         本次預計更新的套件${RESET}"
else
    echo -e "${BOLD}           本次更新的套件${RESET}"
fi
echo -e "${BOLD}======================================${RESET}"
echo

if [[ "$PKG_UPDATED_COUNT" -gt 0 ]]; then
    printf '%s\n' "$PKG_UPDATED_LINES"
    echo
    echo -e "${BOLD}共 ${PKG_UPDATED_COUNT} 個套件${RESET}"
else
    echo "本次無任何套件更新"
    [[ "$PKG_DELTA_OK" == true ]] || echo -e "${YELLOW}（注意：本次無法取得套件清單，無法確認）${RESET}"
fi

# --------- 注意事項 ----------

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
#  失敗時顯示 log 並保留完整檔案
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

        grep -E '^(E:)|^dpkg: error' \
            "$APT_UPDATE_LOG" \
            "$APT_UPGRADE_LOG" \
            "$APT_FIX_LOG" \
            2>/dev/null |
            tail -n 30
    fi

    if [[ "$SNAP_STATUS" == "FAIL" ]]; then
        echo
        echo -e "${BOLD}[ Snap ]${RESET}"
        tail -n 30 "$SNAP_LOG" 2>/dev/null
    fi

    if [[ "$FLATPAK_STATUS" == "FAIL" ]]; then
        echo
        echo -e "${BOLD}[ Flatpak ]${RESET}"
        tail -n 30 "$FLATPAK_LOG" 2>/dev/null
    fi

    if [[ "$LOG_PRESERVED" == true ]]; then
        echo
        echo -e "完整 log 已保留於：${BOLD}$FAIL_LOG_DIR${RESET}"
    fi

fi

# ============================================================
#  清理 apt 快取（僅在成功時執行）
# ============================================================

if [[ "$APT_STATUS" == "OK" || "$APT_STATUS" == "PARTIAL" ]]; then

    CLEAN_STARTED=$SECONDS

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}▶ [模擬] sudo apt-get autoclean${RESET}"
        record_step "apt autoclean" "SKIP" "sudo apt-get autoclean" "0" "模擬模式"
    elif ensure_sudo && sudo apt-get autoclean >/dev/null 2>&1; then
        record_step "apt autoclean" "OK" "sudo apt-get autoclean" "$((SECONDS - CLEAN_STARTED))"
    else
        # 清快取失敗不影響更新結果，但也不該完全消失
        record_step "apt autoclean" "WARN" "sudo apt-get autoclean" "$((SECONDS - CLEAN_STARTED))" "清理快取失敗（不影響更新結果）"
        add_warning "apt autoclean 失敗（不影響更新結果，只是快取沒有清）"
    fi

fi

# ============================================================
#  本次執行摘要
# ============================================================

print_run_summary

# ============================================================
#  結束前等待
#  v2.1：同時要求 stdout 是終端機，否則 ./script | tee log 還是會停下來等
# ============================================================

pause_before_exit() {

    [[ "$ASSUME_YES" == true ]] && return 0
    [[ -t 0 && -t 1 ]] || return 0

    echo
    printf "%b" "${BOLD}按 Enter 鍵關閉視窗...${RESET}"
    read -r _ || true
    echo
}

# ============================================================
#  Exit code
# ============================================================

if [[ "$HAD_FAILURE" == true ]]; then

    echo
    echo -e "${RED}${BOLD}❌ 更新完成，但有部分項目失敗。${RESET}"
    pause_before_exit
    exit 1

elif [[ "$APT_STATUS" == "PARTIAL" ]]; then

    echo
    echo -e "${YELLOW}${BOLD}⚠ 更新完成，但仍有套件被 kept back 而未升級（見上方注意事項）。${RESET}"
    pause_before_exit
    exit 1

elif [[ "$DRY_RUN" == true ]]; then

    echo
    echo -e "${CYAN}${BOLD}🧪 模擬完成，未變更任何系統設定。${RESET}"
    if [[ "$HAD_WARNING" == true ]]; then
        echo -e "${YELLOW}   部分步驟在模擬模式下有警告，詳見上方執行摘要。${RESET}"
    fi
    pause_before_exit
    exit 0

elif [[ "$HAD_WARNING" == true ]]; then

    echo
    if [[ ${#WARNINGS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}${BOLD}⚠ 更新完成，部分步驟有警告（詳見上方執行摘要）。${RESET}"
    else
        echo -e "${YELLOW}${BOLD}⚠ 更新完成，但有一些需要注意的事項（見上方）。${RESET}"
    fi
    pause_before_exit
    exit 0

else

    echo
    echo -e "${GREEN}${BOLD}✅ 所有可用的更新項目皆已完成。${RESET}"
    pause_before_exit
    exit 0

fi

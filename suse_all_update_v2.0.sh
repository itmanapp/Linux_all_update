#!/bin/bash
# ============================================================
#  suse_all_update_v2.0.sh
#
#  openSUSE / SUSE 系統更新腳本（zypper + flatpak）
#
#  這是 v2.0，與 v1 的 suse_all_update.sh 並存，不會覆蓋它。
#  變更摘要見 README_v2.0.md。
#
#  請勿以 sudo 執行本腳本。
# ============================================================

set -u
set -o pipefail

VERSION="2.0"

# --------- PATH 強化 ----------
# 不信任呼叫者的 PATH：把系統目錄放在最前面，避免有人把假的 sudo／zypper
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
ONLY_ZYPPER=true
ONLY_FLATPAK=true

usage() {
cat <<'USAGE'
suse_all_update_v2.0.sh — openSUSE / SUSE 系統更新腳本

用法：
  ./suse_all_update_v2.0.sh [選項]

選項：
  -h, --help          顯示這份說明並結束（不會更新任何東西）
  -n, --dry-run       只模擬，不實際變更系統（zypper 用 --dry-run、
                      flatpak 用 remote-ls --updates）
      --only LIST     只執行指定項目，逗號分隔：zypper,flatpak,all
                       （預設 all）
  -y, --yes           不等待結尾的「按 Enter」
      --keep-logs N   保留最近 N 份失敗 log（預設 10）
      --no-color      關閉顏色輸出
      --version       顯示版本並結束

範例：
  ./suse_all_update_v2.0.sh --dry-run
  ./suse_all_update_v2.0.sh --only zypper

結束碼：
  0  全部成功（可能含非致命警告）
  1  有步驟失敗
  2  命令列參數錯誤
  130／143／129  被 Ctrl+C／TERM／HUP 中斷

關於不可變系統（MicroOS／Aeon／Kalpa）：
  這些系統的根檔案系統是唯讀的，套件更新必須經過
  transactional-update，更新會落在「新的快照」裡，要重開機才會生效。
  本腳本會自動偵測並改用 transactional-update dup，且一律提醒你重開機。

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
            echo "suse_all_update_v2.0.sh $VERSION"
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
    ONLY_ZYPPER=false
    ONLY_FLATPAK=false
    IFS=',' read -r -a _only_items <<< "$ONLY_RAW"
    for _it in "${_only_items[@]}"; do
        case "$_it" in
            zypper)  ONLY_ZYPPER=true ;;
            flatpak) ONLY_FLATPAK=true ;;
            all)     ONLY_ZYPPER=true; ONLY_FLATPAK=true ;;
            "")
                ;;
            *)
                echo "錯誤：--only 不認得「$_it」（可用：zypper,flatpak,all）。" >&2
                exit 2
                ;;
        esac
    done
    if [[ "$ONLY_ZYPPER" != true && "$ONLY_FLATPAK" != true ]]; then
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
    echo "   失敗 log 寫到錯誤的位置，flatpak 的使用者層級更新也會失效。"
    echo "   請改用：./$(basename "$0")"
    exit 1
fi

# --------- 確認是 SUSE 系系統，並偵測版本 ----------

if ! command -v zypper >/dev/null 2>&1; then
    echo -e "${RED}❌ 找不到 zypper，這個腳本只能在 openSUSE／SUSE 上執行。${RESET}"
    echo "   Ubuntu／Debian 請改用 ubuntu_all_update_v2.0.sh"
    exit 1
fi

OS_ID=""
OS_NAME="unknown"

# 在 subshell（command substitution）中讀取 /etc/os-release：不污染本 shell 環境。
if [[ -r /etc/os-release ]]; then
    OS_ID="$( . /etc/os-release; echo "${ID:-}" )"
    OS_NAME="$( . /etc/os-release; echo "${PRETTY_NAME:-unknown}" )"
fi

# Tumbleweed／Slowroll 等滾動版本要用 dup 才是完整升級；Leap／SLE 用 update
case "$OS_ID" in
    opensuse-tumbleweed|opensuse-slowroll)
        ZYPPER_UPGRADE_CMD="dup"
        UPGRADE_LABEL="zypper dup"
        ;;
    *)
        ZYPPER_UPGRADE_CMD="update"
        UPGRADE_LABEL="zypper update"
        ;;
esac

# --------- 不可變／交易式系統偵測 ----------
#
# v1 把 MicroOS／Aeon／Kalpa 也當成「滾動版本」而直接跑 zypper dup，
# 這是錯的：這些系統的根檔案系統是唯讀的，zypper 的 dup／update 都帶有
# NeedsWritableRoot 條件，會改成在「新快照」中執行（或直接以 exit 5 拒絕），
# 結果是更新不會作用到正在執行的系統，而且 needs-rebooting 也不會回報需要重開機，
# 使用者因此以為系統已經補好了。
#
# 判斷方式參考 zypper 的 isTransactionalSystem()：根目錄唯讀 + 有
# transactional-update 可用。

IS_TRANSACTIONAL=false

detect_transactional() {

    command -v transactional-update >/dev/null 2>&1 || return 1

    local opts o
    local -a parts=()

    opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"

    if [[ -n "$opts" ]]; then
        IFS=',' read -r -a parts <<< "$opts"
        for o in "${parts[@]}"; do
            # 精確比對 "ro"，不能用 *ro*（會誤中 errors=remount-ro）
            [[ "$o" == "ro" ]] && return 0
        done
    fi

    # 少數情況根目錄是之後才 remount 成唯讀的，用 ID 補判
    case "$OS_ID" in
        opensuse-microos|opensuse-aeon|opensuse-kalpa|opensuse-microos-desktop)
            return 0
            ;;
    esac

    return 1
}

if detect_transactional; then
    IS_TRANSACTIONAL=true
    UPGRADE_LABEL="transactional-update dup"
fi

# ============================================================
#  中斷處理
#
#  v1 的問題：背景執行的套件管理程序在非互動 bash 中會把 SIGINT 設為
#  SIG_IGN（可用 /proc/<pid>/status 的 SigIgn 遮罩驗證），所以 Ctrl+C
#  只會讓「腳本」結束，套件交易仍在以 root 身分進行；而 cleanup 又會
#  立刻 rm -rf 掉那個程序正在寫入的 log 目錄。
#
#  v2.0：追蹤背景子程序，第一次中斷「等它安全結束」，第二次才強制終止，
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
# 套件交易被中途殺掉會留下半殘狀態，所以預設只等待、不強殺。
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

ZYPPER_REFRESH_LOG="$LOG_DIR/zypper-refresh.log"
ZYPPER_UPGRADE_LOG="$LOG_DIR/zypper-upgrade.log"
ZYPPER_VERIFY_LOG="$LOG_DIR/zypper-verify.log"
ZYPPER_EXIT_FILE="$LOG_DIR/zypper-upgrade.exit"
FLATPAK_LOG="$LOG_DIR/flatpak.log"

FAIL_LOG_BASE="$HOME/.local/share/system-update-logs"
FAIL_LOG_DIR="$FAIL_LOG_BASE/$(date +%Y%m%d-%H%M%S)-$$"

LOG_PRESERVED=false

# 只保留最近幾份失敗 log。
# v2.0：只刪「符合本腳本命名格式」的目錄，且跳過 symlink，
#       避免誤刪使用者自己放在同一個目錄下的東西。
prune_fail_logs() {

    [[ -d "$FAIL_LOG_BASE" ]] || return 0

    local -a dirs=()
    local -a sorted=()
    local -a keep=()
    local d i inserted
    local restore_nullglob=false

    shopt -q nullglob && restore_nullglob=true
    shopt -s nullglob
    dirs=( "$FAIL_LOG_BASE"/*/ )
    [[ "$restore_nullglob" == true ]] || shopt -u nullglob

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

    # v2.0：log 檔本身也收緊為 600，不再只依賴目錄權限；
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

ZYPPER_STATUS="SKIP"
FLATPAK_STATUS="SKIP"

ZYPPER_REBOOT_HINT=false
ZYPPER_SELF_UPDATED=false

WARNINGS=()

# ============================================================
#  進度顯示 + 指令執行
# ============================================================

# 允許「資訊性」的 exit code 被視為可接受（例如 zypper refresh 的 106）
TOLERATE_EXIT_CODES=""
LAST_TOLERATED_RC=0

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
        TOLERATE_EXIT_CODES=""
        return 0
    fi

    # v2.0：容忍已知的資訊性 exit code
    if [[ -n "$TOLERATE_EXIT_CODES" && ",$TOLERATE_EXIT_CODES," == *",$status,"* ]]; then
        LAST_TOLERATED_RC="$status"
        TOLERATE_EXIT_CODES=""
        echo -e "${YELLOW}⚠ $title 回報 exit code $status（資訊性狀態，不是失敗）${RESET}"
        record_step "$title" "WARN" "$cmd_str" "$((SECONDS - started))" "exit code $status（資訊性，非失敗）"
        return 0
    fi

    TOLERATE_EXIT_CODES=""

    if [[ "$DRY_RUN" == true ]]; then
        # 模擬模式的失敗通常只是「非 root 無法讀取套件庫」之類的限制，
        # 不代表實際更新會失敗，因此記為警告。
        echo -e "${YELLOW}⚠ $title 在模擬模式下未成功（多為非 root 的限制）${RESET}"
        record_step "$title" "WARN" "$cmd_str" "$((SECONDS - started))" "exit code $status（模擬模式）"
        return "$status"
    fi

    echo -e "${RED}✗ $title 失敗${RESET}"
    record_step "$title" "FAIL" "$cmd_str" "$((SECONDS - started))" "exit code $status"
    return "$status"
}

# ============================================================
#  預先檢查
# ============================================================

echo
echo -e "${BOLD}======================================${RESET}"
echo -e "${BOLD}       openSUSE 系統更新開始${RESET}"
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${BOLD}       （模擬模式，不會變更系統）${RESET}"
fi
echo -e "${BOLD}======================================${RESET}"
echo
echo -e "${BLUE}▶ 系統：${OS_NAME}${RESET}"
echo -e "${BLUE}▶ 升級方式：${UPGRADE_LABEL}${RESET}"

if [[ "$IS_TRANSACTIONAL" == true ]]; then
    echo -e "${YELLOW}▶ 偵測到不可變／交易式系統（根目錄唯讀）${RESET}"
    echo -e "${YELLOW}  更新會套用到「新的快照」，必須重開機才會生效。${RESET}"
fi

echo

# --------- 磁碟空間預檢 ----------
# 核心套件升級時 /boot 或 / 爆滿，是造成系統半殘最常見的原因之一。

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
    echo -e "${YELLOW}  建議先清出空間（例如 sudo zypper clean、移除舊核心）再執行。${RESET}"
    echo

    if [[ "$DRY_RUN" != true && "$ASSUME_YES" != true && -t 0 ]]; then
        printf "%b" "${BOLD}仍要繼續嗎？[y/N] ${RESET}"
        read -r _ans || _ans=""
        case "$_ans" in
            [yY]|[yY][eE][sS]) echo -e "${YELLOW}  繼續執行。${RESET}" ;;
            *)
                echo -e "${YELLOW}  已取消，未做任何變更。${RESET}"
                exit 1
                ;;
        esac
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

# --------- 檢查是否有殘留的 zypper 鎖檔 ----------
#
# v2.0：不再建議使用者手動刪鎖檔。zypper 自己會處理殘留的鎖；
#       而且 PID 可能已被其他程序重用，kill -0 成功也不代表鎖是活的。

if [[ -e /var/run/zypp.pid ]]; then

    ZYPP_PID="$(sudo cat /var/run/zypp.pid 2>/dev/null || true)"

    if [[ "$ZYPP_PID" =~ ^[0-9]+$ ]] && ! sudo kill -0 "$ZYPP_PID" 2>/dev/null; then
        add_warning "發現疑似殘留的 zypper 鎖檔（PID $ZYPP_PID 已不存在）；通常直接執行 zypper 即可，它會自行處理，不建議手動刪除"
    fi

fi

# ============================================================
#  Zypper
# ============================================================

# --------- 檢查 zypper 是否已被其他程序占用 ----------
#
# v2.0：區分三種結果。v1 把「鎖是空的」和「sudo 憑證過期／fuser 執行失敗」
#       都折成「沒被占用」，會在鎖其實還被持有時印出「鎖已釋放」。

# 回傳：0 = 被占用　1 = 確定沒被占用　2 = 無法判定
zypper_lock_state() {

    local rc

    [[ -e /var/run/zypp.pid ]] || return 1

    sudo -n fuser -s /var/run/zypp.pid 2>/dev/null
    rc=$?

    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

if [[ "$ONLY_ZYPPER" == true && "$DRY_RUN" != true ]]; then

    if ! command -v fuser >/dev/null 2>&1; then
        add_warning "找不到 fuser，略過套件鎖檢查（若同時有其他更新在跑，zypper 可能失敗）"
    else

        LOCK_STATE=2
        zypper_lock_state && LOCK_STATE=0 || LOCK_STATE=$?

        if [[ "$LOCK_STATE" -eq 2 ]]; then
            if ensure_sudo; then
                zypper_lock_state && LOCK_STATE=0 || LOCK_STATE=$?
            fi
        fi

        if [[ "$LOCK_STATE" -eq 0 ]]; then

            echo -e "${YELLOW}⚠ 偵測到其他套件管理程序正在執行（zypper／YaST／PackageKit）${RESET}"
            echo -e "${BLUE}▶ 等待鎖釋放（最多 5 分鐘）...${RESET}"

            LOCK_WAITED=0

            while [[ "$LOCK_WAITED" -lt 300 ]]; do

                if ! ensure_sudo; then
                    add_warning "等待套件鎖時無法取得 sudo 權限，無法確認鎖的狀態"
                    LOCK_STATE=2
                    break
                fi

                zypper_lock_state
                LOCK_STATE=$?
                [[ "$LOCK_STATE" -eq 1 ]] && break
                [[ "$LOCK_STATE" -eq 2 ]] && break

                echo -e "  等待中... 已等 ${LOCK_WAITED} 秒（最多 300 秒）"
                sleep 5
                LOCK_WAITED=$((LOCK_WAITED + 5))
            done

            case "$LOCK_STATE" in
                1) echo -e "${GREEN}✓ 鎖已釋放，繼續執行${RESET}" ;;
                0) add_warning "等待逾時，套件鎖仍被占用，Zypper 更新可能失敗" ;;
                2) add_warning "無法判定套件鎖狀態（sudo 或 fuser 失敗），Zypper 更新可能失敗" ;;
            esac

            echo
        fi
    fi
fi

# --------- 升級包裝函式 ----------
#
# v2.0 修正兩件事：
#  1. 自己先確認 sudo 憑證。v1 依賴 run_with_progress 的預檢，但那個預檢
#     只在第一個參數是 "sudo" 時才觸發，而這裡傳入的是包裝函式名稱，
#     所以整份腳本中最久、最關鍵的特權步驟反而沒有預檢。
#  2. zypper 的資訊性 exit code 102／103 代表「更新成功，但有後續動作」。
#     （注意：這兩個碼主要由 patch 交易產生，一般套件更新通常不會出現；
#       真正可靠的「需要重開機」訊號是 /run/reboot-needed。）

zypper_upgrade() {

    ensure_sudo || return 1

    sudo LC_ALL=C zypper --non-interactive "$ZYPPER_UPGRADE_CMD" --auto-agree-with-licenses

    local rc=$?

    echo "$rc" > "$ZYPPER_EXIT_FILE"

    case "$rc" in
        102|103) return 0 ;;
    esac

    return "$rc"
}

# 不可變系統：更新會落在新快照，不會作用到正在執行的系統
transactional_upgrade() {

    ensure_sudo || return 1

    sudo transactional-update dup

    local rc=$?

    echo "$rc" > "$ZYPPER_EXIT_FILE"

    return "$rc"
}

echo -e "${BOLD}[ Zypper ]${RESET}"

PKG_COUNT_BEFORE="$(rpm -qa 2>/dev/null | wc -l)"
[[ "$PKG_COUNT_BEFORE" =~ ^[0-9]+$ ]] || PKG_COUNT_BEFORE=0

if [[ "$ONLY_ZYPPER" != true ]]; then

    ZYPPER_STATUS="SKIP"
    record_step "Zypper" "SKIP" "" "0" "以 --only 排除"

else

    # 注意：zypper refresh 沒有 --dry-run，而且它會寫入 /var/cache/zypp，
    #       所以模擬模式直接略過這一步（見下方）。
    ZYPPER_REFRESH_CMD=(sudo LC_ALL=C zypper --non-interactive refresh)

    if [[ "$DRY_RUN" == true ]]; then
        ZYPPER_UPGRADE_CMD_ARR=(zypper --non-interactive "$ZYPPER_UPGRADE_CMD" --dry-run)
        ZYPPER_VERIFY_CMD=(zypper --non-interactive verify --dry-run)
    else
        ZYPPER_REFRESH_CMD=(sudo LC_ALL=C zypper --non-interactive refresh)
        ZYPPER_UPGRADE_CMD_ARR=(sudo LC_ALL=C zypper --non-interactive "$ZYPPER_UPGRADE_CMD" --auto-agree-with-licenses)
        ZYPPER_VERIFY_CMD=(sudo LC_ALL=C zypper --non-interactive verify)
    fi

    # --------- refresh ----------
    #
    # v2.0：zypper refresh 的 106（ZYPPER_EXIT_INF_REPOS_SKIPPED）是資訊性狀態，
    #       代表「某些套件庫暫時無法 refresh」。v1 把它當成致命錯誤，
    #       導致某個第三方 repo 掛掉時「完全不套用任何安全性更新」。
    #       上游對 update 是容忍的（只有 dup 會 FailIfReposFail），這裡比照辦理。

    if [[ "$ZYPPER_UPGRADE_CMD" == "dup" ]]; then
        TOLERATE_EXIT_CODES=""
    else
        TOLERATE_EXIT_CODES="106"
    fi

    LAST_TOLERATED_RC=0
    REFRESH_OK=false

    if [[ "$DRY_RUN" == true ]]; then

        echo -e "${CYAN}▶ [模擬] 略過 zypper refresh（refresh 沒有 --dry-run，且會寫入快取）${RESET}"
        record_step "zypper refresh" "SKIP" "sudo LC_ALL=C zypper --non-interactive refresh" "0" "模擬模式，略過"
        REFRESH_OK=true

    elif run_with_progress "zypper refresh" "$ZYPPER_REFRESH_LOG" "${ZYPPER_REFRESH_CMD[@]}"; then

        REFRESH_OK=true

        if [[ "$LAST_TOLERATED_RC" -eq 106 ]]; then
            add_warning "有部分套件庫無法 refresh（zypper 回傳 106），已略過它們繼續更新；請檢查是哪個 repo 出問題"
        fi

    else

        REFRESH_OK=false
        ZYPPER_STATUS="FAIL"
        add_warning "zypper refresh 執行失敗"

    fi

    LAST_TOLERATED_RC=0

    # --------- 升級 ----------

    if [[ "$REFRESH_OK" == true ]]; then

        if [[ "$DRY_RUN" == true ]]; then

            if run_with_progress "$UPGRADE_LABEL（模擬）" "$ZYPPER_UPGRADE_LOG" "${ZYPPER_UPGRADE_CMD_ARR[@]}"; then
                ZYPPER_STATUS="OK"
            else
                ZYPPER_STATUS="SKIP"
            fi

        elif [[ "$IS_TRANSACTIONAL" == true ]]; then

            if run_with_progress "$UPGRADE_LABEL" "$ZYPPER_UPGRADE_LOG" transactional_upgrade; then

                ZYPPER_STATUS="OK"

                # 不可變系統的更新只會落在新快照，一定要重開機才會生效。
                # needs-rebooting 不會回報這件事，所以這裡直接強制提示。
                REBOOT_FORCED=true

            else

                ZYPPER_STATUS="FAIL"
                add_warning "$UPGRADE_LABEL 執行失敗"

            fi

        else

            if run_with_progress "$UPGRADE_LABEL" "$ZYPPER_UPGRADE_LOG" zypper_upgrade; then

                ZYPPER_STATUS="OK"

                ZYPPER_RC="$(cat "$ZYPPER_EXIT_FILE" 2>/dev/null || echo 0)"
                [[ "$ZYPPER_RC" =~ ^[0-9]+$ ]] || ZYPPER_RC=0

                case "$ZYPPER_RC" in
                    102) ZYPPER_REBOOT_HINT=true ;;
                    103) ZYPPER_SELF_UPDATED=true ;;
                esac

            else

                ZYPPER_STATUS="FAIL"
                add_warning "$UPGRADE_LABEL 執行失敗"

                echo -e "${BLUE}▶ 嘗試修復套件相依（zypper verify）...${RESET}"

                if run_with_progress "zypper verify" "$ZYPPER_VERIFY_LOG" "${ZYPPER_VERIFY_CMD[@]}"; then
                    echo -e "${YELLOW}  已嘗試修復相依，請確認系統狀態${RESET}"
                else
                    echo -e "${RED}  修復失敗，建議手動執行：sudo zypper verify${RESET}"
                    add_warning "zypper verify 修復失敗，系統可能有相依問題"
                fi

            fi
        fi
    fi

    PKG_COUNT_AFTER="$(rpm -qa 2>/dev/null | wc -l)"
    [[ "$PKG_COUNT_AFTER" =~ ^[0-9]+$ ]] || PKG_COUNT_AFTER="$PKG_COUNT_BEFORE"

    # --------- 檢查 zypper 的 Error（v2.0：不再把每個 Warning 都當成問題） ----------

    if [[ "$DRY_RUN" == true ]]; then
        :   # 模擬模式的 log 內容不代表真實結果，不做警告判定
    elif grep -Eq '^(Error):|^Problem:' "$ZYPPER_REFRESH_LOG" "$ZYPPER_UPGRADE_LOG" 2>/dev/null; then
        add_warning "zypper log 中有 Error，建議檢查詳細資訊"
    elif grep -Eq '^Warning:' "$ZYPPER_REFRESH_LOG" "$ZYPPER_UPGRADE_LOG" 2>/dev/null; then
        _wcount="$(cat "$ZYPPER_REFRESH_LOG" "$ZYPPER_UPGRADE_LOG" 2>/dev/null | grep -cE '^Warning:' || true)"
        [[ "$_wcount" =~ ^[0-9]+$ ]] || _wcount=0
        add_warning "zypper log 中有 ${_wcount} 則警告（需要時再看 log）"
    fi

    echo

fi

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
REBOOT_FORCED="${REBOOT_FORCED:-false}"

# zypper needs-rebooting 不需要 root（它只是檢查 /run/reboot-needed 是否存在，
# 而 libzypp 在非 root 時會直接跳過鎖的取得）。
# v2.0：不再丟棄非 0／102 的結果，才不會把「檢查失敗」誤認為「不需要重開機」。
if command -v zypper >/dev/null 2>&1; then

    zypper --quiet needs-rebooting >/dev/null 2>&1
    ZYPPER_NR_RC=$?

    case "$ZYPPER_NR_RC" in
        0)   ;;
        102) REBOOT_REQUIRED=true ;;
        *)   add_warning "zypper needs-rebooting 回傳非預期狀態 $ZYPPER_NR_RC，無法確認是否需要重開機" ;;
    esac

fi

# 部分版本／工具會在 /run 下留標記檔
if [[ -f /run/reboot-required || -f /run/reboot-needed ]]; then
    REBOOT_REQUIRED=true
fi

if [[ "$ZYPPER_REBOOT_HINT" == true ]]; then
    REBOOT_REQUIRED=true
fi

if [[ "$REBOOT_REQUIRED" == true ]]; then
    add_warning "系統需要重新啟動"
fi

if [[ "$ZYPPER_SELF_UPDATED" == true ]]; then
    add_warning "套件管理員（zypper／libzypp）本身已更新，請再執行一次本腳本以安裝剩餘更新"
fi

# --------- 不再需要的套件（orphaned packages）---------

UNNEEDED_COUNT=0

if command -v zypper >/dev/null 2>&1; then

    UNNEEDED_COUNT="$(
        LC_ALL=C zypper --quiet packages --unneeded 2>/dev/null |
        awk '/ \| / { if (seen++) count++ } END { print count+0 }'
    )"
    [[ "$UNNEEDED_COUNT" =~ ^[0-9]+$ ]] || UNNEEDED_COUNT=0

    if [[ "$UNNEEDED_COUNT" -gt 0 ]]; then
        add_warning "有 $UNNEEDED_COUNT 個套件已不再需要，可用 sudo zypper rm -u 移除"
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
    [[ "$ZYPPER_STATUS" == "FAIL" ]] && ZYPPER_STATUS="SKIP"
    [[ "$FLATPAK_STATUS" == "FAIL" ]] && FLATPAK_STATUS="SKIP"
fi

echo
echo -e "${BOLD}======================================${RESET}"
echo -e "${BOLD}             更新結果${RESET}"
echo -e "${BOLD}======================================${RESET}"

print_status "Zypper" "$ZYPPER_STATUS"
print_status "Flatpak" "$FLATPAK_STATUS"

echo -e "${BOLD}======================================${RESET}"

if [[ "$ZYPPER_STATUS" == "OK" || "$ZYPPER_STATUS" == "PARTIAL" ]]; then
    PKG_DIFF=$(( PKG_COUNT_AFTER - PKG_COUNT_BEFORE ))
    if [[ "$PKG_DIFF" -gt 0 ]]; then
        PKG_DIFF_STR="+$PKG_DIFF"
    else
        PKG_DIFF_STR="$PKG_DIFF"
    fi
    echo -e "已安裝套件數：${PKG_COUNT_BEFORE} → ${PKG_COUNT_AFTER}（${PKG_DIFF_STR}）"
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

if [[ "$REBOOT_FORCED" == true ]]; then

    echo
    echo -e "${YELLOW}${BOLD}🔄 必須重新啟動系統（更新已套用到新快照）：${RESET}"
    echo "   sudo reboot"
    echo -e "${YELLOW}   在重開機之前，正在執行的系統仍然維持舊的套件版本。${RESET}"

elif [[ "$REBOOT_REQUIRED" == true ]]; then

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
#  失敗時顯示 log 並保留完整檔案
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

        grep -E '^(Error):|^Problem:' \
            "$ZYPPER_REFRESH_LOG" \
            "$ZYPPER_UPGRADE_LOG" \
            "$ZYPPER_VERIFY_LOG" \
            2>/dev/null |
            tail -n 30

        # 若沒有符合前綴的錯誤行（例如 %post 失敗），至少列出 log 尾端
        echo
        echo -e "${BOLD}[ Zypper log 尾端 ]${RESET}"
        tail -n 15 "$ZYPPER_UPGRADE_LOG" 2>/dev/null
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
#  清理 zypper 快取（僅在成功時執行）
#  v2.0：改用 zypper clean（只清套件快取），不再用 --all 連 metadata
#        一起清掉，否則下次執行得重新下載全部索引。
# ============================================================

if [[ "$ZYPPER_STATUS" == "OK" || "$ZYPPER_STATUS" == "PARTIAL" ]]; then

    CLEAN_STARTED=$SECONDS

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}▶ [模擬] sudo zypper clean${RESET}"
        record_step "zypper clean" "SKIP" "sudo zypper clean" "0" "模擬模式"
    elif ensure_sudo && sudo zypper clean >/dev/null 2>&1; then
        record_step "zypper clean" "OK" "sudo zypper clean" "$((SECONDS - CLEAN_STARTED))"
    else
        record_step "zypper clean" "WARN" "sudo zypper clean" "$((SECONDS - CLEAN_STARTED))" "清理快取失敗（不影響更新結果）"
        add_warning "zypper clean 失敗（不影響更新結果，只是快取沒有清）"
    fi

fi

# ============================================================
#  本次執行摘要
# ============================================================

print_run_summary

# ============================================================
#  結束前等待
#  v2.0：同時要求 stdout 是終端機，否則 ./script | tee log 還是會停下來等
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

elif [[ "$REBOOT_FORCED" == true ]]; then

    echo
    echo -e "${YELLOW}${BOLD}⚠ 更新已套用到新快照，請重開機使其生效。${RESET}"
    pause_before_exit
    exit 0

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

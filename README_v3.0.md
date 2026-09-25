# Linux_all_update v3.0

v3.0 是既有腳本的修正版，**與 v1／v2.1 並存，不會覆蓋任何舊檔案**。

| v1（保持不變） | v2.1（保留） | v3.0（現行） |
|---|---|---|
| `ubuntu_all_update.sh` | `ubuntu_all_update_v2.1.sh` | `ubuntu_all_update_v3.0.sh` |
| `suse_all_update.sh` | `suse_all_update_v2.1.sh` | `suse_all_update_v3.0.sh` |
| `README.md` | `README_v2.1.md` | `README_v3.0.md`（本文件） |

## v3.0 的變更（相對 v2.1）

v3.0 是 v2.1 加上一項功能，更新邏輯本身不變。

### 1. 結束前新增「本次更新的套件」清單

**原有的顯示項目全部保留**，只是多印一個區塊，列出這次執行
**實際異動**的套件，一行一個方便瀏覽：

```
======================================
           本次更新的套件
======================================

  coreutils                          9.4-3ubuntu6 → 9.4-3ubuntu6.1
  linux-image-generic                6.8.0-45.45 → 6.8.0-51.54
  zstd                               1.5.5+dfsg2-2build1.1（新安裝）

共 3 個套件
```

若本次沒有任何套件異動，則顯示：

```
本次無任何套件更新
```

實作方式：

- **真實執行**：升級前後各取一次「已安裝套件快照」
  （Ubuntu 用 `dpkg-query -W`、SUSE 用 `rpm -qa`），再比對差異。
  這比解析 apt／zypper 的輸出可靠——不受語系、輸出格式或 `--quiet` 影響，
  也能拿到準確的版本變化，且只列出真正有異動的套件。
- **`--dry-run`**：改為解析模擬輸出（apt 的 `Inst … [舊] (新 …)` 行），
  標題顯示為「本次**預計**更新的套件」。

### 2. 結束時的區塊順序調整

結束時的區塊順序改為：

| 順序 | 區塊 | 內容 |
|---|---|---|
| 1 | **本次執行摘要** | 這次跑了哪些指令、各自結果與耗時 |
| 2 | **更新結果** | APT／Zypper／Snap／Flatpak 狀態、已安裝套件數、注意事項、重開機建議，以及失敗時的錯誤詳細資訊 |
| 3 | **本次更新的套件** | 一行一個套件（**最後一個區塊**） |

> `apt autoclean`／`zypper clean` 一併移到摘要之前執行，所以它們也會被列進
> 「本次執行摘要」，不會因為印完摘要才跑而漏掉。

### 3. 一併修正的兩個模擬模式問題

| # | 問題 | 修正 |
|---|---|---|
| 1 | `--dry-run` 時 `apt-get -s update` 仍會嘗試取得 `/var/lib/apt/lists` 的鎖而需要 root，導致後面的模擬升級根本沒跑，套件清單永遠是空的 | 模擬模式直接略過 `apt update`（它只是重新整理索引，不是「更新」本身），讓 `-s upgrade` 能真正跑出預計更新的套件 |
| 2 | 模擬模式的 apt／zypper 指令少了 `LC_ALL=C`，在中文等非英文語系下 `N not upgraded` 的結尾摘要會被翻譯，**kept back／phasing 的偵測會靜默讀到 0**（畫面上就會出現「有 0 個套件暫緩升級」卻列出 11 個套件名稱） | 模擬指令補上 `LC_ALL=C`。真實執行原本就有帶，所以只有 `--dry-run` 受影響 |

### 4. 其他

- `--dry-run` 時，kept back 的偵測結果只做預告（標題為「預計…」），
  **不會**影響 exit code，模擬一律以 0 結束。
- 套件快照若無法取得（例如 `dpkg-query` 不存在），會顯示
  「本次無任何套件更新」並附註無法確認，而不是默默假裝沒有異動。

## 版本沿革

| 版本 | 內容 |
|---|---|
| v1 | 原始版本（`ubuntu_all_update.sh`／`suse_all_update.sh`），保留不動 |
| v2.0 | 修正多項安全性與正確性問題（Ctrl+C 放生特權程序、held-back 誤報、MicroOS 升級機制、zypper 106、鎖檢查 fail-open 等），並新增命令列選項 |
| v2.1 | 相對 v2.0 只改兩處：磁碟空間確認改為 fail-closed、套件鎖狀態先確認 sudo 憑證再判定 |
| v3.0 | 相對 v2.1 新增「本次更新的套件」清單，並修正上述兩個模擬模式問題 |

### v2.1 的變更（相對 v2.0）

| # | 問題 | v2.0 行為 | v2.1 修正 |
|---|---|---|---|
| 1 | 磁碟空間不足時的確認 | 非互動（cron／systemd timer／stdin 被重導向）且沒有 `-y` 時，`-t 0` 不成立 → 既不詢問也不中止，直接在磁碟偏低的狀況下繼續升級（fail-open） | 改為 fail-closed：非互動且沒有 `-y` 一律 `exit 1`；只有 `-y` 才視為使用者明確同意 |
| 2 | 套件鎖狀態判定 | `sudo -n` 憑證過期時回傳 1，與 `fuser` 回報「沒有任何程序持有」的 1 折在同一分支，於是「無法判定」永遠不會觸發 | 函式開頭先單獨執行 `sudo -n true` 確認憑證，失敗即回傳 2（無法判定），交由外層 `ensure_sudo` 重新驗證後再判斷 |

## 快速開始

```bash
chmod +x ubuntu_all_update_v3.0.sh     # 或 suse_all_update_v3.0.sh
./ubuntu_all_update_v3.0.sh --dry-run  # 先看會做什麼，不會變更系統
./ubuntu_all_update_v3.0.sh            # 確認沒問題再實際執行
```

**請不要用 `sudo` 執行。** 腳本會在需要的步驟自行呼叫 `sudo`；以 root 身分執行會讓 `$HOME` 變成 `/root`，失敗 log 寫到錯誤的位置，Flatpak 的使用者層級更新也會失效。腳本開頭會檢查並拒絕執行。

## 命令列選項（v3.0 新增）

| 選項 | 說明 |
|---|---|
| `-h`, `--help` | 顯示說明並結束 |
| `-n`, `--dry-run` | 只模擬，不變更系統 |
| `--only LIST` | 只執行指定項目：`apt,snap,flatpak,all`（Ubuntu）／`zypper,flatpak,all`（SUSE） |
| `-y`, `--yes` | 不等待結尾的「按 Enter」 |
| `--keep-logs N` | 保留最近 N 份失敗 log（預設 10） |
| `--no-color` | 關閉顏色 |
| `--version` | 顯示版本 |

v1 會**完全忽略**命令列參數，所以 `./ubuntu_all_update.sh --help` 會直接開始更新系統。v3.0 會正確處理，未知選項以 exit code 2 結束。

## 修正清單

### 安全性與正確性

#### 1. Ctrl+C 不再放生正在執行的特權更新（嚴重）

v1 以 `"$@" ... &` 背景執行 `sudo apt upgrade`／`zypper dup`。在非互動 bash 中，**背景子程序會把 SIGINT 設為 `SIG_IGN`**，所以 Ctrl+C 只會結束腳本本身，套件交易仍以 root 身分繼續；而 `cleanup` 接著就 `rm -rf` 掉那個程序正在寫入的 log 目錄，使用者卻看到提示字元回來、以為已經中止。

可用 `/proc/<pid>/status` 的 `SigIgn` 遮罩驗證（`0x1006` 含 bit 1 = SIGINT）：

```
SigIgn: 0000000001001006     ← 非互動 bash 的背景子程序：SIGINT 被忽略
SigIgn: 0000000001001000     ← 開了 set -m（job control）：SIGINT 未被忽略
```

v3.0 追蹤 `CHILD_PID`，第一次中斷會**等套件交易安全結束**（強殺 dpkg 交易會留下半殘狀態），第二次中斷才強制終止；`cleanup` 也一定會先確認子程序消失才刪目錄。

#### 2. 「有套件沒真的升級」不再被誤報為全部完成（嚴重）

v1 只用 `grep -Eq '^(W:|E:)|^dpkg: error'` 判斷 APT 是否有問題。但 `apt upgrade` 在**有套件被 kept back 或因 phased update 延後時，exit code 仍是 0**，輸出也不含 `W:`／`E:`。

實測（Ubuntu 24.04）：

```
$ LC_ALL=C apt-get -s upgrade
The following upgrades have been deferred due to phasing:
  dnsmasq-base
0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.
rc=0
```

v1 的樣式對此**完全沒有反應**，會印出「✅ 所有可用的更新項目皆已完成」。

v3.0 會解析 `N not upgraded`，並區分兩種情況：

- **kept back**（需要 `apt full-upgrade`）→ 列出套件名稱、狀態顯示「⚠ 部分完成」、**exit code 1**
- **phased update**（Ubuntu 刻意的分批推送，會自行生效）→ 列為注意事項，exit code 0

#### 3. 不可變系統（MicroOS／Aeon／Kalpa）改用正確的升級機制（嚴重）

v1 把這些系統與 Tumbleweed 一起歸類為「滾動版本」而執行 `zypper dup`。這是不對的：它們的根檔案系統是唯讀的，`zypper` 的 `dup` 與 `update` 都帶有 `NeedsWritableRoot` 條件。

依官方 `zypper(8)`：

> **Transactional systems** — On a transactional system where the root filesystem is mounted read-only, *zypper* commands that modify the system cannot be executed directly. If the system provides a *transactional-wrapper* utility, *zypper* will automatically attempt to invoke it. The wrapper transparently executes the *zypper* command **within a new, writable snapshot**…

結果是：舊版 zypper 直接以 exit 5 拒絕（然後 v1 建議的 `zypper verify` 同樣無效）；新版 zypper 會把更新寫進**新快照**，正在執行的系統完全沒變，而且 `needs-rebooting` 不會回報需要重開機——使用者因此以為機器已經補好了。

v3.0 以「根目錄唯讀 + 有 `transactional-update`」偵測這類系統（判斷方式參考 zypper 的 `isTransactionalSystem()`），改用 `sudo transactional-update dup`，並且**一律強制提醒必須重開機才會生效**。

> 注意：`opensuse-microos`／`aeon`／`kalpa` 的 `/etc/os-release` `ID` 值未經實機驗證，因此偵測以「根目錄唯讀」為主、`ID` 僅作為備援判斷。

#### 4. zypper refresh 的資訊性 exit code 106 不再中斷整個更新（中）

`106 = ZYPPER_EXIT_INF_REPOS_SKIPPED`，代表「某些套件庫暫時無法 refresh」。v1 把任何非零都當成致命錯誤，於是**某個第三方 repo 掛掉時（Packman 鏡像異常、GPG 金鑰過期、暫時斷網），完全不會套用任何安全性更新**。

上游對 `update` 是容忍的（只有 `dup` 會 `FailIfReposFail`），v3.0 比照辦理：`update` 路徑接受 `0|106` 並警告是哪個 repo 出問題；`dup` 路徑維持嚴格。

#### 5. 套件鎖檢查不再「fail open」（中）

v1：

```bash
if sudo -n fuser -s "$lockfile" 2>/dev/null; then return 0; fi
return 1        # ← sudo 憑證過期時也走這裡
```

`fuser -s` 回 0（被持有）、1（空閒）、>1（錯誤）；`sudo -n` 在憑證過期時也回非零。兩者都被折成「沒被占用」。等待迴圈最多跑 300 秒，而 openSUSE 的 sudo `timestamp_timeout` 預設就是 5 分鐘，憑證可能在等待期間過期 → 印出「✓ 鎖已釋放」但鎖其實還在 → 更新硬生生失敗。

v3.0 區分三種結果（0 被占用／1 空閒／2 無法判定），等待期間每輪都重新確認憑證，無法判定時明確警告而不是假裝沒事。

**v3.0 補強**：v2.0 的 `case` 其實仍把 `sudo -n` 的失敗（exit code 1）與 `fuser` 回報「沒有任何程序持有」（也是 exit code 1）折在同一個分支，所以「無法判定」從來沒有被觸發過。v3.0 在函式開頭先單獨確認 sudo 憑證，失敗就直接回傳 2。

#### 6. 最主要的特權步驟恢復 sudo 預檢（中）

v1 的 `run_with_progress` 只在第一個參數是 `sudo` 時才先驗證憑證，但升級步驟傳入的是包裝函式 `zypper_upgrade`（`sudo` 在函式內部），所以**整份腳本中最久的特權步驟反而沒有預檢**。v3.0 在包裝函式內自行呼叫 `ensure_sudo`。

#### 7. 失敗不再被 exit code 忽略（中）

`dpkg --configure -a`、`apt autoclean`、`zypper clean` 的失敗在 v1 不會進 `WARNINGS`、也不影響 exit code，於是會出現「上面列著 ❌，下面卻說 ✅ 全部完成」的矛盾。v3.0 新增 `WARN` 狀態：真正的失敗影響 exit code，快取清理這類非致命問題則明確標示為警告。

#### 8. 其他

- **`--dry-run` 的失敗不再誤判**：模擬模式的失敗多為「非 root 無法讀取套件庫」的限制，記為警告而非失敗，exit code 維持 0。
- **`W:` 不再等於有問題**：v1 的 `^(W:|E:)` 幾乎每次執行都命中無害警告（例如 `W: Key is stored in legacy trusted.gpg keyring`），讓使用者對警告區塊麻木。v3.0 只對 `E:`／`dpkg: error`／`Error:`／`Problem:` 告警，`W:` 改為計數提示。
- **失敗 log 權限**：log 檔本身也收緊為 `600`（v1 只靠目錄 700；若 umask 是 0002，檔案是 664）。同時檢查 `cp` 是否真的成功，不再「什麼都沒複製到也回報已保留」。
- **log 清理更保守**：只刪符合 `YYYYmmdd-HHMMSS-PID` 命名格式的目錄並跳過 symlink，不會誤刪使用者自己放在 `~/.local/share/system-update-logs/` 的東西。目錄名加入 `$$`，避免同一秒執行兩次互相覆蓋。
- **`| tee log` 的結尾暫停**：v1 只看 stdin，所以在管線中仍會停下來等 Enter（與 README 描述不符）。v3.0 改為同時要求 stdout 是終端機。
- **PATH 強化**：把系統目錄放到 PATH 最前面，避免有人把假的 `sudo` 放在較前面騙取密碼（`sudo` 的 `secure_path` 只保護「sudo 執行的指令」，不保護 `sudo` 本身）。
- **磁碟空間預檢**：在任何變更之前檢查 `/`（與獨立的 `/boot`），空間偏低時明確警告並詢問是否繼續。**非互動執行且未指定 `-y` 時一律中止**（v3.0 修正：v2.0 會因為 `-t 0` 不成立而「既沒問也沒擋」，等於在磁碟偏低時照樣升級）。
- **環境檢查**：Ubuntu 版會確認 `apt-get`／`dpkg` 存在；兩版都會在缺少 `fuser` 時明確警告，而不是靜默略過鎖檢查。
- **`zypper clean --all` → `zypper clean`**：不再連 metadata 快取一起清掉，避免下次執行重新下載全部索引。
- **不再建議手動刪 zypper 鎖檔**：PID 可能被重用，`kill -0` 成功不代表鎖是活的；zypper 自己會處理殘留鎖。
- **訊號結束碼正確**：TERM → 143、HUP → 129（v1 一律回 130）。
- **`zypper needs-rebooting` 的失敗不再被吞掉**：非 0／102 的結果會明確警告，而不是被當成「不需要重開機」。

### README.md 中三處與實際行為不符的敘述

1. **zypper 102／103 的說明誇大了。** 上游 `src/Summary.h` 註解指出：觸發 `ZYPPER_EXIT_INF_REBOOT_NEEDED` 的 `needMachineReboot` **只考慮 patch**，套件更新只會產生 summary hint、不會造成非零回傳。把 102／103 當成功是對的，但對 `update`／`dup` 而言幾乎是死碼。真正可靠的訊號是 `/run/reboot-needed`，而腳本有檢查，所以偵測仍然有效。v3.0 保留了 102／103 的處理並在註解中說明這一點。
2. **`| tee log` 仍會暫停**（見上方第 8 點）。
3. **`--help` 會直接開始更新**（v1 忽略所有參數）。

## 已知的設計取捨

這些是刻意保留的：

- **鎖檔檢查存在 check-then-act 競態**：`apt_lock_state`／`zypper_lock_state` 在「檢查」與「實際執行」之間，鎖的狀態理論上可能改變。這只是提前等待的禮貌性檢查，腳本不重複實作鎖定機制，真正的互斥仍由 `apt`／`zypper` 底層保證。（這與上面第 5 點的 fail-open 是兩回事：那個是實作 bug，這個是設計取捨。）
- **`/etc/os-release` 的讀取**：以官方建議的 `. /etc/os-release` 在 subshell 中取值。若該檔權限被竄改成可寫，代表系統早已被入侵，不在威脅模型內。
- **失敗 log 的清理不解析外部指令輸出**：以純 bash 內建比較（`-nt`）排序後刪除。
- **磁碟空間門檻是經驗值**（`/` 1 GB、`/boot` 256 MB），不同發行版／檔案系統可能需要調整。

## 為什麼沒有拆出共用的函式庫

v1 的兩支腳本有約 458 行完全重複（`diff` 實測），重複的修正很容易只落在其中一支。抽成 `lib/common.sh` 是直覺的解法，但**這裡刻意不做**：

README 的整個安全模型建立在「下載單一檔案 → 從頭到尾讀過 → 再執行」之上。若改成 `source` 一個外部檔案，會破壞這個可審計性，而且等於多出一個可以被單獨竄改的供應鏈環節——對一支會動用 `sudo` 的腳本來說，這個代價比重複高。

兩支 v3.0 腳本因此維持**各自獨立、可單檔下載執行**。

## 安全設計（沿用並強化）

- **不做破壞性動作**：不會自動執行 `apt autoremove`／`zypper rm -u`，只在最後提示
- **保留原有設定檔**：Ubuntu 版使用 `--force-confdef --force-confold`
- **失敗時保留完整 log**：複製到 `~/.local/share/system-update-logs/<時間戳>-<PID>/`，最多保留最近 10 份；連 Ctrl+C 中斷也會保留
- **log 目錄 700、log 檔 600**：目錄在 `umask 077` 的子 shell 中建立，從誕生那一刻就是 700，不存在先寬鬆後收緊的窗口
- **不隱藏密碼提示**：sudo 憑證過期時會當著使用者的面重新詢問
- **拒絕以 root 執行**

## 取得腳本的方式

**不要**用 `curl | bash`。這是一個個人專案，沒有 GPG 簽章或雜湊校驗，任何中間人攔截、CDN 被竄改或帳號被盜的情境，都可能讓你執行到被替換過的內容——而這支腳本會用到 `sudo`。

建議流程：

1. 先在瀏覽器把腳本內容從頭到尾看過一遍（特別是 `sudo` 那幾行）
2. 下載到本機後再執行：

   ```bash
   wget https://raw.githubusercontent.com/itmanapp/Linux_all_update/main/ubuntu_all_update_v3.0.sh
   less ubuntu_all_update_v3.0.sh
   chmod +x ubuntu_all_update_v3.0.sh
   ./ubuntu_all_update_v3.0.sh --dry-run
   ```

3. 想更嚴謹的話，自行計算並記錄雜湊再比對：

   ```bash
   sha256sum ubuntu_all_update_v3.0.sh
   ```

## 結束碼

| 代碼 | 意義 |
|---|---|
| 0 | 全部成功（可能含非致命警告） |
| 1 | 有步驟失敗，或仍有套件被 kept back 而未升級 |
| 2 | 命令列參數錯誤 |
| 130 / 143 / 129 | 被 Ctrl+C / TERM / HUP 中斷 |

## 靜態檢查

兩支 v3.0 腳本都通過：

```bash
bash -n ubuntu_all_update_v3.0.sh
shellcheck -S warning ubuntu_all_update_v3.0.sh
```

CI 設定見 `.github/workflows/shellcheck.yml`。

## 注意事項

- 腳本需要在互動式終端機中執行（會用到 `sudo` 密碼提示）
- 在管道或排程中執行時，進度動畫與結尾暫停會自動停用
- Ubuntu 版的 `NEEDRESTART_MODE=a` 只有在安裝 `needrestart` 時才有效
- `flatpak update` 以呼叫者身分執行；系統層級的 Flatpak 安裝可能需要 root／polkit，這部分未經實機驗證

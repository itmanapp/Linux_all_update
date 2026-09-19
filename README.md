# Linux_all_update

Linux 系統更新腳本。一鍵完成套件庫重新整理、系統升級與 Flatpak 更新，並在需要時提醒你重新開機。

## 腳本一覽

| 檔案 | 適用系統 | 套件管理 | Flatpak |
|---|---|---|---|
| `ubuntu_all_update.sh` | Ubuntu / Debian 系 | `apt` + `snap` | ✅ |
| `suse_all_update.sh` | openSUSE Leap／Tumbleweed／SLE | `zypper` | ✅ |

## 使用方式

```bash
chmod +x ubuntu_all_update.sh   # 或 suse_all_update.sh
./ubuntu_all_update.sh
```

**請不要用 `sudo ./ubuntu_all_update.sh` 執行。** 腳本會在需要的步驟自行呼叫 `sudo`；以 root 身分執行會讓 `$HOME` 變成 `/root`，導致失敗 log 寫到錯誤位置，Flatpak 的使用者層級更新也會失效。腳本開頭有檢查，會直接拒絕執行。

## ⚠️ 取得腳本的方式：請先讀過原始碼

**不要**用 `curl | bash` 這種方式執行：

```bash
# ❌ 不建議
curl -fsSL https://raw.githubusercontent.com/itmanapp/Linux_all_update/main/ubuntu_all_update.sh | bash
```

`curl | bash` 把「下載」和「以你的權限執行」綁在一起。這是一個**個人專案，沒有 GPG 簽章或雜湊校驗**，任何中間人攔截、CDN 被竄改或帳號被盜的情境，都可能讓你執行到被替換過的內容——而這支腳本會用到 `sudo`。

建議流程：

1. **先在瀏覽器把腳本內容從頭到尾看過一遍**（特別是 `sudo` 那幾行）
2. 下載到本機後再執行：

   ```bash
   wget https://raw.githubusercontent.com/itmanapp/Linux_all_update/main/ubuntu_all_update.sh
   less ubuntu_all_update.sh        # 看過再做
   chmod +x ubuntu_all_update.sh
   ./ubuntu_all_update.sh
   ```

3. 想更嚴謹的話，自行計算並記錄雜湊再比對：

   ```bash
   sha256sum ubuntu_all_update.sh
   ```

## 腳本會做什麼

1. 檢查 sudo 權限，失敗就中止
2. 檢查套件管理員是否被其他程序鎖住（背景更新、YaST／PackageKit），必要時等待
3. 重新整理套件庫
   - Ubuntu：`apt update`
   - openSUSE：`zypper refresh`
4. 系統升級
   - Ubuntu：`apt upgrade`（不會為了升級而移除套件）
   - openSUSE Leap／SLE：`zypper update`
   - openSUSE Tumbleweed／Slowroll：`zypper dup`（滾動版本需完整升級）
5. 更新 Flatpak（若已安裝），保留即時下載進度與速率
6. 更新 Snap（僅 Ubuntu 版；未安裝則略過）
7. 檢查是否需要重開機
   - Ubuntu：`/run/reboot-required`
   - openSUSE：`zypper needs-rebooting`（回傳 102 代表建議重開機）＋ `/run/reboot-needed`
8. 列出已不再需要的套件（僅提示，不會自動移除）
9. 升級成功時清理套件快取

### 關於 zypper 的資訊性 exit code

`zypper update`／`dup` 在**成功**套用特定 patch 後，可能回傳非 0 的資訊性 exit code（見 `zypper(8)` 的 EXIT CODES）：

| code | 名稱 | 意義 | 腳本處理 |
|---|---|---|---|
| 102 | `ZYPPER_EXIT_INF_REBOOT_NEEDED` | 更新成功，但建議重開機 | 視為成功，並在結果中加入重開機建議 |
| 103 | `ZYPPER_EXIT_INF_RESTART_NEEDED` | 更新成功，但套件管理員本身被更新，需再執行一次 | 視為成功，並提示你再跑一次本腳本 |

（`103` **不是**「服務需要重啟」——那是由 `zypper ps` 判斷的另一件事。）

## 安全設計

- **不做破壞性動作**：不會自動執行 `apt autoremove`／`zypper rm -u`，只在最後提示你自己決定
- **保留原有設定檔**：Ubuntu 版升級時使用 `--force-confdef --force-confold`，不覆蓋你改過的設定
- **失敗時保留完整 log**：複製到 `~/.local/share/system-update-logs/<時間戳>/`，最多保留最近 10 份；連 Ctrl+C 中斷也會保留
- **log 目錄權限收緊為 `700`**：log 內含已安裝套件與版本清單（屬於系統指紋資訊，可用來鎖定已知漏洞版本）。目錄是在 `umask 077` 的子 shell 中建立，**從誕生那一刻就是 700**，不存在「先以寬鬆權限建立、之後才補 chmod」的短暫窗口；同時對既有目錄補上 `chmod 700`，即使先前的執行留下寬鬆權限也會被修正。其他本機使用者無法讀取。
- **不隱藏密碼提示**：sudo 憑證過期時會當著你的面重新詢問，不會把提示寫進 log 讓畫面看起來像當機
- **結束不關視窗**：在終端機中執行時，結尾會等你按 Enter 才關閉

## 已知的設計取捨

這些是刻意保留、而非疏漏，記錄下來供審閱者參考：

- **鎖檔檢查存在 check-then-act 競態**：`apt_lock_held`／`zypper_lock_held` 在「檢查」與「實際執行」之間，鎖的狀態理論上可能改變。這只是提前等待的禮貌性檢查，腳本**不重複實作鎖定機制**，真正的互斥仍由 `apt`／`zypper` 底層保證。影響僅止於使用體驗，不涉及安全性。
- **`/etc/os-release` 的讀取**：以官方建議的 `. /etc/os-release` 在 subshell 中取值，不污染外部環境。若該檔權限被竄改成可寫，代表系統早已被入侵，不在這支腳本的威脅模型內。
- **失敗 log 的清理不解析外部指令輸出**：以純 bash 內建比較（`-nt`）排序後刪除，避開 `ls | while read` 在檔名含空白或換行時的解析脆弱性。

## 注意事項

- 腳本需要在互動式終端機中執行（會用到 `sudo` 密碼提示與結尾的暫停）
- 在管道或排程中執行（例如 `./ubuntu_all_update.sh | tee log`）時，進度動畫與結尾暫停會自動停用，不會卡住
- Ubuntu 版的 `NEEDRESTART_MODE=a` 只有在安裝 `needrestart` 時才有效；腳本啟動時會告訴你目前的狀態
